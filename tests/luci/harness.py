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
"""

import http.server
import json
import os
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
SIDE_EFFECTS = {'action', 'system_install', 'data_update', 'awg_import', 'geo_import', 'set_log_level', 'sub_update', 'select_node'}

calls = []
unknown = []


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
        if method in SIDE_EFFECTS:
            return {'started': True} if method in ('system_install', 'data_update') else {'ok': True}
        return ucode(os.path.join(os.path.dirname(__file__), 'rpc.uc'), PLUGIN, method, json.dumps(args or {}))

    if obj == 'uci':
        if method == 'get':
            return {'values': uci_get(args['config'])}
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
    return ('<!DOCTYPE html><html><head><meta charset="utf-8">'
            '<link rel="stylesheet" href="/luci-static/bootstrap/cascade.css">'
            '<script src="/luci-static/resources/cbi.js"></script></head>'
            '<body><header><ul class="nav" id="topmenu"></ul><div id="indicators"></div></header>'
            '<div id="maincontent" class="container"><div id="view"><div class="spinning">Loading view…</div></div></div>'
            '<script src="/luci-static/resources/luci.js"></script>'
            '<script>L = new LuCI(%s);</script>'
            '<script>L.require("ui").then(function(ui) { ui.instantiateView("%s"); });</script>'
            '</body></html>') % (json.dumps(env), view)


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

    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = 'http://127.0.0.1:%d' % srv.server_address[1]
    failures = []

    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=os.environ.get('CHROMIUM') or None)

        def open_view(view, actions=None):
            ctx = browser.new_context()
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
                pg.screenshot(path=os.path.join(os.environ['SHOTS'], name + '.png'))

        def close_modal(pg):
            pg.evaluate('L.ui.hideModal()')
            pg.wait_for_timeout(300)

        def open_modals(pg):
            # edit every section of the grid and close the modal again
            btns = pg.query_selector_all('.cbi-section-table-row .cbi-button-edit')
            if not btns:
                raise RuntimeError('no rows to edit')
            for btn in btns:
                btn.click()
                pg.wait_for_selector('.modal', timeout=5000)
                pg.wait_for_timeout(300)
                close_modal(pg)

        def type_tunnel(pg):
            # switch the first section to a tunnel to render its options
            pg.query_selector_all('.cbi-section-table-row .cbi-button-edit')[0].click()
            pg.wait_for_selector('.modal', timeout=5000)
            pg.select_option('.modal select[id$=".type"]', 'interface')
            pg.wait_for_timeout(300)
            if not pg.query_selector('.modal [data-name="route_mode"]'):
                raise RuntimeError('tunnel options did not appear')
            shot(pg, 'sections_tunnel')
            close_modal(pg)

        def import_modal(pg):
            pg.click('text=Import AmneziaWG / WireGuard…')
            pg.wait_for_selector('.modal textarea', timeout=5000)
            shot(pg, 'sections_import')
            close_modal(pg)

        def run_diag(pg):
            pg.click('text=Run')
            pg.wait_for_selector('#mayhem-diag table', timeout=60000)
            pg.wait_for_function('!document.querySelector("#mayhem-diag p").textContent.includes("Checking")', timeout=90000)

        def upload_modal(pg):
            pg.click('text=Upload .dat…')
            pg.wait_for_selector('.modal input', timeout=5000)
            close_modal(pg)

        def dashboard_buttons(pg):
            pg.click('text=Update geo data')
            pg.wait_for_timeout(500)
            if 'Server' not in pg.inner_text('#mayhem-body'):
                raise RuntimeError('no server table on the dashboard')

        pages = [
            ('mayhem/dashboard', [('buttons', dashboard_buttons)]),
            ('mayhem/sections', [('edit sections', open_modals), ('tunnel options', type_tunnel), ('import dialog', import_modal)]),
            ('mayhem/subscriptions', [('edit subscriptions', open_modals)]),
            ('mayhem/settings', [('edit geo sources', open_modals), ('upload dialog', upload_modal)]),
            ('mayhem/diagnostics', [('run diagnostics', run_diag)]),
            ('mayhem/logs', []),
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
