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
.mh-toolbar { display:flex; flex-wrap:wrap; align-items:center; gap:8px; }
.mh-toolbar .mh-grow { flex:1 1 auto; }
.mh-drow { border-bottom:1px solid var(--background-color-low, lightgray); }
.mh-drow > summary { display:flex; align-items:center; gap:8px; padding:7px 2px; cursor:pointer; list-style:none; }
.mh-drow > summary::-webkit-details-marker { display:none; }
.mh-drow > summary > b { flex:1 1 auto; }
.mh-drow-items { display:grid; grid-row-gap:3px; padding:0 0 8px 28px; }
.mh-item { display:grid; grid-template-columns:16px auto 1fr; grid-column-gap:8px; align-items:start; }
.mh-item > b { white-space:nowrap; }
.mh-item > div { word-break:break-word; }
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
	list: null,

	// A row of buttons under the sections: diagnostics and logs open in
	// dialogs. opts.state(): the dashboard data; opts.refresh(): reload it.
	render(opts) {
		this.opts = opts;
		this.node = E('div', { 'class': 'mh-box mh-toolbar', 'id': 'mayhem-tools' });

		L.resolveDefault(callSysinfo(), {}).then((s) => { this.sys = s; });
		window.requestAnimationFrame(() => this.draw());

		return E('div', [ E('style', CSS), this.node ]);
	},

	add(r) {
		if (r && r.checks)
			this.checks = this.checks.concat(r.checks);
		else if (r && r.error)
			this.checks.push({ group: 'system', name: 'Error', status: 'fail', detail: r.error });

		this.drawList();
	},

	run() {
		if (this.running)
			return Promise.resolve();

		this.running = true;
		this.checks = [];
		this.done = {};
		this.drawList();

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
			this.drawList();
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
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.createHandlerFn(this, 'diagnostics', false) }, _('Back')), ' ',
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
			])
		]);

		area.select();
	},

	// --- diagnostics dialog ---------------------------------------------------------

	// Opens the dialog; a new run starts unless `fresh` is false.
	diagnostics(fresh) {
		const s = this.sys;
		const versions = [ 'Mayhem ' + (s.mayhem || '?'), 'xray ' + (s.xray || '?') ];

		if (s.openwrt)
			versions.push(s.openwrt);

		if (s.model)
			versions.push(s.model);

		this.list = E('div');

		ui.showModal(_('Diagnostics'), [
			E('div', { 'class': 'mh-small mh-muted' }, _('Checks every part of the traffic path. External addresses are requested through each section, so you can see where the traffic really leaves.')),
			this.list,
			E('div', { 'class': 'mh-small mh-muted', 'style': 'margin-top:8px' }, versions.join(' · ')),
			E('div', { 'class': 'right', 'style': 'margin-top:8px' }, [
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'run') }, _('Run again')), ' ',
				E('button', { 'class': 'btn', 'click': ui.createHandlerFn(this, 'copy') }, _('Copy report')), ' ',
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
			])
		], 'mh-diag-modal');

		if (fresh !== false || !this.checks.length)
			return this.run();

		this.drawList();
	},

	// One line per part of the traffic path; the ones with problems are open.
	group(group, title, part) {
		const items = this.checks.filter((c) => c.group === group);
		const count = (st) => items.filter((c) => c.status === st).length;
		let state, desc;

		if (!this.done[part]) {
			state = 'busy';
			desc = _('Checking…');
		}
		else if (!items.length) {
			state = 'idle';
			desc = _('Nothing to check');
		}
		else if (count('fail')) {
			state = 'fail';
			desc = _('Problems found');
		}
		else if (count('warn')) {
			state = 'warn';
			desc = _('Works, with warnings');
		}
		else {
			state = 'ok';
			desc = _('All checks passed');
		}

		const icon = { idle: 'circle-idle', busy: 'loader', fail: 'circle-x', warn: 'circle-alert', ok: 'circle-check' }[state];
		const color = { idle: 'mh-muted', busy: 'mh-busy', fail: 'mh-fail', warn: 'mh-warn', ok: 'mh-ok' }[state];

		return E('details', { 'class': 'mh-drow', 'data-state': state, 'open': (state === 'fail' || state === 'warn') ? '' : null }, [
			E('summary', [
				E('span', { 'class': color }, mh.icon(icon)),
				E('b', title),
				E('span', { 'class': 'mh-small ' + color }, desc)
			]),
			E('div', { 'class': 'mh-drow-items mh-small' }, items.map((c) => E('div', {
				'class': 'mh-item ' + ({ ok: 'mh-ok', warn: 'mh-warn', fail: 'mh-fail' }[c.status] || 'mh-muted')
			}, [ mh.icon(ITEM_ICON[c.status] || 'circle-idle', true), E('b', NAMES[c.name] || c.name), E('div', c.detail) ])))
		]);
	},

	drawList() {
		if (!this.list || !document.contains(this.list))
			return;

		// A line the user opened or closed by hand stays so while its result
		// is the same.
		const before = {};

		this.list.querySelectorAll('details').forEach((d, i) => { before[i] = [ d.dataset.state, d.open ]; });

		this.list.replaceChildren(...GROUPS.map((g, i) => {
			const el = this.group(g[0], g[1], g[2]);

			if (before[i] && before[i][0] === el.dataset.state)
				el.open = before[i][1];

			return el;
		}));
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

	// --- toolbar ---------------------------------------------------------------------

	draw() {
		if (!this.node)
			return;

		const d = this.opts.state() || {};
		const any = this.acting != null;
		const btn = (name, icon, cls, text) => mh.button({
			icon: icon, cls: cls, text: text, busy: this.acting === name, disabled: any,
			click: ui.createHandlerFn(this, 'act', name)
		});

		const list = [
			mh.button({ icon: 'search', cls: 'cbi-button-apply', text: _('Diagnostics'), click: ui.createHandlerFn(this, 'diagnostics', true) }),
			mh.button({ icon: 'logs', text: _('Logs'), click: ui.createHandlerFn(this, 'logs') }),
			E('span', { 'class': 'mh-grow' })
		];

		if (d.enabled) {
			list.push(btn('restart', 'restart', 'cbi-button-apply', _('Restart')));
			list.push(d.running ? btn('stop', 'stop', 'cbi-button-remove', _('Stop until restart'))
				: btn('start', 'play', 'cbi-button-save', _('Start Mayhem')));
			list.push(btn('disable', 'pause', 'cbi-button-remove', _('Turn Mayhem off')));
		}
		else {
			list.push(btn('enable', 'play', 'cbi-button-save', _('Turn Mayhem on')));
		}

		this.node.replaceChildren(...list);
	}
});
