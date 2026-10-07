'use strict';
'require view';
'require rpc';
'require poll';
'require uci';
'require ui';

const callLogs = rpc.declare({ object: 'luci.mayhem', method: 'logs', params: [ 'component', 'lines' ], expect: { '': {} } });
const callLevel = rpc.declare({ object: 'luci.mayhem', method: 'set_log_level', params: [ 'level' ], expect: { '': {} } });

return view.extend({
	component: 'all',
	lines: 300,
	follow: true,

	load() {
		return Promise.all([
			uci.load('mayhem'),
			callLogs(this.component, this.lines)
		]);
	},

	show(r) {
		const pre = document.getElementById('mayhem-log');

		if (!pre)
			return;

		const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;

		pre.textContent = (r.lines || []).join('\n') || _('No messages yet.');

		if (atEnd)
			pre.scrollTop = pre.scrollHeight;
	},

	refresh() {
		return callLogs(this.component, this.lines).then((r) => this.show(r));
	},

	setLevel(ev) {
		const level = ev.target.value;

		return callLevel(level).then((r) => {
			if (r.error)
				ui.addNotification(null, E('p', r.error), 'error');
			else
				ui.addNotification(null, E('p', _('Log level is now %s; xray restarts with it.').format(level)), 'info');
		});
	},

	render(data) {
		const level = uci.get('mayhem', 'settings', 'log_level') || 'warning';

		const select = (opts, value, change) => E('select', { 'class': 'cbi-input-select', 'change': change },
			opts.map((o) => E('option', { 'value': o[0], 'selected': o[0] === value ? '' : null }, o[1])));

		const pre = E('pre', {
			'id': 'mayhem-log',
			'style': 'height:60vh;overflow:auto;white-space:pre-wrap;font-size:12px'
		});

		const view = E('div', { 'class': 'cbi-map' }, [
			E('h2', _('Logs')),
			E('div', { 'class': 'cbi-map-descr' }, _('Messages of Mayhem, xray and dnsmasq from the system log. At the debug level xray logs every connection and DNS query: turn it back down when you are done.')),
			E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:8px 0' }, [
				select([ [ 'all', _('Everything') ], [ 'mayhem', 'Mayhem' ], [ 'xray', 'xray' ], [ 'dnsmasq', 'dnsmasq' ] ], this.component,
					(ev) => { this.component = ev.target.value; this.refresh(); }),
				select([ [ '100', _('100 lines') ], [ '300', _('300 lines') ], [ '1000', _('1000 lines') ] ], String(this.lines),
					(ev) => { this.lines = +ev.target.value; this.refresh(); }),
				E('label', [ E('input', {
					'type': 'checkbox', 'checked': this.follow ? '' : null,
					'change': (ev) => this.follow = ev.target.checked
				}), ' ', _('Refresh every 5 seconds') ]),
				E('span', { 'style': 'margin-left:auto' }, _('Log level') + ': '),
				select([ 'debug', 'info', 'warning', 'error', 'none' ].map((l) => [ l, l ]), level, ui.createHandlerFn(this, 'setLevel')),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'refresh') }, _('Refresh'))
			]),
			pre
		]);

		poll.add(() => (this.follow && !document.hidden) ? this.refresh() : Promise.resolve(), 5);
		window.requestAnimationFrame(() => this.show(data[1] || {}));

		return view;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
