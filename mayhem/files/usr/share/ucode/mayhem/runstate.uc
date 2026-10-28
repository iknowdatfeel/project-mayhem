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

// The lock is a directory; one left by a process that is gone, or held
// longer than STALE seconds, is taken over. A writer waits WAIT ms at most.
const STALE = 10;
const WAIT = 5000;

function me() {
	return split(fs.readfile('/proc/self/stat') ?? '', ' ')[0] ?? '';
}

function locked(dir, fn) {
	const lock = `${dir}/state.lock`;
	const pid = me();
	let waited = 0;

	while (!fs.mkdir(lock)) {
		const owner = trim(fs.readfile(`${lock}/pid`) ?? '');
		const st = fs.stat(lock);

		// The same process holds it (rpcd answers calls in one process): a
		// call that died while holding it.
		if (owner == pid || (owner != '' && !fs.access(`/proc/${owner}`)) || !st || time() - st.mtime > STALE || waited >= WAIT) {
			fs.unlink(`${lock}/pid`);
			fs.rmdir(lock);
			continue;
		}

		sleep(20);
		waited += 20;
	}

	fs.writefile(`${lock}/pid`, `${pid}\n`);

	let r;

	try {
		r = fn();
	}
	catch (e) {
		r = null;
		warn(`${e}\n`);
	}

	fs.unlink(`${lock}/pid`);
	fs.rmdir(lock);

	return r;
}

function put(path, data) {
	const tmp = `${path}.${me()}.tmp`;

	if (fs.writefile(tmp, data) == null)
		return false;

	if (!fs.rename(tmp, path)) {
		fs.unlink(tmp);
		return false;
	}

	return true;
}

function read_json(path) {
	try {
		return json(fs.readfile(path) ?? '');
	}
	catch (e) {
		return null;
	}
}

// Writes files of `dir` ({ name: text }) as one change.
export function write(dir, files) {
	return locked(dir, () => {
		let ok = true;

		for (let name, data in files)
			ok = put(`${dir}/${name}`, data) && ok;

		return ok;
	});
};

// Changes nodes.json of `dir`: fn gets it as it is now and changes it in
// place; false from fn leaves the file as it is. Returns the new state, or
// null when there is none or it was not written.
export function update(dir, fn) {
	return locked(dir, () => {
		const state = read_json(`${dir}/nodes.json`);

		if (!state || fn(state) === false)
			return null;

		return put(`${dir}/nodes.json`, sprintf('%J\n', state)) ? state : null;
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

			put(`${dir}/${f}`, length(lines) ? join('\n', lines) + '\n' : '');
		}

		return true;
	});
};
