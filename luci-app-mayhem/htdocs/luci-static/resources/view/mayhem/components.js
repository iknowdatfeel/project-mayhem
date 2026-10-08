'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require mayhem.common as mh';
'require mayhem.tunnels as tunnels';

// Component updates: what is installed and what is out for Xray, Mayhem, geo
// data and rule lists, with buttons to update them and the nightly update of
// Mayhem itself.

const callComponents = rpc.declare({ object: 'luci.mayhem', method: 'components', params: [ 'check' ], expect: { '': {} } });
const callGeo = rpc.declare({ object: 'luci.mayhem', method: 'geo', expect: { '': {} } });
const callDataUpdate = rpc.declare({ object: 'luci.mayhem', method: 'data_update', params: [ 'what', 'name' ], expect: { '': {} } });

function newer(latest, cur) {
	if (!latest || !cur)
		return false;

	const a = latest.split(/[.-]/).map((x) => parseInt(x, 10) || 0);
	const b = cur.split(/[.-]/).map((x) => parseInt(x, 10) || 0);

	for (let i = 0; i < Math.max(a.length, b.length); i++)
		if ((a[i] || 0) !== (b[i] || 0))
			return (a[i] || 0) > (b[i] || 0);

	return false;
}

function updated(ts) {
	return ts ? _('Updated %s').format(new Date(ts * 1000).toLocaleString()) : _('Not updated yet');
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('mayhem'),
			L.resolveDefault(callComponents(false), {}),
			L.resolveDefault(callGeo(), {})
		]);
	},

	// The components tab: what is installed, what is out, buttons to update.
	renderComponents(comp, geo) {
		const body = E('tbody');
		const row = (name, cur, latest, action) => E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, E('b', name)),
			E('td', { 'class': 'td' }, cur || '—'),
			E('td', { 'class': 'td' }, latest),
			E('td', { 'class': 'td right' }, action || '')
		]);
		const geoTime = Math.max(0, ...(geo.sources || []).map((x) => x.updated || 0));
		const listTime = Math.max(0, ...(geo.lists || []).map((x) => x.updated || 0));

		const draw = (c, checking) => {
			const pending = checking ? E('span', { 'class': 'mh-muted' }, _('Checking…')) : null;
			const latest = (v, cur) => pending || (!v ? E('span', { 'class': 'mh-muted' }, _('Unknown'))
				: newer(v, cur) ? E('span', { 'class': 'mh-warn' }, v)
				: E('span', { 'class': 'mh-ok' }, _('%s, up to date').format(cur || v)));
			const btn = (what, v, cur) => (!checking && v && (newer(v, cur) || !cur))
				? E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(tunnels, 'install', what, v) }, _('Update to %s').format(v)) : '';
			const data = (what) => E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, () => callDataUpdate(what, '').then((r) => {
					ui.addNotification(null, E('p', r.busy ? _('An update is already running')
						: _('The update runs in the background. Open this tab again in a few minutes to see the result.')), 'info');
				}))
			}, _('Update now'));

			body.replaceChildren(
				row('Xray', c.xray, latest(c.xray_latest, c.xray), btn('xray', c.xray_latest, c.xray)),
				row('Mayhem', c.mayhem, latest(c.mayhem_latest, c.mayhem), btn('mayhem', c.mayhem_latest, c.mayhem)),
				row(_('Geo data'), updated(geoTime), E('span', { 'class': 'mh-muted' }, _('Every night')), data('geo')),
				row(_('Rule lists'), updated(listTime), E('span', { 'class': 'mh-muted' }, _('Automatically')), data('lists'))
			);
		};

		draw(comp, true);
		callComponents(true).then((c) => draw(c, false)).catch(() => draw(comp, false));

		return E('div', { 'class': 'cbi-section' }, [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Component')), E('th', { 'class': 'th' }, _('Installed')),
					E('th', { 'class': 'th' }, _('Available')), E('th', { 'class': 'th' })
				]),
				body
			])
		]);
	},

	render(data) {
		const comp = data[1] || {};
		const geo = data[2] || {};
		const self = this;
		const m = new form.Map('mayhem', _('Component updates'),
			_('Xray and Mayhem are updated from their releases on GitHub. Updating restarts Xray, connections break for a moment.'));
		let s, o;

		s = m.section(form.NamedSection, 'settings', 'settings');
		s.addremove = false;

		o = s.option(form.DummyValue, '_components');
		o.render = function() {
			return Promise.resolve(self.renderComponents(comp, geo));
		};

		o = s.option(form.Flag, 'auto_update', _('Update Mayhem automatically'),
			_('Once a day, at the nightly update time, Mayhem looks for a new release on GitHub and installs it together with the Xray version it is made for. Connections break for a moment while it updates.'));
		o.rmempty = false;

		return m.render().then((node) => {
			node.insertBefore(mh.style(), node.firstChild);

			return node;
		});
	}
});
