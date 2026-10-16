'use strict';
'require baseclass';
'require dom';
'require ui';
'require uci';
'require mayhem.common as mh';

// Everything but the dashboard opens in a window over it: the server list,
// routing, settings and component updates are pages of their own
// (mayhem/page/*.js) with the usual LuCI forms and the usual Save & Apply.
//
// The window sits under LuCI's modal dialogs, so the dialogs of a page (a
// section's settings, renaming, confirmations, the apply countdown) open over
// it as before. The page name is kept in the address (#servers): a page that
// reloads itself comes back open, Save & Apply ends on the dashboard.

const PAGES = {
	servers: _('Connections'),
	sections: _('Routing'),
	settings: _('Settings'),
	components: _('Component updates')
};

const CSS = `
.mh-sheet-overlay { position:fixed; inset:0; z-index:850; background:rgba(0,0,0,.55); display:flex; align-items:flex-start; justify-content:center; overflow:hidden; }
.mh-sheet { box-sizing:border-box; width:min(1100px, calc(100% - 32px)); max-height:calc(100% - 48px); margin-top:24px; display:flex; flex-direction:column; background:var(--background-color-high, #fff); border:1px solid var(--border-color-low, #ddd); border-radius:6px; box-shadow:0 8px 32px rgba(0,0,0,.35); }
.mh-sheet-head { display:flex; align-items:center; gap:10px; padding:12px 16px; border-bottom:1px solid var(--border-color-low, #ddd); }
.mh-sheet-head h3 { margin:0; padding:0; flex:1; font-size:120%; border:0; }
.mh-sheet-close { border:0; background:none; color:inherit; cursor:pointer; font-size:20px; line-height:1; padding:4px 8px; opacity:.6; }
.mh-sheet-close:hover { opacity:1; }
.mh-sheet-body { padding:12px 16px; overflow:auto; flex:1 1 auto; min-height:120px; }
.mh-sheet-body .cbi-map > h2 { display:none; }
.mh-sheet-body .cbi-dropdown > ul > li { text-align:left; justify-content:flex-start; }
.mh-sheet-body .cbi-dropdown[empty] > .more { flex-grow:1; text-align:left; align-items:flex-start; padding-left:.5em; }
.mh-sheet-notes { padding:10px 16px 0; }
.mh-sheet-notes:empty { display:none; }
.mh-sheet-foot { display:flex; justify-content:flex-end; flex-wrap:wrap; gap:6px; padding:10px 16px; border-top:1px solid var(--border-color-low, #ddd); }
.mh-sheet-foot:empty { display:none; }
.mh-sheet-foot .cbi-page-actions { margin:0; padding:0; border:0; background:none; }
body.mh-sheet-open { overflow:hidden; }
@media (max-width: 600px) {
.mh-sheet { width:100%; max-height:100%; margin-top:0; border-radius:0; }
.mh-sheet-overlay { align-items:stretch; }
}
`;

let open = null;	// { name, overlay, page, restore }

// Configs the pages read: loaded anew each time a page opens.
const CONFIGS = [ 'mayhem', 'network', 'firewall', 'dhcp' ];

