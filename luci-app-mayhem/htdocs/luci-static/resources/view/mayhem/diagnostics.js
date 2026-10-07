'use strict';
'require view';
'require rpc';
'require ui';

const callDiagnose = rpc.declare({ object: 'luci.mayhem', method: 'diagnose', params: [ 'part', 'target' ], expect: { '': {} } });

const GROUPS = [
	[ 'service', _('Service') ],
	[ 'config', _('Configuration') ],
	[ 'xray', 'xray' ],
	[ 'kernel', _('Kernel') ],
	[ 'dns', _('DNS') ],
	[ 'tunnels', _('Tunnels') ],
	[ 'exit', _('External address') ],
	[ 'data', _('Geo data, lists and subscriptions') ],
	[ 'system', _('System') ]
];

const MARKS = {
	ok: [ '#2e7d32', '✔' ],
	warn: [ '#ef6c00', '!' ],
	fail: [ '#c62828', '✖' ],
	info: [ '#757575', '·' ]
};

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

return view.extend({
	checks: [],
	running: false,

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
		this.draw();

		return callDiagnose('local', '').then((r) => {
			this.add(r);

			let p = callDiagnose('dns', '').then((d) => this.add(d));

			// One request per target: each may take up to 10 seconds.
			for (const t of (r.targets || []))
				p = p.then(() => callDiagnose('exit', t.id)).then((d) => this.add(d));

			return p;
		}).catch((e) => {
			this.add({ error: e.message });
		}).finally(() => {
			this.running = false;
			this.draw();
		});
	},

	report() {
		const lines = [ 'Mayhem diagnostics, ' + new Date().toISOString() ];

		for (const [ g, title ] of GROUPS) {
			const items = this.checks.filter((c) => c.group === g);

			if (!items.length)
				continue;

			lines.push('', '[' + title + ']');
			items.forEach((c) => lines.push('%s %s: %s'.format(MARKS[c.status] ? MARKS[c.status][1] : '?', c.name, c.detail)));
		}

		return lines.join('\n');
	},

	copy() {
		const text = this.report();
		const area = E('textarea', { 'style': 'width:100%;height:20em;font-family:monospace', 'readonly': '' }, text);

		ui.showModal(_('Diagnostics report'), [
			E('p', _('Copy the report and attach it to a question or a bug report. It holds no keys or passwords, but it does show your external addresses.')),
			area,
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close')))
		]);

		area.select();
	},

	draw() {
		const out = document.getElementById('mayhem-diag');

		if (!out)
			return;

		const blocks = [];
		const count = { ok: 0, warn: 0, fail: 0 };

		this.checks.forEach((c) => { if (count[c.status] != null) count[c.status]++; });

		blocks.push(E('p', this.running ? _('Checking…') : (this.checks.length
			? _('%d fine, %d warnings, %d problems').format(count.ok, count.warn, count.fail)
			: _('Press "Run" to check the service, DNS, tunnels and the external address of every section.'))));

		for (const [ g, title ] of GROUPS) {
			const items = this.checks.filter((c) => c.group === g);

			if (!items.length)
				continue;

			blocks.push(E('h3', title));
			blocks.push(E('table', { 'class': 'table' }, items.map((c) => {
				const m = MARKS[c.status] || MARKS.info;

				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td', 'style': 'width:2em;font-weight:bold;color:' + m[0] }, m[1]),
					E('td', { 'class': 'td', 'style': 'width:30%' }, NAMES[c.name] || c.name),
					E('td', { 'class': 'td', 'style': 'word-break:break-word' }, c.detail)
				]);
			})));
		}

		out.replaceChildren(...blocks);
	},

	render() {
		const view = E('div', { 'class': 'cbi-map' }, [
			E('h2', _('Diagnostics')),
			E('div', { 'class': 'cbi-map-descr' }, _('Checks every part of the traffic path. External addresses are requested through each section, so you can see where the traffic really leaves.')),
			E('div', { 'style': 'margin:8px 0' }, [
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'run') }, _('Run')), ' ',
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'copy') }, _('Copy report'))
			]),
			E('div', { 'class': 'cbi-section', 'id': 'mayhem-diag' })
		]);

		window.requestAnimationFrame(() => this.draw());

		return view;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
