// mayhem.util: the lock (taken, a live owner kept, one left behind taken
// over, one just taken without its pid yet left alone), the write through a
// temporary file, JSON files, the "applying" flag. Prints one line per
// failed expectation; no output means all is well.
//   ucode tests/util.uc DIR
'use strict';

import * as fs from 'fs';
import * as util from 'mayhem.util';

const dir = ARGV[0];
const L = `${dir}/x.lock`;
let fails = 0;

function expect(what, cond, got) {
	if (!cond) {
		print(`${what}: ${sprintf('%J', got)}\n`);
		fails++;
	}
}

fs.mkdir(dir);

expect('quoting', util.q("it's") == "'it'\\''s'", util.q("it's"));

// taken and let go
expect('a free lock is taken', util.lock(L) && trim(fs.readfile(`${L}/pid`)) == util.my_pid(), fs.readfile(`${L}/pid`));
util.unlock(L);
expect('let go', !fs.stat(L), fs.stat(L));

// a live owner (pid 1) keeps it, at once and after a wait
fs.mkdir(L);
fs.writefile(`${L}/pid`, '1\n');
expect('a live owner keeps it', !util.lock(L), null);

const t0 = clock(true)[0] * 1000 + clock(true)[1] / 1000000;

expect('a live owner keeps it while waited for', !util.lock(L, { wait_ms: 300, poll_ms: 100 }), null);

const t1 = clock(true)[0] * 1000 + clock(true)[1] / 1000000;

expect('waited about as long as asked', t1 - t0 >= 250 && t1 - t0 < 2000, t1 - t0);
expect('it still names its owner', trim(fs.readfile(`${L}/pid`)) == '1', fs.readfile(`${L}/pid`));
expect('take_late takes it after the wait', util.lock(L, { wait_ms: 100, poll_ms: 50, take_late: true }) &&
	trim(fs.readfile(`${L}/pid`)) == util.my_pid(), fs.readfile(`${L}/pid`));
util.unlock(L);

// left behind: a process that is gone
fs.mkdir(L);
fs.writefile(`${L}/pid`, '999999999\n');
expect('a lock of a process that is gone is taken over', util.lock(L), null);
util.unlock(L);

// no pid yet: just taken, left alone; older than stale_s: left behind
fs.mkdir(L);
expect('a lock just taken, no pid yet, is not taken', !util.lock(L), null);
system(`touch -d '-20 sec' '${L}'`);
expect('a lock without a pid for 20 s is taken over', util.lock(L), null);
util.unlock(L);

// this very process (rpcd): only with take_own
fs.mkdir(L);
fs.writefile(`${L}/pid`, `${util.my_pid()}\n`);
expect('a lock of this process is kept without take_own', !util.lock(L), null);
expect('take_own takes it', util.lock(L, { take_own: true }), null);
util.unlock(L);

// no parent directory: false, not a loop
expect('no parent directory: not taken', !util.lock(`${dir}/none/x.lock`), null);

// writes through a temporary file of this process
const f = `${dir}/a.json`;

expect('write_json', util.write_json(f, { a: 1 }) && util.read_json(f)?.a == 1, fs.readfile(f));
expect('no temporary file left', !length(filter(fs.lsdir(dir), (n) => match(n, /\.tmp$/))), fs.lsdir(dir));
expect('a write into a missing directory fails', !util.write_atomic(`${dir}/none/b`, 'x'), null);
fs.writefile(`${dir}/bad.json`, '{ broken');
expect('read_json of a broken file', util.read_json(`${dir}/bad.json`) == null && util.read_json(`${dir}/missing`) == null, null);

// applying.<pid>: a live process counts, a gone one is removed
const run = `${dir}/run`;

fs.mkdir(run);
expect('nothing applied', !util.is_applying(run), null);
fs.writefile(`${run}/applying.${util.my_pid()}`, '');
expect('a live change counts', util.is_applying(run), null);
fs.unlink(`${run}/applying.${util.my_pid()}`);
fs.writefile(`${run}/applying.999999999`, '');
expect('one of a process that is gone does not, and goes', !util.is_applying(run) && !fs.stat(`${run}/applying.999999999`), null);
fs.writefile(`${run}/applying.sub`, '');
system(`touch -d '-10 min' '${run}/applying.sub'`);
expect('one older than 5 minutes does not, and goes', !util.is_applying(run) && !fs.stat(`${run}/applying.sub`), null);

exit(fails ? 1 : 0);
