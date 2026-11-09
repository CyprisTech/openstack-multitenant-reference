#!/usr/bin/env python3
"""Make an asciinema recording of a campaign publishable.

Replaces addresses outside the cluster networks (10.0.0.0/8) with documentation addresses
(RFC 5737), consistently within a file, and applies the --replace pairs. Terminal chunks are merged
up to the end of a line first, so that an address cut between two chunks is still found. The result
is checked: the script fails if an address or a --forbid word remains.

    tests/campaign/sanitize-cast.py input.cast output.cast [--replace real=example ...] [--forbid word ...]
"""

import argparse
import ipaddress
import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tour"))
from capture import DOC_RANGES, Sanitizer  # noqa: E402

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07")
ADDRESS = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")


def merged(events):
    current = None
    for time, kind, data in events:
        if current and kind == current[1] and not current[2].endswith("\n"):
            current[2] += data
            continue
        if current:
            yield current
        current = [time, kind, data]
    if current:
        yield current


def leaks(text, forbidden):
    found = {w for w in forbidden if w.lower() in text.lower()}
    for match in ADDRESS.findall(text):
        try:
            ip = ipaddress.ip_address(match)
        except ValueError:
            continue
        if not (ip in ipaddress.ip_network("10.0.0.0/8") or ip.is_loopback or ip.is_unspecified or any(ip in n for n in DOC_RANGES)):
            found.add(match)
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--replace", action="append", default=[], help="real=example, applied before addresses")
    ap.add_argument("--forbid", action="append", default=[], help="word that must not remain")
    args = ap.parse_args()
    clean = Sanitizer([tuple(r.split("=", 1)) for r in args.replace])

    lines = pathlib.Path(args.input).read_text().splitlines()
    header = json.loads(lines[0])
    header.pop("env", None)
    events = [[e[0], e[1], clean(e[2])] for e in merged(json.loads(line) for line in lines[1:])]
    remaining = leaks(ANSI.sub("", "".join(e[2] for e in events)), args.forbid)
    if remaining:
        sys.exit(f"not written, still present: {', '.join(sorted(remaining))}")
    with open(args.output, "w") as f:
        f.write(json.dumps(header) + "\n")
        for event in events:
            f.write(json.dumps(event) + "\n")


if __name__ == "__main__":
    main()
