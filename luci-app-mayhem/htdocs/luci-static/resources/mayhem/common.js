'use strict';
'require baseclass';
'require dom';

// Shared look of the Mayhem pages: bordered boxes, status colors and small
// line icons. Colors come from the theme where it defines them (bootstrap),
// with plain fallbacks for other themes.

const CSS = `
.mh-page { width:100%; --mh-cols:4; }
@media (max-width: 900px) { .mh-page { --mh-cols:2; } }
.mh-box { border:2px solid var(--background-color-low, lightgray); border-radius:4px; padding:10px; }
.mh-box--ok { border-color:var(--success-color-medium, green); }
.mh-box--warn { border-color:var(--warn-color-medium, orange); }
.mh-box--fail { border-color:var(--error-color-medium, red); }
.mh-box--busy { border-color:var(--primary-color-high, dodgerblue); }
.mh-grid { display:grid; grid-template-columns:repeat(var(--mh-cols), 1fr); grid-gap:10px; }
.mh-stack { display:grid; grid-template-columns:1fr; grid-row-gap:10px; }
.mh-title { font-weight:700; color:var(--text-color-high, inherit); }
.mh-muted { color:var(--text-color-medium, #888); }
.mh-small { font-size:90%; }
.mh-ok { color:var(--success-color-medium, green); }
.mh-warn { color:var(--warn-color-medium, orange); }
.mh-fail { color:var(--error-color-medium, red); }
.mh-busy { color:var(--primary-color-high, dodgerblue); }
.mh-icon { width:20px; height:20px; flex:0 0 auto; }
.mh-icon--small { width:16px; height:16px; }
.mh-spin { animation:mh-spin 1s linear infinite; }
@keyframes mh-spin { to { transform:rotate(360deg); } }
.mh-btn { display:inline-flex; align-items:center; justify-content:center; gap:6px; }
.mh-btn .mh-icon { width:16px; height:16px; }
.cbi-map-tabbed > .cbi-section > h3:first-child { display:none; }
.mh-actions { width:1%; white-space:nowrap; }
.mh-actions > div { display:flex; flex-wrap:nowrap; gap:4px; justify-content:flex-end; }
.mh-actions > div > .btn { flex:0 0 auto; margin:0; }
.mh-note { display:flex; flex-wrap:wrap; align-items:center; gap:6px 10px; }
.mh-note > .btn { margin:0; }
.mh-ip { display:inline-flex; align-items:center; gap:4px; }
.mh-ip-eye { margin:0 !important; padding:0 4px !important; min-width:0; line-height:1; border:0; background:none; box-shadow:none; vertical-align:middle; }
.mh-ip-eye .mh-icon { width:14px; height:14px; }
.mh-dns-dynlist > .item { cursor:grab; }
.mh-dns-dynlist > .item > span { pointer-events:none; }
/* Active connections: wide enough for the table, the table scrolls inside. */
.modal.mh-conns-modal { max-width:min(1100px, 96vw); width:96vw; }
#mh-conns { max-height:65vh; overflow:auto; }
.mh-conns .td { white-space:nowrap; }
.mh-conns .td:nth-child(2) { white-space:normal; word-break:break-all; }
/* Tables of keys and tunnels: on a narrow screen every row is a card, each cell
   with the name of its column, the buttons in one line at the bottom. */
@media (max-width: 800px) {
.mh-rtable, .mh-rtable tbody { display:block; width:100%; }
.mh-rtable .tr.table-titles { display:none !important; }
.mh-rtable .tr { display:block; padding:8px 0; border-bottom:1px solid var(--border-color-low, #ddd); }
.mh-rtable .td { display:flex; justify-content:space-between; align-items:center; gap:10px; padding:3px 0; border:0; width:auto; max-width:none; white-space:normal; text-align:right; }
.mh-rtable .td[data-title]::before { content:attr(data-title); color:var(--text-color-medium, #888); text-align:left; flex:0 0 auto; }
.mh-rtable .td.mh-actions { width:auto; justify-content:flex-end; padding-top:6px; }
.mh-rtable .td.mh-actions > div { flex-wrap:wrap; }
}
`;

