'use strict';
'require view';
'require form';
'require uci';

function randomHwid() {
	const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
	const buf = new Uint8Array(16);

	window.crypto.getRandomValues(buf);

	return Array.from(buf, (b) => abc[b % abc.length]).join('');
}

const DEVICE_FIELDS = [
	[ 'user_agent', _('Client (User-Agent)'), 'Happ/3.13.0' ],
	[ 'hwid', _('HWID'), '' ],
	[ 'os', _('OS'), 'Android' ],
	[ 'os_version', _('OS version'), '14' ],
	[ 'model', _('Device name'), 'OpenWrt' ],
	[ 'locale', _('Language'), 'ru' ]
];

return view.extend({
	load() {
		return uci.load('mayhem');
	},

	render() {
		const proxies = uci.sections('mayhem', 'section')
			.filter((s) => (s.type || 'proxy') === 'proxy')
			.map((s) => s['.name']);
		const dev = uci.get('mayhem', 'device') || {};

		const m = new form.Map('mayhem', '',
			_('Subscription servers are added to sections on the Routing page. Downloads repeat by the interval the provider sets, or every 12 hours.'));
		let s, o;

		// --- device profile ---

		s = m.section(form.NamedSection, 'device', 'device', _('Device profile'),
			_('How the router presents itself to subscription servers. The headers match the Happ client: x-hwid, x-device-os, x-ver-os, x-device-model, x-device-locale.'));
		s.addremove = false;

		DEVICE_FIELDS.forEach((f) => {
			o = s.option(form.Value, f[0], f[1]);
			o.placeholder = f[2];
		});

		o = s.option(form.Button, '_new_hwid', ' ');
		o.inputtitle = _('Generate a new HWID');
		o.inputstyle = 'action';
		o.onclick = function(ev, section_id) {
			const field = this.section.children.filter((c) => c.option === 'hwid')[0];

			field.getUIElement(section_id).setValue(randomHwid());
		};

		// --- subscriptions ---

		s = m.section(form.GridSection, 'subscription', _('Subscriptions'));
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add subscription');
		s.modaltitle = (section_id) => _('Subscription') + ' » ' + section_id;

		s.tab('main', _('Subscription'));
		s.tab('device', _('Device data'));

		o = s.taboption('main', form.Flag, 'enabled', _('Enabled'));
		o.default = '1';
		o.editable = true;
		o.rmempty = false;

		o = s.taboption('main', form.Value, 'url', _('URL'));
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return (/^https?:\/\/\S+$/).test(value || '') ? true : _('Expected an http(s):// address');
		};

		o = s.taboption('main', form.ListValue, 'format', _('Format'));
		o.value('auto', _('Detect'));
		o.value('uri', _('List of links (plain or base64)'));
		o.value('xray_json', _('Xray JSON'));
		o.default = 'auto';
		o.modalonly = true;

		o = s.taboption('main', form.Value, 'update_interval', _('Update every, hours'),
			_('Empty: as the provider says, otherwise 12 hours.'));
		o.datatype = 'range(1,720)';
		o.placeholder = _('auto');

		o = s.taboption('main', form.ListValue, 'update_via', _('Download'),
			_('If the subscription server is blocked, it can be downloaded through a section.'));
		o.value('auto', _('Direct, then through a section if that fails'));
		o.value('direct', _('Direct only'));
		o.value('section', _('Through a section only'));
		o.default = 'auto';
		o.modalonly = true;

		o = s.taboption('main', form.ListValue, 'update_section', _('Section for downloading'));
		o.value('', _('The first section that uses this subscription'));
		proxies.forEach((n) => o.value(n));
		o.depends('update_via', 'auto');
		o.depends('update_via', 'section');
		o.modalonly = true;

		o = s.taboption('main', form.DynamicList, 'header', _('Extra headers'),
			_('In the form "Name: value".'));
		o.modalonly = true;
		o.validate = function(section_id, value) {
			return (!value || /^[A-Za-z0-9-]+:\s*\S/.test(value)) ? true : _('Expected "Name: value"');
		};

		o = s.taboption('device', form.Flag, 'send_hwid', _('Send device data'),
			_('Needed by providers that limit the number of devices.'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;

		DEVICE_FIELDS.forEach((f) => {
			o = s.taboption('device', form.Value, f[0], f[1], _('Empty: from the device profile.'));
			o.placeholder = dev[f[0]] || f[2];
			o.modalonly = true;

			if (f[0] !== 'user_agent')
				o.depends('send_hwid', '1');
		});

		return m.render();
	}
});
