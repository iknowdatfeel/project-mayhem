'use strict';
'require baseclass';
'require form';
'require uci';

return baseclass.extend({
	load() {
		return uci.load('mayhem');
	},

	render() {
		const m = new form.Map('mayhem');
		let s, o;

		s = m.section(form.NamedSection, 'settings', 'settings');
		s.addremove = false;

		o = s.option(form.Flag, 'mux', _('Mux for VLESS'),
			_('Several connections share one connection to the server. Applies to every VLESS server; with XTLS Vision only UDP is multiplexed.'));

		o = s.option(form.Value, 'mux_concurrency', _('Mux concurrency (TCP)'));
		o.datatype = 'range(1,1024)';
		o.placeholder = '8';
		o.depends('mux', '1');

		o = s.option(form.Value, 'mux_xudp_concurrency', _('XUDP concurrency'));
		o.datatype = 'range(1,1024)';
		o.placeholder = '16';
		o.depends('mux', '1');

		o = s.option(form.ListValue, 'mux_xudp_udp443', _('XUDP UDP/443 policy'));
		o.value('reject', _('Drop: browsers fall back to TCP'));
		o.value('allow', _('Send through Mux'));
		o.value('skip', _('Send without Mux'));
		o.default = 'reject';
		o.depends('mux', '1');

		return m.render();
	}
});
