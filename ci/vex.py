#!/usr/bin/env python3
"""CycloneDX-VEX der Fabrik anwenden.

In images/<name>/vex.json verweist affects[].ref auf ein Paket per purl ohne
Qualifier, z. B. "pkg:deb/debian/libc6@2.41-12+deb13u4" (gilt nur für diese
Version) oder "pkg:deb/debian/libc6" (gilt für jede Version – nur mit Begründung).

  vex.py gate <vex.json> <trivy.json> [--fail-on CRITICAL,HIGH] [--report-only]
      Wendet die VEX-Bewertungen auf einen Trivy-JSON-Report an. Befunde mit
      analysis.state not_affected oder false_positive gelten als bewertet.
      Exit 1, wenn ein unbewerteter Befund der genannten Schweregrade bleibt;
      mit --report-only werden solche Befunde nur gemeldet (für -debug).

  vex.py resolve <vex.json> <sbom.cdx.json>
      Gibt die VEX mit BOM-Links (urn:cdx:<serial>/<version>#<bom-ref>) auf genau
      diese SBOM aus, damit SBOM und VEX als Paar attestiert werden können.

Nur Standardbibliothek.
"""

import argparse
import json
import sys
import urllib.parse

SUPPRESSING = {"not_affected", "false_positive"}


def purl_key(purl):
    """(typ/namespace/name, version|None) ohne Qualifier, URL-dekodiert.

    Die Debian-Epoche steht bei syft in der Version ("1:1.37.0"), bei trivy im
    Qualifier "epoch=1"; beides ergibt dieselbe Version.
    """
    base, _, rest = purl.partition("?")
    base = base.split("#", 1)[0]
    qualifiers = urllib.parse.parse_qs(rest.split("#", 1)[0])
    name, _, version = base.partition("@")
    version = urllib.parse.unquote(version)
    epoch = qualifiers.get("epoch", [""])[0]
    if version and epoch and ":" not in version:
        version = f"{epoch}:{version}"
    return urllib.parse.unquote(name), (version or None)


def matches(ref, purl):
    want_name, want_ver = purl_key(ref)
    got_name, got_ver = purl_key(purl)
    return want_name == got_name and (want_ver is None or want_ver == got_ver)


def load(path):
    with open(path) as f:
        return json.load(f)


def gate(args):
    vex = load(args.vex).get("vulnerabilities", [])
    report = load(args.trivy)
    fail_on = set(args.fail_on.split(","))
    open_findings, assessed, counts = [], [], {}
    for result in report.get("Results") or []:
        for v in result.get("Vulnerabilities") or []:
            purl = (v.get("PkgIdentifier") or {}).get("PURL", "")
            sev = v.get("Severity", "UNKNOWN")
            counts[sev] = counts.get(sev, 0) + 1
            hit = next(
                (e for e in vex
                 if e.get("id") == v["VulnerabilityID"]
                 and e.get("analysis", {}).get("state") in SUPPRESSING
                 and any(matches(a.get("ref", ""), purl) for a in e.get("affects", []))),
                None,
            )
            line = f"{sev:8} {v['VulnerabilityID']:18} {v.get('PkgName')} {v.get('InstalledVersion')}"
            if hit:
                assessed.append(f"{line}  -> VEX: {hit['analysis']['state']}")
            elif sev in fail_on:
                open_findings.append(line)

    summary = ", ".join(f"{k}={counts[k]}" for k in sorted(counts)) or "keine"
    print(f"Befunde: {summary}")
    for line in assessed:
        print(f"bewertet {line}")
    for line in open_findings:
        print(f"{'GEMELDET' if args.report_only else 'OFFEN   '} {line}")
    if open_findings and args.report_only:
        print(f"ok     {len(open_findings)} unbewertete Befunde ({args.fail_on}) nur gemeldet")
        return
    if open_findings:
        print(f"FEHLER {len(open_findings)} unbewertete Befunde ({args.fail_on}); in vex.json bewerten oder beheben")
        sys.exit(1)
    print(f"ok     keine unbewerteten Befunde ({args.fail_on})")


def resolve(args):
    vex = load(args.vex)
    sbom = load(args.sbom)
    serial = sbom["serialNumber"].removeprefix("urn:uuid:")
    prefix = f"urn:cdx:{serial}/{sbom.get('version', 1)}#"
    components = [c for c in sbom.get("components", []) if c.get("purl")]
    resolved = []
    for e in vex.get("vulnerabilities", []):
        refs = [
            {"ref": prefix + c["bom-ref"]}
            for a in e.get("affects", [])
            for c in components
            if matches(a.get("ref", ""), c["purl"])
        ]
        if refs:
            resolved.append({**e, "affects": refs})
    out = {k: v for k, v in vex.items() if k != "vulnerabilities"}
    out["vulnerabilities"] = resolved
    json.dump(out, sys.stdout, indent=2)
    print()


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gate")
    g.add_argument("vex")
    g.add_argument("trivy")
    g.add_argument("--fail-on", default="CRITICAL,HIGH")
    g.add_argument("--report-only", action="store_true")
    r = sub.add_parser("resolve")
    r.add_argument("vex")
    r.add_argument("sbom")
    args = ap.parse_args()
    {"gate": gate, "resolve": resolve}[args.cmd](args)


if __name__ == "__main__":
    main()
