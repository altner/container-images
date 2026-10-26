#!/usr/bin/env python3
"""Prüft Inhalt und Konfiguration eines Images aus `docker image save`.

Aufruf:
  inspect-image.py <image.tar> <plattform> <expected-files.txt> [<weitere.txt> ...]
                   [--allow-shell] [--dynamic-out <datei>]

Geprüft wird das zusammengesetzte Dateisystem aller Schichten (Whiteouts berücksichtigt):
  - Inhalt entspricht exakt den Listen (expected-files.txt, bei -debug plus expected-debug.txt)
  - alles gehört 0:0, nichts ist für Gruppe/andere schreibbar, keine setuid/setgid/sticky-Bits
  - keine Gerätedateien, FIFOs oder hängenden Symlinks
  - keine Shell (außer mit --allow-shell)
  - ELF-Dateien passen zur Plattform; dynamisch gelinkte werden in --dynamic-out
    aufgelistet ("<pfad> <loader>"), damit der Aufrufer sie mit dem Loader des Images prüft
  - Config.User ist 65534:65534, Pflicht-Labels sind gesetzt

Nur Standardbibliothek; Ausgabe "ok …" / "FEHLER …", Exit-Code 1 bei Fehlern.
"""

import argparse
import fnmatch
import io
import json
import posixpath
import stat
import struct
import sys
import tarfile

SHELLS = {"sh", "bash", "dash", "ash", "zsh", "ksh", "mksh", "csh", "tcsh", "fish", "busybox"}
ELF_MACHINE = {"linux/amd64": 0x3E, "linux/arm64": 0xB7}
REQUIRED_LABELS = [
    "org.opencontainers.image.source",
    "org.opencontainers.image.version",
    "org.opencontainers.image.revision",
    "org.opencontainers.image.licenses",
    "org.opencontainers.image.base.name",
]
EXPECTED_USER = "65534:65534"
PT_INTERP, PT_DYNAMIC = 3, 2

errors = []


def fail(msg):
    errors.append(msg)
    print(f"FEHLER {msg}")


def ok(msg):
    print(f"ok     {msg}")


# --- Image lesen -----------------------------------------------------------------------


def open_image(path, platform):
    """(manifest_digest, manifest, config, blob) für eine Plattform eines OCI-Archivs."""
    outer = tarfile.open(path)

    def blob(digest):
        algo, hexd = digest.split(":", 1)
        return outer.extractfile(f"blobs/{algo}/{hexd}").read()

    want = tuple(platform.split("/"))

    def find(doc):
        for desc in doc.get("manifests", []):
            if desc.get("annotations", {}).get("vnd.docker.reference.type") == "attestation-manifest":
                continue
            plat = desc.get("platform")
            if plat and (plat.get("os"), plat.get("architecture")) != want:
                continue
            child = json.loads(blob(desc["digest"]))
            if "manifests" in child:
                found = find(child)
                if found:
                    return found
            elif "layers" in child:
                config = json.loads(blob(child["config"]["digest"]))
                if (config.get("os"), config.get("architecture")) == want:
                    return desc["digest"], child, config
        return None

    found = find(json.loads(outer.extractfile("index.json").read()))
    if not found:
        sys.exit(f"FEHLER kein Manifest für {platform} in {path}")
    digest, manifest, config = found
    return digest, manifest, config, blob


def load_image(path, platform):
    _, manifest, config, blob = open_image(path, platform)
    layers = [tarfile.open(fileobj=io.BytesIO(blob(l["digest"])), mode="r:*") for l in manifest["layers"]]
    return config, layers


def merge_layers(layers):
    """Pfad -> (TarFile, TarInfo) des obersten Eintrags, Whiteouts angewandt."""
    fs = {}

    def drop(prefix, keep_self):
        for p in [p for p in fs if p == prefix or p.startswith(prefix.rstrip("/") + "/")]:
            if not (keep_self and p == prefix):
                del fs[p]

    for layer in layers:
        members = layer.getmembers()
        for m in members:  # Whiteouts gelten nur für tiefere Schichten
            d, b = posixpath.split(posixpath.normpath("/" + m.name))
            if b == ".wh..wh..opq":
                drop(d, keep_self=True)
            elif b.startswith(".wh."):
                drop(posixpath.join(d, b[4:]), keep_self=False)
        for m in members:
            p = posixpath.normpath("/" + m.name)
            if p == "/" or posixpath.basename(p).startswith(".wh."):
                continue
            fs[p] = (layer, m)
    return fs


# --- Prüfungen -------------------------------------------------------------------------


def kind(m):
    if m.isdir():
        return "d"
    if m.issym():
        return "l"
    if m.isfile() or m.islnk():
        return "f"
    return "?"


def resolve(fs, path, depth=0):
    """Folgt Symlinks innerhalb des Image-Dateisystems; None, wenn das Ziel fehlt."""
    if depth > 40:
        return None
    parts = [p for p in path.split("/") if p]
    cur = "/"
    for i, part in enumerate(parts):
        nxt = posixpath.normpath(posixpath.join(cur, part))
        if nxt not in fs:
            return None
        _, m = fs[nxt]
        if m.issym():
            target = m.linkname if m.linkname.startswith("/") else posixpath.join(cur, m.linkname)
            rest = "/".join(parts[i + 1 :])
            return resolve(fs, posixpath.normpath(posixpath.join(target, rest)) if rest else posixpath.normpath(target), depth + 1)
        cur = nxt
    return cur


