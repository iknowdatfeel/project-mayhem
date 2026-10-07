'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require tools.widgets as widgets';

const callGeo = rpc.declare({ object: 'luci.mayhem', method: 'geo', expect: { '': {} } });
const callDataUpdate = rpc.declare({ object: 'luci.mayhem', method: 'data_update', params: [ 'what', 'name' ], expect: { '': {} } });
const callGeoImport = rpc.declare({ object: 'luci.mayhem', method: 'geo_import', params: [ 'name', 'kind' ], expect: { '': {} } });

// Asks for a source name and type, uploads the file, registers the source.
function uploadSource() {
	const name = E('input', { 'class': 'cbi-input-text', 'placeholder': 'my_geosite' });
	const kind = E('select', { 'class': 'cbi-input-select' }, [
		E('option', { 'value': 'geosite' }, 'geosite'),
		E('option', { 'value': 'geoip' }, 'geoip')
	]);

	ui.showModal(_('Upload a .dat file'), [
		E('p', _('The file is kept on the router as it is, so it must be small (up to 8 MB). Big files are better added by URL.')),
		E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Source name')), E('div', { 'class': 'cbi-value-field' }, name) ]),
		E('div', { 'class': 'cbi-value' }, [ E('label', { 'class': 'cbi-value-title' }, _('Type')), E('div', { 'class': 'cbi-value-field' }, kind) ]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
			E('button', {
				'class': 'btn cbi-button-action',
				'click': ui.createHandlerFn(this, function() {
					if (!/^[A-Za-z0-9_]+$/.test(name.value)) {
						ui.addNotification(null, E('p', _('The name may only contain letters, digits and _')), 'error');
						return;
					}

					return ui.uploadFile('/tmp/mayhem-upload.dat').then(() => callGeoImport(name.value, kind.value)).then((r) => {
						ui.hideModal();

						if (r.error)
							ui.addNotification(null, E('p', r.error), 'error');
						else
							window.location.reload();
					}).catch((e) => ui.addNotification(null, E('p', e.message), 'error'));
				})
			}, _('Choose file…'))
		])
	]);
}

