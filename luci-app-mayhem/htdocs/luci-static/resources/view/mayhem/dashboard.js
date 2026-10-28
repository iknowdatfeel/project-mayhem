'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require mayhem.common as mh';
'require mayhem.diag as diag';
'require mayhem.sheet as sheet';
'require mayhem.linkedit as linkedit';
'require mayhem.tunnels as tunnels';
'require mayhem.dash.checks as checks';
'require mayhem.dash.chain as chain';
'require mayhem.dash.conns as conns';

// The dashboard, the only page of Mayhem: three small widgets and the servers
// in boxes by where they come from (keys, every subscription with its traffic
// and expiry, tunnels). The buttons at the top open the rest in a window over
// it: connections (keys, subscriptions, tunnels), routing, settings and
// component updates. Checks, diagnostics, logs and the service controls sit
// together at the side. The main section is chosen in the connection box.

const callDashboard = rpc.declare({ object: 'luci.mayhem', method: 'dashboard', expect: { '': {} } });
const callAction = rpc.declare({ object: 'luci.mayhem', method: 'action', params: [ 'name' ], expect: { '': {} } });
const callSelect = rpc.declare({ object: 'luci.mayhem', method: 'select_node', params: [ 'section', 'tag' ], expect: { '': {} } });
const callSubUpdate = rpc.declare({ object: 'luci.mayhem', method: 'sub_update', params: [ 'name' ], expect: { '': {} } });
const callRefresh = rpc.declare({ object: 'luci.mayhem', method: 'refresh_servers', expect: { '': {} } });
const callRename = rpc.declare({ object: 'luci.mayhem', method: 'rename_server', params: [ 'section', 'tag', 'link', 'name' ], expect: { '': {} } });
const callSetSelect = rpc.declare({ object: 'luci.mayhem', method: 'set_select', params: [ 'section', 'mode', 'chain', 'rules' ], expect: { '': {} } });
const callParseOne = rpc.declare({ object: 'luci.mayhem', method: 'parse_link', params: [ 'link' ], expect: { '': {} } });
const callServerDelete = rpc.declare({ object: 'luci.mayhem', method: 'server_delete', params: [ 'section', 'tag' ], expect: { '': {} } });
const callServerEdit = rpc.declare({ object: 'luci.mayhem', method: 'server_edit', params: [ 'section', 'old', 'link' ], expect: { '': {} } });

const DAY = 86400;