function currentHash() {
	const h = (window.location.hash || '').replace(/^#/, '');

	return PAGES[h] ? h : null;
}

function setHash(name) {
	const url = window.location.href.split('#')[0] + (name ? '#' + name : '');

	try {
		window.history.replaceState(null, '', url);
	}
	catch (e) {}
}

// Forms of the page in the window: what the footer buttons save and reset.
function maps(root) {
	return Array.prototype.slice.call(root.querySelectorAll('.cbi-map'));
}

function defaults(page, body) {
	if (page.handleSave === undefined)
		page.handleSave = () => Promise.all(maps(body).map((m) => dom.callClassMethod(m, 'save')));

	if (page.handleSaveApply === undefined)
		page.handleSaveApply = (ev, mode) => page.handleSave(ev).then(() => ui.changes.apply(mode == '0'));

	if (page.handleReset === undefined)
		page.handleReset = () => Promise.all(maps(body).map((m) => dom.callClassMethod(m, 'reset')));
}

// The same buttons as at the bottom of a LuCI page, for the forms in the window.
function footer(page, body) {
	const readonly = !maps(body).some((m) => {
		const inst = dom.findClassInstance(m);

		return inst && !inst.readonly;
	});
	const out = [];

	if (page.handleReset)
		out.push(E('button', {
			'class': 'btn cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(page, 'handleReset'),
			'disabled': readonly || null
		}, _('Discard changes')));

	if (page.handleSave)
		out.push(E('button', {
			'class': 'btn cbi-button cbi-button-save',
			'click': ui.createHandlerFn(page, 'handleSave'),
			'disabled': readonly || null
		}, _('Save')));

	if (page.handleSaveApply)
		out.push(new ui.ComboButton('0', {
			0: [ _('Save & Apply') ],
			1: [ _('Apply unchecked') ]
		}, {
			classes: {
				0: 'btn cbi-button cbi-button-apply important',
				1: 'btn cbi-button cbi-button-negative important'
			},
			click: ui.createHandlerFn(page, 'handleSaveApply'),
			disabled: readonly || null
		}).render());

	return out;
}

function close() {
	if (!open)
		return;

	const o = open;

	open = null;
	o.restore();
	o.overlay.remove();
	document.body.classList.remove('mh-sheet-open');
	setHash(null);

	if (o.onclose)
		o.onclose();
}

function show(name, onclose) {
	if (!PAGES[name])
		return Promise.resolve();

	close();

	const body = E('div', { 'class': 'mh-sheet-body' }, E('p', { 'class': 'spinning' }, _('Loading…')));
	const notes = E('div', { 'class': 'mh-sheet-notes' });
	const foot = E('div', { 'class': 'mh-sheet-foot' });
	const overlay = E('div', { 'class': 'mh-sheet-overlay' }, E('div', { 'class': 'mh-sheet', 'role': 'dialog', 'aria-label': PAGES[name] }, [
		E('div', { 'class': 'mh-sheet-head' }, [
			E('h3', PAGES[name]),
			E('button', { 'class': 'mh-sheet-close', 'title': _('Close'), 'click': close }, '✕')
		]),
		notes,
		body,
		foot
	]));

	// Notifications go to the top of the page, under the window: while it is
	// open they are moved into it.
	const addNotification = ui.addNotification;

	ui.addNotification = function() {
		const msg = addNotification.apply(this, arguments);

		if (msg && msg.parentNode && open && open.overlay === overlay) {
			notes.insertBefore(msg, notes.firstChild);
			body.scrollTop = 0;
		}

		return msg;
	};

	const keydown = (ev) => {
		if (ev.key === 'Escape' && !document.body.classList.contains('modal-overlay-active'))
			close();
	};

	document.addEventListener('keydown', keydown);

	open = {
		name: name, overlay: overlay, onclose: onclose,
		restore: () => {
			ui.addNotification = addNotification;
			document.removeEventListener('keydown', keydown);
		}
	};

	document.body.appendChild(overlay);
	document.body.classList.add('mh-sheet-open');
	setHash(name);

	const mine = open;

	// LuCI keeps a config it once loaded: the dashboard changes the router's
	// config by itself (deleting a server, a tunnel, a chain), and a page that
	// opens later must not show what was there before.
	uci.unload(CONFIGS);

	return L.require('mayhem.page.' + name).then((page) => {
		defaults(page, body);

		return Promise.resolve(page.load()).then((data) => page.render(data)).then((node) => {
			if (open !== mine)
				return;

			dom.content(body, node);
			dom.content(foot, footer(page, body));
		});
	}).catch((e) => {
		if (open === mine)
			dom.content(body, E('div', { 'class': 'alert-message error' }, [ E('p', String((e && e.message) || e)) ]));
	});
}

return baseclass.extend({
	PAGES: PAGES,
	show: show,
	close: close,

	// Is a page open over the dashboard (its polling waits meanwhile)?
	isOpen() {
		return open != null;
	},

	style() {
		return E('style', CSS);
	},

	// The page named in the address, opened again after a reload.
	restore(onclose) {
		const name = currentHash();

		return name ? show(name, onclose) : Promise.resolve();
	},

	// The open page drawn again from the router's config after a change made
	// on it (a key or a tunnel added); the dashboard under it is told when
	// the window closes. Without a window the whole page reloads.
	reload() {
		if (!open) {
			window.location.reload();
			return new Promise(() => {});
		}

		const name = open.name, onclose = open.onclose;

		open.onclose = null;

		return show(name, onclose);
	},

	// A button of the dashboard that opens a page.
	button(opts) {
		return mh.button({ icon: opts.icon, cls: opts.cls, text: opts.text || PAGES[opts.page], click: () => show(opts.page, opts.onclose) });
	}
});
