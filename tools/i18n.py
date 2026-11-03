#!/usr/bin/env python3
"""Translations of the LuCI app.

    tools/i18n.py pot     rewrite luci-app-mayhem/po/templates/mayhem.pot
    tools/i18n.py check   every string has a Russian translation (tests)

Strings are taken from _('...') calls in the JS views and the menu titles,
the same way LuCI's i18n-scan does it.
"""

import glob
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
APP = os.path.join(ROOT, 'luci-app-mayhem')
CALL = re.compile(r"""\b_\(\s*'((?:[^'\\]|\\.)*)'""")


def unescape(s):
    return re.sub(r"\\(.)", lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)


def strings():
    found = {}
    files = sorted(glob.glob(os.path.join(APP, 'htdocs/luci-static/resources/**/*.js'), recursive=True))
    for f in files:
        text = open(f, encoding='utf-8').read()
        for m in CALL.finditer(text):
            found.setdefault(unescape(m.group(1)), os.path.relpath(f, APP))
    for f in glob.glob(os.path.join(APP, 'root/usr/share/luci/menu.d/*.json')):
        for entry in json.load(open(f, encoding='utf-8')).values():
            if 'title' in entry:
                found.setdefault(entry['title'], os.path.relpath(f, APP))
    return found


def po_quote(s):
    s = s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')
    return '"%s"' % s


def read_po(path):
    out, msgid, msgstr, cur = {}, None, None, None
    for line in open(path, encoding='utf-8'):
        line = line.rstrip('\n')
        if line.startswith('msgid '):
            if msgid is not None:
                out[msgid] = msgstr
            msgid, msgstr, cur = json.loads(line[6:]), '', 'id'
        elif line.startswith('msgstr '):
            msgstr, cur = json.loads(line[7:]), 'str'
        elif line.startswith('"'):
            if cur == 'id':
                msgid += json.loads(line)
            elif cur == 'str':
                msgstr += json.loads(line)
    if msgid is not None:
        out[msgid] = msgstr
    out.pop('', None)
    return out


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'check'
    found = strings()

    if cmd == 'pot':
        path = os.path.join(APP, 'po/templates/mayhem.pot')
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as f:
            f.write('msgid ""\nmsgstr "Content-Type: text/plain; charset=UTF-8"\n')
            for s in sorted(found):
                f.write('\n#: %s\nmsgid %s\nmsgstr ""\n' % (found[s], po_quote(s)))
        print('%d strings' % len(found))
        return 0

    ru = read_po(os.path.join(APP, 'po/ru/mayhem.po'))
    missing = [s for s in found if not ru.get(s)]
    for s in missing:
        print('untranslated: %r' % s)
    # Placeholders must survive translation.
    bad = [s for s in found if ru.get(s) and sorted(re.findall(r'%[sd%]', s)) != sorted(re.findall(r'%[sd%]', ru[s]))]
    for s in bad:
        print('placeholders differ: %r -> %r' % (s, ru[s]))
    return 1 if missing or bad else 0


if __name__ == '__main__':
    sys.exit(main())
