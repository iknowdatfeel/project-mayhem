'use strict';
'require baseclass';
'require ui';

// Editing a server: every parameter of its key as a field, or the whole
// server as Xray JSON (an outbound). A key keeps its own format: vless://,
// trojan://, ss:// and the others are URLs, vmess:// is base64 JSON. JSON
// servers are kept as one line with the name in "tag".

// Query parameters of server keys, with choices where they have a fixed set.
const PARAMS = {
	type: [ 'tcp', 'raw', 'ws', 'grpc', 'xhttp', 'httpupgrade', 'kcp' ],
	security: [ 'none', 'tls', 'reality' ],
	encryption: null,
	flow: [ '', 'xtls-rprx-vision', 'xtls-rprx-vision-udp443' ],
	sni: null,
	fp: [ '', 'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', 'random', 'randomized' ],
	alpn: null,
	pbk: null,
	sid: null,
	spx: null,
	pqv: null,
	path: null,
	host: null,
	serviceName: null,
	authority: null,
	mode: [ '', 'gun', 'multi', 'auto', 'packet-up', 'stream-up', 'stream-one' ],
	extra: null,
	headerType: [ '', 'none', 'http', 'srtp', 'utp', 'wechat-video', 'dtls', 'wireguard' ],
	seed: null,
	ech: null,
	allowInsecure: [ '', '0', '1' ],
	insecure: [ '', '0', '1' ],
	obfs: [ '', 'salamander' ],
	'obfs-password': null,
	pinSHA256: null,
	plugin: null,
	publickey: null,
	presharedkey: null,
	address: null,
	reserved: null,
	mtu: null
};

const VMESS_KEYS = [ 'ps', 'add', 'port', 'id', 'aid', 'scy', 'net', 'type', 'host', 'path', 'tls', 'sni', 'alpn', 'fp' ];

const LABELS = {
	ps: _('Name'), add: _('Address'), port: _('Port'), id: 'UUID', aid: 'alterId', scy: _('Encryption'),
	net: _('Transport'), type: _('Header type'), host: 'Host', path: _('Path'), tls: _('Security'),
	sni: 'SNI', alpn: 'ALPN', fp: _('Fingerprint')
};

function b64decode(s) {
	s = s.replace(/-/g, '+').replace(/_/g, '/');

	while (s.length % 4)
		s += '=';

	return decodeURIComponent(Array.prototype.map.call(atob(s), (c) => '%' + ('00' + c.charCodeAt(0).toString(16)).slice(-2)).join(''));
}

function b64encode(s) {
	return btoa(encodeURIComponent(s).replace(/%([0-9A-F]{2})/g, (m, h) => String.fromCharCode(parseInt(h, 16))));
}

function dec(s) {
	try {
		return decodeURIComponent(s.replace(/\+/g, '%20'));
	}
	catch (e) {
		return s;
	}
}

// A key as parts: { scheme, user, host, port, params: [[k, v]], name } or,
// for vmess, { scheme: 'vmess', json }. null when it is not a URL key.
function parse(link) {
	let m = /^vmess:\/\/(.+)$/i.exec(link);

	if (m) {
		try {
			return { scheme: 'vmess', json: JSON.parse(b64decode(m[1].trim())) };
		}
		catch (e) {
			return null;
		}
	}

	m = /^([a-z][a-z0-9+.-]*):\/\/(?:([^@/?#]*)@)?(\[[^\]]+\]|[^:/?#]*)(?::(\d+))?(\/?)([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/i.exec(link);

	if (!m)
		return null;

	const r = {
		scheme: m[1].toLowerCase(), user: m[2] != null ? dec(m[2]) : '', host: m[3].replace(/^\[|\]$/g, ''),
		port: m[4] || '', slash: m[5] || '', rest: m[6] || '', params: [], name: m[8] != null ? dec(m[8]) : ''
	};

	(m[7] || '').split('&').filter((x) => x).forEach((kv) => {
		const i = kv.indexOf('=');

		r.params.push(i < 0 ? [ dec(kv), '' ] : [ dec(kv.slice(0, i)), dec(kv.slice(i + 1)) ]);
	});

	// ss: method:password, often in base64.
	if (r.scheme === 'ss' && r.user && r.user.indexOf(':') < 0) {
		try {
			const plain = b64decode(r.user);

			if (plain.indexOf(':') > 0)
				r.user = plain;
		}
		catch (e) {}
	}

	return r;
}

function enc(s) {
	return encodeURIComponent(s);
}

function build(r) {
	if (r.scheme === 'vmess')
		return 'vmess://' + b64encode(JSON.stringify(r.json));

	const host = r.host.indexOf(':') >= 0 ? '[' + r.host + ']' : r.host;
	let user = '';

	if (r.user !== '') {
		// ss: base64 of method:password works with every cipher.
		user = (r.scheme === 'ss' ? b64encode(r.user).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_') : enc(r.user)) + '@';
	}

	const q = r.params.filter((p) => p[0] !== '' && p[1] !== '').map((p) => enc(p[0]) + '=' + enc(p[1])).join('&');

	return r.scheme + '://' + user + host + (r.port ? ':' + r.port : '') + (r.rest ? '/' + r.rest : (r.slash || '')) +
		(q ? '?' + q : '') + (r.name ? '#' + enc(r.name) : '');
}

function userLabel(scheme) {
	switch (scheme) {
	case 'vless': return 'UUID';
	case 'ss': return _('Cipher:password');
	case 'socks': case 'socks5': case 'http': case 'https': return _('User:password');
	case 'wireguard': case 'wg': return _('Private key');
	default: return _('Password');
	}
}

function row(label, input) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, label),
		E('div', { 'class': 'cbi-value-field' }, input)
	]);
}

