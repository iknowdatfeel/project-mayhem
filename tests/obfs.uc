// WireGuard obfuscation through the rpcd backend: Phobos (wg-obfuscator) and
// fake TCP (phantun) set in the tunnel's dialog. The peer's endpoint goes to
// the local obfuscator and back, the .conf keeps showing the real one, fake TCP
// lowers the MTU and adds its firewall zone, renaming and deleting the tunnel
// take the obfuscation along. Needs MAYHEM_UCI_DIR with writable network,
// firewall and mayhem configs and MAYHEM_WG_OBFUSCATOR / MAYHEM_PHANTUN set to
// executables. Prints what went wrong; no output means all is well.
//   ucode tests/obfs.uc PLUGIN
'use strict';

const plugin = loadfile(ARGV[0])()['luci.mayhem'];
const call = (m, args) => plugin[m].call({ args: args });
const dir = getenv('MAYHEM_UCI_DIR');
let fails = 0;

function expect(what, cond) {
	if (!cond) {
		print(`${what}\n`);
		fails++;
	}
}

function cursor() {
	const c = require('uci').cursor(dir);

	c.load('network');
	c.load('firewall');
	c.load('mayhem');

	return c;
}

function peer(c, iface) {
	let p = null;

	c.foreach('network', `amneziawg_${iface}`, (x) => { p ??= x; });

	return p;
}

function zone(c) {
	let z = false;

	c.foreach('firewall', 'zone', (x) => { if (x.name == 'mayhem_ft') z = true; });

	return z;
}

let g = call('tunnel_get', { iface: 'awg0' });

expect(`get: ${g.error}`, g.ok === true && g.obfs == null && g.installed?.phobos === true);

// Phobos: the endpoint goes to the obfuscator, the MTU leaves room for
// the masking
let r = call('tunnel_set', { iface: 'awg0', conf: g.conf, obfs: 'phobos', obfs_port: 13255, obfs_key: 's3cret', obfs_masking: 'STUN' });
let c = cursor();
let p = peer(c, 'awg0');

expect(`phobos: ${r.error}`, r.ok === true);
expect(`phobos: endpoint ${p?.endpoint_host}:${p?.endpoint_port}`, p?.endpoint_host == '127.0.0.1' && p?.endpoint_port == '41820');
expect('phobos: record', c.get('mayhem', 'ob_awg0', 'kind') == 'phobos' && c.get('mayhem', 'ob_awg0', 'host') == '203.0.113.10' &&
	c.get('mayhem', 'ob_awg0', 'eport') == '51820' && c.get('mayhem', 'ob_awg0', 'port') == '13255' &&
	c.get('mayhem', 'ob_awg0', 'key') == 's3cret' && c.get('mayhem', 'ob_awg0', 'masking') == 'STUN');
expect(`phobos: MTU ${c.get('network', 'awg0', 'mtu')}`, c.get('network', 'awg0', 'mtu') == '1380' && !zone(c));

// the .conf still shows the server
g = call('tunnel_get', { iface: 'awg0' });
expect('get: the real endpoint in the .conf', index(g.conf, 'Endpoint = 203.0.113.10:51820') >= 0 && index(g.conf, '127.0.0.1') < 0);
expect('get: the obfuscation', g.obfs?.kind == 'phobos' && g.obfs?.port == 13255 && g.obfs?.key == 's3cret');

// fake TCP: MTU 1428, the firewall zone, the same local port
r = call('tunnel_set', { iface: 'awg0', conf: g.conf, obfs: 'faketcp', obfs_port: 4567 });
c = cursor();
p = peer(c, 'awg0');
expect(`faketcp: ${r.error}`, r.ok === true);
expect('faketcp: endpoint and MTU', p?.endpoint_port == '41820' && c.get('network', 'awg0', 'mtu') == '1428');
expect('faketcp: firewall zone', zone(c));
expect('faketcp: no key', c.get('mayhem', 'ob_awg0', 'kind') == 'faketcp' && c.get('mayhem', 'ob_awg0', 'key') == null);

// the .conf without obfs keeps it; its MTU is the tunnel's own
g = call('tunnel_get', { iface: 'awg0' });
expect('get: the MTU of the tunnel itself', index(g.conf, 'MTU') < 0);
r = call('tunnel_set', { iface: 'awg0', conf: g.conf });
c = cursor();
expect('kept without obfs', r.ok === true && c.get('mayhem', 'ob_awg0', 'kind') == 'faketcp' && peer(c, 'awg0')?.endpoint_host == '127.0.0.1');

// a bad key or port is refused, nothing changes
expect('phobos without a key is refused', call('tunnel_set', { iface: 'awg0', conf: g.conf, obfs: 'phobos', obfs_port: 1 }).error != null);
expect('port 0 is refused', call('tunnel_set', { iface: 'awg0', conf: g.conf, obfs: 'faketcp', obfs_port: 0 }).error != null);

// renaming takes it along
r = call('rename_interface', { from: 'awg0', to: 'awg9' });
c = cursor();
expect(`rename: ${r.error}`, r.ok === true && c.get('mayhem', 'ob_awg0') == null && c.get('mayhem', 'ob_awg9', 'iface') == 'awg9');

// off: endpoint and MTU back
g = call('tunnel_get', { iface: 'awg9' });
r = call('tunnel_set', { iface: 'awg9', conf: g.conf, obfs: 'none' });
c = cursor();
p = peer(c, 'awg9');
expect(`off: ${r.error}`, r.ok === true);
expect(`off: endpoint ${p?.endpoint_host}:${p?.endpoint_port}`, p?.endpoint_host == '203.0.113.10' && p?.endpoint_port == '51820');
expect('off: MTU and record', c.get('network', 'awg9', 'mtu') == null && c.get('mayhem', 'ob_awg9') == null);

// A .conf made for a local obfuscator (Phobos: "Endpoint = 127.0.0.1:13255"):
// 127.0.0.1 is not the server - without its address the obfuscation is
// refused, with it the obfuscator goes there.
g = call('tunnel_get', { iface: 'awg9' });
const local_conf = replace(g.conf, /Endpoint = [^\n]*/, 'Endpoint = 127.0.0.1:13255');
r = call('tunnel_set', { iface: 'awg9', conf: local_conf, obfs: 'phobos', obfs_port: 13255, obfs_key: 'k' });
expect(`local endpoint without a server: ${r.error}`, r.error != null && index(r.error, 'address') >= 0);
r = call('tunnel_set', { iface: 'awg9', conf: local_conf, obfs: 'phobos', obfs_port: 13255, obfs_key: 'k', obfs_host: '198.51.100.7' });
c = cursor();
p = peer(c, 'awg9');
expect(`local endpoint with a server: ${r.error}`, r.ok === true && c.get('mayhem', 'ob_awg9', 'host') == '198.51.100.7' &&
	p?.endpoint_host == '127.0.0.1' && p?.endpoint_port != '13255');
g = call('tunnel_get', { iface: 'awg9' });
expect(`get: the server, not 127.0.0.1: ${g.conf}`, index(g.conf, 'Endpoint = 198.51.100.7:13255') >= 0 && g.obfs?.host == '198.51.100.7');

// deleting the tunnel deletes its obfuscation
g = call('tunnel_get', { iface: 'awg9' });
call('tunnel_set', { iface: 'awg9', conf: g.conf, obfs: 'faketcp', obfs_port: 4567 });
r = call('tunnel_delete', { iface: 'awg9', mode: 'full' });
c = cursor();
expect(`delete: ${r.error}`, r.ok === true && c.get('mayhem', 'ob_awg9') == null);

exit(fails ? 1 : 0);
