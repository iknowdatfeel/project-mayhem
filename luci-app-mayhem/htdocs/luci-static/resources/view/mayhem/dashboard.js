'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require mayhem.common as mh';

// The dashboard: four small widgets, then every proxy section as a box of
// server tiles grouped by where they come from (a subscription with its
// traffic and expiry, links, interfaces), like Happ shows subscriptions.
// Actions and the detailed checks are on the diagnostics page.

const callDashboard = rpc.declare({ object: 'luci.mayhem', method: 'dashboard', expect: { '': {} } });
const callAction = rpc.declare({ object: 'luci.mayhem', method: 'action', params: [ 'name' ], expect: { '': {} } });
const callSelect = rpc.declare({ object: 'luci.mayhem', method: 'select_node', params: [ 'section', 'tag' ], expect: { '': {} } });
const callProbe = rpc.declare({ object: 'luci.mayhem', method: 'probe', params: [ 'tag', 'method' ], expect: { '': {} } });
const callSubUpdate = rpc.declare({ object: 'luci.mayhem', method: 'sub_update', params: [ 'name' ], expect: { '': {} } });

const PROBE_PARALLEL = 4;
const DAY = 86400;

const CSS = `
.mh-head { display:flex; align-items:center; justify-content:space-between; gap:10px; flex-wrap:wrap; }
.mh-head .mh-grow { flex:1 1 auto; }
.mh-widget-row { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }

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
	return n == null ? '—' : mh.bytes(n) + '/s';
}

function latencyClass(v) {
	return v < 400 ? 'mh-ok' : (v < 1000 ? 'mh-warn' : 'mh-fail');
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

	load() {
		return callDashboard();
	},

	update(d) {
		if (this.data && d.time > this.data.time) {
			const dt = d.time - this.data.time;
			const diff = (a, b) => Math.max(0, (a - b) / dt);

			this.speed = {
				proxy: { up: diff(d.totals.proxy.up, this.data.totals.proxy.up), down: diff(d.totals.proxy.down, this.data.totals.proxy.down) },
				direct: { up: diff(d.totals.direct.up, this.data.totals.direct.up), down: diff(d.totals.direct.down, this.data.totals.direct.down) }
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
		});
	},

	// URL test of every server of the section, a few at a time.
	probeSection(sec) {
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

			return callProbe(n.tag, 'url').then((r) => {
				this.probes[n.tag] = (r.ms != null) ? r.ms : (r.error || 'error');
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

	updateSub(name) {
		this.busy['sub:' + name] = true;
		this.redraw();

		return callSubUpdate(name).then((r) => {
			const res = (r.results || [])[0];

			if (r.error || (res && !res.ok))
				ui.addNotification(null, E('p', _('Subscription %s: %s').format(name, r.error || res.error)), 'error');
		}).finally(() => {
			delete this.busy['sub:' + name];
			return this.refresh();
		});
	},

	// --- widgets -----------------------------------------------------------------

	widget(title, rows) {
		return E('div', { 'class': 'mh-box' }, [
			E('div', { 'class': 'mh-title' }, title)
		].concat(rows.map((r) => E('div', { 'class': 'mh-widget-row', 'title': r[0] + ': ' + r[1] }, [
			E('span', { 'class': 'mh-muted' }, r[0] + ': '),
			E('span', { 'class': r[2] || '' }, r[1])
		]))));
	},

	renderWidgets(d) {
		const working = d.running && d.active;
		const sp = this.speed && working ? this.speed : null;
		const t = d.totals || { proxy: {}, direct: {} };
		const svc = !d.enabled ? [ '✘ ' + _('Disabled'), 'mh-muted' ]
			: working ? [ '✔ ' + _('Working'), 'mh-ok' ]
			: d.running ? [ '… ' + _('Starting…'), 'mh-warn' ]
			: [ '✘ ' + _('Not running'), 'mh-fail' ];

		return E('div', { 'class': 'mh-grid' }, [
			this.widget(_('Speed'), [
				[ _('Proxy'), sp ? '↓ %s ↑ %s'.format(rate(sp.proxy.down), rate(sp.proxy.up)) : '—' ],
				[ _('Direct'), sp ? '↓ %s ↑ %s'.format(rate(sp.direct.down), rate(sp.direct.up)) : '—' ]
			]),
			this.widget(_('Traffic'), [
				[ _('Proxy'), '↓ %s ↑ %s'.format(mh.bytes(t.proxy.down || 0), mh.bytes(t.proxy.up || 0)) ],
				[ _('Direct'), '↓ %s ↑ %s'.format(mh.bytes(t.direct.down || 0), mh.bytes(t.direct.up || 0)) ]
			]),
			this.widget(_('System'), [
				[ _('Mode'), d.mode === 'global' ? _('everything through proxy') : _('by lists') ],
				[ _('xray memory'), d.rss_kb ? mh.bytes(d.rss_kb * 1024) : '—' ]
			]),
			this.widget(_('Services'), [
				[ 'Mayhem', svc[0], svc[1] ],
				[ 'xray', d.xray ? (d.running ? '✔ ' + d.xray : '✘ ' + d.xray) : '✘ ' + _('not installed'),
					d.xray && d.running ? 'mh-ok' : 'mh-fail' ],
				[ 'dnsmasq', d.dnsmasq ? '✔ ' + _('running') : '✘ ' + _('not running'), d.dnsmasq ? 'mh-ok' : 'mh-fail' ]
			])
		]);
	},

	// Configuration errors stop xray: they stay in sight. Warnings are on the
	// diagnostics page.
	renderAlert(d) {
		const errors = ((d.status || {}).errors || []).slice();

		if (!d.xray)
			errors.push(_('xray is not installed: run "mayhem xray-install"'));

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
			E('a', { 'class': 'mh-small', 'href': L.url('admin/services/mayhem/diagnostics') }, _('Diagnostics'))
		]);
	},

	// --- servers ------------------------------------------------------------------

	latency(n) {
		const p = this.probes[n.tag];

		if (typeof p === 'string')
			return E('span', { 'class': 'mh-fail', 'title': p }, _('no answer'));

		const v = p != null ? p : (n.alive === false ? null : n.delay);

		if (v == null)
			return E('span', { 'class': n.alive === false ? 'mh-fail' : 'mh-muted' }, n.alive === false ? _('no answer') : 'N/A');

		return E('span', { 'class': latencyClass(v) }, '%d ms'.format(v));
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
				E('span', { 'class': 'mh-muted' }, n.protocol),
				this.latency(n)
			])
		]);
	},

	// A subscription: title, traffic used of the limit, expiry, last update.
	subHead(sub, now) {
		const info = sub.info || {};
		const u = info.userinfo || {};
		const used = (u.upload || 0) + (u.download || 0);
		const parts = [ E('b', info.title || sub.name) ];

		if (!sub.enabled)
			parts.push(E('span', { 'class': 'mh-muted mh-small' }, _('disabled')));

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
				left < 0 ? _('expired %s').format(date) : _('until %s').format(date)));
		}

		parts.push(E('span', { 'class': 'mh-muted mh-small' }, _('updated %s').format(mh.ago(sub.updated, now))));

		if (sub.error)
			parts.push(E('span', { 'class': 'mh-fail mh-small' }, sub.error));

		if (info.hwid && info.hwid.limit)
			parts.push(E('span', { 'class': 'mh-fail mh-small' }, _('Device limit reached: the provider does not accept this HWID')));
		else if (info.hwid && info.hwid.not_supported)
			parts.push(E('span', { 'class': 'mh-warn mh-small' }, _('The provider expects an HWID: turn on "Send device data"')));

		parts.push(mh.button({
			icon: 'refresh', text: _('Update'), busy: this.busy['sub:' + sub.name],
			click: ui.createHandlerFn(this, 'updateSub', sub.name)
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
			info.push(_('pinned by hand'));

		if (current)
			info.push(_('now: %s').format(current.name));

		const tools = [];

		if (s.mode === 'auto' && s.pinned)
			tools.push(E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'select', s.name, '') }, _('Back to automatic')), ' ');

		tools.push(mh.button({
			icon: 'zap', text: _('Test latency'), busy: this.busy['probe:' + s.name],
			click: ui.createHandlerFn(this, 'probeSection', s)
		}));

		return E('div', { 'class': 'mh-box mh-section' }, [
			E('div', { 'class': 'mh-head' }, [
				E('div', { 'class': 'mh-grow' }, [
					E('span', { 'class': 'mh-title' }, s.name), ' ',
					E('span', { 'class': 'mh-muted mh-small' }, info.join(' · '))
				]),
				E('div', tools)
			])
		].concat(this.groups(s, subs, now)));
	},

	renderTunnel(s, now) {
		const t = s.tunnel || {};
		const state = t.state === 'up' ? [ 'mh-ok', '✔ ' + _('Works') ]
			: t.state === 'down' ? [ 'mh-fail', '✘ ' + _('Down, traffic goes direct') ]
			: [ 'mh-muted', _('Unknown') ];
		const info = [ '%s %s'.format(_('interface'), s.interface || '?'), s.mode === 'xray' ? _('through xray') : _('kernel mode') ];

		if (t.handshake)
			info.push(_('last handshake %s').format(mh.ago(t.handshake, now)));

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
			this.subHead(s, now),
			E('div', { 'class': 'mh-muted mh-small' }, _('%d servers').format(s.nodes))
		]))));
	},

	renderBody(d) {
		const subs = {};

		for (const s of d.subscriptions || [])
			subs[s.name] = Object.assign({}, s);

		const sections = (d.sections || []).map((s) => this.renderSection(s, subs, d.time));

		return [ this.renderAlert(d), this.renderWidgets(d) ].concat(sections, [ this.renderLoose(subs, d.time) ]);
	},

	render(d) {
		this.data = d;

		poll.add(() => document.hidden ? Promise.resolve() : this.refresh(), 2);

		return E('div', { 'class': 'cbi-map mh-page' }, [
			mh.style(),
			E('style', CSS),
			E('h2', _('Mayhem')),
			E('div', { 'id': 'mayhem-body', 'class': 'mh-stack' }, this.renderBody(d))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
