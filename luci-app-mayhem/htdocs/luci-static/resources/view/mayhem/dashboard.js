'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

const callDashboard = rpc.declare({ object: 'luci.mayhem', method: 'dashboard', expect: { '': {} } });
const callAction = rpc.declare({ object: 'luci.mayhem', method: 'action', params: [ 'name' ], expect: { '': {} } });
const callSelect = rpc.declare({ object: 'luci.mayhem', method: 'select_node', params: [ 'section', 'tag' ], expect: { '': {} } });
const callProbe = rpc.declare({ object: 'luci.mayhem', method: 'probe', params: [ 'tag', 'method' ], expect: { '': {} } });
const callSubUpdate = rpc.declare({ object: 'luci.mayhem', method: 'sub_update', params: [ 'name' ], expect: { '': {} } });

const COLORS = { ok: '#2e7d32', warn: '#ef6c00', bad: '#c62828', off: '#9e9e9e' };
const PROBE_PARALLEL = 4;

function bytes(n) {
	if (n == null)
		return '—';

	const u = [ 'B', 'KB', 'MB', 'GB', 'TB' ];
	let i = 0;

	while (n >= 1024 && i < u.length - 1) {
		n /= 1024;
		i++;
	}

	return (i ? n.toFixed(n < 10 ? 1 : 0) : n) + ' ' + u[i];
}

function rate(n) {
	return n == null ? '—' : bytes(n) + '/s';
}

function ago(ts, now) {
	if (!ts)
		return _('never');

	const s = Math.max(0, now - ts);

	if (s < 90)
		return _('just now');

	if (s < 5400)
		return _('%d min ago').format(Math.round(s / 60));

	if (s < 129600)
		return _('%d h ago').format(Math.round(s / 3600));

	return _('%d d ago').format(Math.round(s / 86400));
}

function badge(color, text) {
	return E('span', {
		'style': 'display:inline-block;padding:1px 8px;border-radius:9px;color:#fff;font-size:90%%;background:%s'.format(color)
	}, text);
}

function ms(v) {
	if (v == null)
		return '—';

	if (typeof v === 'string')
		return E('span', { 'style': 'color:' + COLORS.bad, 'title': v }, '✕');

	const c = v < 150 ? COLORS.ok : (v < 400 ? COLORS.warn : COLORS.bad);

	return E('span', { 'style': 'color:' + c }, '%d ms'.format(v));
}

const MODES = {
	auto: _('Automatic: the fastest by URL test'),
	manual: _('Manual choice'),
	single: _('One server')
};

