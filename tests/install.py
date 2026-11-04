#!/usr/bin/env python3
"""Upgrade with DNS unavailable after package replacement; no host changes."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent


class DNSInstall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.t = Path(self.tmp.name)
        t = self.t
        (t / 'libexec').mkdir()
        (t / 'init.d').mkdir()
        (t / 'bin').mkdir()
        (t / 'openwrt_release').write_text('DISTRIB_ARCH=aarch64_cortex-a53\n')
        (t / 'const.sh').write_text('MAYHEM_POLICY_DNS_PORT=12754\n')
        (t / 'lib.sh').write_text('MAYHEM_VERSION=0.26.1\nmayhem_conflicts() { :; }\n')
        for service in ('mayhem', 'rpcd'):
            p = t / 'init.d' / service
            p.write_text('#!/bin/sh\nexit 0\n')
            p.chmod(0o755)
        cli = (ROOT / 'mayhem/files/usr/bin/mayhem').read_text()
        cli = cli.replace('/usr/share/mayhem/lib.sh', str(t / 'lib.sh'))
        cli = cli.replace('/usr/libexec/mayhem', str(t / 'libexec'))
        cli = cli.replace('/etc/openwrt_release', str(t / 'openwrt_release'))
        cli = cli.replace('/tmp/mayhem-dns-install', str(t / 'dns-install'))
        (t / 'cli').write_text(cli)
        shim = t / 'bin/mayhem'
        shim.write_text('''#!/bin/sh
case "$1" in
  dns-policy-install) exec sh "$STUB/cli" "$@" ;;
  *) exit 0 ;;
esac
''')
        shim.chmod(0o755)
        installer = (ROOT / 'install.sh').read_text()
        installer = installer.replace('main "$@"', '')
        for old, new in [('/usr/bin/mayhem', t / 'bin/mayhem'),
                         ('/usr/share/mayhem/const.sh', t / 'const.sh'),
                         ('/usr/share/mayhem/lib.sh', t / 'lib.sh'),
                         ('/etc/init.d', t / 'init.d'),
                         ('/etc/rc.d', t / 'rc.d'),
                         ('/etc/openwrt_release', t / 'openwrt_release'),
                         ('/tmp/mayhem-install', t / 'install'),
                         ('/tmp/luci-', t / 'luci-')]:
            installer = installer.replace(old, str(new))
        (t / 'installer').write_text(installer)
        with zipfile.ZipFile(t / 'engine.zip', 'w') as z:
            z.writestr('dns-policy', '#!/bin/sh\necho mayhem-dns-test\n')
        digest = hashlib.sha256((t / 'engine.zip').read_bytes()).hexdigest()
        (t / 'engine.zip.sha256').write_text(digest + '  engine.zip\n')
        base = 'https://example.invalid/releases/v0.26.1/'
        (t / 'release.json').write_text(json.dumps({'assets': [
            {'browser_download_url': base + 'mayhem-0.26.1.apk'},
            {'browser_download_url': base + 'mayhem-dns-linux-arm64-v8a.zip'},
        ]}))
        self.driver = '''
export STUB="$1"
. "$STUB/installer"
PKG=apk
check_system() { :; }
pkg_update() { :; }
check_deps() { :; }
check_tproxy() { :; }
check_digest() { return 0; }
fetch() {
    [ ! -f "$STUB/dns-off" ] || { echo 'DNS unavailable after upgrade' >&2; return 1; }
    case "$1" in
        *releases/latest) cat "$STUB/release.json" ;;
        *.zip.sha256) cp "$STUB/engine.zip.sha256" "$2" ;;
        *.zip) cp "$STUB/engine.zip" "$2" ;;
        *.apk) echo package > "$2" ;;
        *) return 1 ;;
    esac
}
install_packages() { touch "$STUB/dns-off" "$STUB/packages-installed"; }
main
'''

    def run_upgrade(self):
        return subprocess.run(['sh', '-c', self.driver, 'test', str(self.t)],
                              capture_output=True, text=True)

    def test_offline_engine_install_after_packages(self):
        r = self.run_upgrade()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue((self.t / 'packages-installed').exists())
        self.assertEqual(subprocess.check_output([str(self.t / 'libexec/dns-policy'), '-version'], text=True),
                         'mayhem-dns-test\n')
        self.assertIn('Installed: mayhem-dns-test', r.stdout)
        self.assertNotIn('DNS unavailable', r.stderr)

    def test_bad_checksum_does_not_install_packages(self):
        (self.t / 'engine.zip.sha256').write_text('0' * 64 + '  engine.zip\n')
        r = self.run_upgrade()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('checksum mismatch', r.stderr)
        self.assertFalse((self.t / 'packages-installed').exists())

    def test_local_bad_checksum_preserves_engine(self):
        engine = self.t / 'libexec/dns-policy'
        engine.write_text('previous engine')
        (self.t / 'engine.zip.sha256').write_text('0' * 64 + '  engine.zip\n')
        r = subprocess.run(['sh', str(self.t / 'cli'), 'dns-policy-install', str(self.t / 'engine.zip')],
                           capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(engine.read_text(), 'previous engine')


if __name__ == '__main__':
    unittest.main()
