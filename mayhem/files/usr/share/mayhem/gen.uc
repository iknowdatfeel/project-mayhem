#!/usr/bin/ucode
// Mayhem: configuration generator.
//
//   gen.uc [--model FILE] [--out DIR] [--check] [--print]
//
// Reads /etc/config/mayhem (or a JSON model with --model), then writes
// xray.json, nft.conf, dnsmasq.conf, env and status.json into DIR
// (/var/run/mayhem by default). --check writes nothing and prints the status.
// Exit code 1 means the configuration has errors and must not be started.

'use strict';

import * as fs from 'fs';
import { build } from 'mayhem.build';
import { RUN_DIR } from 'mayhem.const';

const opts = { out: RUN_DIR, model: null, check: false, print: false };

for (let i = 0; i < length(ARGV); i++) {
	switch (ARGV[i]) {
	case '--model': opts.model = ARGV[++i]; break;
	case '--out': opts.out = ARGV[++i]; break;
	case '--check': opts.check = true; break;
	case '--print': opts.print = true; break;
	default:
		warn(`unknown argument "${ARGV[i]}"\n`);
		exit(2);
	}
}

let model;

try {
	if (opts.model)
		model = json(fs.readfile(opts.model) ?? '');
	else
		model = require('mayhem.model').load_model();
}
catch (e) {
	warn(`cannot load configuration: ${e.message}\n`);
	exit(1);
}

const res = build(model);
const status = {
	ok: res.ok,
	generated: time(),
	mode: res.mode,
	ipv6: res.ipv6,
	memlimit_mib: res.memlimit_mib,
	...res.status
};

function put(name, data) {
	const path = `${opts.out}/${name}`;
	const tmp = `${path}.tmp`;

	if (fs.writefile(tmp, data) == null || !fs.rename(tmp, path)) {
		warn(`cannot write ${path}: ${fs.error()}\n`);
		exit(1);
	}
}

if (opts.check) {
	print(sprintf('%.J\n', status));
	exit(res.ok ? 0 : 1);
}

if (opts.print) {
	print(sprintf('%.J\n', res.xray));
	exit(res.ok ? 0 : 1);
}

fs.mkdir(opts.out, 0700);

put('status.json', sprintf('%.J\n', status));

if (!res.ok) {
	for (let e in res.status.errors)
		warn(`mayhem: ${e}\n`);

	exit(1);
}

put('xray.json', sprintf('%.J\n', res.xray));
put('nft.conf', res.nft);
put('dnsmasq.conf', res.dnsmasq);
put('env', `GOMEMLIMIT=${res.memlimit_mib}MiB\nMAYHEM_IPV6=${res.ipv6 ? 1 : 0}\n`);
put('nodes.json', sprintf('%J\n', res.state));
put('overrides', length(res.overrides) ? join('\n', res.overrides) + '\n' : '');

for (let w in res.status.warnings)
	warn(`mayhem: warning: ${w}\n`);

exit(0);
