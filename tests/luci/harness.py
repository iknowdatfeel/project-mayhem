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


def uci_get(config):
    return ucode(os.path.join(os.path.dirname(__file__), 'uci_get.uc'), os.path.join(FIX, 'uci'), config)


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
            pg.goto('%s/page/%s' % (base, view))
            pg.wait_for_selector('#view .cbi-map', timeout=15000)
            pg.wait_for_timeout(500)
            for name, act in (actions or []):
                try:
                    act(pg)
                    pg.wait_for_timeout(700)
                except Exception as e:
                    errors.append('%s: %s' % (name, e))
            if os.environ.get('SHOTS'):
                pg.screenshot(path=os.path.join(os.environ['SHOTS'], view.replace('/', '_') + '.png'), full_page=True)
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
            pg.wait_for_selector('#view .cbi-map', timeout=15000)
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
            area.fill(area.input_value() + '\n91.108.4.0/22\nexample.org # comment')
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

        def import_modal(pg):
            pg.click('.cbi-tabmenu [data-tab="device"] a')
            pg.wait_for_timeout(300)
            shot(pg, 'servers_tunnels')
            pg.click('[data-tab="device"] .cbi-button-add')
            pg.wait_for_selector('.modal textarea', timeout=5000)
            shot(pg, 'sections_import')
            close_modal(pg)

        def run_diag(pg):
            pg.click('#mayhem-body .mh-side button >> nth=-6')
            pg.wait_for_selector('.modal .mh-drow', timeout=5000)
            pg.wait_for_timeout(500)
            pg.wait_for_function('!document.querySelector(".modal .mh-spin")', timeout=90000)
            if not pg.query_selector('.modal .mh-drow-items .mh-item'):
                raise RuntimeError('no check results')
            shot(pg, 'dashboard_diag')
            close_modal(pg)

        def logs_modal(pg):
            pg.click('#mayhem-body .mh-side button >> nth=-5')
            pg.wait_for_selector('.modal .mh-log', timeout=5000)
            pg.wait_for_timeout(500)
            shot(pg, 'dashboard_logs')
            close_modal(pg)

        def backup_modal(pg):
            pg.click('#mayhem-body .mh-side button >> nth=-4')
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

        def upload_modal(pg):
            pg.click('.cbi-tabmenu [data-tab="geo"] a')
            pg.click('[data-tab="geo"] [data-name="_upload_geo"] button')
            pg.wait_for_selector('.modal input', timeout=5000)
            close_modal(pg)

        def components_page(pg):
            pg.wait_for_timeout(1500)
            if not pg.query_selector('#view table') or not pg.query_selector('[data-name="auto_update"]'):
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

        pages = [
            ('mayhem/dashboard', [('buttons', dashboard_buttons), ('logs dialog', logs_modal), ('backup dialog', backup_modal), ('run diagnostics', run_diag)]),
            ('mayhem/sections', [('sections tab', lambda pg: shot(pg, 'routing_sections')), ('main section', main_section),
                                 ('edit sections', lambda pg: open_modals(pg, '[data-tab="settings"]')), ('domains as text', section_text),
                                 ('tunnel options', type_tunnel), ('DNS tab', dns_tab), ('edit geo sources', geo_tab), ('upload dialog', upload_modal)]),
            ('mayhem/servers', [('server list tabs', servers_tabs), ('import dialog', import_modal)]),
            ('mayhem/components', [('components', components_page)]),
            ('mayhem/settings', [('reset dialog', settings_tabs)]),
        ]

        for view, actions in pages:
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
