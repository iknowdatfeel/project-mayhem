'use strict';
'require view';
'require rpc';
'require ui';
'require mayhem.common as mh';

// Diagnostics laid out like podkop's: the checks on the left, one box per
// part of the traffic path; actions and versions on the right.

const callDiagnose = rpc.declare({ object: 'luci.mayhem', method: 'diagnose', params: [ 'part', 'target' ], expect: { '': {} } });
const callDashboard = rpc.declare({ object: 'luci.mayhem', method: 'dashboard', expect: { '': {} } });
const callAction = rpc.declare({ object: 'luci.mayhem', method: 'action', params: [ 'name' ], expect: { '': {} } });
const callSysinfo = rpc.declare({ object: 'luci.mayhem', method: 'sysinfo', expect: { '': {} } });

// [ group, title, request part that fills it ]
const GROUPS = [
	[ 'service', _('Service'), 'local' ],
	[ 'config', _('Configuration'), 'local' ],
	[ 'xray', 'xray', 'local' ],
	[ 'kernel', _('nftables and routing'), 'local' ],
	[ 'dns', _('DNS'), 'dns' ],
	[ 'tunnels', _('Tunnels'), 'local' ],
	[ 'exit', _('External address'), 'exit' ],
	[ 'data', _('Geo data, lists and subscriptions'), 'local' ],
	[ 'system', _('System'), 'local' ]
];

const ITEM_ICON = { ok: 'check', warn: 'alert', fail: 'x', info: 'circle-idle' };

// Check names come from the router in English; known ones are translated here.
const NAMES = {
	'Routing': _('Routing'),
	'Other proxy clients': _('Other proxy clients'),
	'Error': _('Error'),
	'Warning': _('Warning'),
	'Configuration': _('Configuration'),
	'Version': _('Version'),
	'Memory': _('Memory'),
	'Ports': _('Ports'),
	'nftables': 'nftables',
	'Policy routing': _('Policy routing'),
	'dnsmasq': 'dnsmasq',
	'Redirect to xray': _('Redirect to xray'),
	'Clock': _('Clock'),
	'Watchdog': _('Watchdog'),
	'Direct': _('Direct'),
	'Domain outside the lists (openwrt.org)': _('Domain outside the lists (openwrt.org)')
};

const CSS = `
.mh-diag { display:grid; grid-template-columns:2fr 1fr; grid-column-gap:10px; align-items:start; }
@media (max-width: 800px) { .mh-diag { grid-template-columns:1fr; grid-row-gap:10px; } }
.mh-run button { width:100%; }
.mh-check { display:grid; grid-template-columns:24px 1fr; grid-column-gap:10px; align-items:center; }
.mh-check > .mh-icon { width:24px; height:24px; }
.mh-check-items { grid-column:2; margin-top:8px; display:grid; grid-row-gap:3px; }
.mh-item { display:grid; grid-template-columns:16px auto 1fr; grid-column-gap:8px; align-items:start; }
.mh-item > b { white-space:nowrap; }
.mh-item > div { word-break:break-word; }
.mh-actions button { width:100%; }
.mh-info-row { display:grid; grid-template-columns:auto 1fr; grid-column-gap:8px; }
`;

