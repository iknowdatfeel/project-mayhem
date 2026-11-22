// Mayhem: nodes.json and overrides, which several processes change.
//
// The generator writes them on every reload, fallback.uc when a chain moves
// on, the dashboard when a server is chosen (after xray took the choice, a
// second or so later). A writer that read the file before another one wrote
// it put the old content back (the servers of a reload gone until the next
// one), and the writers shared one temporary file. Now every change happens
// under one lock, to the file as it is then, through a temporary file of
// its own.

'use strict';

import * as fs from 'fs';
import * as util from 'mayhem.util';

// The lock is a directory; one left by a process that is gone, or held
// longer than STALE seconds, is taken over. A writer waits WAIT ms at most.
const STALE = 10;
const WAIT = 5000;

function locked(dir, fn) {
	const lock = `${dir}/state.lock`;

	// Taken over also from this very process (rpcd answers calls in one
	// process: a call that died while holding it), when held longer than
	// STALE seconds, or once WAIT ms are over; always only from the owner
	// seen (mayhem.util): another one that took it since keeps it.
	util.lock(lock, { wait_ms: WAIT, poll_ms: 20, stale_s: STALE, hold_s: STALE, take_own: true, take_late: true });

	let r;

	try {
		r = fn();
	}
	catch (e) {
		r = null;
		warn(`${e}\n`);
	}

	util.unlock(lock);

	return r;
}

// Writes files of `dir` ({ name: text }) as one change.
export function write(dir, files) {
	return locked(dir, () => {
		let ok = true;

		for (let name, data in files)
			ok = util.write_atomic(`${dir}/${name}`, data) && ok;

		return ok;
	});
};

// Changes nodes.json of `dir`: fn gets it as it is now and changes it in
// place; false from fn leaves the file as it is. Returns the new state, or
// null when there is none or it was not written.
export function update(dir, fn) {
	return locked(dir, () => {
		const state = util.read_json(`${dir}/nodes.json`);

		if (!state || fn(state) === false)
			return null;

		// flow_path.json follows, in the same lock (the generator reads it)
		if (!util.write_atomic(`${dir}/nodes.json`, sprintf('%J\n', state)))
			return null;

		if (state.flow_path != null)
			util.write_atomic(`${dir}/flow_path.json`, sprintf('%J\n', state.flow_path));

		return state;
	});
};

// The choices that go into xray at its next start (overrides, and
// running.overrides of the xray that runs): lines "<balancer> <tag>". set:
// { balancer: tag, or "" for no choice }.
export function set_overrides(dir, set) {
	return locked(dir, () => {
		for (let f in [ 'overrides', 'running.overrides' ]) {
			const lines = filter(split(fs.readfile(`${dir}/${f}`) ?? '', '\n'),
				(l) => l != '' && !exists(set, split(l, ' ')[0]));

			for (let b, t in set)
				if (t != '')
					push(lines, `${b} ${t}`);

			util.write_atomic(`${dir}/${f}`, length(lines) ? join('\n', lines) + '\n' : '');
		}

		return true;
	});
};
