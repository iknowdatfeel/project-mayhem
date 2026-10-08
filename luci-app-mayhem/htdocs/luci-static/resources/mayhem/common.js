'use strict';
'require baseclass';

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
`;

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
	refresh: [ [], [ 'M21 12a9 9 0 0 1-15 6.7L3 16', 'M3 12a9 9 0 0 1 15-6.7L21 8', 'M21 3v5h-5', 'M3 21v-5h5' ] ],
	download: [ [], [ 'M12 3v12', 'm7 10 5 5 5-5', 'M5 21h14' ] ],
	upload: [ [], [ 'M12 15V3', 'm7 8 5-5 5 5', 'M5 21h14' ] ],
	archive: [ [], [ 'M3 4h18v4H3z', 'M5 8v12h14V8', 'M10 12h4' ] ]
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

	return (i ? n.toFixed(n < 10 ? 1 : 0) : n) + ' ' + u[i];
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

return baseclass.extend({
	icon: icon,
	bytes: bytes,
	ago: ago,

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