const CSS = `
.mh-top { display:flex; align-items:center; justify-content:space-between; gap:10px; flex-wrap:wrap; }
.mh-brand { display:flex; align-items:center; gap:10px; }
.mh-brand-name { font-size:150%; font-weight:700; color:var(--text-color-high, inherit); }
.mh-pill { display:inline-flex; align-items:center; gap:6px; padding:2px 10px; border-radius:999px; font-size:85%; border:1px solid currentColor; background:none; cursor:pointer; font-family:inherit; line-height:1.6; }
.mh-pill:hover { background:rgba(127,127,127,.12); }
.mh-caret { font-size:80%; opacity:.7; }
.mh-pill-wrap { position:relative; }
.mh-svc { position:absolute; top:calc(100% + 6px); left:0; z-index:20; min-width:220px; padding:8px 12px; border-radius:6px; background:var(--background-color-high, #fff); border:1px solid var(--border-color-low, #ddd); box-shadow:0 6px 20px rgba(0,0,0,.3); }
.mh-svc-row { display:flex; justify-content:space-between; gap:16px; padding:3px 0; }
.mh-pill::before { content:''; width:8px; height:8px; border-radius:50%; background:currentColor; }
.mh-pill--ok { color:var(--success-color-medium, green); }
.mh-pill--warn { color:var(--warn-color-medium, orange); }
.mh-pill--fail { color:var(--error-color-medium, red); }
.mh-pill--off { color:var(--text-color-medium, #888); }
.mh-nav { display:flex; flex-wrap:wrap; gap:6px; }
.mh-nav .btn { margin:0; }
@media (max-width: 700px) { .mh-nav { width:100%; } .mh-nav .btn { flex:1 1 calc(50% - 6px); } }
.mh-empty { display:flex; flex-direction:column; align-items:flex-start; gap:6px; }
.mh-ren .mh-icon { width:14px; height:14px; vertical-align:middle; }
.mh-del:hover { color:var(--error-color-medium, red); }
.mh-head { display:flex; align-items:center; justify-content:space-between; gap:10px; flex-wrap:wrap; }
.mh-head .mh-grow { flex:1 1 auto; }
.mh-layout { display:grid; grid-template-columns:1fr 1fr 240px; grid-template-rows:auto 1fr; grid-template-areas:"conn sys side" "servers servers side"; grid-gap:10px; align-items:start; }
.mh-a-conn { grid-area:conn; align-self:stretch; min-width:0; } .mh-a-sys { grid-area:sys; align-self:stretch; min-width:0; } .mh-a-side { grid-area:side; } .mh-a-servers { grid-area:servers; }
@media (max-width: 900px) { .mh-layout { grid-template-columns:1fr; grid-template-rows:none; grid-template-areas:"conn" "sys" "side" "servers"; } }
.mh-widget-row { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.mh-widget-row.mh-wrap { white-space:normal; }
.mh-whead { display:flex; justify-content:space-between; align-items:baseline; gap:8px; }
.mh-split { display:grid; grid-template-columns:1fr 240px; grid-column-gap:12px; align-items:start; }
@media (max-width: 700px) { .mh-split { grid-template-columns:1fr; grid-row-gap:10px; } }
.mh-side { display:grid; grid-template-columns:1fr; gap:6px; align-content:start; }
.mh-side > .btn, .mh-side > select { width:100%; height:30px; line-height:28px; min-height:0; margin:0; padding:0 10px; font-size:90%; box-sizing:border-box; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.mh-side > .btn .mh-icon { width:14px; height:14px; }
.mh-side-gap { grid-column:1 / -1; height:2px; }

.mh-group { margin-top:10px; }
.mh-badge { display:inline-flex; align-items:center; gap:4px; padding:0 8px 0 2px; border-radius:999px; font-size:85%; line-height:20px; border:1px solid var(--border-color-low, #ccc); color:inherit; text-decoration:none; }
.mh-badge:hover { border-color:var(--primary-color-high, dodgerblue); }
.mh-chain-line { flex:1 1 100%; }
.mh-tunrow { padding:6px 10px; border:1px solid var(--border-color-low, #ddd); border-radius:4px; margin-top:6px; }
.mh-list > .mh-group { margin-top:12px; padding-top:10px; border-top:1px solid var(--border-color-low, #ddd); }
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
.mh-tile--chosen:not(.mh-tile--active) { border-color:var(--primary-color-high, dodgerblue); border-style:dashed; }
.mh-rule { display:flex; flex-wrap:wrap; gap:6px; margin-top:4px; }
.mh-rule > select { width:auto; }
.mh-rule > div { flex:1 1 100%; padding-left:10px; border-left:2px solid var(--border-color-low, #ddd); }
.mh-rule .mh-chain-no { background:var(--text-color-medium, gray); }
.mh-pick-list { display:flex; flex-direction:column; gap:2px; }
.mh-pick-list label { display:flex; align-items:center; gap:6px; cursor:pointer; }
.mh-pick-list label > span:last-child { margin-left:auto; font-size:90%; }
.mh-chain-list li .mh-grow { flex:1; min-width:0; }
.mh-chain-list li .mh-grow > b { display:inline; }
.mh-tile-foot { display:flex; justify-content:space-between; margin-top:6px; gap:6px; }
.mh-tile-foot > span:last-child { white-space:nowrap; }
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

// Speed in megabytes a second: one unit, so the numbers do not jump between
// B/s, KB/s and MB/s from one second to the next.
function rate(n) {
	if (n == null)
		return '—';

	const mb = n / 1048576;

	return _('%s MB/s').format(mb >= 10 ? mb.toFixed(0) : mb >= 1 ? mb.toFixed(1) : mb.toFixed(2));
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

// A ping (TCP, ICMP) is one round trip to the server; the URL test goes on
// from the server to the site and back: the same server shows two or three
// times the number.
function latencyClass(v, method) {
	const ping = method === 'tcp' || method === 'icmp';

	return v < (ping ? 150 : 400) ? 'mh-ok' : (v < (ping ? 400 : 1000) ? 'mh-warn' : 'mh-fail');
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

return view.extend({
	data: null,
	speed: null,
	busy: {},
	gone: {},		// tag -> time: deleted servers, hidden until the reload drops them
	pendingSel: {},		// section -> { mode, chain, time }: a choice the reload has not applied yet
	showServices: false,	// the state of the services under the badge

	// With the URL test the page waits for its last numbers too, so the
	// servers have real ones from the first look.
	load() {
		return callDashboard().then((d) => {
			const m = checks.known(d.ping_method) ? d.ping_method : 'url';

			if (m !== 'url' || !d.running)
				return d;

			return checks.load().then((w) => {
				d.warm = w;
				return d;
			}, () => d);
		});
	},

	update(d) {
		this.hideGone(d);
		this.settleSel(d);

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

	// Deleted servers leave the page at once: the router reloads in the
	// background, and until then its data still has them.
	hideGone(d) {
		const now = Date.now();
		const seen = {};

		for (const s of (d.sections || [])) {
			s.nodes = (s.nodes || []).filter((n) => {
				if (!this.gone[n.tag])
					return true;

				seen[n.tag] = true;
				return false;
			});
		}

		for (const tag in this.gone)
			if (!seen[tag] || now - this.gone[tag] > 120000)
				delete this.gone[tag];
	},

	// Redraws asked for in a burst (every answer of a latency test, a poll
	// on top of a choice) are drawn once, in the next frame: each one builds
	// every tile again.
	redraw() {
		if (this.redrawing)
			return;

		this.redrawing = true;

		const draw = () => {
			this.redrawing = false;
			this.redrawNow();
		};

		if (window.requestAnimationFrame && !document.hidden)
			window.requestAnimationFrame(draw);
		else
			window.setTimeout(draw, 0);
	},

	redrawNow() {
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
				checks.checkConnection();
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

	// The pencil of a server: a key is edited as Xray JSON, a tunnel as its
	// .conf; a subscription's server only gets a name of its own.
	editServer(section, n) {
		if (n.iface && (n.tproto === 'amneziawg' || n.tproto === 'wireguard'))
			return tunnels.editDialog(n.iface, () => window.setTimeout(() => this.refresh(), 3000));

		if (!n.link || !n.usec)
			return this.renameDialog(section, n);

		return callParseOne(n.link).then((r) => {
			linkedit.dialog(n.link, r.outbound, n.name, (link) => callServerEdit(n.usec, n.link, link).then((res) => {
				if (res.error)
					return res.error;

				window.setTimeout(() => this.refresh(), 2000);
				return null;
			}));
		});
	},

	// The bin of a server, after a question. It is gone from the page at once.
	deleteServer(section, n) {
		// A deleted tunnel goes from every section that has it as a server;
		// one out of the server list only from that list.
		const forget = (mode) => {
			const tags = n.iface ? [].concat(...(this.data.sections || []).filter((x) => mode === 'full' || x.name === 'pool').map((x) =>
				(x.nodes || []).filter((y) => y.iface === n.iface).map((y) => y.tag))) : [ n.tag ];

			for (const t of tags.length ? tags : [ n.tag ]) {
				this.gone[t] = Date.now();
				delete checks.probes[t];
			}

			this.hideGone(this.data);
			this.redraw();
			return this.refresh();
		};

		// A tunnel: out of the server list, or deleted with its interface,
		// as under Tunnels.
		if (n.iface)
			return tunnels.deleteDialog(n.iface, false, forget);

		const what = (n.source === 'link' || n.source === 'json') ? _('The server key is deleted.')
			: _('The server is hidden from this subscription and does not come back with its updates.');

		ui.showModal(_('Delete server %s?').format(n.name), [
			E('p', _('Are you sure you want to delete server %s?').format(n.name)),
			E('p', { 'class': 'mh-muted mh-small' }, what),
			E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, () => callServerDelete(section, n.tag).then((r) => {
					ui.hideModal();

					if (r.error) {
						ui.addNotification(null, E('p', r.error), 'error');
						return;
					}

					return forget();
				})) }, _('Delete'))
			])
		]);
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

	// --- top -----------------------------------------------------------------------

	// The name, the state of the service and the pages that open over the
	// dashboard.
	navButton(page, icon, cls, text) {
		return sheet.button({ page: page, icon: icon, cls: cls, text: text, onclose: () => this.refresh() });
	},

	renderTop(d) {
		const working = d.running && d.active;
		const st = !d.enabled ? [ 'mh-pill--off', _('Turned off') ]
			: working ? [ 'mh-pill--ok', _('Works') ]
			: d.running ? [ 'mh-pill--warn', _('Starting…') ]
			: [ 'mh-pill--fail', _('Does not work') ];

		// The badge opens the state of each service.
		const services = () => {
			const xray = !d.xray ? [ _('Not installed'), 'mh-fail' ]
				: d.running ? [ _('Works'), 'mh-ok' ] : [ _('Does not work'), 'mh-fail' ];
			const row = (name, v) => E('div', { 'class': 'mh-svc-row' }, [
				E('span', name), E('span', { 'class': v[1] }, v[0])
			]);

			return E('div', { 'class': 'mh-svc' }, [
				row('Mayhem', [ st[1], st[0].replace('mh-pill--', 'mh-').replace('mh-off', 'mh-muted') ]),
				row('Xray', xray),
				row('Dnsmasq', d.dnsmasq ? [ _('Works'), 'mh-ok' ] : [ _('Does not work'), 'mh-fail' ])
			]);
		};

		return E('div', { 'class': 'mh-top' }, [
			E('div', { 'class': 'mh-brand' }, [
				E('span', { 'class': 'mh-brand-name' }, 'Mayhem'),
				E('span', { 'class': 'mh-pill-wrap' }, [
					E('button', {
						'class': 'mh-pill ' + st[0], 'title': _('Services'), 'aria-expanded': this.showServices ? 'true' : 'false',
						'click': () => { this.showServices = !this.showServices; this.redraw(); }
					}, [ st[1], E('span', { 'class': 'mh-caret' }, this.showServices ? '▴' : '▾') ]),
					this.showServices ? services() : ''
				]),
				// The router is applying a change (a reload): what is shown
				// may change in a moment.
				d.applying ? E('span', { 'class': 'mh-muted mh-small mh-btn', 'title': _('Servers and rules on the page update by themselves when it is done.') },
					[ mh.icon('loader', true), _('Applying changes…') ]) : ''
			])
		]);
	},

	// --- widgets -----------------------------------------------------------------

	widget(title, rows, note) {
		return E('div', { 'class': 'mh-box' }, [
			E('div', { 'class': 'mh-whead' }, [ E('span', { 'class': 'mh-title' }, title),
				(note && typeof note === 'object') ? note : note ? E('span', { 'class': 'mh-muted mh-small' }, note) : '' ])
		].concat(rows.map((r) => E('div', { 'class': 'mh-widget-row' + (r[4] ? ' mh-wrap' : ''), 'title': (typeof (r[3] || r[1]) === 'string') ? r[0] + ': ' + (r[3] || r[1]) : null }, [
			E('span', { 'class': 'mh-muted' }, r[0] + ': '),
			E('span', { 'class': r[2] || '' }, r[1])
		]))));
	},

	// The title of a subscription: the one its provider gives, or its name.
	subTitle(name) {
		const sub = ((this.data || {}).subscriptions || []).find((x) => x.name === name);

		return (sub && sub.info && sub.info.title) || name;
	},

	// The server the main traffic uses now and how it was chosen.
	serverRow(d) {
		const m = mh.mainServer(d);
		const s = m.section;

		if (!s)
			return [ _('Server'), '—' ];

		if (s.type === 'interface')
			return [ _('Server'), s.label ? '%s (%s)'.format(s.label, s.interface) : _('Interface %s').format(s.interface || '?') ];

		// No server of the section answers: its traffic goes direct until
		// one does (kill switch off).
		if (s.down)
			return [ _('Server'), _('Direct: the servers do not answer'), 'mh-warn' ];

		const how = s.mode === 'auto' ? (s.pinned ? (s.name === 'pool' ? _('chosen by hand') : _('pinned by hand')) : _('automatic'))
			: s.mode === 'fallback' ? _('fallback chain') : null;

		return [ _('Server'), m.node ? (how ? '%s (%s)'.format(m.node.name, how) : m.node.name) : '—' ];
	},

	connectionRows(d, working) {
		const c = checks.conn;
		const sp = this.speed && working ? this.speed : null;
		const rows = [
			this.serverRow(d)
		];

		if (d.dns_down)
			rows.push([ _('DNS'), _('Provider\'s: the remote DNS does not answer'), 'mh-warn' ]);

		rows.push(
			[ _('Incoming'), sp ? rate(sp.down) : '—' ],
			[ _('Outgoing'), sp ? rate(sp.up) : '—' ]
		);
		const wait = '…';

		if (!c) {
			rows.push([ _('Ping time'), '—' ], [ _('External IP'), '—' ], [ _('Location'), '—' ]);
			return rows;
		}

		if (c.ms != null)
			rows.push([ _('Ping time'), _('%d ms').format(c.ms), latencyClass(c.ms, c.method) ]);
		else
			rows.push([ _('Ping time'), c.busy ? wait : _('No answer'), c.busy ? 'mh-muted' : 'mh-fail', c.pingError ]);

		const x = c.exit || {};

		if (x.ip) {
			const f = flag(x.country_code);
			const place = [ x.country_code ? countryName(x.country_code, x.country) : x.country, x.city ].filter((v) => v).join(', ');

			rows.push([ _('External IP'), E('span', [ f ? f + ' ' : '', mh.ipSpan(x.ip) ]) ]);
			rows.push([ _('Location'), place || '—' ]);
		}
		else {
			rows.push([ _('External IP'), c.busy ? wait : _('No answer'), c.busy ? 'mh-muted' : 'mh-fail', x.error ]);
			rows.push([ _('Location'), c.busy ? wait : '—', 'mh-muted' ]);
		}

		return rows;
	},

	// The connection, the system and all the buttons in one row; the state of
	// the service is the badge at the top.
	renderWidgets(d) {
		const working = d.running && d.active;

		return [
			this.widget(_('Connection state'), this.connectionRows(d, working)),
			this.widget(_('System'), [
				[ _('Router'), d.model || '—' ],
				[ _('OS'), d.system || '—' ],
				[ 'Mayhem', d.version || '—' ],
				[ 'Xray', d.xray || '—' ],
				// xray's data, as the watchdog counts it; with its code, in the hint.
				[ _('Memory use'), d.rss_kb ? mh.bytes(d.rss_kb * 1024) : '—', '',
					d.rss_total_kb ? _('%s with the code of xray').format(mh.bytes(d.rss_total_kb * 1024)) : null ]
			])
		];
	},

	// Configuration errors stop xray: they stay in sight. Warnings are on the
	// diagnostics page.
	renderAlert(d) {
		const errors = ((d.status || {}).errors || []).slice();

		if (!d.xray)
			errors.push(_('Xray is not installed: run "mayhem xray-install"'));

		if (d.xray_error && d.enabled)
			errors.push(_('Xray does not start: %s').format(d.xray_error));

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

	// The number of the chosen check. xray's own check (n.delay) opens a new
	// connection through the server every time, handshakes and all, and is
	// several times the real one: it shows only when the chosen check has
	// nothing for the server. While that check is still coming: "…".
	latency(n) {
		const p = checks.probes[n.tag];

		if (p) {
			const label = p.method === 'url' ? '' : p.method.toUpperCase() + ' ';

			if (p.pending)
				return E('span', { 'class': 'mh-muted', 'title': _('Checking…') }, label + '…');

			if (typeof p.value === 'string')
				return E('span', { 'class': 'mh-fail', 'title': p.value }, label + _('No answer'));

			return E('span', { 'class': latencyClass(p.value, p.method) }, label + _('%d ms').format(p.value));
		}

		if (n.alive === false)
			return E('span', { 'class': 'mh-fail' }, _('No answer'));

		if (this.latencyPending(n))
			return E('span', { 'class': 'mh-muted', 'title': _('Checking…') }, '…');

		if (n.delay == null)
			return E('span', { 'class': 'mh-muted' }, 'N/A');

		return E('span', { 'class': latencyClass(n.delay) }, _('%d ms').format(n.delay));
	},

	latencyPending(n) {
		if (!this.data || !this.data.running)
			return false;

		if (checks.firstCheck)
			return true;

		// Kept-alive URL test: the server is in it, its first answer is coming.
		return checks.method === 'url' && !!checks.warm && (checks.warm.tags || []).indexOf(n.tag) >= 0;
	},

	tile(s, n) {
		const active = n.tag === s.active;
		let pick = s.balancer && !active && s.mode !== 'fallback';
		let pos = s.mode === 'fallback' ? (s.chain || []).indexOf(n.tag) : -1;
		let chosen = false;
		const section = s.name;

		// The list as a chain: numbers for the servers it names; in a
		// subscription, its own rule (its chain, the one chosen by hand).
		if (s.name === 'pool' && s.mode === 'fallback') {
			pos = (s.items || []).findIndex((i) => i.tag === n.tag);

			if (chain.isSub(n.source)) {
				const r = this.subRule(s, n.source);

				if (r.mode === 'manual')
					chosen = r.selected === n.tag;
				else if (r.mode === 'fallback' && pos < 0)
					pos = (r.chain || []).indexOf(n.tag);
			}
		}

		// Any server of the list: a click chooses it by hand, from any mode.
		if (s.name === 'pool')
			pick = !active && !!s.balancer;

		const attrs = {
			'class': 'mh-tile' + (active ? ' mh-tile--active' : '') + (pick ? ' mh-tile--pick' : '') + (chosen ? ' mh-tile--chosen' : ''),
			'title': '%s · ↓ %s ↑ %s'.format(n.iface ? _('Interface %s').format(n.iface) : mh.ipText('%s:%s'.format(n.address || '?', n.port || '?')),
				mh.bytes(n.down), mh.bytes(n.up))
		};

		if (pick)
			attrs.click = s.name === 'pool' ? ui.createHandlerFn(this, 'pickInList', s, n.tag) : ui.createHandlerFn(this, 'select', section, n.tag);

		return E('div', attrs, [
			E('div', { 'class': 'mh-tile-head' }, [
				pos >= 0 ? E('span', { 'class': 'mh-chain-no', 'title': _('Place in the fallback chain') }, String(pos + 1)) : '',
				E('b', n.name),
				E('button', {
					'class': 'mh-ren', 'title': ((n.link && n.usec) || n.iface) ? _('Edit') : _('Rename'),
					'click': (ev) => {
						ev.stopPropagation();
						this.editServer(s.name, n);
					}
				}, mh.icon('pencil', true)),
				E('button', {
					'class': 'mh-ren mh-del', 'title': _('Delete'),
					'click': (ev) => {
						ev.stopPropagation();
						this.deleteServer(s.name, n);
					}
				}, mh.icon('trash', true))
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
		else if (sub.via_why)
			parts.push(E('span', { 'class': 'mh-warn mh-small', 'title': sub.via_why }, _('Downloaded directly: not through Xray')));

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

	// The rule of a subscription: how it picks one of its servers where the
	// list's chain names it. Shown while the list is a chain.
	subRule(pool, sub) {
		const pend = this.pendingSel[sub];
		const r = (pool.subs || {})[sub] || { mode: 'auto' };

		return pend ? { mode: pend.mode, chain: null, selected: r.selected, pending: true } : r;
	},

	// Where a subscription stands in the list's chain and by which rule: one
	// small badge in its head. The rule is set in the chain's window.
	subBadge(pool, sub) {
		const pos = (pool.items || []).findIndex((i) => i.sub === sub);

		if (pos < 0)
			return null;

		const r = this.subRule(pool, sub);
		const how = r.mode === 'manual' ? _('chosen by hand') : r.mode === 'fallback' ? _('its own chain') : _('fastest');

		return E('a', {
			'href': '#', 'class': 'mh-badge', 'title': _('Change in the chain'),
			'click': ui.createHandlerFn(this, (ev) => {
				ev.preventDefault();
				return chain.dialog(pool);
			})
		}, [ E('span', { 'class': 'mh-chain-no' }, String(pos + 1)), ' ', how ]);
	},

	// A subscription's servers and rule in the shape chainDialog() takes.
	subAsSection(pool, sub, nodes) {
		const r = (pool.subs || {})[sub] || {};

		return { name: sub, nodes: nodes, mode: r.mode, chain: r.chain || [] };
	},

	// The servers of a proxy section as boxes by where they come from: keys,
	// JSON outbounds and tunnels first, then every subscription. In the
	// server list a subscription's box has its rule while the list is a chain.
	sourceBoxes(s, subs, now) {
		const order = [];
		const by = {};
		const pool = s.name === 'pool';
		const own = (src) => src === 'link' || src === 'json' || src === 'interface';

		// The keys and tunnels of the list have their group even empty, but
		// only while there is no subscription either.
		if (pool && !(this.data.subscriptions || []).length) {
			by.link = [];
			order.push('link');
		}

		for (const n of s.nodes || []) {
			const src = own(n.source || 'link') ? 'link' : n.source;

			if (!by[src]) {
				by[src] = [];
				order.push(src);
			}

			by[src].push(n);
		}

		order.sort((a, b) => (a === 'link' ? 0 : 1) - (b === 'link' ? 0 : 1));

		const chain = pool && this.listMode(s) === 'fallback';

		return order.map((src) => {
			let head;

			if (src === 'link') {
				head = E('div', { 'class': 'mh-ghead' }, [
					E('span', { 'class': 'mh-title' }, pool ? _('Server list') : _('Server list "%s"').format(s.name))
				]);
			}
			else {
				const sub = subs[src] || { name: src, enabled: true };

				sub.shown = true;
				head = this.subHead(sub, now);
			}

			// In the list: a group of its one box; elsewhere a box of its own.
			const box = E('div', { 'class': pool ? 'mh-group' : 'mh-box mh-section' }, [
				head,
				by[src].length ? E('div', { 'class': 'mh-grid' }, by[src].map((n) => this.tile(s, n)))
					: E('div', { 'class': 'mh-muted mh-small' }, _('Add servers with the "Add connection" button.'))
			]);

			const badge = (chain && src !== 'link') ? this.subBadge(s, src) : null;

			if (badge)
				head.insertBefore(badge, head.querySelector('.btn'));

			return box;
		});
	},

	// The way the list picks its server, with a choice not yet applied.
	listMode(s) {
		const pend = this.pendingSel[s.name];

		return pend ? pend.mode : this.shownMode(s);
	},

	// The list chosen by hand is its automatic choice with a pinned server.
	shownMode(s) {
		return (s.name === 'pool' && s.mode === 'auto' && s.pinned) ? 'manual' : s.mode;
	},

	// A server of the list chosen by hand: from any mode; '' goes back to the
	// fastest server.
	pickInList(s, tag) {
		if (tag === '' && s.mode === 'fallback')
			return this.saveSelect('pool', 'auto', []);

		this.pendingSel.pool = { mode: tag ? 'manual' : 'auto', chain: [], tag: tag, time: Date.now() };

		// The tile and the server line change at once; the router's answer
		// (a second or so for xray) only confirms it.
		if (tag) {
			s.active = tag;
			s.pinned = tag;
		}

		this.redraw();

		// The router's answer settles it (settleSel), as with other choices.
		return this.select('pool', tag).catch(() => {
			delete this.pendingSel.pool;
			this.redraw();
		});
	},

	// The server list: one box, its title and how it picks the server on top,
	// then its groups (keys and tunnels, every subscription).
	listBox(s, groups) {
		const bar = this.chooseBar(s);
		const head = E('div', { 'class': 'mh-ghead' }, [ E('span', { 'class': 'mh-title' }, _('Server choice')) ].concat(Array.from(bar.childNodes)));

		return E('div', { 'class': 'mh-box mh-section mh-list' }, [ head ].concat(groups));
	},

	// The server list when xray has none of it (nothing added yet).
	emptyPool() {
		return E('div', { 'class': 'mh-box mh-section mh-empty' }, [
			E('div', { 'class': 'mh-title' }, _('No servers yet')),
			E('div', { 'class': 'mh-muted' }, _('Add a server or a subscription with the "Add connection" button.')),
			this.navButton('servers', 'plus', 'cbi-button-add', _('Add connection'))
		]);
	},

	renderSection(s, subs, now) {
		// Tunnel sections are rows of the server list's box (renderBody).
		if (s.type === 'interface')
			return [];

		if (s.type !== 'proxy')
			return [];

		const boxes = this.sourceBoxes(s, subs, now);

		if (s.name === 'pool')
			return [ this.listBox(s, boxes) ];

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
	// chain (server 1 > server 2 > ...), shown in its order. The server list
	// has the fastest (a server may be pinned) and the chain.
	chooseBar(s) {
		const byTag = {};

		(s.nodes || []).forEach((n) => byTag[n.tag] = n);

		const pool = s.name === 'pool';
		const modes = [ [ 'auto', _('Fastest server') ], [ 'manual', _('Chosen by hand') ], [ 'fallback', _('Fallback chain') ] ];
		const pend = this.pendingSel[s.name];
		const mode = pool ? this.listMode(s) : pend ? pend.mode : s.mode;
		const sel = E('select', {
			'class': 'cbi-input-select',
			'title': _('How the server is chosen'),
			'change': ui.createHandlerFn(this, (ev) => {
				const v = ev.target.value;

				ev.target.blur();

				if (v === 'fallback')
					return chain.dialog(s);

				// The list by hand: the server it uses now, pinned.
				if (pool)
					return this.pickInList(s, v === 'manual' ? (s.active || ((s.nodes || [])[0] || {}).tag || '') : '');

				return this.saveSelect(s.name, v, []);
			})
		}, modes.map((m) => E('option', { 'value': m[0], 'selected': m[0] === mode ? '' : null }, m[1])));

		const parts = [ sel ];

		if (pend)
			parts.push(E('span', { 'class': 'mh-muted mh-small' }, _('applying…')));

		if (mode === 'fallback') {
			const change = E('a', { 'href': '#', 'class': 'mh-small', 'click': ui.createHandlerFn(this, (ev) => {
				ev.preventDefault();
				return chain.dialog(s);
			}) }, _('Change'));

			// The list: numbers on the servers and the subscriptions' badges
			// show the chain; the line only names it.
			if (pool) {
				const names = (pend ? pend.chain : chain.listEntries(s)).map((e) => e.charAt(0) === '@' ? this.subTitle(e.slice(1)) : chain.entryLabel(s, e));

				parts.push(change, E('span', { 'class': 'mh-muted mh-small mh-chain-line' }, names.join(' → ')));
			}
			else {
				const names = pend ? pend.chain : (s.chain || []).map((t) => byTag[t] ? byTag[t].name : '?');

				parts.push(E('span', { 'class': 'mh-small' }, names.join(' → ')), change);
			}
		}
		else if (pool && !pend)
			parts.push(E('span', { 'class': 'mh-muted mh-small' }, mode === 'manual'
				? _('click another server to switch to it') : _('the fastest of all servers; click one to choose it by hand')));

		return E('div', { 'class': 'mh-chain' }, parts);
	},


	// The choice shows at once; the router takes a few seconds to reload, and
	// until its data has the new mode the dashboard keeps showing the choice
	// (before, a poll in between put the old mode back in the list).
	saveSelect(section, mode, chain, rules) {
		this.pendingSel[section] = { mode: mode, chain: chain, rules: rules || null, time: Date.now() };
		this.redraw();

		return callSetSelect(section, mode, chain, rules || {}).then((r) => {
			if (r.error) {
				delete this.pendingSel[section];
				ui.addNotification(null, E('p', r.error), 'error');
			}

			return this.refresh();
		}).catch((e) => {
			delete this.pendingSel[section];
			this.redraw();
			throw e;
		});
	},

	// Choices the router has applied (or that waited too long) are dropped.
	settleSel(d) {
		for (const name in this.pendingSel) {
			const p = this.pendingSel[name];
			const pool = (d.sections || []).find((x) => x.name === 'pool') || {};
			// A subscription's rule is kept with the server list.
			const s = (d.sections || []).find((x) => x.name === name) || (pool.subs || {})[name];
			const done = s && (name === 'pool' ? this.shownMode(s) : s.mode) === p.mode && (p.mode !== 'fallback' ||
				(name === 'pool' ? (s.items || []).length === p.chain.length : (s.chain || []).length === p.chain.length));

			if (done || !s || Date.now() - p.time > 90000 || (!d.applying && Date.now() - p.time > 20000))
				delete this.pendingSel[name];
		}
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
					checks.setMethod(ev.target.value);
				}
			}, checks.METHODS.map((p) => E('option', { 'value': p[0], 'selected': p[0] === checks.method ? '' : null }, p[1]))));

			side.push(mh.button({
				icon: 'zap', text: _('Test latency'), busy: this.busy.probeAll,
				click: ui.createHandlerFn(checks, 'probeAll', proxies)
			}));
		}

		if (proxies.length || subNames.length)
			side.push(mh.button({
				icon: 'refresh', text: _('Refresh the dashboard'), busy: this.busy.refresh,
				click: ui.createHandlerFn(this, 'refreshServers')
			}));

		side.push(mh.button({ icon: 'activity', text: _('Active connections'), click: () => conns.open() }));

		// The pages that open over the dashboard.
		side.push(E('div', { 'class': 'mh-side-gap' }));
		side.push(this.navButton('servers', 'plus', 'cbi-button-add mh-navbtn', _('Add connection')));
		side.push(this.navButton('sections', 'route', 'cbi-button mh-navbtn'));
		side.push(this.navButton('settings', 'settings', 'cbi-button mh-navbtn'));
		side.push(this.navButton('components', 'package', 'cbi-button mh-navbtn'));
		side.push(E('div', { 'class': 'mh-side-gap' }));

		return E('div', { 'class': 'mh-box mh-side' }, side.concat(diag.controls()));
	},


	renderTunnel(s, now) {
		const t = s.tunnel || {};
		const state = t.state === 'up' ? [ 'mh-ok', '✔ ' + _('Works') ]
			: t.state === 'down' ? [ 'mh-fail', '✘ ' + _('Down, traffic goes direct') ]
			: t.state === 'held' ? [ 'mh-fail', '✘ ' + _('Down, traffic waits for it (KillSwitch)') ]
			: [ 'mh-muted', _('Unknown') ];
		const info = [ _('Interface %s').format(s.interface || '?'), s.mode === 'xray' ? _('Through Xray') : _('Kernel mode') ];

		if (t.handshake)
			info.push(_('Last handshake %s').format(mh.ago(t.handshake, now)));

		info.push('↓ %s ↑ %s'.format(mh.bytes(s.traffic.down), mh.bytes(s.traffic.up)));

		return E('div', { 'class': 'mh-tunrow mh-head' }, [
			E('div', { 'class': 'mh-grow' }, [
				E('b', s.name), ' ',
				E('span', { 'class': 'mh-muted mh-small' }, _('Tunnel') + ' · ' + info.join(' · '))
			]),
			E('span', { 'class': state[0] }, state[1])
		]);
	},

	// Subscriptions xray has no servers of: turned off, not downloaded yet or
	// failed. Their state is still worth seeing.
	renderLoose(subs, now) {
		return Object.values(subs).filter((s) => !s.shown).map((s) => E('div', { 'class': 'mh-group' }, [
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

		// Subscriptions xray has no servers of are groups of the list too;
		// with nothing at all, the list asks for a server.
		const loose = this.renderLoose(subs, d.time);
		let list = boxes.find((b) => b.classList.contains('mh-list'));

		if (!list) {
			list = loose.length ? E('div', { 'class': 'mh-box mh-section mh-list' },
				[ E('div', { 'class': 'mh-ghead' }, [ E('span', { 'class': 'mh-title' }, _('Server list')) ]) ]) : this.emptyPool();
			list.classList.add('mh-list');
			boxes.unshift(list);
		}

		loose.forEach((g) => list.appendChild(g));

		// Tunnels that are not servers of the list but carry the traffic of
		// routing rules: their state, as the last group of the same box.
		const tunnels = sections.filter((s) => s.type === 'interface');

		if (tunnels.length)
			list.appendChild(E('div', { 'class': 'mh-group' }, [
				E('div', { 'class': 'mh-ghead' }, [
					E('span', { 'class': 'mh-title' }, _('Tunnels for rules')),
					E('span', { 'class': 'mh-muted mh-small' }, _('not servers of the list: they carry the traffic of their sections under Routing'))
				])
			].concat(tunnels.map((t) => this.renderTunnel(t, d.time)))));

		// The connection and the system on top, the servers under them, the
		// column of buttons at the side all the way down.
		const [ conn, sys ] = this.renderWidgets(d);
		const side = this.renderSide(d);

		conn.classList.add('mh-a-conn');
		sys.classList.add('mh-a-sys');
		side.classList.add('mh-a-side');

		return [ this.renderTop(d), this.renderAlert(d), E('div', { 'class': 'mh-layout' }, [
			conn, sys, side,
			E('div', { 'class': 'mh-stack mh-a-servers' }, boxes)
		]) ];
	},

	render(d) {
		this.data = d;
		this.hideGone(d);
		checks.bind(this);
		chain.bind(this);

		if (checks.known(d.ping_method))
			checks.method = d.ping_method;

		// The URL test: its numbers came with the page. Another ping method:
		// the servers are checked with it once when the page opens, and show
		// no number until then (see latency()).
		checks.firstCheck = !(checks.method === 'url' && checks.applyWarm(d.warm));

		window.setTimeout(() => {
			const proxies = (d.sections || []).filter((s) => s.type === 'proxy' && (s.nodes || []).length);
			const done = () => {
				checks.firstCheck = false;
				this.redraw();
			};

			if (checks.method === 'url')
				return (checks.warm ? Promise.resolve() : checks.pollWarm(false)).then(done, done).then(() => checks.checkConnection());

			return (proxies.length ? checks.probeAll(proxies) : checks.checkConnection()).then(done, done);
		}, 0);

		// Behind an open window or dialog, in a hidden tab or while the last answer has
		// not come yet, the dashboard does not ask: rpcd answers one call at a
		// time, and a queue of polls made the browser drop the calls of the
		// window ("XHR request aborted"). A failed poll is just skipped.
		let polling = false;

		poll.add(() => {
			if (polling || document.hidden || sheet.isOpen() || document.body.classList.contains('modal-overlay-active'))
				return Promise.resolve();

			polling = true;

			return this.refresh().then(() => (checks.method === 'url' && this.data && this.data.running) ? checks.pollWarm(false) : null)
				.catch(() => {}).finally(() => { polling = false; });
		}, 3);

		// First: the section headers draw its buttons.
		const dialogs = diag.render({ state: () => this.data, refresh: () => this.refresh(), redraw: () => this.redraw() });

		// A page that reloads itself (renaming, a restore) opens again.
		window.setTimeout(() => sheet.restore(() => this.refresh()), 0);

		return E('div', { 'class': 'cbi-map mh-page mh-stack' }, [
			mh.style(),
			E('style', CSS),
			sheet.style(),
			dialogs,
			E('div', { 'id': 'mayhem-body', 'class': 'mh-stack' }, this.renderBody(d))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
