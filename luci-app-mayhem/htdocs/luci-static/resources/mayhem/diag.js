'use strict';
'require baseclass';
'require rpc';
'require uci';
'require ui';
'require mayhem.common as mh';

// Diagnostics block of the dashboard, laid out like podkop's: the checks on
// the left, one box per part of the traffic path; actions, logs and versions
// on the right. The logs open in a dialog.

const callDiagnose = rpc.declare({ object: 'luci.mayhem', method: 'diagnose', params: [ 'part', 'target' ], expect: { '': {} } });
const callAction = rpc.declare({ object: 'luci.mayhem', method: 'action', params: [ 'name' ], expect: { '': {} } });
const callSysinfo = rpc.declare({ object: 'luci.mayhem', method: 'sysinfo', expect: { '': {} } });
const callLogs = rpc.declare({ object: 'luci.mayhem', method: 'logs', params: [ 'component', 'lines' ], expect: { '': {} } });
const callLevel = rpc.declare({ object: 'luci.mayhem', method: 'set_log_level', params: [ 'level' ], expect: { '': {} } });

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
.mh-run button, .mh-actions button { width:100%; }
.mh-check { display:grid; grid-template-columns:24px 1fr; grid-column-gap:10px; align-items:center; }
.mh-check > span > .mh-icon { width:24px; height:24px; }
.mh-check-items { grid-column:2; margin-top:8px; display:grid; grid-row-gap:3px; }
.mh-item { display:grid; grid-template-columns:16px auto 1fr; grid-column-gap:8px; align-items:start; }
.mh-item > b { white-space:nowrap; }
.mh-item > div { word-break:break-word; }
.mh-info-row { display:grid; grid-template-columns:auto 1fr; grid-column-gap:8px; }
.mh-log { height:60vh; overflow:auto; white-space:pre-wrap; font-size:12px; }
.mh-log-tools { display:flex; flex-wrap:wrap; gap:8px; align-items:center; margin:8px 0; }
.mh-log-tools select { width:auto; }
`;

return baseclass.extend({
	checks: [],
	done: {},
	running: false,
	acting: null,
	sys: {},
	node: null,

	// opts.state(): the dashboard data (enabled, running); opts.refresh(): reload it.
	render(opts) {
		this.opts = opts;
		this.node = E('div', { 'class': 'mh-diag', 'id': 'mayhem-diag' });

		L.resolveDefault(callSysinfo(), {}).then((s) => {
			this.sys = s;
			this.draw();
		});

		window.requestAnimationFrame(() => this.draw());

		return E('div', [ E('style', CSS), this.node ]);
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

			return p;
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

		return callAction(name).then(() => this.opts.refresh()).finally(() => {
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

	// --- logs dialog -------------------------------------------------------------

	logs() {
		let component = 'all', lines = 300, follow = true, timer = null;
		const pre = E('pre', { 'class': 'mh-log' }, _('Loading…'));

		const show = () => callLogs(component, lines).then((r) => {
			const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;

			pre.textContent = (r.lines || []).join('\n') || _('No messages yet.');

			if (atEnd)
				pre.scrollTop = pre.scrollHeight;
		});

		const select = (opts, value, change) => E('select', { 'class': 'cbi-input-select', 'change': change },
			opts.map((o) => E('option', { 'value': o[0], 'selected': o[0] === value ? '' : null }, o[1])));

		const close = () => {
			window.clearInterval(timer);
			ui.hideModal();
		};

		return uci.load('mayhem').then(() => {
			const level = uci.get('mayhem', 'settings', 'log_level') || 'warning';

			ui.showModal(_('Logs'), [
				E('div', { 'class': 'mh-small mh-muted' }, _('Messages of Mayhem, xray and dnsmasq from the system log. At the debug level xray logs every connection and DNS query: turn it back down when you are done.')),
				E('div', { 'class': 'mh-log-tools' }, [
					select([ [ 'all', _('Everything') ], [ 'mayhem', 'Mayhem' ], [ 'xray', 'xray' ], [ 'dnsmasq', 'dnsmasq' ] ], component,
						(ev) => { component = ev.target.value; show(); }),
					select([ [ '100', _('100 lines') ], [ '300', _('300 lines') ], [ '1000', _('1000 lines') ] ], String(lines),
						(ev) => { lines = +ev.target.value; show(); }),
					E('label', [ E('input', { 'type': 'checkbox', 'checked': '', 'change': (ev) => follow = ev.target.checked }),
						' ', _('Refresh every 5 seconds') ]),
					E('span', { 'style': 'margin-left:auto' }, _('Log level') + ':'),
					select([ 'debug', 'info', 'warning', 'error', 'none' ].map((l) => [ l, l ]), level, (ev) => callLevel(ev.target.value).then((r) => {
						if (r.error)
							ui.addNotification(null, E('p', r.error), 'error');
					}))
				]),
				pre,
				E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': close }, _('Close')))
			], 'mh-logs-modal');

			show().then(() => { pre.scrollTop = pre.scrollHeight; });

			// Stops by itself once the dialog is gone, however it was closed.
			timer = window.setInterval(() => {
				if (!document.contains(pre))
					return window.clearInterval(timer);

				if (follow && !document.hidden)
					show();
			}, 5000);
		});
	},

	// --- drawing -------------------------------------------------------------------

	checkBox(group, title, part) {
		const items = this.checks.filter((c) => c.group === group);
		let state, desc;

		if (!this.done[part]) {
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

	actions() {
		const d = this.opts.state() || {};
		const any = this.acting != null;
		const btn = (name, icon, cls, text) => mh.button({
			icon: icon, cls: cls, text: text, busy: this.acting === name, disabled: any,
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

		list.push(mh.button({ icon: 'logs', text: _('Logs'), click: ui.createHandlerFn(this, 'logs') }));
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
		if (!this.node)
			return;

		const left = [
			E('div', { 'class': 'mh-run' }, mh.button({
				icon: 'search', cls: 'cbi-button-apply', text: this.running ? _('Checking…') : _('Run diagnostics'),
				busy: this.running, click: ui.createHandlerFn(this, 'run')
			}))
		];

		// The boxes appear with the first run: idle ones would only take room.
		if (this.running || this.checks.length)
			GROUPS.forEach((g) => left.push(this.checkBox(g[0], g[1], g[2])));
		else
			left.push(E('div', { 'class': 'mh-box mh-small mh-muted' }, _('Checks every part of the traffic path. External addresses are requested through each section, so you can see where the traffic really leaves.')));

		this.node.replaceChildren(
			E('div', { 'class': 'mh-stack' }, left),
			E('div', { 'class': 'mh-stack' }, [ this.actions(), this.sysInfo() ])
		);
	}
});
