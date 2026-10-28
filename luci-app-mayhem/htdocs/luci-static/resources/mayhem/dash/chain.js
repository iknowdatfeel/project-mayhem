'use strict';
'require baseclass';
'require ui';

// The fallback chains of the dashboard: the window that orders the servers
// of a section, and the server list's chain, whose items may be servers of
// any kind or whole subscriptions with their own rule.
//
// Its items as the router keeps them: a server by name ("<subscription>\t
// <name>" for one of a subscription) or "@<subscription>", the server the
// subscription's rule picks.

return baseclass.extend({
	// The dashboard: names, latencies and saving the choice.
	bind(view) {
		this.view = view;
	},

	isSub(src) {
		return !!src && src !== 'link' && src !== 'json' && src !== 'interface';
	},

	nodeEntry(n) {
		return this.isSub(n.source) ? n.source + '\t' + n.name : n.name;
	},

	listEntries(s) {
		const byTag = {};

		(s.nodes || []).forEach((n) => byTag[n.tag] = n);

		return (s.items || []).map((i) => i.sub ? '@' + i.sub : byTag[i.tag] ? this.nodeEntry(byTag[i.tag]) : null).filter((e) => e);
	},

	// A subscription's rule in words; rules: those being edited, by name.
	ruleText(s, sub, rules) {
		const r = (rules && rules[sub]) || this.ruleOf(s, sub);

		if (r.mode === 'manual')
			return _('chosen: %s').format(r.selected || '?');

		if (r.mode === 'fallback')
			return _('its chain: %s').format((r.chain || []).join(' → ') || '?');

		return _('fastest');
	},

	// The rule the router has, with names instead of tags.
	ruleOf(s, sub) {
		const r = (s.subs || {})[sub] || { mode: 'auto' };
		const name = (t) => ((s.nodes || []).find((n) => n.tag === t) || {}).name;

		return { mode: r.mode, selected: r.selected ? name(r.selected) : null, chain: (r.chain || []).map(name).filter((x) => x) };
	},

	entryLabel(s, e, rules) {
		if (e.charAt(0) === '@')
			return '%s (%s)'.format(this.view.subTitle(e.slice(1)), this.ruleText(s, e.slice(1), rules));

		const i = e.indexOf('\t');

		return i > 0 ? '%s · %s'.format(e.slice(i + 1), this.view.subTitle(e.slice(0, i))) : e;
	},

	// An ordered list with up, down, remove and "add": the chain, and inside
	// it the chain of a subscription.
	orderedList(items, label, choices, placeholder, changed) {
		const list = E('ul', { 'class': 'mh-chain-list' });
		const add = E('select', { 'class': 'cbi-input-select mh-add', 'style': 'width:100%' });

		const draw = () => {
			list.replaceChildren(...items.map((it, i) => E('li', [
				E('span', { 'class': 'mh-chain-no' }, String(i + 1)),
				E('div', { 'class': 'mh-grow' }, label(it, i)),
				E('button', { 'class': 'btn', 'title': _('Up'), 'disabled': i === 0 ? '' : null,
					'click': () => { items.splice(i - 1, 0, items.splice(i, 1)[0]); draw(); changed(); } }, '↑'),
				E('button', { 'class': 'btn', 'title': _('Down'), 'disabled': i === items.length - 1 ? '' : null,
					'click': () => { items.splice(i + 1, 0, items.splice(i, 1)[0]); draw(); changed(); } }, '↓'),
				E('button', { 'class': 'btn cbi-button-remove', 'title': _('Remove'),
					'click': () => { items.splice(i, 1); draw(); changed(); } }, '✕')
			])));

			if (!items.length)
				list.appendChild(E('li', { 'class': 'mh-muted' }, _('Add servers in the order they should be tried.')));

			const groups = choices().filter((g) => g.options.some((o) => items.indexOf(o[0]) < 0));

			add.replaceChildren(E('option', { 'value': '' }, placeholder),
				...groups.map((g) => {
					const opts = g.options.filter((o) => items.indexOf(o[0]) < 0).map((o) => E('option', { 'value': o[0] }, o[1]));

					return g.label ? E('optgroup', { 'label': g.label }, opts) : opts;
				}).flat());
		};

		add.addEventListener('change', () => {
			if (add.value)
				items.push(add.value);

			draw();
			changed();
		});

		draw();

		return { el: E('div', [ list, add ]), draw: draw };
	},

	// The chain of the server list: servers of any kind and whole
	// subscriptions, each subscription with its rule, which can be changed
	// here as well (it is the same rule as in the subscription's box).
	listChainDialog(s) {
		const subsOf = {};

		for (const n of s.nodes || [])
			if (this.isSub(n.source))
				(subsOf[n.source] = subsOf[n.source] || []).push(n);

		const subNames = Object.keys(subsOf);
		const rules = {};

		subNames.forEach((sub) => rules[sub] = this.ruleOf(s, sub));

		const entries = s.mode === 'fallback' ? this.listEntries(s) : [];

		const ruleEditor = (sub) => {
			const r = rules[sub];
			const box = E('div', { 'class': 'mh-rule' });
			const draw = () => {
				const mode = E('select', { 'class': 'cbi-input-select', 'change': (ev) => {
					r.mode = ev.target.value;

					if (r.mode === 'manual' && !r.selected)
						r.selected = subsOf[sub][0].name;

					draw();
					outer.draw();
				} }, [ [ 'auto', _('Fastest server') ], [ 'fallback', _('Fallback chain') ], [ 'manual', _('Chosen by hand') ] ]
					.map((m) => E('option', { 'value': m[0], 'selected': m[0] === r.mode ? '' : null }, m[1])));
				const rows = [ mode ];

				// Chosen by hand: every server of the subscription, one marked.
				if (r.mode === 'manual')
					rows.push(E('div', { 'class': 'mh-pick-list' }, subsOf[sub].map((n) => E('label', [
						E('input', { 'type': 'radio', 'name': 'mh-pick-' + sub, 'value': n.name, 'checked': n.name === r.selected ? '' : null,
							'change': () => { r.selected = n.name; outer.draw(); } }),
						' ', n.name, ' ', this.view.latency(n)
					]))));
				else if (r.mode === 'fallback') {
					r.chain = r.chain || [];
					rows.push(this.orderedList(r.chain, (name) => E('span', name),
						() => [ { options: subsOf[sub].map((n) => [ n.name, n.name ]) } ], _('Add a server…'), () => outer.draw()).el);
				}

				box.replaceChildren(...rows);
			};

			draw();

			return box;
		};

		const outer = this.orderedList(entries, (e) => {
			const sub = e.charAt(0) === '@' ? e.slice(1) : null;

			return sub && rules[sub] ? [ E('b', this.view.subTitle(sub)), ' ', E('span', { 'class': 'mh-muted mh-small' }, _('whole subscription')), ruleEditor(sub) ]
				: [ E('b', this.entryLabel(s, e)) ];
		}, () => [
			{ label: _('Subscriptions'), options: subNames.map((sub) => [ '@' + sub, _('%s: the whole subscription').format(this.view.subTitle(sub)) ]) },
			{ label: _('Server list'), options: (s.nodes || []).filter((n) => !this.isSub(n.source)).map((n) => [ n.name, n.name ]) },
			...subNames.map((sub) => ({ label: this.view.subTitle(sub), options: subsOf[sub].map((n) => [ sub + '\t' + n.name, n.name ]) }))
		], _('Add a server or a subscription…'), () => {});

		ui.showModal(_('Fallback chain'), [
			E('p', _('The first item carries the traffic while it works; when it stops answering, the next one takes over, and an item higher in the chain takes over again as soon as it works. A subscription stands for the server its rule picks: the fastest of its servers, its own chain, or the one chosen by hand. Checks run every 20 seconds, nothing restarts.')),
			outer.el,
			E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
				E('button', { 'class': 'btn', 'click': () => { ui.hideModal(); this.view.redraw(); } }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () => {
					if (!entries.length) {
						ui.addNotification(null, E('p', _('The chain is empty')), 'warning');
						return;
					}

					for (const e of entries) {
						const r = e.charAt(0) === '@' ? rules[e.slice(1)] : null;

						if (r && r.mode === 'fallback' && !(r.chain || []).length) {
							ui.addNotification(null, E('p', _('The chain of %s is empty').format(this.view.subTitle(e.slice(1)))), 'warning');
							return;
						}
					}

					// Only the rules of the subscriptions in the chain are sent.
					const send = {};

					entries.filter((e) => e.charAt(0) === '@' && rules[e.slice(1)]).forEach((e) => {
						const r = rules[e.slice(1)];

						send[e.slice(1)] = { mode: r.mode, chain: r.mode === 'fallback' ? r.chain : [], selected: r.mode === 'manual' ? r.selected : '' };
					});

					ui.hideModal();
					return this.view.saveSelect(s.name, 'fallback', entries, send);
				}) }, _('Save'))
			])
		], 'mh-chain-modal');
	},

	// The chain: servers in the order they are tried, up and down, add, remove.
	dialog(s) {
		if (s.name === 'pool')
			return this.listChainDialog(s);

		const byTag = {};

		(s.nodes || []).forEach((n) => byTag[n.tag] = n);

		let chain = (s.mode === 'fallback' ? (s.chain || []) : []).filter((t) => byTag[t]).map((t) => byTag[t].name);
		const list = E('ul', { 'class': 'mh-chain-list' });
		const add = E('select', { 'class': 'cbi-input-select', 'style': 'width:100%' });

		const draw = () => {
			list.replaceChildren(...chain.map((name, i) => E('li', [
				E('span', { 'class': 'mh-chain-no' }, String(i + 1)),
				E('b', name),
				E('button', { 'class': 'btn', 'title': _('Up'), 'disabled': i === 0 ? '' : null,
					'click': () => { chain.splice(i - 1, 0, chain.splice(i, 1)[0]); draw(); } }, '↑'),
				E('button', { 'class': 'btn', 'title': _('Down'), 'disabled': i === chain.length - 1 ? '' : null,
					'click': () => { chain.splice(i + 1, 0, chain.splice(i, 1)[0]); draw(); } }, '↓'),
				E('button', { 'class': 'btn cbi-button-remove', 'title': _('Remove'),
					'click': () => { chain.splice(i, 1); draw(); } }, '✕')
			])));

			if (!chain.length)
				list.appendChild(E('li', { 'class': 'mh-muted' }, _('Add servers in the order they should be tried.')));

			const rest = (s.nodes || []).filter((n) => chain.indexOf(n.name) < 0);

			add.replaceChildren(E('option', { 'value': '' }, _('Add a server…')),
				...rest.map((n) => E('option', { 'value': n.name }, n.name)));
		};

		add.addEventListener('change', () => {
			if (add.value)
				chain.push(add.value);

			draw();
		});

		draw();

		ui.showModal(_('Fallback chain'), [
			E('p', _('The first server carries the traffic while it works. When it stops answering, the next one takes over, and so on; a server higher in the chain takes over again as soon as it works. Checks run every 20 seconds, nothing restarts.')),
			list,
			add,
			E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
				E('button', { 'class': 'btn', 'click': () => { ui.hideModal(); this.view.redraw(); } }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () => {
					if (chain.length < 2) {
						ui.addNotification(null, E('p', _('A chain needs two servers or more')), 'warning');
						return;
					}

					ui.hideModal();
					return this.view.saveSelect(s.name, 'fallback', chain);
				}) }, _('Save'))
			])
		]);
	}
});