function field(value, choices) {
	if (choices) {
		const list = choices.indexOf(value) < 0 ? choices.concat([ value ]) : choices;

		return E('select', { 'class': 'cbi-input-select' },
			list.map((c) => E('option', { 'value': c, 'selected': c === value ? '' : null }, c === '' ? _('(not set)') : c)));
	}

	return E('input', { 'class': 'cbi-input-text', 'value': value || '' });
}

return baseclass.extend({
	parse: parse,
	build: build,

	// The dialog. save(newLink) applies the result; outbound is the server as
	// Xray JSON (from the router's parser), name its current name.
	dialog(link, outbound, name, save) {
		const r = link.charAt(0) === '{' ? null : parse(link);
		const msg = E('div', { 'class': 'mh-small' });
		const say = (m, cls) => {
			msg.className = 'mh-small ' + (cls || 'mh-muted');
			msg.textContent = m;
		};

		// --- parameters ---
		let collect = null;
		const form = E('div');

		if (r && r.scheme === 'vmess') {
			const inputs = {};
			const keys = VMESS_KEYS.concat(Object.keys(r.json).filter((k) => VMESS_KEYS.indexOf(k) < 0 && k !== 'v'));

			keys.forEach((k) => {
				inputs[k] = field(r.json[k] != null ? String(r.json[k]) : '');
				form.appendChild(row(LABELS[k] || k, inputs[k]));
			});

			collect = () => {
				const j = Object.assign({}, r.json);

				keys.forEach((k) => {
					const v = inputs[k].value.trim();

					if (v === '')
						delete j[k];
					else
						j[k] = v;
				});

				return build({ scheme: 'vmess', json: j });
			};
		}
		else if (r) {
			const core = {
				name: field(r.name), host: field(r.host), port: field(r.port), user: field(r.user)
			};
			const params = r.params.map((p) => [ p[0], field(p[1], PARAMS[p[0]] || null) ]);
			const plist = E('div');
			const drawParams = () => plist.replaceChildren(...params.map((p, i) => row(p[0], E('span', [
				p[1], ' ',
				E('button', { 'class': 'btn cbi-button-remove', 'title': _('Remove'), 'click': () => { params.splice(i, 1); drawParams(); } }, '✕')
			]))));
			const addSel = E('select', { 'class': 'cbi-input-select' }, [ E('option', { 'value': '' }, _('Add a parameter…')) ]
				.concat(Object.keys(PARAMS).map((k) => E('option', { 'value': k }, k)))
				.concat([ E('option', { 'value': '*' }, _('Other…')) ]));

			addSel.addEventListener('change', () => {
				let k = addSel.value;

				addSel.value = '';

				if (k === '*')
					k = (window.prompt(_('Parameter name')) || '').trim();

				if (!k || params.some((p) => p[0] === k))
					return;

				params.push([ k, field('', PARAMS[k] || null) ]);
				drawParams();
			});

			drawParams();

			form.appendChild(row(_('Protocol'), E('b', r.scheme)));
			form.appendChild(row(_('Name'), core.name));
			form.appendChild(row(_('Address'), core.host));
			form.appendChild(row(_('Port'), core.port));
			form.appendChild(row(userLabel(r.scheme), core.user));
			form.appendChild(plist);
			form.appendChild(row('', addSel));

			collect = () => build(Object.assign({}, r, {
				name: core.name.value.trim(), host: core.host.value.trim(), port: core.port.value.trim(), user: core.user.value,
				params: params.map((p) => [ p[0], p[1].value.trim() ])
			}));
		}

		// --- Xray JSON ---
		const j = Object.assign({ tag: name || '' }, outbound || {});
		const text = E('textarea', {
			'class': 'cbi-input-textarea', 'rows': 18, 'spellcheck': 'false',
			'style': 'width:100%;font-family:monospace;box-sizing:border-box'
		}, JSON.stringify(j, null, 2));

		const jsonValue = () => {
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

		const tabs = E('div');
		const panes = [];

		if (collect)
			panes.push([ _('Parameters'), E('div', [ form ]), collect ]);

		panes.push([ _('Xray JSON'), E('div', [
			E('p', { 'class': 'mh-muted mh-small' }, _('One Xray outbound; "tag" is the name of the server. Saving here keeps the server as JSON instead of a key.')),
			text
		]), jsonValue ]);

		let current = 0;
		const head = E('ul', { 'class': 'cbi-tabmenu' });
		const show = (i) => {
			current = i;
			head.replaceChildren(...panes.map((p, k) => E('li', { 'class': 'cbi-tab' + (k === i ? '' : '-disabled') },
				E('a', { 'href': '#', 'click': (ev) => { ev.preventDefault(); show(k); } }, p[0]))));
			tabs.replaceChildren(panes[i][1]);
		};

		show(0);

		ui.showModal(_('Edit server: %s').format(name || ''), [
			head,
			tabs,
			msg,
			E('div', { 'class': 'right', 'style': 'margin-top:1em' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'btn cbi-button-action', 'click': ui.createHandlerFn(this, () => {
					let out;

					try {
						out = panes[current][2]();
					}
					catch (e) {
						say(e.message, 'mh-fail');
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
	}
});
