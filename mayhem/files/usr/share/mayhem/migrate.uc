// Mayhem: brings an older configuration up to date. Run on install and
// update; does nothing when there is nothing to do.
//
// 0.12: the server list. Servers added by key and every subscription form one
// list whose active server is chosen on the dashboard; a proxy section
// without servers of its own uses it. The links and the server choice of the
// main proxy section move into the list, unless that section is special
// (a JSON outbound, tunnels as servers, name filters).

'use strict';

import { cursor } from 'uci';
import { readfile } from 'fs';
import { UCI_DIR, SUBS_DIR } from 'mayhem.const';

const c = cursor(UCI_DIR);

c.load('mayhem');

// 0.16: the old default check URL becomes the new one (plain HTTP, the
// checks vary less). A URL the user chose stays.
if (c.get('mayhem', 'settings', 'probe_url') == 'https://www.gstatic.com/generate_204') {
	c.set('mayhem', 'settings', 'probe_url', 'http://www.gstatic.com/generate_204');
	c.commit('mayhem');
	print('the server check URL is now plain HTTP\n');
}

// 0.22: one server list. A subscription is no longer a section of its own
// (its "select" is now the rule it picks a server by when the list's chain
// names it), and the main section is always the server list: a former main
// subscription or tunnel becomes the list's chain. "default_section" is left
// in place, unread, so going back to an older version keeps it.
if (c.get('mayhem', 'pool') && c.get('mayhem', 'pool', 'v') != '2') {
	const main = c.get('mayhem', 'settings', 'default_section') ?? '';
	const sub = match(main, /^sub_(.+)$/);

	c.foreach('mayhem', 'subscription', (s) => c.delete('mayhem', s['.name'], 'override'));

	if (c.get('mayhem', 'pool', 'select') == 'manual') {
		const pick = c.get('mayhem', 'pool', 'selected');

		c.set('mayhem', 'pool', 'select', 'auto');
		c.delete('mayhem', 'pool', 'selected');

		if (pick)
			c.set('mayhem', 'pool', 'override', pick);
	}

	if (sub && c.get('mayhem', sub[1]) == 'subscription') {
		c.set('mayhem', 'pool', 'select', 'fallback');
		c.set('mayhem', 'pool', 'chain', [ `@${sub[1]}` ]);
		c.delete('mayhem', 'pool', 'override');
		print(`the main subscription "${sub[1]}" is now the chain of the server list\n`);
	}
	else if (c.get('mayhem', main) == 'section' && c.get('mayhem', main, 'type') == 'interface' && c.get('mayhem', main, 'interface')) {
		c.set('mayhem', 'pool', 'select', 'fallback');
		c.set('mayhem', 'pool', 'chain', [ c.get('mayhem', main, 'interface') ]);
		c.delete('mayhem', 'pool', 'override');
		print(`the main tunnel "${main}" is now the chain of the server list\n`);
	}

	c.set('mayhem', 'pool', 'v', '2');
	c.commit('mayhem');
}

// 0.18.1: a server deleted from a subscription is kept with the subscription
// ("list hidden"), where its window can restore it. Before, it was a
// ^name$ entry in the name exclusions of the section.
const META = '[]\\.*+?(){}|^$';

// The alternatives of a name regexp, split at the "|" that is not escaped.
const alternatives = (re) => {
	const out = [];
	let cur = '';

	for (let i = 0; i < length(re); i++) {
		const ch = substr(re, i, 1);

		if (ch == '\\' && i + 1 < length(re)) {
			cur += ch + substr(re, ++i, 1);
		}
		else if (ch == '|') {
			push(out, cur);
			cur = '';
		}
		else
			cur += ch;
	}

	push(out, cur);

	return out;
};

