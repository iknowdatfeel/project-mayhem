// Mayhem: reads /etc/config/mayhem and runtime facts into the model consumed
// by mayhem.build. Only this module touches UCI and the live system.
// Loaded with require() so that tests without the uci module can skip it.

'use strict';

import { cursor } from 'uci';
import { readfile, access } from 'fs';
import { SUBS_DIR, UCI_DIR } from 'mayhem.const';

const RESOLV_FILES = [ '/tmp/resolv.conf.d/resolv.conf.auto', '/tmp/resolv.conf.auto' ];

function wan_dns() {
	const out = [];

	for (let f in RESOLV_FILES) {
		const data = readfile(f);

		if (!data)
			continue;

		for (let line in split(data, '\n')) {
			const m = match(line, /^[[:space:]]*nameserver[[:space:]]+([^[:space:]#%]+)/);

			if (m && index(out, m[1]) < 0)
				push(out, m[1]);
		}

		if (length(out))
			break;
	}

	return out;
}

function mem_total_kb() {
	const m = match(readfile('/proc/meminfo') ?? '', /MemTotal:[[:space:]]+([0-9]+)/);

	return m ? int(m[1]) : null;
}

function runtime() {
	return {
		wan_dns: wan_dns(),
		ipv6: access('/proc/net/if_inet6') == true,
		mem_total_kb: mem_total_kb()
	};
}

function load_model() {
	const c = cursor(UCI_DIR);

	c.load('mayhem');

	const sections = [];

	c.foreach('mayhem', 'section', (s) => {
		push(sections, s);
	});

	// Downloaded subscriptions, keyed by the subscription section name.
	const subscriptions = {};

	c.foreach('mayhem', 'subscription', (s) => {
		try {
			const cache = json(readfile(`${SUBS_DIR}/${s['.name']}.json`) ?? '');

			if (type(cache) == 'object')
				subscriptions[s['.name']] = cache;
		}
		catch (e) {
			// not downloaded yet
		}
	});

	return {
		subscriptions: subscriptions,
		settings: c.get_all('mayhem', 'settings') ?? {},
		dns: c.get_all('mayhem', 'dns') ?? {},
		sections: sections,
		runtime: runtime()
	};
}

return { load_model, runtime };