// A call to the router that drops before its answer (the browser reports
// "XHR request aborted by browser": the router closed the connection while it
// was busy) is sent again, up to three times, when everything in it only reads.
// Calls that change something are never repeated: the first one may have
// gone through. Every page of Mayhem loads this module, so it covers them all.
// The usual cause is a kept-alive connection that uhttpd closes after a few
// idle seconds just as the browser sends the next call over it.
const READ_ONLY = {
	'uci': [ 'get', 'state', 'changes', 'configs' ],
	'luci-rpc': true,
	'luci': [ 'getVersion', 'getFeatures', 'getInitList', 'getLocaltime', 'getTimezones', 'getMountPoints', 'getRealtimeStats',
		'getConntrackList', 'getProcessList', 'getUSBDevices', 'getSwconfigFeatures', 'getSwconfigPortState', 'getBlockDevices',
		'getCoreInfo', 'getConntrackHelpers', 'getDUIDHints', 'getLEDs' ],
	'network.interface': [ 'dump', 'status' ],
	'network.device': [ 'status' ],
	'network.wireless': [ 'status' ],
	'network': [ 'get_proto_handlers' ],
	'iwinfo': true,
	'session': [ 'access', 'get' ],
	'rc': [ 'list' ],
	'service': [ 'list' ],
	'system': [ 'board', 'info' ],
	'file': [ 'read', 'list', 'stat' ],
	'luci.mayhem': [ 'dashboard', 'status', 'geo', 'sysinfo', 'logs', 'tunnel_info', 'tunnel_get', 'parse_link',
		'probe', 'exit_info', 'diagnose', 'components', 'backup_export' ]
};

function readOnly(data) {
	const calls = Array.isArray(data) ? data : [ data ];

	return calls.length > 0 && calls.every((c) => {
		const p = (c && c.method === 'call' && Array.isArray(c.params)) ? c.params : null;
		const allowed = p ? READ_ONLY[p[1]] : null;

		return allowed === true || (Array.isArray(allowed) && allowed.indexOf(p[2]) >= 0);
	});
}