function since(ts) {
	if (!ts)
		return _('never');

	return new Date(ts * 1000).toLocaleString();
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('mayhem'),
			L.resolveDefault(callGeo(), {})
		]);
	},

	render(data) {
		const geo = data[1] || {};
		const sourceInfo = {};

		(geo.sources || []).forEach((x) => sourceInfo[x.name] = x);

		const proxies = uci.sections('mayhem', 'section')
			.filter((s) => (s.type || 'proxy') === 'proxy')
			.map((s) => s['.name']);

		const m = new form.Map('mayhem', _('Settings'));
		let s, o;

		s = m.section(form.NamedSection, 'settings', 'settings', _('General'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable routing'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('Mode'),
			_('Only matched lists: sections get what matches their rules, everything else goes direct. Everything through proxy: all traffic goes to the default section, except direct sections.'));
		o.value('lists', _('Only matched lists'));
		o.value('global', _('Everything through proxy, except exclusions'));
		o.default = 'lists';

		o = s.option(form.ListValue, 'default_section', _('Default section'),
			_('Where traffic goes when nothing else matched.'));
		o.value('', _('First proxy section'));
		proxies.forEach((n) => o.value(n));
		o.depends('mode', 'global');

		o = s.option(widgets.DeviceSelect, 'interface', _('LAN interfaces'),
			_('Traffic coming from these interfaces is routed. The router itself always goes direct.'));
		o.multiple = true;
		o.noaliases = true;
		o.nocreate = true;
		o.default = 'br-lan';

		o = s.option(form.ListValue, 'ip_family', _('IP version'));
		o.value('prefer_ipv4', _('Prefer IPv4'));
		o.value('prefer_ipv6', _('Prefer IPv6'));
		o.value('ipv4_only', _('IPv4 only'));
		o.value('ipv6_only', _('IPv6 only'));
		o.default = 'prefer_ipv4';

		o = s.option(form.ListValue, 'log_level', _('Log level'));
		[ 'debug', 'info', 'warning', 'error', 'none' ].forEach((l) => o.value(l));
		o.default = 'warning';

		o = s.option(form.Value, 'memlimit', _('xray memory limit, MiB'),
			_('Soft limit: xray frees memory more often when it gets close. Empty means a quarter of the router RAM.'));
		o.datatype = 'range(16,4096)';
		o.placeholder = _('auto');

		o = s.option(form.Flag, 'watchdog', _('Watchdog'),
			_('Restarts xray when it holds too much memory for 3 minutes in a row, and dnsmasq when it is gone.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'watchdog_mem', _('Restart xray above'));
		[ 30, 40, 50, 60 ].forEach((p) => o.value(String(p), _('%d%% of RAM').format(p)));
		o.default = '40';
		o.depends('watchdog', '1');

		o = s.option(form.Value, 'probe_url', _('URL for server checks'),
			_('Automatic server choice and the URL test request this address through each server.'));
		o.placeholder = 'https://www.gstatic.com/generate_204';
		o.validate = function(section_id, value) {
			return (!value || /^https?:\/\/\S+$/.test(value)) ? true : _('Expected an http(s):// address');
		};

		o = s.option(form.ListValue, 'probe_interval', _('Check servers every'));
		o.value('1m', _('1 minute'));
		o.value('3m', _('3 minutes'));
		o.value('5m', _('5 minutes'));
		o.value('10m', _('10 minutes'));
		o.value('30m', _('30 minutes'));
		o.default = '3m';

		o = s.option(form.Value, 'ip_check_url', _('Address for the external IP check'),
			_('Diagnostics request it directly and through every section; it must answer with the IP address as plain text.'));
		o.placeholder = 'https://api.ipify.org';
		o.validate = function(section_id, value) {
			return (!value || /^https?:\/\/\S+$/.test(value)) ? true : _('Expected an http(s):// address');
		};

		o = s.option(form.Flag, 'mux', _('Mux for VLESS'),
			_('Applies to every VLESS server. With XTLS Vision only UDP is multiplexed.'));

		o = s.option(form.Value, 'mux_concurrency', _('Mux: TCP connections per tunnel'));
		o.datatype = 'range(1,1024)';
		o.placeholder = '8';
		o.depends('mux', '1');

		o = s.option(form.Value, 'mux_xudp_concurrency', _('Mux: UDP connections per tunnel (XUDP)'));
		o.datatype = 'range(1,1024)';
		o.placeholder = '16';
		o.depends('mux', '1');

		o = s.option(form.ListValue, 'mux_xudp_udp443', _('Mux: QUIC (UDP 443)'));
		o.value('reject', _('Reject, browsers fall back to TCP'));
		o.value('allow', _('Send through Mux'));
		o.value('skip', _('Send without Mux'));
		o.default = 'reject';
		o.depends('mux', '1');

		s = m.section(form.NamedSection, 'dns', 'dns', _('DNS'),
			_('Direct traffic is resolved by the domestic DNS, proxied traffic by the remote DNS. The first server in a list is the main one, the next ones are fallbacks. Xray has no DNS-over-TLS: use https:// (DoH), tcp:// or a plain address.'));
		s.addremove = false;

		o = s.option(form.DynamicList, 'domestic', _('Domestic DNS'),
			_('Empty: DNS servers received from the provider.'));
		o.placeholder = '77.88.8.8';

		o = s.option(form.DynamicList, 'remote', _('Remote DNS'));
		o.placeholder = 'https://1.1.1.1/dns-query';

		o = s.option(form.Flag, 'via_proxy', _('Remote DNS through proxy'),
			_('Off: remote DNS queries go direct (encrypted with DoH).'));

		o = s.option(form.ListValue, 'proxy_section', _('Section for DNS'));
		o.value('', _('Default section'));
		proxies.forEach((n) => o.value(n));
		o.depends('via_proxy', '1');

		o = s.option(form.Flag, 'hijack', _('Intercept DNS on port 53'),
			_('Devices that use their own DNS server (8.8.8.8 and so on) are answered by Mayhem as well.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'fakedns', _('FakeDNS'),
			_('Proxied domains get addresses from 198.18.0.0/15. Helps when an app hides the domain, but cached fake addresses break if Mayhem stops.'));

		s = m.section(form.NamedSection, 'geo', 'geo', _('Geo data'),
			_('geosite and geoip files are read on the router while they download; only the categories used in sections are kept, so a 70 MB file takes a few hundred kilobytes of flash. New categories are downloaded within a minute after saving, the rest is refreshed nightly.'));
		s.addremove = false;

		o = s.option(form.ListValue, 'update_hour', _('Nightly update at'));
		for (let h = 0; h < 24; h++)
			o.value(String(h), '%02d:00'.format(h));
		o.default = '4';

		o = s.option(form.ListValue, 'update_via', _('Download'),
			_('Applies to geo data and lists.'));
		o.value('auto', _('Direct, then through a section'));
		o.value('direct', _('Direct only'));
		o.value('section', _('Through a section only'));
		o.default = 'auto';

		o = s.option(form.ListValue, 'update_section', _('Section for downloads'));
		o.value('', _('First proxy section'));
		proxies.forEach((n) => o.value(n));
		o.depends('update_via', 'auto');
		o.depends('update_via', 'section');

		o = s.option(form.ListValue, 'lists_interval', _('Refresh lists every'));
		o.value('6', _('6 hours'));
		o.value('12', _('12 hours'));
		o.value('24', _('24 hours'));
		o.value('72', _('3 days'));
		o.default = '24';

		o = s.option(form.Button, '_upload_geo', _('Own file'));
		o.inputtitle = _('Upload .dat…');
		o.inputstyle = 'action';
		o.onclick = uploadSource;

		o = s.option(form.Button, '_update_geo', _('Update now'));
		o.inputtitle = _('Download geo data');
		o.inputstyle = 'action';
		o.onclick = function() {
			return callDataUpdate('geo', '').then((r) => {
				ui.addNotification(null, E('p', r.busy ? _('An update is already running')
					: _('The update runs in the background, see the dashboard for its result.')), 'info');
			});
		};

		s = m.section(form.GridSection, 'geo_source', _('Geo sources'),
			_('Sections refer to categories as geosite:category or geosite:source:category. When several sources have a category, the first one in this list wins.'));
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add source');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'kind', _('Type'));
		o.value('geosite', 'geosite');
		o.value('geoip', 'geoip');
		o.default = 'geosite';

		o = s.option(form.Value, 'url', _('URL or file'),
			_('https:// address of a .dat file, or a path to a file on the router.'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return /^(https?:\/\/\S+|file:\/\/\/\S+|\/\S+)$/.test(value || '') ? true : _('Expected an http(s):// address or a file path');
		};

		o = s.option(form.DummyValue, '_state', _('State'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const x = sourceInfo[section_id];

			if (!x)
				return _('not downloaded yet');

			if (x.error)
				return E('span', { 'style': 'color:#c62828' }, x.error);

			if (x.categories == null)
				return _('not downloaded yet');

			return _('%d categories, %d in use, updated %s').format(x.categories, x.copied.length, since(x.updated));
		};

		return m.render();
	}
});
