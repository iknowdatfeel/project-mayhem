#!/usr/bin/env python3
"""Opens every Mayhem page in headless Chromium with the real LuCI client code
and reports JavaScript errors.

    tests/luci/harness.py LUCI_SRC FIXTURE_DIR

LUCI_SRC     a checkout of github.com/openwrt/luci (modules/luci-base and
             themes/luci-theme-bootstrap are enough)
FIXTURE_DIR  prepared by tests/luci/run.sh: uci/ (mayhem, network, firewall),
             run/ (generated state), geo/, subs/

Requests to /ubus/ are answered by a small fake ubus: uci and network calls
from the fixture, luci.mayhem calls by the real rpcd plugin run with ucode.
Needs python3-playwright with Chromium.

For screenshots (SHOTS=DIR saves one per page):
  MAYHEM_LANG=ru  pages in Russian, from luci-app-mayhem/po/ru/mayhem.po
  MAYHEM_DARK=1   the dark variant of the bootstrap theme
  MAYHEM_DEMO=1   xray looks running: a fake metrics endpoint answers with
                  delays and growing traffic for the servers in run/nodes.json
"""

import http.server
import importlib.util
import json
import os
import random
import subprocess
import sys
import threading
import urllib.parse

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
LUCI = os.path.abspath(sys.argv[1])
FIX = os.path.abspath(sys.argv[2])
UCODE = os.environ.get('UCODE', 'ucode')
UCODE_LIB = os.environ.get('UCODE_LIB')
PLUGIN = os.path.join(ROOT, 'luci-app-mayhem/root/usr/share/rpcd/ucode/luci.mayhem')

STATIC = [
    ('/luci-static/resources/', os.path.join(ROOT, 'luci-app-mayhem/htdocs/luci-static/resources')),
    ('/luci-static/resources/', os.path.join(LUCI, 'modules/luci-base/htdocs/luci-static/resources')),
    ('/luci-static/resources/', os.path.join(LUCI, 'themes/luci-theme-bootstrap/htdocs/luci-static/resources')),
    ('/luci-static/bootstrap/', os.path.join(LUCI, 'themes/luci-theme-bootstrap/htdocs/luci-static/bootstrap')),
]

# Methods the pages may call that would change the system: never run them.
SIDE_EFFECTS = {'action', 'system_install', 'data_update', 'awg_import', 'geo_import', 'set_log_level', 'sub_update', 'select_node',
                'set_ping_method', 'backup_import', 'reset_config', 'rename_section', 'refresh_servers', 'set_main_section'}

calls = []
installs = []
imports = []
uci_writes = []
unknown = []
DEMO = bool(os.environ.get('MAYHEM_DEMO'))
METRICS_PORT = 12781
TRANSLATIONS = {}


def translations():
    lang = os.environ.get('MAYHEM_LANG')
    if not lang:
        return {}
    spec = importlib.util.spec_from_file_location('i18n', os.path.join(ROOT, 'tools/i18n.py'))
    i18n = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(i18n)
    po = i18n.read_po(os.path.join(ROOT, 'luci-app-mayhem/po', lang, 'mayhem.po'))
    return {k: v for k, v in po.items() if k and v}


def fake_netifd():
    """AmneziaWG is installed, but netifd started before it: awg0 runs as
    "none" and the Tunnels tab offers to restart the network."""
    shim = os.path.join(FIX, 'netifd-bin')
    proto = os.path.join(FIX, 'netifd-proto')
    os.makedirs(shim, exist_ok=True)
    os.makedirs(proto, exist_ok=True)
    open(os.path.join(proto, 'amneziawg.sh'), 'w').close()
    os.environ['MAYHEM_NETIFD_PROTO_DIR'] = proto
    os.environ['PATH'] = shim + ':' + os.environ['PATH']
    with open(os.path.join(shim, 'ubus'), 'w') as f:
        f.write('#!/bin/sh\n'
                'case "$2 $3" in\n'
                '"network get_proto_handlers") echo \'{"static":{},"dhcp":{},"wireguard":{}}\' ;;\n'
                '"network.interface dump") echo \'{"interface":[{"interface":"awg0","proto":"none","up":false}]}\' ;;\n'
                '*) exit 1 ;;\n'
                'esac\n')
    os.chmod(os.path.join(shim, 'ubus'), 0o755)


