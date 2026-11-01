#!/usr/bin/env python3
"""Embed local catalogs/runtime into the standalone, CSP-restricted dashboard."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
START = '<!-- BEGIN GENERATED I18N -->'
END = '<!-- END GENERATED I18N -->'


def render():
    catalogs = {p.stem: json.loads(p.read_text(encoding='utf-8'))
                for p in sorted((ROOT / 'locales').glob('*.json'))}
    source = json.dumps(catalogs, ensure_ascii=False, separators=(',', ':'))
    source = source.replace('<', r'\u003c').replace('\u2028', r'\u2028').replace('\u2029', r'\u2029')
    runtime = (ROOT / 'src/i18n.js').read_text(encoding='utf-8')
    return f'{START}\n<script>\nconst batteryHogCatalogs = {source};\n{runtime}</script>\n{END}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    dashboard = ROOT / 'dashboard.html'
    text = dashboard.read_text(encoding='utf-8')
    a, b = text.index(START), text.index(END) + len(END)
    updated = text[:a] + render() + text[b:]
    if args.check:
        if updated != text:
            raise SystemExit('Localization bundle is stale. Run python3 scripts/build_localizations.py')
    else:
        dashboard.write_text(updated, encoding='utf-8')


if __name__ == '__main__':
    main()
