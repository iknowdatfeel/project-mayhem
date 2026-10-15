'use strict';
'require baseclass';
'require ui';

// Editing a server as Xray JSON: one outbound, its "tag" is the name of the
// server. A key edited here is kept as JSON (one line) from then on.

return baseclass.extend({
	// The dialog. save(newLink) applies the result and resolves to an error
	// text or nothing; outbound is the server as Xray JSON (from the router's
	// parser), name its current name.
	dialog(link, outbound, name, save) {
		const msg = E('div', { 'class': 'mh-small' });
		const say = (m, cls) => {
			msg.className = 'mh-small ' + (cls || 'mh-muted');
			msg.textContent = m;
		};

		const j = Object.assign({ tag: name || '' }, outbound || {});
		const text = E('textarea', {
			'class': 'cbi-input-textarea', 'rows': 22, 'spellcheck': 'false',
			'style': 'width:100%;font-family:monospace;font-size:90%;box-sizing:border-box'
		}, JSON.stringify(j, null, 2));

		const value = () => {
			let o;

			try {
				o = JSON.parse(text.value);
			}
			catch (e) {
				throw new Error(_('Not valid JSON: %s').format(e.message));
			}

			if (!o || typeof o !== 'object' || typeof o.protocol !== 'string')
				throw new Error(_('The outbound needs "protocol"'));

			return JSON.stringify(o);
		};

		ui.showModal(_('Edit server: %s').format(name || ''), [
			E('p', { 'class': 'mh-muted mh-small' }, _('One Xray outbound; "tag" is the name of the server. Saving here keeps the server as JSON instead of a key.')),
			text,
			msg,
			E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () => {
					let out;

					try {
						out = value();
					}
					catch (e) {
						say(e.message, 'mh-fail');
						return;
					}

					// Nothing changed: a key stays a key.
					if (link && link.charAt(0) !== '{' && out === JSON.stringify(j)) {
						ui.hideModal();
						return;
					}

					return Promise.resolve(save(out)).then((err) => {
						if (err)
							say(err, 'mh-fail');
						else
							ui.hideModal();
					});
				}) }, _('Save'))
			])
		]);

		text.focus();
	}
});
