// Tunnels through the rpcd backend: import of an AmneziaWG config into the
// server list (no routing section), renaming the interface with everything
// that refers to it. Needs MAYHEM_UCI_DIR with writable network, firewall and
// mayhem configs, and MAYHEM_NETIFD_PROTO_DIR with amneziawg.sh. Prints what
// went wrong; no output means all is well.
//   ucode tests/tunnels.uc PLUGIN
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

const conf = '[Interface]\nPrivateKey = cGFzc3Bhc3NwYXNzcGFzc3Bhc3NwYXNzcGFzc3Bhc3M=\nAddress = 10.8.1.2/32\nJc = 4\n\n' +
	'[Peer]\nPublicKey = Zm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyMTI=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 203.0.113.10:51820\n';

let r = call('awg_import', { name: 'awgnl', conf: conf, label: 'Нидерланды' });
let c = cursor();
const in_pool = (n) => c.get('mayhem', n, 'server') != '0' && c.get('network', n) == 'interface';
let peers = 0;

c.foreach('network', 'amneziawg_awgnl', () => peers++);
expect(`import: ${r.error}`, r.ok === true);
expect('import: interface and its peer', c.get('network', 'awgnl', 'proto') == 'amneziawg' && peers == 1);
expect('import: the tunnel is in the server list', in_pool('awgnl'));
expect('import: no routing section unless asked', r.section == null && c.get('mayhem', 'awgnl') == 'tunnel');
expect('import: the name of the tunnel', c.get('mayhem', 'awgnl', 'label') == 'Нидерланды');

// pinned on the dashboard by its interface
if (c.get('mayhem', 'pool') == null)
	c.set('mayhem', 'pool', 'pool');

c.set('mayhem', 'pool', 'override', 'awgnl');
c.commit('mayhem');

r = call('rename_interface', { from: 'awgnl', to: 'awg_nl' });
c = cursor();
peers = 0;
c.foreach('network', 'amneziawg_awg_nl', () => peers++);

let old_peers = 0;

c.foreach('network', 'amneziawg_awgnl', () => old_peers++);

let zone_ok = false;

c.foreach('firewall', 'zone', (z) => {
	if (z.name == 'mayhem')
		zone_ok = index(z.network ?? [], 'awg_nl') >= 0 && index(z.network ?? [], 'awgnl') < 0;
});

expect(`rename: ${r.error}`, r.ok === true);
expect('rename: interface moved with its options',
	c.get('network', 'awgnl') == null && c.get('network', 'awg_nl', 'proto') == 'amneziawg' &&
	c.get('network', 'awg_nl', 'private_key') == 'cGFzc3Bhc3NwYXNzcGFzc3Bhc3NwYXNzcGFzc3Bhc3M=');
expect('rename: peers moved', peers == 1 && old_peers == 0);
expect('rename: firewall zone', zone_ok);
expect('rename: the pinned server', in_pool('awg_nl') && !in_pool('awgnl') && c.get('mayhem', 'pool', 'override') == 'awg_nl');
expect('rename: the name of the tunnel stays', c.get('mayhem', 'awg_nl', 'label') == 'Нидерланды' && c.get('mayhem', 'awgnl') == null);
expect('rename to an existing interface is refused', call('rename_interface', { from: 'awg_nl', to: 'lan' }).error != null);
expect('rename to a bad name is refused', call('rename_interface', { from: 'awg_nl', to: 'Bad-Name' }).error != null);

exit(fails ? 1 : 0);
