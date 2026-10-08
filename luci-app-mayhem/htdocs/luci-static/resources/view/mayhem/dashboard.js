'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require mayhem.common as mh';
'require mayhem.diag as diag';

// The dashboard: three small widgets and every proxy section as a box of
// server tiles grouped by where they come from (a subscription with its
// traffic and expiry, links, interfaces), like Happ shows subscriptions. The
// buttons sit together at the top right of the first section: checks,
// updates, diagnostics and logs (in dialogs), restart, stop, autostart.

const callDashboard = rpc.declare({ object: 'luci.mayhem', method: 'dashboard', expect: { '': {} } });
const callAction = rpc.declare({ object: 'luci.mayhem', method: 'action', params: [ 'name' ], expect: { '': {} } });
const callSelect = rpc.declare({ object: 'luci.mayhem', method: 'select_node', params: [ 'section', 'tag' ], expect: { '': {} } });
const callProbe = rpc.declare({ object: 'luci.mayhem', method: 'probe', params: [ 'tag', 'method' ], expect: { '': {} } });
const callSubUpdate = rpc.declare({ object: 'luci.mayhem', method: 'sub_update', params: [ 'name' ], expect: { '': {} } });
const callExitInfo = rpc.declare({ object: 'luci.mayhem', method: 'exit_info', params: [ 'section', 'lang' ], expect: { '': {} } });
const callSetPing = rpc.declare({ object: 'luci.mayhem', method: 'set_ping_method', params: [ 'method' ], expect: { '': {} } });

const PROBE_PARALLEL = 4;
const DAY = 86400;
const PROBES = [ [ 'url', _('URL test') ], [ 'tcp', _('TCP ping') ], [ 'icmp', _('ICMP ping') ] ];

const CSS = `
.mh-head { display:flex; align-items:center; justify-content:space-between; gap:10px; flex-wrap:wrap; }
.mh-head .mh-grow { flex:1 1 auto; }
.mh-widgets { display:grid; grid-template-columns:repeat(3, 1fr); grid-gap:10px; }
@media (max-width: 700px) { .mh-widgets { grid-template-columns:1fr; } }
.mh-widget-row { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.mh-whead { display:flex; justify-content:space-between; align-items:baseline; gap:8px; }
.mh-split { display:grid; grid-template-columns:1fr 240px; grid-column-gap:12px; align-items:start; }
@media (max-width: 700px) { .mh-split { grid-template-columns:1fr; grid-row-gap:10px; } }
.mh-side { display:grid; grid-template-columns:1fr; grid-row-gap:6px; }
.mh-side > .btn, .mh-side > select { width:100%; height:30px; line-height:28px; min-height:0; margin:0; padding:0 10px; font-size:90%; box-sizing:border-box; }
.mh-side > .btn .mh-icon { width:14px; height:14px; }
.mh-side-gap { height:4px; }

.mh-group { margin-top:10px; }
.mh-ghead { display:flex; align-items:center; flex-wrap:wrap; gap:4px 12px; margin-bottom:6px; }
.mh-bar { display:inline-block; width:90px; height:6px; border-radius:3px; background:var(--background-color-low, lightgray); vertical-align:middle; overflow:hidden; }
.mh-bar > span { display:block; height:100%; background:var(--primary-color-high, dodgerblue); }
.mh-bar.mh-full > span { background:var(--error-color-medium, red); }
.mh-tile { border:2px solid var(--background-color-low, lightgray); border-radius:4px; padding:8px 10px; transition:border .2s ease; min-width:0; }
.mh-tile b { display:block; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.mh-tile--pick { cursor:pointer; }
.mh-tile--pick:hover { border-color:var(--primary-color-high, dodgerblue); }
.mh-tile--active { border-color:var(--success-color-medium, green); }
.mh-tile-foot { display:flex; justify-content:space-between; margin-top:6px; gap:6px; }
.mh-alert { display:grid; grid-template-columns:24px 1fr auto; grid-column-gap:10px; align-items:center; }
.mh-alert ul { margin:4px 0 0; padding-left:18px; }
.mh-ghead .btn { padding:0 8px; line-height:22px; min-height:0; }
.mh-ghead > .btn:last-child { margin-left:auto; }
`;