def start_demo():
    """xray seems to run: a pid, the active flag, and /debug/vars with numbers."""
    run = os.path.join(FIX, 'run')
    open(os.path.join(run, 'xray.pid'), 'w').write('%d\n' % os.getpid())
    open(os.path.join(run, 'active'), 'w').close()
    open(os.path.join(run, 'xray.version'), 'w').write('26.9.30\n')
    shim = os.path.join(FIX, 'demo-bin')
    os.makedirs(shim, exist_ok=True)
    with open(os.path.join(shim, 'pidof'), 'w') as f:
        f.write('#!/bin/sh\necho 1234\n')
    os.chmod(os.path.join(shim, 'pidof'), 0o755)
    os.environ['PATH'] = shim + ':' + os.environ['PATH']

    state = json.load(open(os.path.join(run, 'nodes.json')))
    tags = [n['tag'] for s in state.get('sections', {}).values() for n in s.get('nodes', [])]
    rnd = random.Random(7)
    delay = {t: rnd.choice([None, 48, 63, 95, 142, 210, 380]) for t in tags}
    total = {t: [rnd.randint(1, 900) << 20, rnd.randint(1, 9000) << 20] for t in tags}
    total['direct'] = [700 << 20, 21000 << 20]

    class Vars(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            for t in total:
                total[t][0] += rnd.randint(20, 200) << 10
                total[t][1] += rnd.randint(200, 3000) << 10
            body = json.dumps({
                'stats': {'outbound': {t: {'uplink': v[0], 'downlink': v[1]} for t, v in total.items()}},
                'observatory': {t: {'alive': d is not None, 'delay': d or 0} for t, d in delay.items()},
            }).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    srv = http.server.ThreadingHTTPServer(('127.0.0.1', METRICS_PORT), Vars)
    threading.Thread(target=srv.serve_forever, daemon=True).start()


def ucode_env():
    env = dict(os.environ)
    env.update({
        'MAYHEM_UCI_DIR': os.path.join(FIX, 'uci'),
        'MAYHEM_RUN_DIR': os.path.join(FIX, 'run'),
        'MAYHEM_GEO_DIR': os.path.join(FIX, 'geo'),
        'MAYHEM_LISTS_DIR': os.path.join(FIX, 'lists'),
        'MAYHEM_SUBS_DIR': os.path.join(FIX, 'subs'),
        'MAYHEM_LIB_DIR': os.path.join(ROOT, 'mayhem/files/usr/share/mayhem'),
    })
    return env


def ucode(script, *args):
    cmd = [UCODE, '-L', os.path.join(ROOT, 'mayhem/files/usr/share/ucode/*.uc')]
    if UCODE_LIB:
        cmd += ['-L', UCODE_LIB]
    out = subprocess.run(cmd + [script] + list(args), env=ucode_env(), capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or 'ucode failed')
    return json.loads(out.stdout)


# Set by a test to show the router as one without subscriptions.
HIDE = {'subscription': False}


def uci_get(config):
    values = ucode(os.path.join(os.path.dirname(__file__), 'uci_get.uc'), os.path.join(FIX, 'uci'), config)
    if config == 'mayhem' and HIDE['subscription']:
        values = {k: v for k, v in values.items() if v.get('.type') != 'subscription'}
        for v in values.values():
            v.pop('subscription', None)
    return values


NETWORK_DUMP = {'interface': [
    {'interface': 'lan', 'up': True, 'proto': 'static', 'device': 'br-lan', 'l3_device': 'br-lan'},
    {'interface': 'wan', 'up': True, 'proto': 'dhcp', 'device': 'eth1', 'l3_device': 'eth1'},
    {'interface': 'awg0', 'up': True, 'proto': 'amneziawg', 'device': 'awg0', 'l3_device': 'awg0'},
]}


def call(obj, method, args):
    calls.append('%s.%s' % (obj, method))

    if obj == 'luci.mayhem':
        # In the demo the checks through a server answer like a real one would.
        if DEMO and method == 'exit_info':
            return {'section': 'main', 'ip': '185.132.132.192', 'country_code': 'NL', 'country': 'Netherlands', 'city': 'Amsterdam'}
        if DEMO and method == 'probe':
            return {'ms': random.choice([48, 63, 95, 142])}
        # The latest releases come from GitHub: no network in tests.
        if method == 'components' and (args or {}).get('check'):
            return {'mayhem': '0.11.0', 'xray': '26.9.30', 'xray_latest': '26.9.30', 'mayhem_latest': '0.12.0'}
        if method == 'system_install':
            installs.append((args or {}).get('what'))
        if method == 'awg_import':
            imports.append(args or {})
        if method in SIDE_EFFECTS:
            return {'started': True} if method in ('system_install', 'data_update') else {'ok': True}
        return ucode(os.path.join(os.path.dirname(__file__), 'rpc.uc'), PLUGIN, method, json.dumps(args or {}))

    if obj == 'uci':
        if method == 'get':
            return {'values': uci_get(args['config'])}
        if method in ('set', 'add', 'delete'):
            uci_writes.append((method, args))
        if method == 'changes':
            return {'changes': {}}
        return {}

    if obj == 'session' and method == 'access':
        return {'access': True}
    if obj == 'luci' and method == 'getFeatures':
        return {}
    if obj == 'file' and method == 'list':
        return {'entries': []}
    if obj == 'network.interface' and method == 'dump':
        return NETWORK_DUMP
    if obj == 'network' and method == 'get_proto_handlers':
        return {'static': {}, 'dhcp': {}}
    if obj == 'luci-rpc' and method in ('getNetworkDevices', 'getWirelessDevices', 'getHostHints'):
        return {}
    if obj == 'luci-rpc' and method == 'getBoardJSON':
        return {}

    unknown.append('%s.%s' % (obj, method))
    return None


def page(view):
    env = {
        'media': '/luci-static/bootstrap', 'resource': '/luci-static/resources',
        'scriptname': '/cgi-bin/luci', 'pathinfo': '/admin/services/mayhem/' + view.split('/')[-1],
        'documentroot': '/www', 'requestpath': ['admin', 'services', 'mayhem', view.split('/')[-1]],
        'dispatchpath': ['admin', 'services', 'mayhem', view.split('/')[-1]], 'pollinterval': 5,
        'ubuspath': '/ubus/', 'sessionid': '0' * 32, 'token': '0' * 32,
        'nodespec': {'action': {'type': 'view', 'path': view}},
        'apply_rollback': 90, 'apply_holdoff': 4, 'apply_timeout': 5, 'apply_display': 1.5, 'rollback_token': None,
    }
    html = ('<!DOCTYPE html><html><head><meta charset="utf-8">'
            '<link rel="stylesheet" href="/luci-static/bootstrap/cascade.css">'
            '<script src="/luci-static/resources/cbi.js"></script></head>'
            '<body><header><ul class="nav" id="topmenu"></ul><div id="indicators"></div></header>'
            '<div id="maincontent" class="container"><div id="view"><div class="spinning">Loading view…</div></div></div>'
            '<script src="/luci-static/resources/luci.js"></script>'
            '<script>L = new LuCI(%s);</script>'
            '<script>L.require("ui").then(function(ui) { ui.instantiateView("%s"); });</script>'
            '</body></html>') % (json.dumps(env), view)

    # Added after the % formatting: the translations contain "%d" and "%s".
    if os.environ.get('MAYHEM_DARK'):
        html = html.replace('<html>', '<html data-darkmode="true">', 1)
    if os.environ.get('MAYHEM_LANG'):
        html = html.replace('<html', '<html lang="%s"' % os.environ['MAYHEM_LANG'], 1)
    if TRANSLATIONS:
        script = '<script>(function(t){window.TR={};for(var k in t)TR[sfh(trimws(k))]=t[k];})(%s);</script>' % json.dumps(TRANSLATIONS)
        html = html.replace('</head>', script + '</head>', 1)
    return html


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path

        if path.startswith('/page/'):
            return self.send(200, page(path[6:]), 'text/html; charset=utf-8')

        if path.startswith('/cgi-bin/luci/admin/translations'):
            return self.send(200, '', 'application/javascript')

        for prefix, base in STATIC:
            if path.startswith(prefix):
                f = os.path.join(base, path[len(prefix):])
                if os.path.isfile(f):
                    ctype = 'application/javascript' if f.endswith('.js') else ('text/css' if f.endswith('.css') else 'application/octet-stream')
                    return self.send(200, open(f, 'rb').read(), ctype)

        self.send(404, 'not found', 'text/plain')

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        batch = req if isinstance(req, list) else [req]
        res = []

        for r in batch:
            if r.get('method') == 'list':
                res.append({'jsonrpc': '2.0', 'id': r.get('id'), 'result': {}})
                continue
            sid, obj, method, args = r['params']
            try:
                data = call(obj, method, args)
                result = [0, data] if data is not None else [3]
            except Exception as e:
                print('backend error in %s.%s: %s' % (obj, method, e))
                result = [9]
            res.append({'jsonrpc': '2.0', 'id': r.get('id'), 'result': result})

        self.send(200, json.dumps(res if isinstance(req, list) else res[0]), 'application/json')


def main():
    from playwright.sync_api import sync_playwright

    global TRANSLATIONS
    TRANSLATIONS = translations()

    fake_netifd()
    if DEMO:
        start_demo()

    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % srv.server_address[1]
    failures = []

    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=os.environ.get('CHROMIUM') or None)

        def open_view(view, actions=None):
            ctx = browser.new_context(viewport={'width': 1280, 'height': int(os.environ.get('SHOTS_HEIGHT', '720'))})
            pg = ctx.new_page()
            errors = []
            pg.on('pageerror', lambda e: errors.append('page error: %s' % e))
            pg.on('console', lambda m: errors.append('console: %s' % m.text) if m.type == 'error' and 'Failed to load resource' not in m.text else None)
            pg.on('response', lambda r: errors.append('HTTP %d for %s' % (r.status, r.url)) if r.status >= 400 else None)
            # Pages other than the dashboard open in a window over it (#name).
            path, _sep, frag = view.partition('#')
            pg.goto('%s/page/%s%s' % (base, path, '#' + frag if frag else ''))
            pg.wait_for_selector('.mh-sheet-body .cbi-map' if frag else '#view .cbi-map', timeout=15000)
            pg.wait_for_timeout(500)
            for name, act in (actions or []):
                try:
                    act(pg)
                    pg.wait_for_timeout(700)
                except Exception as e:
                    errors.append('%s: %s' % (name, e))
            if os.environ.get('SHOTS'):
                pg.screenshot(path=os.path.join(os.environ['SHOTS'], view.replace('/', '_').replace('#', '_') + '.png'), full_page=True)
            body = pg.inner_text('body')
            for marker in ('TypeError', 'ReferenceError', 'SyntaxError', 'is not defined', 'Unable to'):
                if marker in body:
                    errors.append('page text shows "%s"' % marker)
            ctx.close()
            return errors

        def shot(pg, name):
            if os.environ.get('SHOTS'):
                pg.wait_for_timeout(600)  # modals fade in
                pg.screenshot(path=os.path.join(os.environ['SHOTS'], name + '.png'), full_page=True)

        def close_modal(pg):
            pg.evaluate('L.ui.hideModal()')
            pg.wait_for_timeout(300)

        def open_modals(pg, scope=''):
            # edit every section of the grid and close the modal again
            btns = pg.query_selector_all(scope + ' .cbi-section-table-row .cbi-button-edit')
            if not btns:
                raise RuntimeError('no rows to edit')
            for btn in btns:
                btn.click()
                pg.wait_for_selector('.modal', timeout=5000)
                pg.wait_for_timeout(300)
                close_modal(pg)

        def section_text(pg):
            # own domains and addresses as text: added lines go to the
            # domain and ip lists, geo categories stay where they were
            # dialogs closed with hideModal leave the grid's stack behind: start clean
            pg.reload()
            pg.wait_for_selector('.mh-sheet-body .cbi-map', timeout=15000)
            pg.wait_for_timeout(500)
            pg.query_selector_all('[data-tab="settings"] .cbi-section-table-row .cbi-button-edit')[0].click()
            pg.wait_for_selector('.modal [data-name="_text"] textarea', timeout=5000)
            area = pg.query_selector('.modal [data-name="_text"] textarea')
            if not area or 'youtube.test' not in area.input_value():
                raise RuntimeError('own domains are not shown as text')
            shot(pg, 'section_modal')
            js = pg.query_selector('.modal [data-name="outbound_json"]')
            if js and js.is_visible():
                raise RuntimeError('the outbound JSON field is shown for a section with keys')
            # a section without servers of its own uses the server list
            if pg.eval_on_selector('.modal select[id$=".servers"]', 'e => e.value') != 'pool':
                raise RuntimeError('the main section does not use the server list')
            keys = pg.query_selector('.modal [data-name="_links"]')
            if keys and keys.is_visible():
                raise RuntimeError('server keys are shown for a section that uses the server list')
            area.fill(area.input_value() + '\nexample.org # comment')
            pg.fill('.modal [data-name="_text_ip"] textarea', '91.108.4.0/22')
            # the dialog's Save already sends the changes to the router
            n = len(uci_writes)
            pg.click('.modal .cbi-button-positive')
            pg.wait_for_timeout(1500)
            got = {}
            for method, args in uci_writes[n:]:
                if method == 'set' and args.get('section') == 'main':
                    got.update(args.get('values', {}))
            if got.get('domain') != ['geosite:youtube', 'youtube.test', 'example.org'] or got.get('ip') != ['geoip:telegram', '91.108.4.0/22']:
                raise RuntimeError('text rules were saved as %s' % got)

        def main_section(pg):
            # the main section is chosen on the dashboard, not here; the switch
            # for the rest of the traffic names the active server
            if pg.query_selector('select[id$=".default_section"]'):
                raise RuntimeError('the main section is still chosen on the Routing page')
            if 'DE' not in pg.inner_text('[data-name="mode"]'):
                raise RuntimeError('the active server is not shown at the rest of the traffic')

        def type_tunnel(pg):
            # switch the first section to a tunnel to render its options
            pg.query_selector_all('[data-tab="settings"] .cbi-section-table-row .cbi-button-edit')[0].click()
            pg.wait_for_selector('.modal', timeout=5000)
            pg.select_option('.modal select[id$=".type"]', 'interface')
            pg.wait_for_timeout(300)
            if not pg.query_selector('.modal [data-name="route_mode"]'):
                raise RuntimeError('tunnel options did not appear')
            shot(pg, 'sections_tunnel')
            close_modal(pg)

        def add_vpn_key(pg):
            # A vpn:// key on the Add server tab becomes a tunnel, named after
            # the key, with a message under the field (not a hang).
            key = open(os.path.join(ROOT, 'tests/awg/key.txt')).read().strip()
            pg.click('.cbi-tabmenu [data-tab="geo"] a')
            pg.wait_for_timeout(300)
            n = len(imports)
            pg.fill('div[data-tab="geo"] textarea', key)
            pg.click('div[data-tab="geo"] .cbi-button-add')
            pg.wait_for_timeout(1500)
            got = imports[n:]
            if not got or '[Interface]' not in (got[0].get('conf') or '') or got[0].get('label') != 'Test':
                raise RuntimeError('a vpn:// key is not imported as a tunnel: %s' % got)
            shot(pg, 'servers_add_vpn')

        def import_modal(pg):
            pg.click('.mh-sheet-body .cbi-tabmenu [data-tab="device"] a')
            pg.wait_for_timeout(300)
            shot(pg, 'servers_tunnels')
            text = pg.inner_text('.mh-sheet-body div[data-tab="device"]')
            if 'awg0' not in text or 'AmneziaWG' not in text:
                raise RuntimeError('awg0 running as "none" is not listed as an AmneziaWG tunnel')
            btn = pg.locator('.mh-sheet-body div[data-tab="device"] button', has_text=TRANSLATIONS.get('Restart the network', 'Restart the network'))
            if not btn.count():
                raise RuntimeError('no button to restart the network for the unloaded protocol')
            n = len(installs)
            btn.first.click()
            pg.wait_for_timeout(800)
            if 'protos' not in installs[n:]:
                raise RuntimeError('the button does not start the network restart: %s' % installs[n:])
            close_modal(pg)
            if not pg.locator('.mh-sheet-body div[data-tab="device"] input[placeholder="awg0"]').count():
                raise RuntimeError('no field for the name of the tunnel')
            pg.click('.mh-sheet-body div[data-tab="device"] button[title]:has-text("✎")')
            pg.wait_for_selector('.modal input[maxlength="15"]', timeout=5000)
            shot(pg, 'servers_tunnel_rename')
            close_modal(pg)
            pg.click('.mh-sheet-body [data-tab="device"] .cbi-button-add')
            pg.wait_for_selector('.modal textarea', timeout=5000)
            shot(pg, 'sections_import')
            close_modal(pg)

        def run_diag(pg):
            pg.click('#mayhem-body .mh-side button >> nth=-4')
            pg.wait_for_selector('.modal .mh-drow', timeout=5000)
            pg.wait_for_timeout(500)
            pg.wait_for_function('!document.querySelector(".modal .mh-spin")', timeout=90000)
            if not pg.query_selector('.modal .mh-drow-items .mh-item'):
                raise RuntimeError('no check results')
            shot(pg, 'dashboard_diag')
            close_modal(pg)

        def logs_modal(pg):
            # the logs open from the diagnostics dialog
            pg.click('#mayhem-body .mh-side button >> nth=-4')
            pg.wait_for_selector('.modal .mh-drow', timeout=5000)
            pg.click('.modal button:has-text("%s")' % TRANSLATIONS.get('View logs', 'View logs'))
            pg.wait_for_selector('.modal .mh-log', timeout=5000)
            pg.wait_for_timeout(500)
            shot(pg, 'dashboard_logs')
            close_modal(pg)

        def backup_modal(pg):
            # the backup is in the settings, next to the reset
            pg.click('[data-name="_backup"] button')
            pg.wait_for_selector('.modal .mh-backup', timeout=5000)
            pg.wait_for_timeout(300)
            shot(pg, 'dashboard_backup')
            close_modal(pg)

        def servers_tabs(pg):
            if not pg.query_selector('[data-tab="geo"] .mh-keys'):
                raise RuntimeError('no table of servers added by key')
            shot(pg, 'servers_add')
            # a key into a new section: checked by the backend, then saved
            pg.fill('[data-tab="geo"] textarea', 'ss://YWVzLTI1Ni1nY206cHc@1.2.3.6:8388#FI 3')
            if pg.query_selector('[data-tab="geo"] select'):
                raise RuntimeError('keys are added to a section, not to the server list')
            # applying needs the router: only note that it was asked for
            pg.evaluate('L.ui.changes.apply = function() { window.mhApplied = true; return Promise.resolve(); }')
            n = len(calls)
            w = len(uci_writes)
            pg.click('[data-tab="geo"] .cbi-button-add')
            pg.wait_for_timeout(1500)
            if 'luci.mayhem.parse_link' not in calls[n:] or not pg.evaluate('window.mhApplied === true'):
                raise RuntimeError('adding a key did not save and apply it: %s' % calls[n:])
            links = [a.get('values', {}).get('link') for m, a in uci_writes[w:] if m == 'set' and a.get('section') == 'pool']
            if not links or not any('1.2.3.6' in ' '.join(x or []) for x in links):
                raise RuntimeError('the key did not go into the server list: %s' % uci_writes[w:])
            pg.click('.cbi-tabmenu [data-tab="subscription"] a')
            pg.wait_for_timeout(300)
            shot(pg, 'servers_subscriptions')
            open_modals(pg, '[data-tab="subscription"]')
            pg.click('.cbi-tabmenu [data-tab="settings"] a')
            pg.wait_for_timeout(300)
            shot(pg, 'servers_advanced')

        def geo_tab(pg):
            pg.click('.cbi-tabmenu [data-tab="geo"] a')
            pg.wait_for_timeout(300)
            shot(pg, 'routing_geo')
            open_modals(pg, '[data-tab="geo"]')
            pg.click('.cbi-tabmenu [data-tab="settings"] a')

        def dns_tab(pg):
            pg.click('.cbi-tabmenu [data-tab="dns"] a')
            pg.wait_for_selector('[data-tab="dns"] [data-name="remote"]', state='visible', timeout=5000)
            shot(pg, 'routing_dns')
            # one type for the list, a resolver from the drop-down: saved as one entry
            pg.select_option('[data-tab="dns"] select[id$="._domestic_type"]', 'tcp')
            pg.evaluate("""() => {
                const w = L.dom.findClassInstance(document.querySelector('[data-tab="dns"] [data-name="domestic"] .cbi-dropdown'));
                w.setValue(['google', 'quad9']);
            }""")
            n = len(uci_writes)
            pg.click('.mh-sheet-foot .cbi-button-save')
            pg.wait_for_timeout(1000)
            got = [a.get('values', {}).get('domestic') for m, a in uci_writes[n:] if m == 'set' and a.get('section') == 'dns']
            if ['tcp://8.8.8.8', 'tcp://9.9.9.9'] not in got:
                raise RuntimeError('domestic DNS saved as %s' % uci_writes[n:])

        def upload_modal(pg):
            pg.click('.cbi-tabmenu [data-tab="geo"] a')
            pg.click('[data-tab="geo"] [data-name="_upload_geo"] button')
            pg.wait_for_selector('.modal input', timeout=5000)
            close_modal(pg)

        def components_page(pg):
            pg.wait_for_timeout(1500)
            if not pg.query_selector('.mh-sheet table') or not pg.query_selector('[data-name="auto_update"]'):
                raise RuntimeError('no component table or automatic update')
            shot(pg, 'components')

        def settings_tabs(pg):
            pg.click('[data-name="_reset"] button')
            pg.wait_for_selector('.modal input[type="checkbox"]', timeout=5000)
            shot(pg, 'settings_reset')
            close_modal(pg)

        def dashboard_buttons(pg):
            if not pg.query_selector('#mayhem-body .mh-tile'):
                raise RuntimeError('no servers on the dashboard')
            # like Happ: servers by link in one box, every subscription in its own
            titles = pg.eval_on_selector_all('#mayhem-body .mh-section .mh-ghead > .mh-title', 'es => es.map(e => e.textContent)')
            if not any(x in ('Server list', 'Список серверов') for x in titles) or len(titles) < 2:
                raise RuntimeError('server boxes: %s' % titles)
            # several proxy or tunnel sections: the main one is chosen here
            n = len(calls)
            pg.select_option('#mayhem-body .mh-whead select', 'awg')
            pg.wait_for_selector('.modal .cbi-button-action', timeout=5000)
            shot(pg, 'dashboard_main')
            pg.click('.modal .cbi-button-action')
            pg.wait_for_timeout(1000)
            if 'luci.mayhem.set_main_section' not in calls[n:]:
                raise RuntimeError('choosing the main section did not reach the router: %s' % calls[n:])
            if not pg.query_selector('#mayhem-body .mh-ghead .mh-bar'):
                raise RuntimeError('no subscription traffic on the dashboard')
            if not DEMO:  # a screenshot shows the demo delays, not failed checks
                pg.click('#mayhem-body .mh-side button >> nth=0')
                pg.wait_for_timeout(1500)
            else:
                pg.wait_for_timeout(4500)  # two polls: the speed widget has numbers

        def add_section(pg, no_subs=False):
            # the dialog of a new section opens, also on a router without
            # subscriptions (an empty dropdown used to throw in LuCI)
            HIDE['subscription'] = no_subs
            try:
                pg.reload()
                pg.wait_for_selector('.mh-sheet-body .cbi-map', timeout=15000)
                pg.wait_for_timeout(500)
                pg.click('.cbi-tabmenu li[data-tab="settings"] a')  # earlier actions leave another tab open
                inp = pg.locator('[data-tab="settings"] .cbi-section-create input[type=text]').first
                inp.click()
                inp.press_sequentially('newsec')
                pg.locator('[data-tab="settings"] .cbi-section-create .cbi-button-add').first.click()
                pg.wait_for_selector('.modal', timeout=5000)
                pg.wait_for_timeout(500)
                n = len(uci_writes)
                pg.click('.modal .cbi-button-positive')
                pg.wait_for_timeout(1500)
                if not any(m == 'add' and a.get('name') == 'newsec' for m, a in uci_writes[n:]):
                    raise RuntimeError('the new section was not saved: %s' % uci_writes[n:])
            finally:
                HIDE['subscription'] = False

        def edit_server(pg):
            # the pencil of a server added by key: its Xray JSON, nothing else
            n = len(calls)
            pg.click('#mayhem-body .mh-section .mh-tile .mh-ren >> nth=0')
            pg.wait_for_selector('.modal textarea', timeout=5000)
            if pg.query_selector('.modal .cbi-tabmenu'):
                raise RuntimeError('the server dialog still has tabs')
            if 'luci.mayhem.parse_link' not in calls[n:]:
                raise RuntimeError('the dialog did not ask the router for the JSON: %s' % calls[n:])
            text = pg.input_value('.modal textarea')
            if '"protocol"' not in text:
                raise RuntimeError('no outbound JSON in the dialog: %s' % text[:200])
            shot(pg, 'dashboard_edit')
            close_modal(pg)

        def delete_server(pg):
            # the bin of a server added by key: a question, then it is gone
            # from the page at once and its key from the server list
            conf = os.path.join(FIX, 'uci', 'mayhem')
            saved = open(conf).read()
            try:
                delete_checks(pg, conf)
            finally:
                open(conf, 'w').write(saved)  # the other pages want the server back

        def delete_checks(pg, conf):
            names = pg.eval_on_selector_all('#mayhem-body .mh-tile b', 'es => es.map(e => e.textContent)')
            pg.click('#mayhem-body .mh-section .mh-tile .mh-del >> nth=0')
            pg.wait_for_selector('.modal .cbi-button-negative', timeout=5000)
            shot(pg, 'dashboard_delete')
            pg.click('.modal .cbi-button-negative')
            pg.wait_for_timeout(1000)
            if 'luci.mayhem.server_delete' not in calls:
                raise RuntimeError('deleting did not reach the router')
            after = pg.eval_on_selector_all('#mayhem-body .mh-tile b', 'es => es.map(e => e.textContent)')
            if len(after) != len(names) - 1 or after.count(names[0]) >= names.count(names[0]):
                raise RuntimeError('the server is still on the page: %s -> %s' % (names, after))
            pg.wait_for_timeout(3500)  # a poll with the old data does not bring it back
            again = pg.eval_on_selector_all('#mayhem-body .mh-tile b', 'es => es.map(e => e.textContent)')
            if again != after:
                raise RuntimeError('the server came back with the next poll: %s' % again)
            if ('#%s\'' % names[0]) in open(conf).read():
                raise RuntimeError('the key of %s is still in the config' % names[0])

        def services_badge(pg):
            # the badge at the top opens the state of each service
            pg.click('#mayhem-body .mh-pill')
            pg.wait_for_selector('#mayhem-body .mh-svc', timeout=3000)
            text = pg.inner_text('#mayhem-body .mh-svc')
            if 'Xray' not in text or 'Dnsmasq' not in text:
                raise RuntimeError('no service states under the badge: %s' % text)
            shot(pg, 'dashboard_services')
            pg.click('#mayhem-body .mh-pill')

        def nav_pages(pg):
            # every page opens in the window from its button and closes again
            for i in range(4):
                pg.click('#mayhem-body .mh-navbtn >> nth=%d' % i)
                pg.wait_for_selector('.mh-sheet-body .cbi-map', timeout=15000)
                if i == 0:
                    shot(pg, 'dashboard_sheet')
                pg.keyboard.press('Escape')
                pg.wait_for_selector('.mh-sheet-overlay', state='detached', timeout=5000)
            if '#' in pg.url:
                raise RuntimeError('the address keeps a page after closing: %s' % pg.url)

        pages = [
            ('mayhem/dashboard', [('buttons', dashboard_buttons), ('logs dialog', logs_modal), ('run diagnostics', run_diag),
                                  ('edit a server', edit_server), ('delete a server', delete_server), ('services', services_badge), ('pages in a window', nav_pages)]),
            ('mayhem/dashboard#sections', [('sections tab', lambda pg: shot(pg, 'routing_sections')), ('main section', main_section),
                                 ('edit sections', lambda pg: open_modals(pg, '[data-tab="settings"]')), ('domains as text', section_text),
                                 ('tunnel options', type_tunnel), ('DNS tab', dns_tab), ('edit geo sources', geo_tab), ('upload dialog', upload_modal),
                                 ('add a section', add_section), ('add a section without subscriptions', lambda pg: add_section(pg, True))]),
            ('mayhem/dashboard#servers', [('server list tabs', servers_tabs), ('import dialog', import_modal), ('vpn key as a server', add_vpn_key)]),
            ('mayhem/dashboard#components', [('components', components_page)]),
            ('mayhem/dashboard#settings', [('reset dialog', settings_tabs), ('backup dialog', backup_modal)]),
        ]

        only = os.environ.get('MAYHEM_ONLY')

        for view, actions in pages:
            if only and only not in view:
                continue

            try:
                errs = open_view(view, actions)
            except Exception as e:
                errs = ['did not render: %s' % e]
            for e in errs:
                failures.append('%s: %s' % (view, e))
                if os.environ.get('GITHUB_ACTIONS'):
                    print('::error title=luci::%s: %s' % (view, e.replace('%', '%25').replace('\n', '%0A')))
            print('%s %s' % ('FAIL' if errs else 'ok  ', view))
            for e in errs:
                print('     ' + e)

        browser.close()

    if unknown:
        print('unanswered ubus calls: %s' % ', '.join(sorted(set(unknown))))

    print('luci: %s' % ('some pages failed' if failures else 'all pages render'))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
