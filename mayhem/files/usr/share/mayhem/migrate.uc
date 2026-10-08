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
import { UCI_DIR } from 'mayhem.const';

const c = cursor(UCI_DIR);

c.load('mayhem');

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
