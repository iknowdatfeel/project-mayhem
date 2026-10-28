'use strict';
'require baseclass';
'require rpc';
'require ui';
'require mayhem.common as mh';

// The "Active connections" window of the dashboard: what each device connects
// to, over which protocol, and which way it goes: a server through xray, a
// tunnel in the kernel, or direct. From the kernel's connection table; servers
// and names from xray's log while the window is open.

const callConns = rpc.declare({ object: 'luci.mayhem', method: 'connections', params: [ 'stop', 'device' ], expect: { '': {} } });

return baseclass.extend({
	open() {
		this.conns = null;
		this.connsOpen = true;
		this.connPaused = false;
		this.connDev = '';
		this.connBase = null;

		const body = E('div', { 'id': 'mh-conns' }, E('p', { 'class': 'mh-muted' }, [ mh.icon('loader', true), ' ', _('Loading…') ]));

		// The device list keeps its place: it is filled again, not redrawn,
		// so an open list does not close under the hand.
		const devs = E('select', {
			'id': 'mh-conns-dev', 'class': 'cbi-input-select',
			'change': (ev) => {
				this.connDev = ev.target.value;
				this.connBase = null;
				this.fetch();
			}
		}, E('option', { 'value': '' }, _('All devices')));

		const pause = E('button', { 'id': 'mh-conns-pause', 'class': 'btn', 'click': () => this.pause() }, _('Pause'));
		const clear = E('button', { 'class': 'btn', 'click': () => this.clear(),
			'title': _('Shows only connections opened from now on, and the traffic from now on') }, _('Clear'));

		ui.showModal(_('Active connections'), [
			E('p', { 'class': 'mh-muted mh-small' },
				_('Every connection of the network that is open now, grouped by device, address and route. A site name is known when its address came in a DNS answer through Xray; otherwise the address is shown.')),
			E('div', { 'class': 'mh-conns-bar' }, [ devs, pause, clear,
				E('span', { 'id': 'mh-conns-count', 'class': 'mh-small' }),
				E('span', { 'id': 'mh-conns-note', 'class': 'mh-muted mh-small' }) ]),
			body,
			E('div', { 'class': 'right' }, E('button', { 'class': 'btn', 'click': () => this.close() }, _('Close')))
		], 'mh-conns-modal');

		this.fetch();
	},

	// One request now; the next one in 3 s unless paused or closed.
	fetch() {
		window.clearTimeout(this.connsTimer);

		if (!this.connsOpen)
			return;

		const seq = this.connSeq = (this.connSeq || 0) + 1;

		callConns(false, this.connDev).then((r) => {
			// An answer to a request made before the filter changed.
			if (seq !== this.connSeq)
				return;

			this.conns = r;
			this.draw();
		}).catch(() => {}).finally(() => {
			if (seq === this.connSeq && this.connsOpen && !this.connPaused)
				this.connsTimer = window.setTimeout(() => this.fetch(), 3000);
		});
	},

	pause() {
		this.connPaused = !this.connPaused;

		const btn = document.getElementById('mh-conns-pause');

		if (btn)
			btn.textContent = this.connPaused ? _('Resume') : _('Pause');

		if (this.connPaused)
			window.clearTimeout(this.connsTimer);
		else
			this.fetch();

		this.draw();
	},

	// From now on: what is there now is set aside, and what comes after is
	// counted from here (a connection that carries more shows up again with
	// the traffic since).
	clear() {
		const base = {};

		for (const c of (this.conns && this.conns.rows) || [])
			base[this.key(c)] = c.bytes;

		this.connBase = base;
		this.connBaseTime = new Date();
		this.draw();
	},

	key(c) {
		const x = c.route || {};

		return [ c.network, c.ip, c.host, c.port, x.kind, x.server || '' ].join('|');
	},

	close() {
		this.connsOpen = false;
		this.connSeq = (this.connSeq || 0) + 1;
		window.clearTimeout(this.connsTimer);
		ui.hideModal();
		callConns(true).catch(() => {});
	},

	// Where a connection goes, in a word: the server (or tunnel) by its name.
	route(r) {
		const x = r.route || {};

		switch (x.kind) {
		case 'proxy':
		case 'tunnel': return [ x.server || '?', 'mh-ok' ];
		case 'xray': return [ 'Xray', 'mh-ok' ];
		case 'inbound': return [ _('Inbound to port %d').format(x.port), 'mh-ok' ];
		case 'block': return [ _('Blocked'), 'mh-fail' ];
		case 'dns': return [ 'DNS', '' ];
		case 'direct': return [ _('Direct'), 'mh-muted' ];
		default: return [ x.tag || '?', '' ];
		}
	},

	draw() {
		const box = document.getElementById('mh-conns');
		const r = this.conns;

		if (!box || !r)
			return;

		if (r.error) {
			box.replaceChildren(E('p', { 'class': 'mh-fail' }, r.error));
			return;
		}

		this.fillDevices(r.devices || []);

		const cnt = document.getElementById('mh-conns-count');

		if (cnt && r.counts) {
			const h = r.hidden || {};

			cnt.textContent = 'TCP: %d · UDP: %d'.format(r.counts.tcp || 0, r.counts.udp || 0) +
				(h.total ? ' · ' + _('hidden: %d').format(h.total) : '');
			cnt.title = h.total ? _('Not in the table: the router\'s own %d, to the router %d, being closed %d, local and multicast %d, not understood %d')
				.format(h.router || 0, h.to_router || 0, h.closing || 0, h.local || 0, h.other || 0) : '';
		}

		const note = document.getElementById('mh-conns-note');

		if (note)
			note.textContent = [
				this.connPaused ? _('Paused') : '',
				this.connBase ? _('Since %s').format(this.connBaseTime.toLocaleTimeString()) : ''
			].filter((x) => x).join(' · ');

		// After "Clear": new connections, and old ones only with the traffic
		// they carried since.
		const rows = (r.rows || []).map((c) => {
			const was = this.connBase ? this.connBase[this.key(c)] : null;

			if (was == null)
				return c;

			return c.bytes > was ? Object.assign({}, c, { bytes: c.bytes - was }) : null;
		}).filter((c) => c);

		if (!rows.length) {
			box.replaceChildren(E('p', { 'class': 'mh-muted' }, _('No connections yet.')));
			return;
		}

		const tr = (cells, cls) => E('tr', { 'class': 'tr' + (cls ? ' ' + cls : '') }, cells);
		const td = (title, content) => E('td', { 'class': 'td', 'data-title': title }, content);

		box.replaceChildren(E('table', { 'class': 'table mh-rtable mh-conns' }, [
			tr([ _('Device'), _('Destination'), _('Protocol'), _('Connected via'), _('Open connections'), _('Traffic') ].map((h) => E('th', { 'class': 'th' }, h)), 'table-titles'),
			...rows.map((c) => {
				const rt = this.route(c);
				const dest = (c.domain || mh.ipText(c.host)) + (c.port != null ? ':' + c.port : '');
				const tip = c.domain ? mh.ipText(c.host) : null;

				return tr([
					td(_('Device'), c.device === 'router' ? _('This router') : (c.device || mh.ipText(c.ip))),
					td(_('Destination'), [ E('span', { 'title': tip }, dest),
						c.fake ? E('span', { 'class': 'mh-muted mh-small' }, ' FakeDNS') : '' ]),
					td(_('Protocol'), c.network.toUpperCase()),
					td(_('Connected via'), E('span', { 'class': rt[1] }, rt[0])),
					td(_('Open connections'), String(c.count)),
					td(_('Traffic'), mh.bytes(c.bytes))
				]);
			})
		]), r.total > rows.length ? E('p', { 'class': 'mh-muted mh-small' }, _('The %d busiest of %d.').format(rows.length, r.total)) : '');
	},

	// The devices with connections; the chosen one stays chosen even when it
	// has none at the moment.
	fillDevices(list) {
		const sel = document.getElementById('mh-conns-dev');

		if (!sel || document.activeElement === sel)
			return;

		const name = (d) => d.name === 'router' ? _('This router') : (d.name ? '%s (%s)'.format(d.name, mh.ipText(d.ip)) : mh.ipText(d.ip));
		const items = list.slice();

		if (this.connDev && !items.some((d) => d.ip === this.connDev))
			items.push({ ip: this.connDev, name: null, count: 0 });

		const key = items.map((d) => d.ip + ' ' + d.name).join(',');

		if (sel.dataset.key === key)
			return;

		sel.dataset.key = key;
		sel.replaceChildren(
			E('option', { 'value': '' }, _('All devices')),
			...items.map((d) => E('option', { 'value': d.ip, 'selected': d.ip === this.connDev ? '' : null }, name(d)))
		);
		sel.value = this.connDev;
	}
});