def read_expected(path, platform, seen=None):
    """Regeln (typ, muster, herkunft) für eine Plattform; folgt "include <image>"."""
    seen = seen if seen is not None else set()
    rules = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            parts = line.split("#", 1)[0].split()
            if not parts:
                continue
            if parts[0] == "include" and len(parts) == 2:
                inc = posixpath.normpath(posixpath.join(posixpath.dirname(path), "..", parts[1], "expected-files.txt"))
                if inc not in seen:
                    seen.add(inc)
                    rules += read_expected(inc, platform, seen)
            elif parts[0] in ("d", "f", "l") and len(parts) in (2, 3):
                if len(parts) == 3:
                    if not parts[2].startswith("@"):
                        sys.exit(f"FEHLER {path}:{n}: drittes Feld muss @<plattform> sein")
                    if parts[2][1:] != platform:
                        continue
                rules.append((parts[0], parts[1], f"{path}:{n}"))
            else:
                sys.exit(f"FEHLER {path}:{n}: unverständliche Zeile {line.strip()!r}")
    return rules


def elf_info(data):
    """(e_machine, interp|None, dynamisch) für 64-Bit-Little-Endian-ELF."""
    if data[4] != 2 or data[5] != 1:
        return None
    machine = struct.unpack_from("<H", data, 18)[0]
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    interp, dynamic = None, False
    for i in range(phnum):
        off = phoff + i * phentsize
        p_type = struct.unpack_from("<I", data, off)[0]
        if p_type == PT_DYNAMIC:
            dynamic = True
        elif p_type == PT_INTERP:
            p_offset = struct.unpack_from("<Q", data, off + 8)[0]
            p_filesz = struct.unpack_from("<Q", data, off + 32)[0]
            interp = data[p_offset : p_offset + p_filesz].rstrip(b"\0").decode()
    return machine, interp, dynamic


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tar")
    ap.add_argument("platform")
    ap.add_argument("expected", nargs="+")
    ap.add_argument("--allow-shell", action="store_true")
    ap.add_argument("--dynamic-out")
    args = ap.parse_args()

    config, layers = load_image(args.tar, args.platform)
    fs = merge_layers(layers)

    # Konfiguration
    cfg = config.get("config", {})
    if cfg.get("User") == EXPECTED_USER:
        ok(f"Config.User = {EXPECTED_USER}")
    else:
        fail(f"Config.User = {cfg.get('User')!r}, erwartet {EXPECTED_USER}")
    labels = cfg.get("Labels") or {}
    missing = [l for l in REQUIRED_LABELS if not labels.get(l)]
    if missing:
        fail(f"Labels fehlen oder leer: {', '.join(missing)}")
    else:
        ok("OCI-Labels gesetzt")

    # Inhalt exakt wie erwartet
    rules = [r for e in args.expected for r in read_expected(e, args.platform)]
    hits = {r: 0 for r in rules}
    unexpected = []
    for path, (_, m) in sorted(fs.items()):
        k = kind(m)
        matched = [r for r in rules if r[0] == k and fnmatch.fnmatchcase(path, r[1])]
        for r in matched:
            hits[r] += 1
        if not matched:
            unexpected.append(f"{k} {path}")
    for u in unexpected:
        fail(f"nicht erlaubt: {u}")
    for r, n in hits.items():
        if n == 0:
            fail(f"fehlt: {r[0]} {r[1]} ({r[2]})")
    if not unexpected and all(hits.values()):
        ok(f"Inhalt entspricht {' + '.join(posixpath.basename(e) for e in args.expected)} ({len(fs)} Einträge)")

    # Eigentum, Rechte, Typen, Symlinks, Shells, ELF
    n_err = len(errors)
    dynamic = []
    machine_want = ELF_MACHINE[args.platform]
    for path, (layer, m) in sorted(fs.items()):
        if (m.uid, m.gid) != (0, 0):
            fail(f"{path} gehört {m.uid}:{m.gid}")
        if m.mode & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX):
            fail(f"{path} hat setuid/setgid/sticky (Modus {m.mode:o})")
        if not m.issym() and m.mode & 0o022:
            fail(f"{path} ist für Gruppe/andere schreibbar (Modus {m.mode:o})")
        if kind(m) == "?":
            fail(f"{path} ist weder Datei, Verzeichnis noch Symlink")
        if m.issym() and resolve(fs, path) is None:
            fail(f"hängender Symlink: {path} -> {m.linkname}")
        if m.islnk() and posixpath.normpath("/" + m.linkname) not in fs:
            fail(f"Hardlink ohne Ziel: {path} -> {m.linkname}")
        if posixpath.basename(path) in SHELLS and not args.allow_shell:
            fail(f"Shell im Image: {path}")
        if m.isfile():
            data = layer.extractfile(m).read()
            if data[:4] == b"\x7fELF":
                info = elf_info(data)
                if info is None:
                    fail(f"{path}: ELF-Format nicht unterstützt")
                    continue
                machine, interp, is_dyn = info
                if machine != machine_want:
                    fail(f"{path}: ELF für falsche Architektur (e_machine 0x{machine:x})")
                if interp:
                    dynamic.append((path, interp))
                    if resolve(fs, interp) is None:
                        fail(f"{path}: Loader {interp} fehlt")
                elif is_dyn:
                    dynamic.append((path, ""))
    if len(errors) == n_err:
        ok("Eigentum 0:0, keine schreibbaren Einträge, keine Sonderbits, keine hängenden Symlinks")
        ok("keine Shell" if not args.allow_shell else "Shell erlaubt (-debug)")
    ok(f"{len(dynamic)} dynamisch gelinkte ELF-Dateien")

    if args.dynamic_out:
        with open(args.dynamic_out, "w") as f:
            for path, interp in dynamic:
                f.write(f"{path} {interp}\n")

    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