return view.extend({
	data: null,
	prev: null,
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

	probeSection(sec, method) {
		const queue = sec.nodes.slice();
		const key = sec.name + ':' + method;

		if (this.busy[key])
			return Promise.resolve();

		this.busy[key] = true;
		this.redraw();

		const worker = () => {
			const n = queue.shift();

			if (!n)
				return Promise.resolve();

			return callProbe(n.tag, method).then((r) => {
				this.probes[n.tag] = this.probes[n.tag] || {};
				this.probes[n.tag][method] = (r.ms != null) ? r.ms : (r.error || 'error');
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

	renderSummary(d) {
		const st = d.status || {};
		const working = d.running && d.active;
		const state = !d.enabled ? badge(COLORS.off, _('Disabled'))
			: working ? badge(COLORS.ok, _('Working'))
			: d.running ? badge(COLORS.warn, _('Starting…'))
			: badge(COLORS.bad, _('Not running'));

		const rows = [
			[ _('State'), state ],
			[ _('Mode'), d.mode === 'global' ? _('Everything through proxy, except exclusions') : _('Only matched lists') ],
			[ _('xray'), d.xray || E('em', _('not installed — run "mayhem xray-install"')) ],
			[ _('xray memory'), d.rss_kb ? '%s (%s %d MiB)'.format(bytes(d.rss_kb * 1024), _('soft limit'), st.memlimit_mib || 0) : '—' ]
		];

		if (this.speed)
			rows.push([ _('Speed'), '%s ↓ %s ↑ %s · %s ↓ %s ↑ %s'.format(
				_('proxy'), rate(this.speed.proxy.down), rate(this.speed.proxy.up),
				_('direct'), rate(this.speed.direct.down), rate(this.speed.direct.up)) ]);

		const notes = [].concat(
			(st.errors || []).map((m) => E('li', { 'style': 'color:' + COLORS.bad }, m)),
			(st.warnings || []).map((m) => E('li', { 'style': 'color:' + COLORS.warn }, m))
		);

		return E('div', { 'class': 'cbi-section' }, [
			E('table', { 'class': 'table' }, rows.map((r) => E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'style': 'width:30%' }, r[0]),
				E('td', { 'class': 'td left' }, r[1])
			]))),
			notes.length ? E('ul', { 'style': 'margin-top:8px' }, notes) : '',
			E('div', { 'style': 'margin-top:8px' }, [
				E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, 'act', 'enable') }, _('Enable')), ' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, 'act', 'disable') }, _('Disable')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'act', 'restart') }, _('Restart'))
			])
		]);
	},

	renderSection(s) {
		if (s.type !== 'proxy')
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', '%s — %s'.format(s.name, s.type === 'block' ? _('Block') : _('Direct')))
			]);

		const probe = (m, label) => {
			const busy = this.busy[s.name + ':' + m];

			return E('button', {
				'class': 'btn cbi-button',
				'disabled': busy ? '' : null,
				'click': ui.createHandlerFn(this, 'probeSection', s, m)
			}, busy ? label + '…' : label);
		};

		const head = E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th', 'style': 'width:1.5em' }, ''),
			E('th', { 'class': 'th' }, _('Server')),
			E('th', { 'class': 'th' }, _('Protocol')),
			E('th', { 'class': 'th' }, _('URL test')),
			E('th', { 'class': 'th' }, _('TCP')),
			E('th', { 'class': 'th' }, _('ICMP')),
			E('th', { 'class': 'th' }, _('Traffic')),
			E('th', { 'class': 'th' }, '')
		]);

		const rows = s.nodes.map((n) => {
			const p = this.probes[n.tag] || {};
			const active = n.tag === s.active;
			const auto = n.alive === false ? _('down') : n.delay;
			const url = p.url != null ? p.url : auto;

			return E('tr', { 'class': 'tr', 'style': active ? 'font-weight:600' : '' }, [
				E('td', { 'class': 'td' }, active ? E('span', { 'style': 'color:' + COLORS.ok }, '●') : ''),
				E('td', { 'class': 'td', 'title': '%s:%s'.format(n.address || '?', n.port || '?') },
					n.source && n.source !== 'link' ? [ n.name, E('small', { 'style': 'color:#888' }, ' · ' + n.source) ] : n.name),
				E('td', { 'class': 'td' }, n.protocol),
				E('td', { 'class': 'td' }, typeof url === 'string' ? E('span', { 'style': 'color:' + COLORS.bad }, url) : ms(url)),
				E('td', { 'class': 'td' }, ms(p.tcp)),
				E('td', { 'class': 'td' }, ms(p.icmp)),
				E('td', { 'class': 'td' }, '↓ %s ↑ %s'.format(bytes(n.down), bytes(n.up))),
				E('td', { 'class': 'td' }, (s.balancer && !active)
					? E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, 'select', s.name, n.tag) }, _('Use'))
					: '')
			]);
		});

		const tools = [ probe('url', _('URL test')), ' ', probe('tcp', _('TCP ping')), ' ', probe('icmp', _('ICMP ping')) ];

		if (s.mode === 'auto' && s.pinned)
			tools.unshift(E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'select', s.name, '') }, _('Back to automatic')), ' ');

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', s.name),
			E('div', { 'class': 'cbi-section-descr' }, '%s%s · %s ↓ %s ↑ %s'.format(
				MODES[s.mode] || s.mode,
				s.mode === 'auto' && s.pinned ? ' (' + _('pinned by hand') + ')' : '',
				_('traffic'), bytes(s.traffic.down), bytes(s.traffic.up))),
			E('div', { 'style': 'margin:6px 0' }, tools),
			E('table', { 'class': 'table' }, [ head ].concat(rows))
		]);
	},

	renderSubscriptions(d) {
		if (!d.subscriptions || !d.subscriptions.length)
			return '';

		const head = E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Subscription')),
			E('th', { 'class': 'th' }, _('Servers')),
			E('th', { 'class': 'th' }, _('Traffic')),
			E('th', { 'class': 'th' }, _('Expires')),
			E('th', { 'class': 'th' }, _('Updated')),
			E('th', { 'class': 'th' }, '')
		]);

		const rows = d.subscriptions.map((s) => {
			const info = s.info || {};
			const ui_ = info.userinfo || {};
			const used = (ui_.upload || 0) + (ui_.download || 0);
			const notes = [];

			if (s.error)
				notes.push(E('div', { 'style': 'color:' + COLORS.bad }, s.error));

			if (info.hwid && info.hwid.limit)
				notes.push(E('div', { 'style': 'color:' + COLORS.bad }, _('Device limit reached: the provider does not accept this HWID')));
			else if (info.hwid && info.hwid.not_supported)
				notes.push(E('div', { 'style': 'color:' + COLORS.warn }, _('The provider expects an HWID: turn on "Send device data"')));

			if (info.announce)
				notes.push(E('div', { 'style': 'color:#888' }, info.announce));

			const busy = this.busy['sub:' + s.name];

			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, [ E('strong', info.title || s.name), info.title ? E('small', { 'style': 'color:#888' }, ' · ' + s.name) : '' ].concat(notes)),
				E('td', { 'class': 'td' }, s.skipped ? '%d (+%d %s)'.format(s.nodes, s.skipped, _('unreadable')) : String(s.nodes)),
				E('td', { 'class': 'td' }, ui_.total ? '%s / %s'.format(bytes(used), bytes(ui_.total)) : (used ? bytes(used) : '—')),
				E('td', { 'class': 'td' }, ui_.expire ? new Date(ui_.expire * 1000).toLocaleDateString() : '—'),
				E('td', { 'class': 'td' }, ago(s.updated, d.time)),
				E('td', { 'class': 'td' }, E('button', {
					'class': 'btn cbi-button',
					'disabled': busy ? '' : null,
					'click': ui.createHandlerFn(this, 'updateSub', s.name)
				}, busy ? _('Updating…') : _('Update')))
			]);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', _('Subscriptions')),
			E('table', { 'class': 'table' }, [ head ].concat(rows))
		]);
	},

	renderBody(d) {
		return [ this.renderSummary(d) ]
			.concat((d.sections || []).map((s) => this.renderSection(s)))
			.concat([ this.renderSubscriptions(d) ]);
	},

	render(d) {
		this.data = d;

		poll.add(() => document.hidden ? Promise.resolve() : this.refresh(), 2);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', _('Mayhem')),
			E('div', { 'id': 'mayhem-body' }, this.renderBody(d))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
