'use strict';
'require baseclass';
'require rpc';
'require ui';
'require mayhem.common as mh';

// Service controls of the dashboard: diagnostics, logs and the backup open in
// dialogs; restart, stop or start, autostart on boot.

const callDiagnose = rpc.declare({ object: 'luci.mayhem', method: 'diagnose', params: [ 'part', 'target' ], expect: { '': {} } });
const callAction = rpc.declare({ object: 'luci.mayhem', method: 'action', params: [ 'name' ], expect: { '': {} } });
const callSysinfo = rpc.declare({ object: 'luci.mayhem', method: 'sysinfo', expect: { '': {} } });
const callLogs = rpc.declare({ object: 'luci.mayhem', method: 'logs', params: [ 'component', 'lines', 'level' ], expect: { '': {} } });
const callExport = rpc.declare({ object: 'luci.mayhem', method: 'backup_export', params: [ 'connections' ], expect: { '': {} } });
const callImport = rpc.declare({ object: 'luci.mayhem', method: 'backup_import', params: [ 'backup' ], expect: { '': {} } });

// [ group, title, request part that fills it ]
const GROUPS = [
	[ 'service', _('Service'), 'local' ],
	[ 'config', _('Configuration'), 'local' ],
	[ 'xray', 'Xray', 'local' ],
	[ 'kernel', _('Nftables and routing'), 'local' ],
	[ 'dns', _('DNS'), 'dns' ],
	[ 'tunnels', _('Tunnels'), 'local' ],
	[ 'exit', _('External address'), 'exit' ],
	[ 'data', _('Geo data, lists and subscriptions'), 'local' ],
	[ 'system', _('System'), 'local' ]
];

const ITEM_ICON = { ok: 'check', warn: 'alert', fail: 'x', info: 'circle-idle' };

// Check names come from the router in English; known ones are translated here.
// Names and details of data checks come with the name of the thing checked.
function checkName(n) {
	if (NAMES[n])
		return NAMES[n];

	const m = /^(Geo source|Subscription|List) (.+)$/.exec(n || '');

	return m ? '%s %s'.format({ 'Geo source': _('Geo source'), 'Subscription': _('Subscription'), 'List': _('List') }[m[1]], m[2]) : n;
}

function checkAgo(s) {
	return String(s).replace(/(\d+) min ago/, (x, n) => _('%d min ago').format(+n))
		.replace(/(\d+) h ago/, (x, n) => _('%d h ago').format(+n))
		.replace(/(\d+) d ago/, (x, n) => _('%d d ago').format(+n));
}

function checkDetail(d) {
	const details = {
		'no generated configuration status': _('No generated configuration status'),
		'remote DNS failed; queries may use the provider fallback': _('Remote DNS failed; queries may use the provider fallback'),
		'VPN failed; traffic waits for it': _('VPN failed; traffic waits for it'),
		'VPN failed; traffic goes direct': _('VPN failed; traffic goes direct'),
		'no active VPN server; the section may be using direct fallback': _('No active VPN server; the section may be using direct fallback'),
		'VPN server did not answer': _('VPN server did not answer'),
		'traffic waits for the VPN': _('Traffic waits for the VPN'),
		'traffic uses direct fallback': _('Traffic uses direct fallback')
	};
	if (details[d]) return details[d];
	let m;
	if ((m = /^VPN server answered, HTTP ([0-9]+)$/.exec(d || '')))
		return _('VPN server answered, HTTP %s').format(m[1]);

	if ((m = /^(\d+) (categories|servers)(, updated (.+))?$/.exec(d || '')))
		return (m[2] === 'categories' ? _('Categories: %d') : _('%d servers')).format(+m[1]) +
			(m[4] ? ', ' + _('updated %s').format(checkAgo(m[4])) : '');

	if ((m = /^updated (.+)$/.exec(d || '')))
		return _('Updated %s').format(checkAgo(m[1]));

	if (d === 'not downloaded yet')
		return _('Not downloaded yet');

	if (d === 'not downloaded: no section uses it yet')
		return _('Not downloaded: no section uses it yet');

	return d;
}

const NAMES = {
	'Routing': _('Routing'),
	'Other proxy clients': _('Other proxy clients'),
	'Error': _('Error'),
	'Warning': _('Warning'),
	'Configuration': _('Configuration'),
	'Version': _('Version'),
	'Memory': _('Memory'),
	'Ports': _('Ports'),
	'nftables': 'Nftables',
	'Policy routing': _('Policy routing'),
	'dnsmasq': 'Dnsmasq',
	'DNS policy': _('DNS policy'),
	'Remote DNS': _('Remote DNS'),
	'Clock': _('Clock'),
	'Watchdog': _('Watchdog'),
	'Direct': _('Direct'),
	'pool': _('Server list'),
	'Domain outside the lists (openwrt.org)': _('Domain outside the lists (openwrt.org)')
};