return view.extend({
	checks: [],
	done: {},
	running: false,
	acting: null,
	state: {},
	sys: {},

	load() {
		return Promise.all([
			L.resolveDefault(callDashboard(), {}),
			L.resolveDefault(callSysinfo(), {})
		]);
	},

	add(r) {
		if (r && r.checks)
			this.checks = this.checks.concat(r.checks);
		else if (r && r.error)
			this.checks.push({ group: 'system', name: 'Error', status: 'fail', detail: r.error });

		this.draw();
	},

	run() {
		if (this.running)
			return Promise.resolve();

		this.running = true;
		this.checks = [];
		this.done = {};
		this.draw();

		return callDiagnose('local', '').then((r) => {
			this.done.local = true;
			this.add(r);

			let p = callDiagnose('dns', '').then((d) => {
				this.done.dns = true;
				this.add(d);
			});

			// One request per target: each may take up to 10 seconds.
			for (const t of (r.targets || []))
				p = p.then(() => callDiagnose('exit', t.id)).then((d) => this.add(d));

			return p.then(() => { this.done.exit = true; });
		}).catch((e) => {
			this.add({ error: e.message });
		}).finally(() => {
			this.running = false;
			this.done = { local: true, dns: true, exit: true };
			this.draw();
		});
	},

	act(name) {
		this.acting = name;
		this.draw();

		return callAction(name).then(() => L.resolveDefault(callDashboard(), {})).then((d) => {
			this.state = d;
		}).finally(() => {
			this.acting = null;
			this.draw();
		});
	},

	report() {
		const s = this.sys;
		const lines = [
			'Mayhem diagnostics, ' + new Date().toISOString(),
			'Mayhem %s, xray %s, %s, %s'.format(s.mayhem || '?', s.xray || '?', s.openwrt || '?', s.model || '?')
		];

		for (const [ g, title ] of GROUPS) {
			const items = this.checks.filter((c) => c.group === g);

			if (!items.length)
				continue;

			lines.push('', '[' + title + ']');
			items.forEach((c) => lines.push('%s %s: %s'.format({ ok: '✔', warn: '!', fail: '✖' }[c.status] || '·', c.name, c.detail)));
		}

		return lines.join('\n');
	},

	copy() {
		const area = E('textarea', { 'style': 'width:100%;height:20em;font-family:monospace', 'readonly': '' }, this.report());

		ui.showModal(_('Diagnostics report'), [
			E('p', _('Copy the report and attach it to a question or a bug report. It holds no keys or passwords, but it does show your external addresses.')),
			area,
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close')))
		]);

		area.select();
	},

	// --- left: checks ------------------------------------------------------------

	checkBox(group, title, part) {
		const items = this.checks.filter((c) => c.group === group);
		const started = this.running || this.checks.length;
		let state, desc;

		if (!started) {
			state = 'idle';
			desc = _('Not checked yet');
		}
		else if (!this.done[part]) {
			state = 'busy';
			desc = _('Checking…');
		}
		else if (!items.length) {
			state = 'idle';
			desc = _('Nothing to check');
		}
		else if (items.some((c) => c.status === 'fail')) {
			state = 'fail';
			desc = _('Problems found');
		}
		else if (items.some((c) => c.status === 'warn')) {
			state = 'warn';
			desc = _('Works, with warnings');
		}
		else {
			state = 'ok';
			desc = _('All checks passed');
		}

		const icon = { idle: 'circle-idle', busy: 'loader', fail: 'circle-x', warn: 'circle-alert', ok: 'circle-check' }[state];
		const color = { idle: 'mh-muted', busy: 'mh-busy', fail: 'mh-fail', warn: 'mh-warn', ok: 'mh-ok' }[state];

		const box = E('div', { 'class': 'mh-box mh-check ' + (state === 'idle' ? '' : 'mh-box--' + state) }, [
			E('span', { 'class': color }, mh.icon(icon)),
			E('div', [ E('b', { 'class': color }, title), E('div', { 'class': 'mh-small mh-muted' }, desc) ])
		]);

		if (items.length)
			box.appendChild(E('div', { 'class': 'mh-check-items mh-small' }, items.map((c) => E('div', {
				'class': 'mh-item ' + ({ ok: 'mh-ok', warn: 'mh-warn', fail: 'mh-fail' }[c.status] || 'mh-muted')
			}, [ mh.icon(ITEM_ICON[c.status] || 'circle-idle', true), E('b', NAMES[c.name] || c.name), E('div', c.detail) ]))));

		return box;
	},

	// --- right: actions and versions ----------------------------------------------

	actions() {
		const d = this.state;
		const busy = (n) => this.acting === n;
		const any = this.acting != null;
		const btn = (name, icon, cls, text) => mh.button({
			icon: icon, cls: cls, text: text, busy: busy(name), disabled: any,
			click: ui.createHandlerFn(this, 'act', name)
		});

		const list = [ E('b', _('Actions')) ];

		if (d.enabled) {
			list.push(btn('restart', 'restart', 'cbi-button-apply', _('Restart Mayhem')));
			list.push(d.running ? btn('stop', 'stop', 'cbi-button-remove', _('Stop until restart'))
				: btn('start', 'play', 'cbi-button-save', _('Start Mayhem')));
			list.push(btn('disable', 'pause', 'cbi-button-remove', _('Turn Mayhem off')));
		}
		else {
			list.push(btn('enable', 'play', 'cbi-button-save', _('Turn Mayhem on')));
		}

		list.push(mh.button({ icon: 'logs', text: _('View logs'), click: () => { window.location.href = L.url('admin/services/mayhem/logs'); } }));
		list.push(mh.button({ icon: 'copy', text: _('Copy report'), disabled: !this.checks.length, click: ui.createHandlerFn(this, 'copy') }));

		return E('div', { 'class': 'mh-box mh-stack mh-actions' }, list);
	},

	sysInfo() {
		const s = this.sys;
		const rows = [
			[ 'Mayhem', s.mayhem ],
			[ 'xray', s.xray ],
			[ 'OpenWrt', s.openwrt ],
			[ _('Device'), s.model ],
			[ _('Kernel'), s.kernel ]
		];

		return E('div', { 'class': 'mh-box mh-stack' }, [ E('b', _('System information')) ].concat(rows.map((r) =>
			E('div', { 'class': 'mh-info-row' }, [ E('b', r[0]), E('span', r[1] || '—') ]))));
	},

	draw() {
		const out = document.getElementById('mayhem-diag');

		if (!out)
			return;

		out.replaceChildren(
			E('div', { 'class': 'mh-stack' }, [
				E('div', { 'class': 'mh-run' }, mh.button({
					icon: 'search', cls: 'cbi-button-apply', text: this.running ? _('Checking…') : _('Run diagnostics'),
					busy: this.running, click: ui.createHandlerFn(this, 'run')
				}))
			].concat(GROUPS.map((g) => this.checkBox(g[0], g[1], g[2])))),
			E('div', { 'class': 'mh-stack' }, [
				E('div', { 'class': 'mh-box mh-small mh-muted' }, _('Checks every part of the traffic path. External addresses are requested through each section, so you can see where the traffic really leaves.')),
				this.actions(),
				this.sysInfo()
			])
		);
	},

	render(data) {
		this.state = data[0] || {};
		this.sys = data[1] || {};

		const view = E('div', { 'class': 'cbi-map mh-page' }, [
			mh.style(),
			E('style', CSS),
			E('h2', _('Diagnostics')),
			E('div', { 'class': 'mh-diag', 'id': 'mayhem-diag' })
		]);

		window.requestAnimationFrame(() => this.draw());

		return view;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
