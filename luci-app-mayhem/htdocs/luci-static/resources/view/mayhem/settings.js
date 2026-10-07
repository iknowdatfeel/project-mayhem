'use strict';
'require view';
'require form';
'require uci';
'require tools.widgets as widgets';

return view.extend({
	load() {
		return uci.load('mayhem');
	},

	render() {
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

		return m.render();
	}
});