(function() {
	const R = L.Request;

	if (!R || R.mhRetry)
		return;

	const post = R.post;

	// A connection to the router can be gone for a few seconds (seen on a
	// router: 2-4 s when the computer's Wi-Fi reconnects), so the calls are
	// repeated over about six seconds.
	const WAITS = [ 500, 1000, 2000, 3000 ];

	R.mhRetry = true;
	R.post = function(url, data, options) {
		const args = arguments;
		const again = (n) => post.apply(R, args).catch((e) => {
			if (n < WAITS.length && /aborted by browser/.test(String(e && e.message)) && /\/ubus\//.test(String(url)) && readOnly(data))
				return new Promise((res) => window.setTimeout(res, WAITS[n])).then(() => again(n + 1));

			throw e;
		});

		return again(0);
	};
})();

// Line icons on a 24x24 grid: [ circles [cx, cy, r], paths ].
const ICONS = {
	check: [ [], [ 'M20 6 9 17l-5-5' ] ],
	x: [ [], [ 'M18 6 6 18', 'M6 6l12 12' ] ],
	alert: [ [], [ 'M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z', 'M12 9v4', 'M12 17h.01' ] ],
	'circle-check': [ [ [ 12, 12, 10 ] ], [ 'm8.5 12 2.5 2.5 4.5-5' ] ],
	'circle-x': [ [ [ 12, 12, 10 ] ], [ 'm15 9-6 6', 'm9 9 6 6' ] ],
	'circle-alert': [ [ [ 12, 12, 10 ] ], [ 'M12 8v4', 'M12 16h.01' ] ],
	'circle-idle': [ [ [ 12, 12, 10 ] ], [ 'M8 12h8' ] ],
	loader: [ [], [ 'M21 12a9 9 0 1 1-6.2-8.6' ] ],
	search: [ [ [ 11, 11, 7 ] ], [ 'm20 20-4-4' ] ],
	restart: [ [], [ 'M3 12a9 9 0 1 0 3-6.7L3 8', 'M3 3v5h5' ] ],
	stop: [ [ [ 12, 12, 10 ] ], [ 'M9 9h6v6H9z' ] ],
	play: [ [ [ 12, 12, 10 ] ], [ 'm10 8 6 4-6 4V8Z' ] ],
	pause: [ [], [ 'M8 5v14', 'M16 5v14' ] ],
	logs: [ [], [ 'M4 6h16', 'M4 12h10', 'M4 18h13' ] ],
	copy: [ [], [ 'M8 8h12v12H8z', 'M16 8V4H4v12h4' ] ],
	zap: [ [], [ 'M13 2 4 14h7l-1 8 9-12h-7l1-8Z' ] ],
	activity: [ [], [ 'M22 12h-4l-3 9L9 3l-3 9H2' ] ],
	refresh: [ [], [ 'M21 12a9 9 0 0 1-15 6.7L3 16', 'M3 12a9 9 0 0 1 15-6.7L21 8', 'M21 3v5h-5', 'M3 21v-5h5' ] ],
	download: [ [], [ 'M12 3v12', 'm7 10 5 5 5-5', 'M5 21h14' ] ],
	upload: [ [], [ 'M12 15V3', 'm7 8 5-5 5 5', 'M5 21h14' ] ],
	archive: [ [], [ 'M3 4h18v4H3z', 'M5 8v12h14V8', 'M10 12h4' ] ],
	plus: [ [], [ 'M12 5v14', 'M5 12h14' ] ],
	route: [ [ [ 6, 19, 3 ], [ 18, 5, 3 ] ], [ 'M9 19h8.5a3.5 3.5 0 0 0 0-7h-11a3.5 3.5 0 0 1 0-7H15' ] ],
	settings: [ [ [ 12, 12, 3 ] ], [ 'M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1Z' ] ],
	package: [ [], [ 'm7.5 4.3 9 5.2', 'M21 8 12 3 3 8v8l9 5 9-5V8Z', 'M3.3 7 12 12l8.7-5', 'M12 22V12' ] ],
	pencil: [ [], [ 'M17 3a2.8 2.8 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z' ] ],
	trash: [ [], [ 'M3 6h18', 'M8 6V4h8v2', 'M19 6l-1 14H6L5 6', 'M10 11v6', 'M14 11v6' ] ],
	eye: [ [ [ 12, 12, 3 ] ], [ 'M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z' ] ],
	'eye-off': [ [], [ 'M10.7 5.1A10 10 0 0 1 12 5c6.5 0 10 7 10 7a17 17 0 0 1-2.2 3.2', 'M6.6 6.6A17 17 0 0 0 2 12s3.5 7 10 7a9.7 9.7 0 0 0 5.4-1.6', 'M9.9 9.9a3 3 0 0 0 4.2 4.2', 'M2 2l20 20' ] ]
};

const SVG = 'http://www.w3.org/2000/svg';

function icon(name, small) {
	const def = ICONS[name] || ICONS.x;
	const svg = document.createElementNS(SVG, 'svg');

	svg.setAttribute('viewBox', '0 0 24 24');
	svg.setAttribute('fill', 'none');
	svg.setAttribute('stroke', 'currentColor');
	svg.setAttribute('stroke-width', '2');
	svg.setAttribute('stroke-linecap', 'round');
	svg.setAttribute('stroke-linejoin', 'round');
	svg.setAttribute('aria-hidden', 'true');
	svg.setAttribute('class', 'mh-icon' + (small ? ' mh-icon--small' : '') + (name === 'loader' ? ' mh-spin' : ''));

	for (const c of def[0]) {
		const el = document.createElementNS(SVG, 'circle');

		el.setAttribute('cx', c[0]);
		el.setAttribute('cy', c[1]);
		el.setAttribute('r', c[2]);
		svg.appendChild(el);
	}

	for (const d of def[1]) {
		const el = document.createElementNS(SVG, 'path');

		el.setAttribute('d', d);
		svg.appendChild(el);
	}

	return svg;
}

function bytes(n) {
	if (n == null)
		return '—';

	const u = [ _('B'), _('KB'), _('MB'), _('GB'), _('TB') ];
	let i = 0;

	while (n >= 1024 && i < u.length - 1) {
		n /= 1024;
		i++;
	}

	return (i ? n.toFixed(n < 10 ? 1 : 0) : Math.round(n)) + ' ' + u[i];
}

function ago(ts, now) {
	if (!ts)
		return _('never');

	const s = Math.max(0, now - ts);

	if (s < 90)
		return _('just now');

	if (s < 5400)
		return _('%d min ago').format(Math.round(s / 60));

	if (s < 129600)
		return _('%d h ago').format(Math.round(s / 3600));

	return _('%d d ago').format(Math.round(s / 86400));
}

// The section that carries the main traffic and the server it uses now, from
// the dashboard data. A section without servers of its own uses the server
// list ("pool"); the server list is the main section by default.
function mainServer(d) {
	const secs = (d && d.sections) || [];
	let sec = secs.find((s) => s.name === d.default_section) || null;

	if (sec && sec.pool)
		sec = secs.find((s) => s.name === 'pool') || sec;

	const node = sec ? (sec.nodes || []).find((n) => n.tag === sec.active) : null;

	return { section: sec, node: node || null };
}

// "Server name" or the section name when it has no servers to name.
function mainServerText(d) {
	const m = mainServer(d);

	if (m.node)
		return m.node.name;

	return (m.section && m.section.name !== 'pool') ? m.section.name : null;
}

// IP addresses are hidden by default wherever Mayhem shows them (the external
// address, diagnostics, logs): an eye next to one shows them all, and the
// choice is kept in the browser. A hidden IPv4 address keeps its first
// number (185.*.*.*), an IPv6 one its first group (2a01:****).
const IP4_RE = /\b(\d{1,3})\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/g;
const IP6_RE = /\b([0-9a-f]{1,4}):(?:[0-9a-f]{0,4}:){1,6}[0-9a-f]{0,4}\b/gi;
const IP_KEY = 'mayhem-show-ip';

function ipShown() {
	try {
		return window.localStorage.getItem(IP_KEY) === '1';
	}
	catch (e) {
		return false;
	}
}

function maskIps(text) {
	return String(text == null ? '' : text)
		.replace(IP4_RE, (m, a) => (/^(127|10|192|172)$/.test(a) && /^(127\.0\.0\.1|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(m)) ? m : a + '.*.*.*')
		.replace(IP6_RE, (m, a) => {
			const groups = m.split(':').length;

			// not a time (12:30:45), a MAC address or a loopback/link-local one
			if (groups < 4 || /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(m) || (groups < 8 && m.indexOf('::') < 0) || /^(::|fe80:)/i.test(m))
				return m;

			return a + ':****';
		});
}

// The text as shown now: masked unless IP addresses are shown.
function ipText(text) {
	return ipShown() ? String(text == null ? '' : text) : maskIps(text);
}

// Every element with data-mh-ip (its real text) follows the choice.
function ipRefresh() {
	document.querySelectorAll('[data-mh-ip]').forEach((el) => {
		el.textContent = ipText(el.getAttribute('data-mh-ip'));
	});

	document.querySelectorAll('.mh-ip-eye').forEach((b) => {
		dom.content(b, icon(ipShown() ? 'eye-off' : 'eye', true));
		b.title = ipShown() ? _('Hide IP addresses') : _('Show IP addresses');
	});

	document.dispatchEvent(new CustomEvent('mh-ip-change'));
}

function ipToggle(ev) {
	if (ev)
		ev.preventDefault();

	try {
		window.localStorage.setItem(IP_KEY, ipShown() ? '0' : '1');
	}
	catch (e) {}

	ipRefresh();
}

// The eye button that shows or hides IP addresses everywhere.
function ipEye() {
	return E('button', {
		'class': 'btn mh-ip-eye', 'type': 'button',
		'title': ipShown() ? _('Hide IP addresses') : _('Show IP addresses'),
		'click': ipToggle
	}, icon(ipShown() ? 'eye-off' : 'eye', true));
}

// Text with IP addresses, hidden by default, and the eye next to it.
function ipSpan(text, eye) {
	const span = E('span', { 'data-mh-ip': String(text == null ? '' : text) }, ipText(text));

	return eye === false ? span : E('span', { 'class': 'mh-ip' }, [ span, ipEye() ]);
}

return baseclass.extend({
	icon: icon,
	maskIps: maskIps,
	ipText: ipText,
	ipShown: ipShown,
	ipEye: ipEye,
	ipSpan: ipSpan,
	bytes: bytes,
	ago: ago,
	mainServer: mainServer,
	mainServerText: mainServerText,

	style() {
		return E('style', CSS);
	},

	// A button with an icon; with `busy` it spins and is disabled.
	button(opts) {
		return E('button', {
			'class': 'btn mh-btn ' + (opts.cls || 'cbi-button'),
			'disabled': (opts.busy || opts.disabled) ? '' : null,
			'click': opts.click
		}, [ icon(opts.busy ? 'loader' : opts.icon), E('span', opts.text) ]);
	}
});
