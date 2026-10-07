// Geo data and rule helpers.
//   geo.uc DIR    DIR holds geosite.dat and geoip.dat from tests/geo/mkdat.py
'use strict';

import * as fs from 'fs';
import { scan, geoip_cidrs, geosite_domains, resolve, wanted, HEAVY } from 'mayhem.geo';
import { norm_domain, norm_ip, split_list, list_key } from 'mayhem.rules';

const dir = ARGV[0];
let failed = 0, total = 0;

function check(what, got, want) {
	total++;

	const g = sprintf('%J', got), w = sprintf('%J', want);

	if (g != w) {
		failed++;
		print(`FAIL ${what}: expected ${w}, got ${g}\n`);
	}
}

// --- streaming scan and the trimmed copy ------------------------------------------

let out = fs.open(`${dir}/site-trim.dat`, 'w');
let r = scan(fs.open(`${dir}/geosite.dat`, 'r'), { YOUTUBE: true, GOV: true }, out);
out.close();

check('geosite categories', r.categories, { youtube: 4, gov: 1, heavy: HEAVY + 1, empty: 0 });
check('geosite copied', sort(r.copied), [ 'gov', 'youtube' ]);
check('geosite size', r.bytes, length(fs.readfile(`${dir}/geosite.dat`)));

// Reading through a small pipe exercises the chunk boundaries.
const p = fs.popen(`cat ${dir}/geosite.dat`, 'r');
r = scan(p, {}, null);
p.close();
check('geosite from a pipe', r.categories.heavy, HEAVY + 1);

const sites = geosite_domains(`${dir}/site-trim.dat`, [ 'youtube', 'gov', 'heavy' ]);
check('trimmed geosite', sites, {
	youtube: [ 'domain:youtube.test', 'full:www.yt.test', 'keyword:tubekw', 'regexp:^re[0-9]+\\.test$' ],
	gov: [ 'domain:gosuslugi.test' ]
});

out = fs.open(`${dir}/ip-trim.dat`, 'w');
r = scan(fs.open(`${dir}/geoip.dat`, 'r'), { RU: true, TELEGRAM: true }, out);
out.close();

check('geoip categories', r.categories, { ru: 2, telegram: 2, private: 2 });

const ips = geoip_cidrs(`${dir}/ip-trim.dat`, [ 'RU', 'telegram' ]);
check('geoip ru', ips.ru, { v4: [ '45.0.0.6/32' ], v6: [ '2001:db8:1:0:0:0:0:0/48' ], reverse: false });
check('geoip telegram', ips.telegram.v4, [ '45.0.0.7/32', '91.108.4.0/22' ]);

let bad = null;

try {
	scan(fs.open(`${dir}/broken.dat`, 'r') ?? die('no broken.dat'), {}, null);
}
catch (e) {
	bad = e.message;
}

check('truncated file is an error', bad != null, true);

// --- category resolution -------------------------------------------------------

const sources = [
	{ name: 'a', kind: 'geosite', enabled: true, index: { categories: { youtube: 4, gov: 1 }, copied: [ 'youtube' ] } },
	{ name: 'b', kind: 'geosite', enabled: true, index: { categories: { youtube: 9, extra: 3 }, copied: [] } },
	{ name: 'c', kind: 'geosite', enabled: true, index: null },
	{ name: 'ip', kind: 'geoip', enabled: true, index: { categories: { ru: 2 }, copied: [ 'ru' ] } },
	{ name: 'off', kind: 'geoip', enabled: false, index: null }
];

const res = (s) => {
	const x = norm_domain(s).geo ?? norm_ip(s).geo;
	const v = resolve(sources, x);

	return v.error ? 'error' : `${v.source}:${v.cat}:${v.state}`;
};

check('first source with the category', res('geosite:youtube'), 'a:youtube:ready');
check('known but not kept', res('geosite:gov'), 'a:gov:pending');
check('second source', res('geosite:extra'), 'b:extra:pending');
check('explicit source', res('geosite:b:youtube'), 'b:youtube:pending');
check('unknown goes to a source never downloaded', res('geosite:nothing'), 'c:nothing:pending');
check('geoip', res('geoip:RU'), 'ip:ru:ready');
check('disabled source', res('geoip:off:ru'), 'error');
check('wrong kind', res('geosite:ip:ru'), 'error');
check('attribute kept apart', norm_domain('geosite:google@ads').geo, { kind: 'geosite', source: null, cat: 'google', attr: '@ads', neg: false });
check('negated geoip', norm_ip('geoip:!ru').geo.neg, true);
check('ext is rejected', norm_domain('ext:x.dat:y').error != null, true);

check('wanted', wanted([
	{ '.name': 's1', domain: [ 'geosite:youtube', 'example.com', 'geosite:b:extra' ], ip: [ 'geoip:ru' ] },
	{ '.name': 's2', enabled: '0', domain: [ 'geosite:gov' ] }
], sources), { a: [ 'youtube' ], b: [ 'extra' ], c: [], ip: [ 'ru' ], off: [] });

// --- rule lists ----------------------------------------------------------------

check('list parsing', split_list('# comment\nexample.com\n  10.0.0.0/8 # office\n2001:db8::/32\nfull:a.test\n0.0.0.0 ads.test\nnot a rule\n\n'), {
	domains: [ 'example.com', 'full:a.test', 'ads.test' ],
	ips: [ '10.0.0.0/8', '2001:db8::/32' ],
	bad: 1
});
check('list key is stable', list_key('https://example.com/a.lst'), list_key('https://example.com/a.lst'));
check('list keys differ', list_key('https://example.com/a.lst') != list_key('https://example.com/b.lst'), true);

print(`geo: ${total - failed}/${total} ok\n`);
exit(failed ? 1 : 0);
