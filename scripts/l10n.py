#!/usr/bin/env python3
"""Vedetta localization tool.

Reads Resources/Localization/strings.tsv (English key, Italian, French) and:
  * generates <lang>.lproj/Localizable.strings and InfoPlist.strings for en, it, fr
  * checks that every L("...") key used in Sources/ has a translation (and reports unused rows)
  * checks that placeholders (%@, %1$@ …) match in every language

Usage: python3 scripts/l10n.py            generate + check (exit 1 on problems)
       python3 scripts/l10n.py --check    check only
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOC = os.path.join(ROOT, "Resources", "Localization")
LANGS = ["en", "it", "fr"]
INFO_KEY = "Vedetta connects to the recorder and cameras on your network to show you live video and recordings."

def load():
    rows = []
    for n, line in enumerate(open(os.path.join(LOC, "strings.tsv"), encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            sys.exit(f"strings.tsv:{n}: expected 3 columns, got {len(parts)}")
        rows.append((n, *parts))
    return rows

def placeholders(s):
    return sorted(re.sub(r"%\d+\$", "%", p) for p in re.findall(r"%(?:\d+\$)?@", s))

def used_keys():
    keys = {}
    pat = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"')
    for f in glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True):
        if f.endswith("SelfTest.swift") or "vedetta-probe" in f:
            continue
        for n, line in enumerate(open(f, encoding="utf-8"), 1):
            for m in pat.finditer(line):
                keys.setdefault(m.group(1), f"{os.path.relpath(f, ROOT)}:{n}")
    return keys

def esc(s):
    # TSV already holds Swift-style escapes (\n); only quotes need escaping for .strings
    return s.replace('"', '\\"')

def generate(rows):
    for i, lang in enumerate(LANGS):
        d = os.path.join(LOC, f"{lang}.lproj")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as out:
            out.write(f"/* Generated from strings.tsv by scripts/l10n.py — do not edit ({lang}) */\n\n")
            for _, en, it, fr in rows:
                value = (en, it, fr)[i]
                out.write(f'"{esc(en)}" = "{esc(value)}";\n')
        info = next(((en, it, fr)[i] for _, en, it, fr in rows if en == INFO_KEY), INFO_KEY)
        with open(os.path.join(d, "InfoPlist.strings"), "w", encoding="utf-8") as out:
            out.write(f'"CFBundleDisplayName" = "Vedetta";\n"CFBundleName" = "Vedetta";\n'
                      f'"NSLocalNetworkUsageDescription" = "{esc(info)}";\n')

def check(rows):
    problems = 0
    table = {en: (it, fr, n) for n, en, it, fr in rows}
    if len(table) != len(rows):
        print("✘ duplicate English keys in strings.tsv"); problems += 1
    for en, (it, fr, n) in table.items():
        for lang, value in (("it", it), ("fr", fr)):
            if not value.strip():
                print(f"✘ strings.tsv:{n}: missing {lang} translation for {en!r}"); problems += 1
            elif placeholders(value) != placeholders(en):
                print(f"✘ strings.tsv:{n}: placeholders differ in {lang}: {en!r} vs {value!r}"); problems += 1
    used = used_keys()
    for key, where in sorted(used.items()):
        if key not in table:
            print(f"✘ {where}: no translation for {key!r}"); problems += 1
    unused = [en for en in table if en not in used and en != INFO_KEY]
    for en in unused:
        print(f"· unused row: {en!r}")
    print(f"{len(used)} keys used, {len(table)} rows, {len(unused)} unused, {problems} problems")
    return problems

if __name__ == "__main__":
    rows = load()
    if "--check" not in sys.argv:
        generate(rows)
    sys.exit(1 if check(rows) else 0)