function rate(n) {
	return n == null ? '—' : _('%s/s').format(mh.bytes(n));
}

const PROTOCOLS = {
	vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', shadowsocks: 'Shadowsocks', socks: 'SOCKS', http: 'HTTP',
	hysteria: 'Hysteria2', hysteria2: 'Hysteria2', wireguard: 'WireGuard', freedom: 'Freedom'
};

function protocolName(p) {
	return p === 'interface' ? _('Tunnel') : (PROTOCOLS[p] || (p ? p.charAt(0).toUpperCase() + p.slice(1) : '?'));
}

function latencyClass(v) {
	return v < 400 ? 'mh-ok' : (v < 1000 ? 'mh-warn' : 'mh-fail');
}

function pageLang() {
	return document.documentElement.getAttribute('lang') || (L.env && L.env.lang) || navigator.language || 'en';
}

// Flag emoji of a country: the two letters of its code as regional indicators.
function flag(cc) {
	if (!/^[A-Z]{2}$/.test(cc || ''))
		return '';

	return String.fromCodePoint(0x1F1E6 + cc.charCodeAt(0) - 65, 0x1F1E6 + cc.charCodeAt(1) - 65);
}

// Country name in the language of the page; the service's name otherwise.
function countryName(cc, fallback) {
	try {
		return new Intl.DisplayNames([ pageLang() ], { type: 'region' }).of(cc) || fallback;
	}
	catch (e) {
		return fallback;
	}
}

// Languages the geo services know city names in.
function geoLang() {
	const l = pageLang().replace('_', '-');
	const known = [ 'en', 'de', 'es', 'fr', 'ja', 'pt-BR', 'ru', 'zh-CN' ];

	return known.indexOf(l) >= 0 ? l : (known.indexOf(l.split('-')[0]) >= 0 ? l.split('-')[0] : 'en');
}

const MODES = {
	auto: _('Automatic: the fastest by URL test'),
	manual: _('Manual choice'),
	single: _('One server')
};