const CSS = `
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
.mh-backup { display:grid; grid-row-gap:6px; padding:8px 0 12px; border-bottom:1px solid var(--background-color-low, lightgray); }
.mh-backup:last-of-type { border-bottom:0; }
.mh-backup .btn { justify-self:start; }
`;

return baseclass.extend({
	checks: [],
	done: {},
	running: false,
	acting: null,
	sys: {},
	node: null,
	list: null,

	// opts.state(): the dashboard data; opts.refresh(): reload it;
	// opts.redraw(): draw it again. Returns the styles for the dialogs.
	render(opts) {
		this.opts = opts;

		L.resolveDefault(callSysinfo(), {}).then((s) => { this.sys = s; });

		return E('style', CSS);
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

		const request = (part, target) => callDiagnose(part, target).then((r) => {
			if (!r || r.error || !Array.isArray(r.checks) || !r.checks.length)
				throw new Error((r && r.error) || _('No diagnostic result'));
			this.add(r);
			return r;
		}).catch((e) => {
			this.add({ checks: [ { group: part === 'local' ? 'service' : part,
				name: target || _('Diagnostics'), status: 'fail', detail: e.message } ] });
			return {};
		});

		return request('local', '').then((r) => {
			this.done.local = true;
			let p = request('dns', '').then(() => { this.done.dns = true; this.drawList(); });
			for (const t of (r.targets || []))
				p = p.then(() => request('exit', t.id));
			return p;
		}).finally(() => {
			this.running = false;
			this.done = { local: true, dns: true, exit: true };
			this.drawList();
		});
	},

	act(name) {
		this.acting = name;
		this.opts.redraw();

		return callAction(name).finally(() => {
			this.acting = null;
			return this.opts.refresh();
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
			items.forEach((c) => lines.push('%s %s: %s'.format({ ok: '✔', warn: '!', fail: '✖' }[c.status] || '·', c.name, mh.ipText(c.detail))));
		}

		return lines.join('\n');
	},

	copy() {
		const area = E('textarea', { 'style': 'width:100%;height:20em;font-family:monospace', 'readonly': '' }, this.report());

		ui.showModal(_('Diagnostics report'), [
			E('p', _('Copy the report and attach it to a question or a bug report. It holds no keys or passwords, but it does show your external addresses.')),
			area,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Back'))
			])
		]);

		area.select();
	},

	// --- diagnostics dialog ---------------------------------------------------------

	// The same content is used in the Settings tab and the dashboard dialog.
	diagnosticContent() {
		const s = this.sys;
		const versions = [ 'Mayhem ' + (s.mayhem || '?'), 'xray ' + (s.xray || '?'), s.openwrt, s.model ].filter(Boolean);
		this.list = E('div');
		return E('div', [
			E('div', { 'class': 'mh-small mh-muted mh-note' }, [
				E('span', _('Checks every part of the traffic path. External addresses are requested through each section, so you can see where the traffic really leaves.')),
				mh.ipEye()
			]),
			this.list,
			E('div', { 'class': 'mh-small mh-muted', 'style': 'margin-top:8px' }, versions.join(' · ')),
			E('div', { 'class': 'right', 'style': 'margin-top:8px' }, [
				E('button', { 'class': 'btn', 'click': ui.createHandlerFn(this, 'logs') }, _('Logs')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'run') }, _('Run again')), ' ',
				E('button', { 'class': 'btn', 'click': ui.createHandlerFn(this, 'copy') }, _('Copy report'))
			])
		]);
	},

	diagnostics(fresh) {
		ui.showModal(_('Diagnostics'), [ this.diagnosticContent(),
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Back')))
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
		else if (count('info')) {
			state = 'idle';
			desc = _('Some checks could not be confirmed');
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
			}, [ mh.icon(ITEM_ICON[c.status] || 'circle-idle', true), E('b', checkName(c.name)), E('div', [ mh.ipSpan(checkDetail(c.detail), false) ]) ])))
		]);
	},

	drawList() {
		if (!this.list || !document.contains(this.list))
			return;

		// A line the user opened or closed by hand stays so while its result
		// is the same.
		const before = {};

		this.list.querySelectorAll('details').forEach((d) => { before[d.dataset.group] = [ d.dataset.state, d.open ]; });

		this.list.replaceChildren(...GROUPS.filter((g) => g[0] !== 'tunnels' || this.checks.some((c) => c.group === 'tunnels')).map((g) => {
			const el = this.group(g[0], g[1], g[2]);

			el.dataset.group = g[0];
			if (before[g[0]] && before[g[0]][0] === el.dataset.state)
				el.open = before[g[0]][1];

			return el;
		}));
	},

	// --- logs tab ---------------------------------------------------------------

	logs() {
		ui.showModal(_('Logs'), [
			this.logContent(),
			E('div', { 'class': 'right' },
				E('button', {
					'class': 'btn',
					'click': () => {
						this.stopLogs();
						ui.hideModal();
					}
				}, _('Back')))
		]);
		this.startLogs();
	},

	stopLogs() {
		if (this.logView) this.logView.stop();
	},

	startLogs() {
		if (this.logView) this.logView.start();
	},

	logContent() {
		this.stopLogs();
		let component = 'all', level = 'all', lines = 300, follow = true, timer = null, raw = '';
		try {
			const saved = window.localStorage.getItem('mayhem.log.filter.level');
			if ([ 'all', 'debug', 'info', 'warning', 'error' ].indexOf(saved) >= 0) level = saved;
		}
		catch (e) {}
		let active = false, busy = false, revision = 0, pending = false, first = true;
		const pre = E('pre', { 'class': 'mh-log' }, _('Loading…'));
		const error = E('div', { 'class': 'mh-fail', 'role': 'status' });
		const onIp = () => {
			const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
			const scroll = pre.scrollTop;
			pre.textContent = mh.ipText(raw || _('No messages yet.'));
			pre.scrollTop = atEnd ? pre.scrollHeight : scroll;
		};
		const schedule = () => {
			window.clearTimeout(timer);
			if (active && follow) timer = window.setTimeout(show, 5000);
		};
		const show = () => {
			window.clearTimeout(timer);
			if (!active) return Promise.resolve();
			if (busy) { pending = true; return Promise.resolve(); }
			if (document.hidden) { schedule(); return Promise.resolve(); }
			busy = true;
			pending = false;
			const mine = revision;
			return callLogs(component, lines, level).then((r) => {
				if (!active || mine !== revision) return;
				if (r.error || !Array.isArray(r.lines)) throw new Error(r.error || _('No log result'));
				const atEnd = first || pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
				const scroll = pre.scrollTop;
				raw = r.lines.join('\n');
				onIp();
				error.textContent = '';
				pre.scrollTop = atEnd ? pre.scrollHeight : scroll;
				first = false;
			}).catch((e) => {
				if (!active || mine !== revision) return;
				error.textContent = e.message || String(e);
				if (first) pre.textContent = '';
			}).finally(() => {
				busy = false;
				if (active && pending) show();
				else schedule();
			});
		};
		const change = () => { revision++; first = true; pre.textContent = _('Loading…'); raw = ''; show(); };
		const select = (opts, value, change) => E('select', { 'class': 'cbi-input-select', 'change': change },
			opts.map((o) => E('option', { 'value': o[0], 'selected': o[0] === value ? '' : null }, o[1])));
		this.logView = {
			start: () => {
				if (active) return;
				active = true;
				if (!first) onIp();
				document.addEventListener('mh-ip-change', onIp);
				show();
			},
			stop: () => {
				active = false;
				revision++;
				pending = false;
				window.clearTimeout(timer);
				document.removeEventListener('mh-ip-change', onIp);
			}
		};
		return E('div', [
			E('div', { 'class': 'mh-small mh-muted' }, _('Messages of Mayhem, xray and dnsmasq from the system log. At the debug level xray logs every connection and DNS query: turn it back down when you are done.')),
			E('div', { 'class': 'mh-log-tools' }, [
				select([ [ 'all', _('Everything') ], [ 'mayhem', 'Mayhem' ], [ 'xray', 'Xray' ], [ 'dnsmasq', 'Dnsmasq' ] ], component,
					(ev) => { component = ev.target.value; change(); }),
				E('label', [ _('Minimum displayed level') + ': ',
					select([ [ 'all', _('All levels') ], [ 'debug', 'debug' ], [ 'info', 'info' ], [ 'warning', 'warning' ], [ 'error', 'error' ] ], level,
						(ev) => {
							level = ev.target.value;
							try { window.localStorage.setItem('mayhem.log.filter.level', level); }
							catch (e) {}
							change();
						}) ]),
				select([ [ '100', _('100 lines') ], [ '300', _('300 lines') ], [ '1000', _('1000 lines') ] ], String(lines),
					(ev) => { lines = +ev.target.value; change(); }),
				E('label', [ E('input', { 'type': 'checkbox', 'checked': '', 'change': (ev) => {
					follow = ev.target.checked;
					window.clearTimeout(timer);
					if (follow) show();
				} }), ' ', _('Refresh every 5 seconds') ]),
				E('span', { 'class': 'mh-ip' }, [ E('span', { 'class': 'mh-small mh-muted' }, _('IP addresses')), mh.ipEye() ])
			]),
			error, pre
		]);
	},

	// --- backup ----------------------------------------------------------------------
	// All settings in one JSON file; subscriptions and server keys only when
	// asked for. Restoring a file without them keeps the router's own.

	backup() {
		const links = E('input', { 'type': 'checkbox', 'checked': '' });
		const file = E('input', { 'type': 'file', 'accept': '.json,application/json', 'style': 'display:none' });
		const found = E('div');

		const download = () => callExport(links.checked).then((b) => {
			if (!b || b.mayhem_backup !== 1) {
				ui.addNotification(null, E('p', _('The router did not return a backup.')), 'error');
				return;
			}

			const day = new Date().toISOString().slice(0, 10);
			const a = E('a', {
				'href': URL.createObjectURL(new Blob([ JSON.stringify(b, null, '\t') ], { 'type': 'application/json' })),
				'download': 'mayhem-%s%s.json'.format(day, b.connections ? '' : '-no-keys')
			});

			document.body.appendChild(a);
			a.click();
			window.setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
		});

		const restore = (b) => callImport(b).then((r) => {
			if (r.error) {
				ui.addNotification(null, E('p', r.error), 'error');
				return;
			}

			ui.hideModal();
			ui.addNotification(null, E('p', r.kept_connections
				? _('Settings restored; the subscriptions and server keys of this router are kept. Mayhem applies them now.')
				: _('Settings restored. Mayhem applies them now.')), 'info');
			window.setTimeout(() => this.opts.refresh(), 3000);
		});

		file.addEventListener('change', () => {
			const f = file.files[0];

			if (!f)
				return;

			f.text().then((t) => {
				let b;

				try {
					b = JSON.parse(t);
				}
				catch (e) {
					b = null;
				}

				if (!b || b.mayhem_backup !== 1 || !Array.isArray(b.sections)) {
					found.replaceChildren(E('p', { 'class': 'mh-fail' }, _('This file is not a Mayhem backup.')));
					return;
				}

				found.replaceChildren(
					E('p', [
						E('b', f.name), E('br'),
						_('Made %s, Mayhem %s.').format(b.created ? new Date(b.created * 1000).toLocaleString() : '?', b.version || '?'), ' ',
						b.connections ? _('With subscriptions and server keys.') : _('Without subscriptions and server keys: the ones of this router stay.')
					]),
					E('p', { 'class': 'mh-warn' }, _('All current settings of Mayhem are replaced.')),
					E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, restore, b) }, _('Restore'))
				);
			});
		});

		ui.showModal(_('Backup'), [
			E('div', { 'class': 'mh-backup' }, [
				E('b', _('Export')),
				E('div', { 'class': 'mh-small' }, _('One file with every setting of Mayhem: sections and their rules, DNS, geo sources, settings and rule list files. Downloaded data is fetched again after a restore.')),
				E('label', [ links, ' ', _('With connections: subscriptions, server keys and HWID') ]),
				mh.button({ icon: 'download', cls: 'cbi-button-action', text: _('Download the backup'), click: ui.createHandlerFn(this, download) })
			]),
			E('div', { 'class': 'mh-backup' }, [
				E('b', _('Import')),
				E('div', { 'class': 'mh-small' }, _('Restores a backup file. A backup without connections keeps the subscriptions and server keys this router has.')),
				file,
				mh.button({ icon: 'upload', text: _('Choose a file…'), click: () => file.click() }),
				found
			]),
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Back')))
		]);
	},

	// --- buttons ---------------------------------------------------------------------

	controls() {
		const d = this.opts.state() || {};
		const any = this.acting != null;
		const btn = (name, icon, cls, text) => mh.button({
			icon: icon, cls: cls, text: text, busy: this.acting === name, disabled: any,
			click: ui.createHandlerFn(this, 'act', name)
		});

		return [
			btn('restart', 'restart', 'cbi-button-apply', _('Restart Mayhem')),
			d.running ? btn('stop', 'stop', 'cbi-button-remove', _('Stop Mayhem'))
				: btn('start', 'play', 'cbi-button-save', _('Start Mayhem')),
			d.autostart ? btn('autostart_off', 'pause', 'cbi-button-remove', _('Turn autostart off'))
				: btn('autostart_on', 'play', 'cbi-button-save', _('Turn autostart on'))
		];
	}
});
