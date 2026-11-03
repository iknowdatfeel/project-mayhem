#!/usr/bin/ucode
// Mayhem: why a reload restarts xray. Compares the config xray runs with
// (running.xray.key) with the new one (xray.key) and prints what differs:
//
//   config:dns,inbounds    parts of the config without the servers
//   servers                live.uc could not change the servers (it marks
//                          xray.key with a "restart" line)
//
// Nothing when they are the same. Used by mayhem_restart_reason (lib.sh).

'use strict';

import * as fs from 'fs';
import { RUN_DIR } from 'mayhem.const';

function first(name) {
	const text = fs.readfile(`${RUN_DIR}/${name}`) ?? '';
	const nl = index(text, '\n');

	return { json: nl < 0 ? text : substr(text, 0, nl), marked: nl >= 0 && index(substr(text, nl), 'restart ') >= 0 };
}

const now = first('xray.key'), was = first('running.xray.key');

if (now.marked) {
	print('servers\n');
	exit(0);
}

if (now.json == was.json)
	exit(0);

let a = {}, b = {};

try {
	a = json(was.json) ?? {};
	b = json(now.json) ?? {};
}
catch (e) {
	print('config\n');
	exit(0);
}

const parts = [];

for (let k in uniq([ ...keys(a), ...keys(b) ]))
	if (sprintf('%J', a[k]) != sprintf('%J', b[k]))
		push(parts, k);

print(`config:${join(',', parts)}\n`);