// "^name$" with every special character escaped is a plain name; anything
// else is a real expression and null.
const literal = (alt) => {
	if (length(alt) < 3 || substr(alt, 0, 1) != '^' || substr(alt, -1) != '$')
		return null;

	const body = substr(alt, 1, length(alt) - 2);
	let name = '';

	for (let i = 0; i < length(body); i++) {
		const ch = substr(body, i, 1);

		if (ch == '\\') {
			if (i + 1 >= length(body) || index(META, substr(body, i + 1, 1)) < 0)
				return null;

			name += substr(body, ++i, 1);
		}
		else if (index(META, ch) >= 0)
			return null;
		else
			name += ch;
	}

	return name;
};

const as_array = (v) => v == null ? [] : (type(v) == 'array' ? v : [ v ]);
let moved = 0;

const move_exclusions = (sn) => {
	const exc = c.get('mayhem', sn, 'exclude');
	const subs = split(join(' ', as_array(c.get('mayhem', sn, 'subscription'))), /[ ,]+/);

	if (type(exc) != 'string' || exc == '' || !length(subs))
		return;

	const keep = [];

	for (let alt in alternatives(exc)) {
		const name = literal(alt);
		let found = false;

		if (name != null) {
			for (let sub in subs) {
				if (c.get('mayhem', sub) != 'subscription')
					continue;

				let cache = null;

				try {
					cache = json(readfile(`${SUBS_DIR}/${sub}.json`) ?? '');
				}
				catch (e) {
					cache = null;
				}

				if (!length(filter(cache?.nodes ?? [], (nd) => nd.name == name)))
					continue;

				const have = as_array(c.get('mayhem', sub, 'hidden'));

				if (index(have, name) < 0)
					push(have, name);

				c.set('mayhem', sub, 'hidden', have);
				found = true;
			}
		}

		if (found)
			moved++;
		else
			push(keep, alt);
	}

	if (length(keep))
		c.set('mayhem', sn, 'exclude', join('|', keep));
	else
		c.delete('mayhem', sn, 'exclude');
};

c.foreach('mayhem', 'section', (s) => move_exclusions(s['.name']));
c.foreach('mayhem', 'pool', (s) => move_exclusions(s['.name']));

if (moved) {
	c.commit('mayhem');
	print(`${moved} deleted subscription servers moved to their subscriptions\n`);
}

if (c.get('mayhem', 'pool')) {
	print('nothing to do\n');
	exit(0);
}

c.set('mayhem', 'pool', 'pool');

const is_proxy = (sn) => c.get('mayhem', sn) == 'section' && (c.get('mayhem', sn, 'type') ?? 'proxy') == 'proxy';
let main = c.get('mayhem', 'settings', 'default_section');

if (!main || !is_proxy(main)) {
	main = null;

	c.foreach('mayhem', 'section', (s) => {
		if (!main && (s.type ?? 'proxy') == 'proxy')
			main = s['.name'];
	});
}

const special = (sn) => c.get('mayhem', sn, 'proxy_type') == 'json' || c.get('mayhem', sn, 'iface_node') ||
	c.get('mayhem', sn, 'filter') || c.get('mayhem', sn, 'exclude');

if (main && !special(main)) {
	const links = c.get('mayhem', main, 'link');

	if (links)
		c.set('mayhem', 'pool', 'link', type(links) == 'array' ? links : [ links ]);

	for (let o in [ 'select', 'selected', 'override' ]) {
		const v = c.get('mayhem', main, o);

		if (v != null)
			c.set('mayhem', 'pool', o, v);

		c.delete('mayhem', main, o);
	}

	c.delete('mayhem', main, 'link');
	c.delete('mayhem', main, 'subscription');
	c.set('mayhem', main, 'servers', 'pool');

	if (c.get('mayhem', 'settings', 'default_section') == main)
		c.delete('mayhem', 'settings', 'default_section');

	print(`the servers of section "${main}" moved to the server list\n`);
}

if (!c.get('mayhem', 'pool', 'select'))
	c.set('mayhem', 'pool', 'select', 'auto');

c.commit('mayhem');
