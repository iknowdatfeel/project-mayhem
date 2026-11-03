// System-log filters use the emitting process, not names in its message.
'use strict';
import * as fs from 'fs';

const logs = loadfile(ARGV[0])()['luci.mayhem'].logs;
const file = getenv('MAYHEM_TEST_LOG');
let fails = 0;
function expect(what, cond) {
	if (!cond) { print(`${what}\n`); fails++; }
}
function call(component, lines, level) {
	return logs.call({ args: { component: component, lines: lines ?? 300, level: level ?? 'all' } });
}
fs.writefile(file, join('\n', [
	'Tue Nov  3 17:00:01 2026 daemon.info mayhem[1]: service started',
	'Tue Nov  3 17:00:02 2026 daemon.info xray-run[2]: connection accepted',
	'Tue Nov  3 17:00:03 2026 daemon.warn xray[3]: connection failed',
	'Tue Nov  3 17:00:04 2026 daemon.info dnsmasq[4]: DNS ready',
	'Tue Nov  3 17:00:05 2026 daemon.info dnsmasq-dhcp[4]: lease renewed',
	'Tue Nov  3 17:00:06 2026 daemon.info dnsmasq-script[4]: script finished',
	'Tue Nov  3 17:00:07 2026 daemon.info other[5]: mayhem xray dnsmasq are mentioned here',
	'Tue Nov  3 17:00:08 2026 daemon.info mayhem-helper[6]: unrelated tag'
]) + '\n');
let r = call('all');
expect('all: only known emitters', !r.error && length(r.lines) == 6);
r = call('xray');
expect('xray: both procd wrapper and native tag', length(r.lines ?? []) == 2 && index(r.lines[0], 'xray-run[2]:') >= 0 && index(r.lines[1], 'xray[3]:') >= 0);
r = call('mayhem');
expect('mayhem: exact tag, no mentions or prefix matches', length(r.lines ?? []) == 1 && index(r.lines[0], 'mayhem[1]:') >= 0);
r = call('dnsmasq');
expect('dnsmasq: include service subcomponents', length(r.lines ?? []) == 3);
r = call('all', 2);
expect('limit: latest matching lines in chronological order', length(r.lines ?? []) == 2 && index(r.lines[0], 'dnsmasq-dhcp') >= 0 && index(r.lines[1], 'dnsmasq-script') >= 0);
fs.writefile(file, join('\n', [
	'Tue Nov  3 18:00:01 2026 daemon.warning mayhem[1]: warning',
	'Tue Nov  3 18:00:02 2026 daemon.err dnsmasq[2]: error',
	'Tue Nov  3 18:00:03 2026 daemon.info xray-run[3]: 2026/11/03 18:00:03.123456 [Error] real error',
	'Tue Nov  3 18:00:04 2026 daemon.err xray-run[3]: 2026/11/03 18:00:04.123456 [Debug] debug on stderr',
	'Tue Nov  3 18:00:05 2026 daemon.info mayhem[1]: ordinary info mentioning [Error]',
	'Tue Nov  3 18:00:06 2026 daemon.notice dnsmasq[2]: notice'
]) + '\n');
r = call('all', 300, 'warning');
expect('warning includes errors and excludes info/debug/notice', length(r.lines ?? []) == 3);
r = call('xray', 300, 'error');
expect('Xray severity overrides procd priority in both directions', length(r.lines ?? []) == 1 && index(r.lines[0], '[Error]') >= 0);
r = call('all', 1, 'error');
expect('severity filter runs before the line limit', length(r.lines ?? []) == 1 && index(r.lines[0], '[Error]') >= 0);
r = call('all', 300, 'info');
expect('info includes notice and more severe levels', length(r.lines ?? []) == 5);
r = call('all', 300, 'debug');
expect('debug includes every known severity', length(r.lines ?? []) == 6);
r = call('all', 300, 'invalid');
expect('invalid severity is an error', r.error != null);
fs.writefile(file, '');
r = call('all');
expect('empty log: successful empty result', !r.error && length(r.lines ?? []) == 0);
fs.writefile(file + '.fail', '');
r = call('all');
expect('logread failure is an error, not an empty log', r.error && r.lines == null);
exit(fails ? 1 : 0);
