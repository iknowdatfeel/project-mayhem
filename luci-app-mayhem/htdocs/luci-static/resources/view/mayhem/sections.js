'use strict';
'require view';
'require form';
'require uci';

const LINK_RE = /^(vless|vmess|trojan|ss|socks5?|https?|hysteria2|hy2|wireguard|wg):\/\/\S+/i;
const DOMAIN_RE = /^(domain:|full:)?(\*\.|\.)?[a-z0-9_-]+(\.[a-z0-9_-]+)*\.?$/i;

function validateDomain(section_id, value) {
	if (!value)
		return true;

	if (/^(keyword|regexp):.+/.test(value) || /^(geosite|ext):/.test(value) || DOMAIN_RE.test(value))
		return true;

	return _('Expected a domain, or domain:, full:, keyword:, regexp: rule');
}

function validateIP(section_id, value) {
	if (!value)
		return true;

	if (/^(geoip|ext):/.test(value))
		return true;

	const v4 = /^(\d{1,3}\.){3}\d{1,3}(\/\d{1,2})?$/;
	const v6 = /^[0-9a-f:]+(\/\d{1,3})?$/i;

	return (v4.test(value) || (v6.test(value) && value.indexOf(':') >= 0))
		? true : _('Expected an IP address or a subnet in CIDR form');
}

function validateRegexp(section_id, value) {
	if (!value)
		return true;

	try {
		new RegExp(value);
		return true;
	}
	catch (e) {
		return _('Invalid regular expression');
	}
}

return view.extend({
	load() {
		return uci.load('mayhem');
	},

	render() {
		const subs = uci.sections('mayhem', 'subscription').map((s) => s['.name']);

		const m = new form.Map('mayhem', _('Sections'),
			_('A section is a set of rules and the way its traffic leaves the router. Sections are checked top to bottom; block sections always go first.'));

		const s = m.section(form.GridSection, 'section');
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add section');
		s.modaltitle = (section_id) => _('Section') + ' » ' + section_id;

		let o;

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'type', _('Type'),
			_('Proxy: through a server. Direct: bypass the proxy. Block: drop the traffic.'));
		o.value('proxy', _('Proxy'));
		o.value('exclusion', _('Direct'));
		o.value('block', _('Block'));
		o.default = 'proxy';

		o = s.option(form.ListValue, 'proxy_type', _('Servers from'));
		o.value('link', _('Links and subscriptions'));
		o.value('json', _('Xray outbound JSON'));
		o.default = 'link';
		o.depends('type', 'proxy');
		o.modalonly = true;

		o = s.option(form.DynamicList, 'link', _('Links'),
			_('One server per entry: vless://, vmess://, trojan://, ss://, socks://, http(s)://, hysteria2://, wireguard://'));
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return (!value || LINK_RE.test(value.trim())) ? true : _('Unsupported or malformed link');
		};

		o = s.option(form.MultiValue, 'subscription', _('Subscriptions'),
			subs.length ? _('Servers of these subscriptions are added to the section.')
				: _('No subscriptions yet: add them on the Subscriptions page.'));
		subs.forEach((n) => o.value(n));
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;

		o = s.option(form.Value, 'filter', _('Take servers named'),
			_('Regular expression over server names, case-insensitive. Example: NL|DE'));
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;
		o.validate = validateRegexp;

		o = s.option(form.Value, 'exclude', _('Skip servers named'));
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;
		o.validate = validateRegexp;

		o = s.option(form.ListValue, 'select', _('Server choice'),
			_('With several servers. Automatic: the fastest by URL test, checked periodically; you can still pin a server on the dashboard. Manual: the server picked on the dashboard.'));
		o.value('auto', _('Automatic'));
		o.value('manual', _('Manual'));
		o.default = 'auto';
		o.depends({ type: 'proxy', proxy_type: 'link' });
		o.modalonly = true;

		o = s.option(form.TextValue, 'outbound_json', _('Outbound JSON'),
			_('A single Xray outbound object. Its tag is replaced automatically.'));
		o.rows = 12;
		o.monospace = true;
		o.depends({ type: 'proxy', proxy_type: 'json' });
		o.modalonly = true;
		o.validate = function(section_id, value) {
			try {
				const j = JSON.parse(value);

				return (j && (typeof j.protocol === 'string' || Array.isArray(j.outbounds) || Array.isArray(j)))
					? true : _('The object has no "protocol"');
			}
			catch (e) {
				return _('Invalid JSON: %s').format(e.message);
			}
		};

		o = s.option(form.DynamicList, 'domain', _('Domains'),
			_('example.com matches the domain and its subdomains. Prefixes: full: exact name, keyword: substring, regexp: regular expression.'));
		o.modalonly = true;
		o.validate = validateDomain;

		o = s.option(form.DynamicList, 'ip', _('IP addresses and subnets'),
			_('IPv4 or IPv6 addresses, CIDR allowed: 91.108.4.0/22'));
		o.modalonly = true;
		o.validate = validateIP;

		o = s.option(form.DummyValue, '_servers', _('Servers'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const get = (k) => L.toArray(this.map.data.get('mayhem', section_id, k));
			const type = this.map.data.get('mayhem', section_id, 'type') || 'proxy';

			if (type !== 'proxy')
				return '—';

			if (this.map.data.get('mayhem', section_id, 'proxy_type') === 'json')
				return 'JSON';

			const parts = [];
			const links = get('link').length;

			if (links)
				parts.push(_('%d links').format(links));

			get('subscription').forEach((n) => parts.push(n));

			return parts.join(', ') || _('none');
		};

		o = s.option(form.DummyValue, '_rules', _('Rules'));
		o.modalonly = false;
		o.textvalue = function(section_id) {
			const d = L.toArray(this.map.data.get('mayhem', section_id, 'domain')).length;
			const i = L.toArray(this.map.data.get('mayhem', section_id, 'ip')).length;

			return _('%d domains, %d addresses').format(d, i);
		};

		return m.render();
	}
});
