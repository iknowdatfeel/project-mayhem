// nodes.json changed by several processes at once (mayhem.runstate): no
// change is lost, the file is never half written. Prints one line per failed
// expectation; no output means all is well.
//   ucode -L 'mayhem/files/usr/share/ucode/*.uc' tests/runstate.uc UCODE LIBPATH
// With the argument "worker DIR N" it is one of the writers.
'use strict';

import * as fs from 'fs';
import * as runstate from 'mayhem.runstate';

if (ARGV[0] == 'worker') {
	for (let i = 0; i < int(ARGV[2]); i++)
		runstate.update(ARGV[1], (st) => {
			st.count++;
			// a reader of the file meanwhile must see whole JSON
			st.pad = sprintf('%0100d', i);
		});

	exit(0);
}

const ucode = ARGV[0] ?? 'ucode';
const lib = ARGV[1];
const dir = trim(fs.popen('mktemp -d', 'r').read('all'));
let fails = 0;

function expect(what, cond, got) {
	if (!cond) {
		print(`${what}: ${got}\n`);
		fails++;
	}
}

fs.writefile(`${dir}/nodes.json`, '{ "count": 0, "sections": {} }\n');

const me = sourcepath();
const N = 4, EACH = 40;
let cmd = '';

for (let i = 0; i < N; i++)
	cmd += `${ucode} -L '${lib}' '${me}' worker '${dir}' ${EACH} & `;

// A reader at the same time.
cmd += `i=0; while [ $i -lt 200 ]; do cat '${dir}/nodes.json' > '${dir}/seen.$i' 2>/dev/null; i=$((i + 1)); done; wait`;
system(cmd);

const st = json(fs.readfile(`${dir}/nodes.json`));

expect('every change is there', st.count == N * EACH, st.count);

let broken = 0;

for (let f in fs.glob(`${dir}/seen.*`)) {
	try {
		json(fs.readfile(f));
	}
	catch (e) {
		broken++;
	}
}

expect('never half written', broken == 0, broken);
expect('no temporary files left', !length(fs.glob(`${dir}/*.tmp`)), join(' ', fs.glob(`${dir}/*.tmp`)));
expect('no lock left', !fs.access(`${dir}/state.lock`), 'state.lock');

// overrides: one balancer changed, the others kept, "" takes the choice away.
fs.writefile(`${dir}/overrides`, 'bal-a n-a-1\nbal-b n-b-1\n');
runstate.set_overrides(dir, { 'bal-a': 'n-a-2', 'bal-c': 'n-c-1' });
runstate.set_overrides(dir, { 'bal-b': '' });
expect('overrides', fs.readfile(`${dir}/overrides`) == 'bal-a n-a-2\nbal-c n-c-1\n', fs.readfile(`${dir}/overrides`));
expect('running.overrides too', fs.readfile(`${dir}/running.overrides`) == 'bal-a n-a-2\nbal-c n-c-1\n', fs.readfile(`${dir}/running.overrides`));

// A lock left by a process that is gone does not hold anyone up.
fs.mkdir(`${dir}/state.lock`);
fs.writefile(`${dir}/state.lock/pid`, '999999\n');
expect('a stale lock is taken over', runstate.update(dir, (st) => { st.count = 0; }) != null, 'not written');

system(`rm -rf '${dir}'`);
exit(fails ? 1 : 0);
