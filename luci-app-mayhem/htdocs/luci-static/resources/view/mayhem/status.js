'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

const callStatus = rpc.declare({
	object: 'luci.mayhem',
	method: 'status',
	expect: { '': {} }
});

const callAction = rpc.declare({
	object: 'luci.mayhem',
	method: 'action',
	params: [ 'name' ],
	expect: { '': {} }
});

const TYPES = {
	proxy: _('Proxy'),
	exclusion: _('Direct'),
	block: _('Block'),
	interface: _('Interface')
};

function badge(ok, yes, no) {
	return E('span', {
		'class': 'label',
		'style': 'background:%s;color:#fff;padding:2px 8px;border-radius:4px'.format(ok ? '#2e7d32' : '#9e9e9e')
	}, ok ? yes : no);
}

function row(title, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'style': 'width:33%' }, title),
		E('td', { 'class': 'td left' }, value)
	]);
}

return view.extend({
	load() {
		return callStatus();
	},

	renderState(st) {
		const cfg = st.config || {};
		const running = st.running && st.intercepting;
		const rows = [
			row(_('Routing'), badge(st.enabled, _('Enabled'), _('Disabled'))),
			row(_('Service'), running
				? badge(true, _('Working'), '')
				: badge(false, '', st.running ? _('Starting…') : _('Stopped'))),
			row(_('Mode'), cfg.mode === 'global' ? _('Everything through proxy, except exclusions') : _('Only matched lists')),
			row(_('xray'), st.xray || E('em', _('not installed — run "mayhem xray-install"'))),
			row(_('Mayhem'), st.version || '?')
		];

		if (cfg.memlimit_mib)
			rows.push(row(_('Memory limit for xray'), '%d MiB'.format(cfg.memlimit_mib)));

		if (st.conflicts)
			rows.push(row(_('Conflicts'), E('strong', { 'style': 'color:#c62828' },
				_('Another traffic interceptor is running: %s. Stop it before enabling Mayhem.').format(st.conflicts))));

		const nodes = [ E('table', { 'class': 'table' }, rows) ];
		const notes = [].concat(
			(cfg.errors || []).map((m) => E('li', { 'style': 'color:#c62828' }, m)),
			(cfg.warnings || []).map((m) => E('li', { 'style': 'color:#ef6c00' }, m))
		);

		if (notes.length)
			nodes.push(E('h3', _('Configuration notes')), E('ul', notes));

		if ((cfg.sections || []).length) {
			const head = E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Section')),
				E('th', { 'class': 'th' }, _('Type')),
				E('th', { 'class': 'th' }, _('Server')),
				E('th', { 'class': 'th' }, _('State'))
			]);

			const body = cfg.sections.map((s) => E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, s.name),
				E('td', { 'class': 'td' }, TYPES[s.type] || s.type),
				E('td', { 'class': 'td' }, s.node || '—'),
				E('td', { 'class': 'td' }, !s.enabled ? _('off') : (s.ok ? _('ok') : E('span', { 'style': 'color:#c62828' }, s.error || _('error'))))
			]));

			nodes.push(E('h3', _('Sections')), E('table', { 'class': 'table' }, [ head ].concat(body)));
		}

		return E('div', { 'id': 'mayhem-state' }, nodes);
	},

	act(name) {
		return callAction(name)
			.then(() => callStatus())
			.then((st) => {
				const el = document.getElementById('mayhem-state');

				if (el)
					el.replaceWith(this.renderState(st));
			})
			.catch((e) => ui.addNotification(null, E('p', e.message), 'error'));
	},

	render(st) {
		const buttons = E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
			E('button', { 'class': 'btn cbi-button-positive', 'click': ui.createHandlerFn(this, 'act', 'enable') }, _('Enable')),
			' ',
			E('button', { 'class': 'btn cbi-button-negative', 'click': ui.createHandlerFn(this, 'act', 'disable') }, _('Disable')),
			' ',
			E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, 'act', 'restart') }, _('Restart'))
		]);

		poll.add(() => callStatus().then((s) => {
			const el = document.getElementById('mayhem-state');

			if (el)
				el.replaceWith(this.renderState(s));
		}), 5);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', _('Mayhem')),
			E('div', { 'class': 'cbi-map-descr' }, _('Routes LAN traffic through Xray by sections and lists.')),
			this.renderState(st),
			buttons
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