return view.extend({
	data: null,
	speed: null,
	probes: {},
	busy: {},
	method: 'url',
	conn: null,		// ping and exit of the default section, checked on demand

	load() {
		return callDashboard();
	},

	update(d) {
		if (this.data && d.time > this.data.time) {
			const dt = d.time - this.data.time;
			const diff = (a, b) => Math.max(0, (a - b) / dt);

			const all = (x) => x.totals.all || { up: 0, down: 0 };

			this.speed = {
				up: diff(all(d).up, all(this.data).up),
				down: diff(all(d).down, all(this.data).down)
			};
		}

		this.data = d;
		this.redraw();
	},

	redraw() {
		const body = document.getElementById('mayhem-body');

		if (body)
			body.replaceChildren(...this.renderBody(this.data));
	},

	refresh() {
		return callDashboard().then((d) => this.update(d));
	},

	act(name) {
		return callAction(name).then(() => this.refresh());
	},

	select(section, tag) {
		return callSelect(section, tag).then((r) => {
			if (r.error)
				ui.addNotification(null, E('p', r.error), 'error');

			return this.refresh();
		}).then(() => {
			if (section === this.data.default_section)
				this.checkConnection();
		});
	},

	// Ping and external address of the default section: once when the page
	// opens, after a server change and with the latency test. Never polled.
	checkConnection() {
		const d = this.data;
		const sec = (d.sections || []).find((s) => s.name === d.default_section);

		if (!sec || !d.running) {
			this.conn = null;
			this.redraw();
			return Promise.resolve();
		}

		const conn = this.conn = { section: sec.name, busy: true };
		const method = this.method;

		this.redraw();

		const ping = sec.active
			? callProbe(sec.active, method).then((r) => { conn.ms = r.ms; conn.pingError = r.error; })
			: Promise.resolve();
		const exit = callExitInfo(sec.name, geoLang()).then((r) => { conn.exit = r; });

		return Promise.all([ ping, exit ]).catch(() => {}).finally(() => {
			conn.busy = false;

			if (this.conn === conn)
				this.redraw();
		});
	},

	setMethod(m) {
		this.method = m;
		callSetPing(m);
	},

	// Checks every server of the section with the chosen method, a few at a time.
	probeSection(sec) {
		const method = this.method;
		const queue = sec.nodes.slice();
		const key = 'probe:' + sec.name;

		if (this.busy[key])
			return Promise.resolve();

		this.busy[key] = true;
		this.redraw();

		const worker = () => {
			const n = queue.shift();

			if (!n)
				return Promise.resolve();

			return callProbe(n.tag, method).then((r) => {
				this.probes[n.tag] = { method: method, value: (r.ms != null) ? r.ms : (r.error || 'error') };
				this.redraw();
			}).then(worker);
		};

		const workers = [];

		for (let i = 0; i < PROBE_PARALLEL; i++)
			workers.push(worker());

		return Promise.all(workers).finally(() => {
			delete this.busy[key];
			this.redraw();
		});
	},

	probeAll(sections) {
		this.busy.probeAll = true;
		this.redraw();

		return Promise.all(sections.map((s) => this.probeSection(s)).concat([ this.checkConnection() ])).finally(() => {
			delete this.busy.probeAll;
			this.redraw();
		});
	},

	// Downloads the given subscriptions again, one after another.
	updateSubs(key, names) {
		this.busy[key] = true;
		this.redraw();

		let p = Promise.resolve();

		for (const name of names)
			p = p.then(() => callSubUpdate(name)).then((r) => {
				const res = (r.results || [])[0];

				if (r.error || (res && !res.ok))
					ui.addNotification(null, E('p', _('Subscription %s: %s').format(name, r.error || res.error)), 'error');
			});

		return p.finally(() => {
			delete this.busy[key];
			return this.refresh();
		});
	},

	// --- widgets -----------------------------------------------------------------

	widget(title, rows, note) {
		return E('div', { 'class': 'mh-box' }, [
			E('div', { 'class': 'mh-whead' }, [ E('span', { 'class': 'mh-title' }, title), note ? E('span', { 'class': 'mh-muted mh-small' }, note) : '' ])
		].concat(rows.map((r) => E('div', { 'class': 'mh-widget-row', 'title': r[0] + ': ' + (r[3] || r[1]) }, [
			E('span', { 'class': 'mh-muted' }, r[0] + ': '),
			E('span', { 'class': r[2] || '' }, r[1])
		]))));
	},

	connectionRows(d, working) {
		const c = this.conn;
		const sp = this.speed && working ? this.speed : null;
		const rows = [
			[ _('Incoming'), sp ? rate(sp.down) : '—' ],
			[ _('Outgoing'), sp ? rate(sp.up) : '—' ]
		];
		const wait = '…';

		if (!c) {
			rows.push([ _('Ping time'), '—' ], [ _('External IP'), '—' ], [ _('Location'), '—' ]);
			return rows;
		}

		if (c.ms != null)
			rows.push([ _('Ping time'), _('%d ms').format(c.ms), latencyClass(c.ms) ]);
		else
			rows.push([ _('Ping time'), c.busy ? wait : _('No answer'), c.busy ? 'mh-muted' : 'mh-fail', c.pingError ]);

		const x = c.exit || {};

		if (x.ip) {
			const f = flag(x.country_code);
			const place = [ x.country_code ? countryName(x.country_code, x.country) : x.country, x.city ].filter((v) => v).join(', ');

			rows.push([ _('External IP'), (f ? f + ' ' : '') + x.ip ]);
			rows.push([ _('Location'), place || '—' ]);
		}
		else {
			rows.push([ _('External IP'), c.busy ? wait : _('No answer'), c.busy ? 'mh-muted' : 'mh-fail', x.error ]);
			rows.push([ _('Location'), c.busy ? wait : '—', 'mh-muted' ]);
		}

		return rows;
	},

	renderWidgets(d) {
		const working = d.running && d.active;
		const svc = !d.enabled ? [ '✘ ' + _('Turned off'), 'mh-muted' ]
			: working ? [ '✔ ' + _('Works'), 'mh-ok' ]
			: d.running ? [ '… ' + _('Starting…'), 'mh-warn' ]
			: [ '✘ ' + _('Does not work'), 'mh-fail' ];
		const xray = !d.xray ? [ '✘ ' + _('Not installed'), 'mh-fail' ]
			: d.running ? [ '✔ ' + _('Works'), 'mh-ok' ]
			: [ '✘ ' + _('Does not work'), 'mh-fail' ];

		return E('div', { 'class': 'mh-widgets' }, [
			this.widget(_('Connection state'), this.connectionRows(d, working), this.conn ? this.conn.section : ''),
			this.widget(_('System'), [
				[ _('Router'), d.model || '—' ],
				[ _('OS'), d.system || '—' ],
				[ 'Mayhem', d.version || '—' ],
				[ 'Xray', d.xray || '—' ]
			]),
			this.widget(_('Services'), [
				[ 'Mayhem', svc[0], svc[1] ],
				[ 'Xray', xray[0], xray[1] ],
				[ 'Dnsmasq', d.dnsmasq ? '✔ ' + _('Works') : '✘ ' + _('Does not work'), d.dnsmasq ? 'mh-ok' : 'mh-fail' ],
				[ _('Xray memory'), d.rss_kb ? mh.bytes(d.rss_kb * 1024) : '—' ]
			])
		]);
	},

	// Configuration errors stop xray: they stay in sight. Warnings are on the
	// diagnostics page.
	renderAlert(d) {
		const errors = ((d.status || {}).errors || []).slice();

		if (!d.xray)
			errors.push(_('Xray is not installed: run "mayhem xray-install"'));

		if (!d.enabled)
			return E('div', { 'class': 'mh-box mh-alert' }, [
				E('span', { 'class': 'mh-muted' }, mh.icon('circle-idle')),
				E('div', [ E('b', _('Mayhem is turned off')), E('div', { 'class': 'mh-muted mh-small' }, _('All traffic goes direct.')) ]),
				mh.button({ icon: 'play', cls: 'cbi-button-positive', text: _('Enable'), click: ui.createHandlerFn(this, 'act', 'enable') })
			]);

		if (!errors.length)
			return '';

		return E('div', { 'class': 'mh-box mh-box--fail mh-alert mh-fail' }, [
			mh.icon('circle-x'),
			E('div', [
				E('b', _('Mayhem cannot work like this')),
				E('ul', { 'class': 'mh-small' }, errors.map((m) => E('li', m)))
			]),
			E('a', { 'class': 'mh-small', 'href': '#', 'click': (ev) => { ev.preventDefault(); diag.diagnostics(true); } }, _('Diagnostics'))
		]);
	},

	// --- servers ------------------------------------------------------------------

	latency(n) {
		const p = this.probes[n.tag];

		if (p) {
			const label = p.method === 'url' ? '' : p.method.toUpperCase() + ' ';

			if (typeof p.value === 'string')
				return E('span', { 'class': 'mh-fail', 'title': p.value }, label + _('No answer'));

			return E('span', { 'class': latencyClass(p.value) }, label + _('%d ms').format(p.value));
		}

		if (n.alive === false)
			return E('span', { 'class': 'mh-fail' }, _('No answer'));

		if (n.delay == null)
			return E('span', { 'class': 'mh-muted' }, 'N/A');

		return E('span', { 'class': latencyClass(n.delay) }, _('%d ms').format(n.delay));
	},

	tile(s, n) {
		const active = n.tag === s.active;
		const pick = s.balancer && !active;
		const attrs = {
			'class': 'mh-tile' + (active ? ' mh-tile--active' : '') + (pick ? ' mh-tile--pick' : ''),
			'title': '%s:%s · ↓ %s ↑ %s'.format(n.address || '?', n.port || '?', mh.bytes(n.down), mh.bytes(n.up))
		};

		if (pick)
			attrs.click = ui.createHandlerFn(this, 'select', s.name, n.tag);

		return E('div', attrs, [
			E('b', n.name),
			E('div', { 'class': 'mh-tile-foot mh-small' }, [
				E('span', { 'class': 'mh-muted' }, protocolName(n.protocol)),
				this.latency(n)
			])
		]);
	},

	// A subscription: title, traffic used of the limit, expiry, last update.
	subHead(sub, now, loose) {
		const info = sub.info || {};
		const u = info.userinfo || {};
		const used = (u.upload || 0) + (u.download || 0);
		const parts = [ E('b', info.title || sub.name) ];

		if (!sub.enabled)
			parts.push(E('span', { 'class': 'mh-muted mh-small' }, _('Disabled subscription')));

		if (u.total) {
			const share = Math.min(1, used / u.total);

			parts.push(E('span', { 'class': 'mh-small' }, [
				E('span', { 'class': 'mh-bar' + (share > 0.9 ? ' mh-full' : '') }, E('span', { 'style': 'width:%d%%'.format(Math.round(share * 100)) })),
				' ', _('%s of %s').format(mh.bytes(used), mh.bytes(u.total))
			]));
		}
		else if (used) {
			parts.push(E('span', { 'class': 'mh-small' }, mh.bytes(used)));
		}

		if (u.expire) {
			const left = u.expire - now;
			const date = new Date(u.expire * 1000).toLocaleDateString();

			parts.push(E('span', { 'class': 'mh-small ' + (left < 0 ? 'mh-fail' : left < 3 * DAY ? 'mh-warn' : 'mh-muted') },
				left < 0 ? _('Expired %s').format(date) : _('Until %s').format(date)));
		}

		parts.push(E('span', { 'class': 'mh-muted mh-small' }, _('Updated %s').format(mh.ago(sub.updated, now))));

		if (sub.error)
			parts.push(E('span', { 'class': 'mh-fail mh-small' }, sub.error));

		if (info.hwid && info.hwid.limit)
			parts.push(E('span', { 'class': 'mh-fail mh-small' }, _('Device limit reached: the provider does not accept this HWID')));
		else if (info.hwid && info.hwid.not_supported)
			parts.push(E('span', { 'class': 'mh-warn mh-small' }, _('The provider expects an HWID: turn on "Send device data"')));

		if (loose)
			parts.push(mh.button({
				icon: 'refresh', text: _('Update'), busy: this.busy['subs:' + sub.name],
				click: ui.createHandlerFn(this, 'updateSubs', 'subs:' + sub.name, [ sub.name ])
			}));

		return E('div', { 'class': 'mh-ghead' }, parts);
	},

	groups(s, subs, now) {
		const order = [];
		const by = {};

		for (const n of s.nodes) {
			const src = n.source || 'link';

			if (!by[src]) {
				by[src] = [];
				order.push(src);
			}

			by[src].push(n);
		}

		const own = { link: _('Links'), json: _('JSON outbound'), interface: _('Interfaces') };

		order.sort((a, b) => (own[a] ? 1 : 0) - (own[b] ? 1 : 0));

		return order.map((src) => {
			let head;

			if (own[src]) {
				head = E('div', { 'class': 'mh-ghead' }, E('b', own[src]));
			}
			else {
				const sub = subs[src] || { name: src, enabled: true };

				sub.shown = true;
				head = this.subHead(sub, now);
			}

			return E('div', { 'class': 'mh-group' }, [
				head,
				E('div', { 'class': 'mh-grid' }, by[src].map((n) => this.tile(s, n)))
			]);
		});
	},

	renderSection(s, subs, now) {
		if (s.type === 'interface')
			return this.renderTunnel(s, now);

		if (s.type !== 'proxy')
			return '';

		const current = (s.nodes || []).find((n) => n.tag === s.active);
		const info = [ MODES[s.mode] || s.mode ];

		if (s.mode === 'auto' && s.pinned)
			info.push(_('Pinned by hand'));

		if (current)
			info.push(_('Now: %s').format(current.name));

		const head = [ E('span', { 'class': 'mh-title' }, s.name), ' ',
			E('span', { 'class': 'mh-muted mh-small' }, info.join(' · ')) ];

		if (s.mode === 'auto' && s.pinned)
			head.push(' ', E('a', { 'href': '#', 'class': 'mh-small', 'click': ui.createHandlerFn(this, 'select', s.name, '') }, _('Back to automatic')));

		return E('div', { 'class': 'mh-box mh-section' }, [ E('div', head) ].concat(this.groups(s, subs, now)));
	},

	// The box at the side: checks and updates of every section, then the
	// service controls; all buttons of one width and height.
	renderSide(d) {
		const proxies = (d.sections || []).filter((s) => s.type === 'proxy');
		const own = { link: true, json: true, interface: true };
		const subNames = [ ...new Set([].concat(...proxies.map((s) => s.nodes.map((n) => n.source))).filter((x) => x && !own[x])) ];
		const side = [];

		if (proxies.length) {
			side.push(E('select', {
				'class': 'cbi-input-select',
				'title': _('Check method'),
				'change': (ev) => this.setMethod(ev.target.value)
			}, PROBES.map((p) => E('option', { 'value': p[0], 'selected': p[0] === this.method ? '' : null }, p[1]))));

			side.push(mh.button({
				icon: 'zap', text: _('Test latency'), busy: this.busy.probeAll,
				click: ui.createHandlerFn(this, 'probeAll', proxies)
			}));
		}

		if (subNames.length)
			side.push(mh.button({
				icon: 'refresh', text: _('Update'), busy: this.busy['subs:all'],
				click: ui.createHandlerFn(this, 'updateSubs', 'subs:all', subNames)
			}));

		if (side.length)
			side.push(E('div', { 'class': 'mh-side-gap' }));

		return E('div', { 'class': 'mh-box mh-side' }, side.concat(diag.controls()));
	},

	renderTunnel(s, now) {
		const t = s.tunnel || {};
		const state = t.state === 'up' ? [ 'mh-ok', '✔ ' + _('Works') ]
			: t.state === 'down' ? [ 'mh-fail', '✘ ' + _('Down, traffic goes direct') ]
			: [ 'mh-muted', _('Unknown') ];
		const info = [ _('Interface %s').format(s.interface || '?'), s.mode === 'xray' ? _('Through Xray') : _('Kernel mode') ];

		if (t.handshake)
			info.push(_('Last handshake %s').format(mh.ago(t.handshake, now)));

		info.push('↓ %s ↑ %s'.format(mh.bytes(s.traffic.down), mh.bytes(s.traffic.up)));

		return E('div', { 'class': 'mh-box mh-section mh-head' }, [
			E('div', { 'class': 'mh-grow' }, [
				E('span', { 'class': 'mh-title' }, s.name), ' ',
				E('span', { 'class': 'mh-muted mh-small' }, _('Tunnel') + ' · ' + info.join(' · '))
			]),
			E('span', { 'class': state[0] }, state[1])
		]);
	},

	// Subscriptions no section uses yet: their state is still worth seeing.
	renderLoose(subs, now) {
		const left = Object.values(subs).filter((s) => !s.shown);

		if (!left.length)
			return '';

		return E('div', { 'class': 'mh-box mh-section' }, [
			E('div', { 'class': 'mh-title' }, _('Subscriptions without a section'))
		].concat(left.map((s) => E('div', { 'class': 'mh-group' }, [
			this.subHead(s, now, true),
			E('div', { 'class': 'mh-muted mh-small' }, _('%d servers').format(s.nodes))
		]))));
	},

	renderBody(d) {
		const subs = {};

		for (const s of d.subscriptions || [])
			subs[s.name] = Object.assign({}, s);

		const sections = (d.sections || []).map((s) => this.renderSection(s, subs, d.time));

		// Sections on the left, the buttons in a box of their own on the right.
		return [ this.renderAlert(d), this.renderWidgets(d), E('div', { 'class': 'mh-split' }, [
			E('div', { 'class': 'mh-stack' }, sections.concat([ this.renderLoose(subs, d.time) ])),
			this.renderSide(d)
		]) ];
	},

	render(d) {
		this.data = d;

		if (PROBES.some((p) => p[0] === d.ping_method))
			this.method = d.ping_method;

		window.setTimeout(() => this.checkConnection(), 0);

		poll.add(() => document.hidden ? Promise.resolve() : this.refresh(), 2);

		// First: the section headers draw its buttons.
		const dialogs = diag.render({ state: () => this.data, refresh: () => this.refresh(), redraw: () => this.redraw() });

		return E('div', { 'class': 'cbi-map mh-page mh-stack' }, [
			mh.style(),
			E('style', CSS),
			dialogs,
			E('div', { 'id': 'mayhem-body', 'class': 'mh-stack' }, this.renderBody(d))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
