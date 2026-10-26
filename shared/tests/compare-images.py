#!/usr/bin/env python3
"""Vergleicht zwei Builds desselben Images (OCI-Archive) für make repro.

Aufruf: compare-images.py <a.tar> <b.tar> <plattform> [<plattform> ...]

Pro Plattform: gleiche diff_ids (unkomprimierte Schichten) und gleicher Inhalt
(Datei für Datei: Typ, Modus, Eigentümer, Zeitstempel, Symlink-Ziel, SHA-256).
Zusätzlich gemeldet: ob auch Manifest- und Index-Digest übereinstimmen.
Exit 1, wenn diff_ids oder Inhalt abweichen. Nur Standardbibliothek.
"""

import hashlib
import importlib.util
import json
import os
import sys
import tarfile

spec = importlib.util.spec_from_file_location(
    "inspect_image", os.path.join(os.path.dirname(os.path.abspath(__file__)), "inspect-image.py"))
ii = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ii)


def index_digest(path):
    with tarfile.open(path) as t:
        index = json.loads(t.extractfile("index.json").read())
    return index["manifests"][0]["digest"]


def fingerprint(path, platform):
    config, layers = ii.load_image(path, platform)
    files = {}
    for p, (layer, m) in ii.merge_layers(layers).items():
        digest = hashlib.sha256(layer.extractfile(m).read()).hexdigest() if m.isfile() else ""
        files[p] = (ii.kind(m), oct(m.mode), m.uid, m.gid, m.mtime, m.linkname, digest)
    return config["rootfs"]["diff_ids"], files


def main():
    a, b, platforms = sys.argv[1], sys.argv[2], sys.argv[3:]
    failed = False
    for platform in platforms:
        ma, _, _, _ = ii.open_image(a, platform)
        mb, _, _, _ = ii.open_image(b, platform)
        ids_a, files_a = fingerprint(a, platform)
        ids_b, files_b = fingerprint(b, platform)
        if ids_a == ids_b:
            ii.ok(f"{platform}: gleiche diff_ids ({len(ids_a)} Schichten)")
        else:
            ii.fail(f"{platform}: diff_ids weichen ab")
            failed = True
        diff = sorted(p for p in files_a.keys() | files_b.keys() if files_a.get(p) != files_b.get(p))
        if diff:
            failed = True
            ii.fail(f"{platform}: {len(diff)} Einträge unterscheiden sich")
            for p in diff[:20]:
                print(f"       {p}\n         a: {files_a.get(p)}\n         b: {files_b.get(p)}")
        else:
            ii.ok(f"{platform}: gleicher Inhalt ({len(files_a)} Einträge)")
        print(f"       Manifest {'gleich' if ma == mb else 'verschieden'}: {ma[:19]}… / {mb[:19]}…")
    ia, ib = index_digest(a), index_digest(b)
    print(f"       Index {'gleich' if ia == ib else 'verschieden'}: {ia}" + ("" if ia == ib else f" / {ib}"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
