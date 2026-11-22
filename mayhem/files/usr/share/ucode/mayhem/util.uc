// Mayhem: small helpers every script and the rpcd plugin share: shell
// quoting, JSON files, writes through a temporary file, the system log,
// locks, the "a change is being applied" flag.

'use strict';

import * as fs from 'fs';

// A word for sh -c, quoted as a whole.
export function q(s) {
	return "'" + replace(`${s}`, /'/g, "'\\''") + "'";
};

// The pid of this process (its threads have none of their own here).
export function my_pid() {
	return fs.readlink('/proc/self') || split(fs.readfile('/proc/self/stat') ?? '', ' ')[0] || '';
};

// The parsed file, or null when there is none or it is not JSON.
export function read_json(path) {
	try {
		return json(fs.readfile(path) ?? '');
	}
	catch (e) {
		return null;
	}
};

// Writes `data` through a temporary file of this process and renames it:
// a reader sees the old file or the new one, never a half; two writers at
// once do not share a temporary file. false when it could not be written.
export function write_atomic(path, data) {
	const tmp = `${path}.${my_pid()}.tmp`;

	if (fs.writefile(tmp, data) == null)
		return false;

	if (!fs.rename(tmp, path)) {
		fs.unlink(tmp);
		return false;
	}

	return true;
};

export function write_json(path, v) {
	return write_atomic(path, sprintf('%J\n', v));
};

export function log(msg, level) {
	system(`logger -t mayhem -p daemon.${level ?? 'info'} -- ${q(msg)}`);
};

// A lock: a directory holding the pid of its owner. Taken over when it was
// left behind: its process is gone, or it has no pid for more than stale_s
// seconds (a lock just taken has none yet, between mkdir and the write of
// the pid). Removed only while it still names the owner seen: two waiters
// must not both take it, nor one take it from a process that took it since.
// opts:
//   wait_ms     how long to wait for a live owner (0: give up at once)
//   poll_ms     between tries while waiting (500)
//   stale_s     a lock without a pid older than this is left behind (10)
//   hold_s      a lock older than this is taken over whoever holds it
//   take_own    a lock of this very process is taken over (rpcd answers
//               every call in one process: a call that died holding it)
//   take_late   once wait_ms is over the lock is taken over, not given up
// true when taken.
export function lock(dir, opts) {
	const o = opts ?? {};
	const me = my_pid();
	const poll = o.poll_ms ?? 500;
	let waited = 0, gone = 0;

	for (;;) {
		if (fs.mkdir(dir, 0700)) {
			fs.writefile(`${dir}/pid`, `${me}\n`);
			return true;
		}

		const owner = trim(fs.readfile(`${dir}/pid`) ?? '');
		const st = fs.stat(dir);

		// gone meanwhile: try again; not there at all (no parent): give up
		if (!st) {
			if (++gone > 10)
				return false;

			continue;
		}

		const left = owner != '' ? !fs.access(`/proc/${owner}`) : time() - st.mtime > (o.stale_s ?? 10);
		const late = waited >= (o.wait_ms ?? 0);

		if (left || (o.take_own && owner == me) || (o.hold_s != null && time() - st.mtime > o.hold_s) || (o.take_late && late)) {
			if (trim(fs.readfile(`${dir}/pid`) ?? '') == owner) {
				fs.unlink(`${dir}/pid`);
				fs.rmdir(dir);
			}

			continue;
		}

		if (late)
			return false;

		sleep(poll);
		waited += poll;
	}
};

export function unlock(dir) {
	fs.unlink(`${dir}/pid`);
	fs.rmdir(dir);
};

// A change is being applied (applying.<pid> of the init script, the
// dashboard, a subscription): what runs is about to change. A file of a
// process that is gone, or older than 5 minutes, is removed.
export function is_applying(run_dir) {
	const now = time();
	let on = false;

	for (let f in fs.glob(`${run_dir}/applying.*`) ?? []) {
		const st = fs.stat(f);

		if (!st)
			continue;

		const m = match(f, /applying\.([0-9]+)$/);

		if ((m && !fs.access(`/proc/${m[1]}`)) || now - st.mtime >= 300) {
			fs.unlink(f);
			continue;
		}

		on = true;
	}

	return on;
};

// The TCP ports of `ports` something listens on (any address family), as
// mayhem_ports_listening of lib.sh tells them. MAYHEM_PROC_NET: the
// directory of tcp and tcp6 (the tests).
export function listening(ports) {
	const net = getenv('MAYHEM_PROC_NET') ?? '/proc/net';
	const want = {}, found = {};

	for (let p in ports)
		want[sprintf('%04X', int(p))] = int(p);

	for (let f in [ `${net}/tcp`, `${net}/tcp6` ]) {
		for (let line in split(fs.readfile(f) ?? '', '\n')) {
			const parts = split(trim(line), /[ \t]+/);

			if (length(parts) < 4 || uc(parts[3]) != '0A')
				continue;

			const m = match(parts[1], /:([0-9A-Fa-f]{4})$/);

			if (m && exists(want, uc(m[1])))
				found[want[uc(m[1])]] = true;
		}
	}

	return filter(ports, (p) => found[int(p)] == true);
};
