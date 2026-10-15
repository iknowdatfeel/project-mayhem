'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require mayhem.common as mh';
'require mayhem.diag as diag';

// The dashboard: three small widgets and the servers like Happ shows them:
// servers added by link in "Server list", every subscription in a box of its
// own with its traffic and expiry, tunnels used as servers. The buttons sit
// together at the side: checks, updates, diagnostics and logs (in dialogs),
// restart, stop, autostart. The main section is chosen in the connection box.

const callDashboard = rpc.declare({ object: 'luci.mayhem', method: 'dashboard', expect: { '': {} } });
const callAction = rpc.declare({ object: 'luci.mayhem', method: 'action', params: [ 'name' ], expect: { '': {} } });
const callSelect = rpc.declare({ object: 'luci.mayhem', method: 'select_node', params: [ 'section', 'tag' ], expect: { '': {} } });
const callProbe = rpc.declare({ object: 'luci.mayhem', method: 'probe', params: [ 'tag', 'method' ], expect: { '': {} } });
const callSubUpdate = rpc.declare({ object: 'luci.mayhem', method: 'sub_update', params: [ 'name' ], expect: { '': {} } });
const callRefresh = rpc.declare({ object: 'luci.mayhem', method: 'refresh_servers', expect: { '': {} } });
const callExitInfo = rpc.declare({ object: 'luci.mayhem', method: 'exit_info', params: [ 'section', 'lang' ], expect: { '': {} } });
const callSetPing = rpc.declare({ object: 'luci.mayhem', method: 'set_ping_method', params: [ 'method' ], expect: { '': {} } });
const callSetMain = rpc.declare({ object: 'luci.mayhem', method: 'set_main_section', params: [ 'section' ], expect: { '': {} } });
const callRename = rpc.declare({ object: 'luci.mayhem', method: 'rename_server', params: [ 'section', 'tag', 'link', 'name' ], expect: { '': {} } });
const callSetSelect = rpc.declare({ object: 'luci.mayhem', method: 'set_select', params: [ 'section', 'mode', 'chain' ], expect: { '': {} } });

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
.mh-tile-head { display:flex; align-items:center; gap:4px; }
.mh-tile-head b { flex:1; }
.mh-ren { border:0; background:none; padding:0 2px; cursor:pointer; opacity:.35; color:inherit; font-size:.9em; }
.mh-tile:hover .mh-ren { opacity:.8; }
.mh-tile--pick { cursor:pointer; }
.mh-tile--pick:hover { border-color:var(--primary-color-high, dodgerblue); }
.mh-tile--active { border-color:var(--success-color-medium, green); }
.mh-tile-foot { display:flex; justify-content:space-between; margin-top:6px; gap:6px; }
.mh-alert { display:grid; grid-template-columns:24px 1fr auto; grid-column-gap:10px; align-items:center; }
.mh-alert ul { margin:4px 0 0; padding-left:18px; }
.mh-ghead .btn { padding:0 8px; line-height:22px; min-height:0; font-size:90%; }
.mh-ghead > .btn:last-child { margin-left:auto; }
.mh-ghead .mh-title { margin-right:4px; }
.mh-whead select { width:auto; height:24px; line-height:22px; min-height:0; padding:0 4px; font-size:90%; }
.mh-ghead select { width:auto; height:24px; line-height:22px; min-height:0; padding:0 4px; font-size:90%; }
.mh-chain-no { display:inline-block; min-width:16px; padding:0 4px; border-radius:8px; text-align:center; font-size:80%; line-height:16px; background:var(--primary-color-high, dodgerblue); color:var(--on-primary-color, white); }
.mh-chain { display:flex; flex-wrap:wrap; align-items:center; gap:4px 6px; margin-bottom:6px; }
.mh-chain-list { margin:0 0 10px; padding:0; list-style:none; }
.mh-chain-list li { display:flex; align-items:center; gap:6px; padding:4px 0; border-bottom:1px solid var(--border-color-low, #eee); }
.mh-chain-list li b { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.mh-chain-list .btn { padding:0 8px; line-height:22px; min-height:0; }
`;

function rate(n) {
	return n == null ? '—' : _('%s/s').format(mh.bytes(n));
}

const PROTOCOLS = {
	vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', shadowsocks: 'Shadowsocks', socks: 'SOCKS', http: 'HTTP',
	hysteria: 'Hysteria 2', hysteria2: 'Hysteria 2', wireguard: 'WireGuard', freedom: 'Freedom',
	amneziawg: 'AmneziaWG', openvpn: 'OpenVPN', openconnect: 'OpenConnect', vpnc: 'VPNC', l2tp: 'L2TP', pptp: 'PPTP'
};

// The kind of a server: its protocol, or for a tunnel the interface's one.
function protocolName(n) {
	const p = n.tproto || n.protocol;

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
		const focus = document.activeElement;

		// An open drop-down list would close under the user's hand.
		if (body && focus && focus.tagName === 'SELECT' && body.contains(focus))
			return;

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
			const main = mh.mainServer(this.data).section;

			if (main && section === main.name)
				this.checkConnection();
		});
	},

	// A new name for a server, saved where the server comes from.
	renameDialog(section, n) {
		const input = E('input', { 'class': 'cbi-input-text', 'value': n.name, 'maxlength': 64, 'style': 'width:100%' });
		const submit = () => {
			const name = input.value.trim();

			if (!name || name === n.name) {
				ui.hideModal();
				return Promise.resolve();
			}

			return callRename(section, n.tag, '', name).then((r) => {
				if (r.error) {
					ui.addNotification(null, E('p', r.error), 'error');
					return;
				}

				ui.hideModal();
				window.setTimeout(() => this.refresh(), 2000);
			});
		};

		input.addEventListener('keydown', (ev) => {
			if (ev.key === 'Enter')
				submit();
		});

		ui.showModal(_('Rename the server'), [
			E('p', n.iface ? _('The name of tunnel %s.').format(n.iface)
				: n.source === 'link' ? _('The name is saved in the server key.')
				: _('The name is kept for this server of the subscription and survives its updates.')),
			input,
			E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, submit) }, _('Rename'))
			])
		]);

		input.focus();
		input.select();
	},

	// Ping and external address of the default section: once when the page
	// opens, after a server change and with the latency test. Never polled.
	checkConnection() {
		const d = this.data;
		const main = mh.mainServer(d);
		const sec = main.section;

		if (!sec || !d.running) {
			this.conn = null;
			this.redraw();
			return Promise.resolve();
		}

		const conn = this.conn = { section: sec.name, busy: true };
		const method = this.method;

		this.redraw();

		const ping = main.node
			? callProbe(main.node.tag, method).then((r) => { conn.ms = r.ms; conn.pingError = r.error; })
			: Promise.resolve();
		const exit = callExitInfo(sec.name, geoLang()).then((r) => { conn.exit = r; });

		return Promise.all([ ping, exit ]).catch(() => {}).finally(() => {
			conn.busy = false;

			if (this.conn === conn)
				this.redraw();
		});
	},

	// The main section carries remote DNS, downloads and the rest of the
	// traffic: it is asked first.
	setMain(name) {
		const d = this.data;

		if (!name || name === (mh.mainServer(d).section || {}).name)
			return Promise.resolve();

		const label = name === 'pool' ? _('Server list') : name;

		return new Promise((resolve) => {
			const done = (ok) => {
				ui.hideModal();
				resolve(ok);
			};

			ui.showModal(_('Main section: %s').format(label), [
				E('p', _('Remote DNS, downloads and the rest of the traffic go through the active server of %s. New connections go there at once, open ones finish where they are.').format(label)),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': () => done(false) }, _('Cancel')), ' ',
					E('button', { 'class': 'btn cbi-button-action', 'click': () => done(true) }, _('Change'))
				])
			]);
		}).then((ok) => {
			if (!ok) {
				this.redraw();
				return;
			}

			return callSetMain(name).then((r) => {
				if (r.error)
					ui.addNotification(null, E('p', r.error), 'error');

				return this.refresh();
			}).then(() => this.checkConnection());
		});
	},

	setMethod(m) {
		this.method = m;
		callSetPing(m);
	},

	// Checks every server of the section with the chosen method, a few at a
	// time, but never two of one address at once: subscriptions often have
	// many servers on one host, and a burst of connections to it makes its
	// firewall drop some (a lost SYN costs a second or three of "ping").
	probeSection(sec) {
		const method = this.method;
		const queue = sec.nodes.slice();
		const key = 'probe:' + sec.name;
		const busyHost = {};

		if (this.busy[key])
			return Promise.resolve();

		this.busy[key] = true;
		this.redraw();

		const next = () => {
			const i = queue.findIndex((n) => !n.address || !busyHost[n.address]);

			return i < 0 ? null : queue.splice(i, 1)[0];
		};

		const worker = () => {
			const n = next();

			if (!n)
				return queue.length ? new Promise((r) => window.setTimeout(r, 150)).then(worker) : Promise.resolve();

			if (n.address)
				busyHost[n.address] = true;

			return callProbe(n.tag, method).then((r) => {
				this.probes[n.tag] = { method: method, value: (r.ms != null) ? r.ms : (r.error || 'error') };
				this.redraw();
			}).catch(() => {}).finally(() => {
				if (n.address)
					delete busyHost[n.address];
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

	// Downloads every subscription again and applies the servers, also those
	// that did not get into xray for some reason.
	refreshServers() {
		this.busy.refresh = true;
		this.redraw();

		return callRefresh().then((r) => {
			for (const res of (r.results || []))
				if (!res.ok)
					ui.addNotification(null, E('p', _('Subscription %s: %s').format(res.name, res.error)), 'error');
		}).finally(() => {
			delete this.busy.refresh;
			return this.refresh();
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
			E('div', { 'class': 'mh-whead' }, [ E('span', { 'class': 'mh-title' }, title),
				(note && typeof note === 'object') ? note : note ? E('span', { 'class': 'mh-muted mh-small' }, note) : '' ])
		].concat(rows.map((r) => E('div', { 'class': 'mh-widget-row', 'title': r[0] + ': ' + (r[3] || r[1]) }, [
			E('span', { 'class': 'mh-muted' }, r[0] + ': '),
			E('span', { 'class': r[2] || '' }, r[1])
		]))));
	},

	// The main section: the server list, or a tunnel or a section with servers
	// of its own; a choice when there is more than the server list.
	mainChoice(d) {
		const targets = (d.sections || []).filter((s) => s.type === 'interface' || (s.type === 'proxy' && !s.pool));
		const cur = (mh.mainServer(d).section || {}).name;

		if (targets.length < 2)
			return '';

		return E('select', {
			'class': 'cbi-input-select',
			'title': _('Main section'),
			'change': ui.createHandlerFn(this, (ev) => {
				ev.target.blur();
				return this.setMain(ev.target.value);
			})
		}, targets.map((s) => E('option', { 'value': s.name, 'selected': s.name === cur ? '' : null },
			s.name === 'pool' ? _('Server list') : s.name)));
	},

	// The server the main traffic uses now and how it was chosen.
	serverRow(d) {
		const m = mh.mainServer(d);
		const s = m.section;

		if (!s)
			return [ _('Server'), '—' ];

		if (s.type === 'interface')
			return [ _('Server'), s.label ? '%s (%s)'.format(s.label, s.interface) : _('Interface %s').format(s.interface || '?') ];

		const how = s.mode === 'auto' ? (s.pinned ? _('pinned by hand') : _('automatic'))
			: s.mode === 'fallback' ? _('fallback chain') : null;

		return [ _('Server'), m.node ? (how ? '%s (%s)'.format(m.node.name, how) : m.node.name) : '—' ];
	},

	connectionRows(d, working) {
		const c = this.conn;
		const sp = this.speed && working ? this.speed : null;
		const rows = [
			this.serverRow(d),
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
			this.widget(_('Connection state'), this.connectionRows(d, working), this.mainChoice(d)),
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
		const pick = s.balancer && !active && s.mode !== 'fallback';
		const pos = s.mode === 'fallback' ? (s.chain || []).indexOf(n.tag) : -1;
		const attrs = {
			'class': 'mh-tile' + (active ? ' mh-tile--active' : '') + (pick ? ' mh-tile--pick' : ''),
			'title': '%s · ↓ %s ↑ %s'.format(n.iface ? _('Interface %s').format(n.iface) : '%s:%s'.format(n.address || '?', n.port || '?'),
				mh.bytes(n.down), mh.bytes(n.up))
		};

		if (pick)
			attrs.click = ui.createHandlerFn(this, 'select', s.name, n.tag);

		return E('div', attrs, [
			E('div', { 'class': 'mh-tile-head' }, [
				pos >= 0 ? E('span', { 'class': 'mh-chain-no', 'title': _('Place in the fallback chain') }, String(pos + 1)) : '',
				E('b', n.name),
				E('button', {
					'class': 'mh-ren', 'title': _('Rename'),
					'click': (ev) => {
						ev.stopPropagation();
						this.renameDialog(s.name, n);
					}
				}, '✎')
			]),
			E('div', { 'class': 'mh-tile-foot mh-small' }, [
				E('span', { 'class': 'mh-muted' }, protocolName(n)),
				this.latency(n)
			])
		]);
	},

	// A subscription: title, traffic used of the limit, expiry, last update and
	// a button to download it again.
	subHead(sub, now, note) {
		const info = sub.info || {};
		const u = info.userinfo || {};
		const used = (u.upload || 0) + (u.download || 0);
		const parts = [ E('span', { 'class': 'mh-title' }, info.title || sub.name) ];

		if (note)
			parts.push(E('span', { 'class': 'mh-muted mh-small' }, note));

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

		parts.push(mh.button({
			icon: 'refresh', text: _('Update'), busy: this.busy['subs:' + sub.name],
			click: ui.createHandlerFn(this, 'updateSubs', 'subs:' + sub.name, [ sub.name ])
		}));

		return E('div', { 'class': 'mh-ghead' }, parts);
	},

	// The servers of a proxy section as boxes by where they come from: links
	// first ("Server list"), then every subscription, then tunnels. With
	// several proxy sections each box names its section.
	sourceBoxes(s, subs, now) {
		const order = [];
		const by = {};
		const pool = s.name === 'pool';

		// The server list always has its box, empty or not.
		if (pool) {
			by.link = [];
			order.push('link');
		}

		for (const n of s.nodes || []) {
			const src = n.source || 'link';

			if (!by[src]) {
				by[src] = [];
				order.push(src);
			}

			by[src].push(n);
		}

		const keys = pool ? _('Server list') : _('Server keys');
		const own = { link: keys, json: keys };
		const rank = (src) => src === 'link' ? 0 : src === 'json' ? 1 : 2;
		const note = pool ? null : _('section %s').format(s.name);

		order.sort((a, b) => rank(a) - rank(b));

		// Keys, JSON outbounds and tunnels share one box: the section's own
		// servers.
		for (const src of [ 'json', 'interface' ]) {
			if (!by[src])
				continue;

			if (!by.link) {
				by.link = [];
				order.unshift('link');
			}

			by.link = by.link.concat(by[src]);
			order.splice(order.indexOf(src), 1);
		}

		return order.map((src) => {
			let head;

			if (own[src]) {
				head = E('div', { 'class': 'mh-ghead' }, [
					E('span', { 'class': 'mh-title' }, own[src]),
					note ? E('span', { 'class': 'mh-muted mh-small' }, note) : ''
				]);
			}
			else {
				const sub = subs[src] || { name: src, enabled: true };

				sub.shown = true;
				head = this.subHead(sub, now, note);
			}

			return E('div', { 'class': 'mh-box mh-section' }, [
				head,
				by[src].length ? E('div', { 'class': 'mh-grid' }, by[src].map((n) => this.tile(s, n)))
					: E('div', { 'class': 'mh-muted mh-small' }, _('Add servers by key on the Server list page.'))
			]);
		});
	},

	// The server list when xray has none of it (nothing added yet).
	emptyPool() {
		return E('div', { 'class': 'mh-box mh-section' }, [
			E('div', { 'class': 'mh-ghead' }, E('span', { 'class': 'mh-title' }, _('Server list'))),
			E('div', { 'class': 'mh-muted mh-small' }, _('Add servers by key or a subscription on the Server list page.'))
		]);
	},

	renderSection(s, subs, now) {
		if (s.type === 'interface')
			return [ this.renderTunnel(s, now) ];

		if (s.type !== 'proxy')
			return [];

		const boxes = this.sourceBoxes(s, subs, now);

		if (s.balancer && boxes.length)
			boxes[0].insertBefore(this.chooseBar(s), boxes[0].children[1] || null);

		// Automatic choice with a server pinned by hand: the way back.
		if (s.mode === 'auto' && s.pinned && boxes.length) {
			const head = boxes[0].firstChild;

			head.insertBefore(E('a', {
				'href': '#', 'class': 'mh-small', 'click': ui.createHandlerFn(this, 'select', s.name, '')
			}, _('Back to automatic')), head.querySelector('.btn'));
		}

		return boxes;
	},

	// How the section picks its server: the fastest, by hand, or a fallback
	// chain (server 1 > server 2 > ...), shown in its order.
	chooseBar(s) {
		const byTag = {};

		(s.nodes || []).forEach((n) => byTag[n.tag] = n);

		const modes = [ [ 'auto', _('Fastest server') ], [ 'manual', _('Chosen by hand') ], [ 'fallback', _('Fallback chain') ] ];
		const sel = E('select', {
			'class': 'cbi-input-select',
			'title': _('How the server is chosen'),
			'change': ui.createHandlerFn(this, (ev) => {
				const v = ev.target.value;

				ev.target.blur();

				if (v === 'fallback')
					return this.chainDialog(s);

				return this.saveSelect(s.name, v, []);
			})
		}, modes.map((m) => E('option', { 'value': m[0], 'selected': m[0] === s.mode ? '' : null }, m[1])));

		const parts = [ sel ];

		if (s.mode === 'fallback') {
			const names = (s.chain || []).map((t) => byTag[t] ? byTag[t].name : '?');

			parts.push(E('span', { 'class': 'mh-small' }, names.join(' → ')));
			parts.push(E('a', { 'href': '#', 'class': 'mh-small', 'click': ui.createHandlerFn(this, (ev) => {
				ev.preventDefault();
				return this.chainDialog(s);
			}) }, _('Change')));
		}

		return E('div', { 'class': 'mh-chain' }, parts);
	},

	saveSelect(section, mode, chain) {
		return callSetSelect(section, mode, chain).then((r) => {
			if (r.error)
				ui.addNotification(null, E('p', r.error), 'error');

			// The reload takes a moment.
			return new Promise((res) => window.setTimeout(res, 1500));
		}).then(() => this.refresh());
	},

	// The chain: servers in the order they are tried, up and down, add, remove.
	chainDialog(s) {
		const byTag = {};

		(s.nodes || []).forEach((n) => byTag[n.tag] = n);

		let chain = (s.mode === 'fallback' ? (s.chain || []) : []).filter((t) => byTag[t]).map((t) => byTag[t].name);
		const list = E('ul', { 'class': 'mh-chain-list' });
		const add = E('select', { 'class': 'cbi-input-select', 'style': 'width:100%' });

		const draw = () => {
			list.replaceChildren(...chain.map((name, i) => E('li', [
				E('span', { 'class': 'mh-chain-no' }, String(i + 1)),
				E('b', name),
				E('button', { 'class': 'btn', 'title': _('Up'), 'disabled': i === 0 ? '' : null,
					'click': () => { chain.splice(i - 1, 0, chain.splice(i, 1)[0]); draw(); } }, '↑'),
				E('button', { 'class': 'btn', 'title': _('Down'), 'disabled': i === chain.length - 1 ? '' : null,
					'click': () => { chain.splice(i + 1, 0, chain.splice(i, 1)[0]); draw(); } }, '↓'),
				E('button', { 'class': 'btn cbi-button-remove', 'title': _('Remove'),
					'click': () => { chain.splice(i, 1); draw(); } }, '✕')
			])));

			if (!chain.length)
				list.appendChild(E('li', { 'class': 'mh-muted' }, _('Add servers in the order they should be tried.')));

			const rest = (s.nodes || []).filter((n) => chain.indexOf(n.name) < 0);

			add.replaceChildren(E('option', { 'value': '' }, _('Add a server…')),
				...rest.map((n) => E('option', { 'value': n.name }, n.name)));
		};

		add.addEventListener('change', () => {
			if (add.value)
				chain.push(add.value);

			draw();
		});

		draw();

		ui.showModal(_('Fallback chain'), [
			E('p', _('The first server carries the traffic while it works. When it stops answering, the next one takes over, and so on; a server higher in the chain takes over again as soon as it works. Checks run every 20 seconds, nothing restarts.')),
			list,
			add,
			E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
				E('button', { 'class': 'btn', 'click': () => { ui.hideModal(); this.redraw(); } }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () => {
					if (chain.length < 2) {
						ui.addNotification(null, E('p', _('A chain needs two servers or more')), 'warning');
						return;
					}

					ui.hideModal();
					return this.saveSelect(s.name, 'fallback', chain);
				}) }, _('Save'))
			])
		]);
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
				'change': (ev) => {
					ev.target.blur();
					this.setMethod(ev.target.value);
				}
			}, PROBES.map((p) => E('option', { 'value': p[0], 'selected': p[0] === this.method ? '' : null }, p[1]))));

			side.push(mh.button({
				icon: 'zap', text: _('Test latency'), busy: this.busy.probeAll,
				click: ui.createHandlerFn(this, 'probeAll', proxies)
			}));
		}

		if (proxies.length || subNames.length)
			side.push(mh.button({
				icon: 'refresh', text: _('Update servers'), busy: this.busy.refresh,
				click: ui.createHandlerFn(this, 'refreshServers')
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

	// Subscriptions xray has no servers of: turned off, not downloaded yet or
	// failed. Their state is still worth seeing.
	renderLoose(subs, now) {
		return Object.values(subs).filter((s) => !s.shown).map((s) => E('div', { 'class': 'mh-box mh-section' }, [
			this.subHead(s, now),
			E('div', { 'class': 'mh-muted mh-small' }, _('%d servers').format(s.nodes))
		]));
	},

	renderBody(d) {
		const subs = {};

		for (const s of d.subscriptions || [])
			subs[s.name] = Object.assign({}, s);

		// A tunnel section whose interface is a server of a proxy section is
		// shown there, not twice.
		const served = {};

		for (const s of d.sections || [])
			for (const n of s.nodes || [])
				if (n.iface)
					served[n.iface] = true;

		const sections = (d.sections || []).filter((s) => !(s.type === 'interface' && served[s.interface]));
		const boxes = [].concat(...sections.map((s) => this.renderSection(s, subs, d.time)));

		if (!sections.some((s) => s.name === 'pool'))
			boxes.unshift(this.emptyPool());

		// Servers on the left, the buttons in a box of their own on the right.
		return [ this.renderAlert(d), this.renderWidgets(d), E('div', { 'class': 'mh-split' }, [
			E('div', { 'class': 'mh-stack' }, boxes.concat(this.renderLoose(subs, d.time))),
			this.renderSide(d)
		]) ];
	},

	render(d) {
		this.data = d;

		if (PROBES.some((p) => p[0] === d.ping_method))
			this.method = d.ping_method;

		// A ping method other than the URL test that xray runs by itself: the
		// servers are checked with it once when the page opens.
		window.setTimeout(() => {
			const proxies = (d.sections || []).filter((s) => s.type === 'proxy' && (s.nodes || []).length);

			return (this.method !== 'url' && proxies.length) ? this.probeAll(proxies) : this.checkConnection();
		}, 0);

		poll.add(() => document.hidden ? Promise.resolve() : this.refresh(), 3);

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
