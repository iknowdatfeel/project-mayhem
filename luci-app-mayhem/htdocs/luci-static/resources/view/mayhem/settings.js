'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require mayhem.common as mh';

// Settings: logging, memory, watchdog, server checks and the reset to defaults.

const callReset = rpc.declare({ object: 'luci.mayhem', method: 'reset_config', params: [ 'connections' ], expect: { '': {} } });

function resetDialog() {
	const keep = E('input', { 'type': 'checkbox', 'checked': '' });

	ui.showModal(_('Restore defaults'), [
		E('p', _('Every setting of Mayhem goes back to how it was after installation: sections, rules, DNS, geo sources. Xray restarts.')),
		E('label', [ keep, ' ', _('Keep subscriptions, server keys and HWID') ]),
		E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
			E('button', {
				'class': 'btn cbi-button-negative',
				'click': ui.createHandlerFn(this, () => callReset(keep.checked).then((r) => {
					if (r.error) {
						ui.addNotification(null, E('p', r.error), 'error');
						return;
					}

					ui.hideModal();
					ui.addNotification(null, E('p', _('The settings are reset. The page reloads in a few seconds.')), 'info');
					window.setTimeout(() => window.location.reload(), 3000);
				}))
			}, _('Reset settings'))
		])
	]);
}

return view.extend({
	load() {
		return uci.load('mayhem');
	},

	render(data) {
		const m = new form.Map('mayhem');
		let s, o;

		s = m.section(form.NamedSection, 'settings', 'settings');
		s.addremove = false;

		o = s.option(form.ListValue, 'log_level', _('Log level'));
		[ 'debug', 'info', 'warning', 'error', 'none' ].forEach((l) => o.value(l));
		o.default = 'warning';

		o = s.option(form.Value, 'memlimit', _('Xray memory limit, MiB'),
			_('A soft limit: Xray frees memory more often when it gets close. Empty: a quarter of the router memory.'));
		o.datatype = 'range(16,4096)';
		o.placeholder = _('Auto');

		o = s.option(form.Flag, 'watchdog', _('Watchdog'),
			_('Restarts Xray when it holds too much memory for 3 minutes in a row, and dnsmasq when it is gone.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.ListValue, 'watchdog_mem', _('Restart Xray above'));
		[ 30, 40, 50, 60 ].forEach((p) => o.value(String(p), _('%d%% of memory').format(p)));
		o.default = '40';
		o.depends('watchdog', '1');

		o = s.option(form.Value, 'probe_url', _('Address for server checks'),
			_('The automatic server choice and the URL test request it through each server.'));
		o.placeholder = 'https://www.gstatic.com/generate_204';
		o.validate = function(section_id, value) {
			return (!value || /^https?:\/\/\S+$/.test(value)) ? true : _('Expected an http(s):// address');
		};

		o = s.option(form.ListValue, 'probe_interval', _('Check servers'));
		o.value('1m', _('Every minute'));
		o.value('3m', _('Every 3 minutes'));
		o.value('5m', _('Every 5 minutes'));
		o.value('10m', _('Every 10 minutes'));
		o.value('30m', _('Every 30 minutes'));
		o.default = '3m';

		o = s.option(form.Value, 'ip_check_url', _('Address for the external IP check'),
			_('Diagnostics request it directly and through every section; it must answer with the IP address as plain text.'));
		o.placeholder = 'https://api.ipify.org';
		o.validate = function(section_id, value) {
			return (!value || /^https?:\/\/\S+$/.test(value)) ? true : _('Expected an http(s):// address');
		};

		o = s.option(form.Button, '_reset', _('Restore defaults'));
		o.inputtitle = _('Reset settings…');
		o.inputstyle = 'negative';
		o.onclick = resetDialog;

		return m.render().then((node) => {
			node.insertBefore(mh.style(), node.firstChild);

			return node;
		});
	}
});
