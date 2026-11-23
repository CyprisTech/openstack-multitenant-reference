#!/usr/bin/env python3
"""Documentation links check: every relative link and anchor resolves, and every Markdown page
is reachable from README.md. Exits with status 1 otherwise. Run from the repository root."""

import glob
import os
import re
import sys

CODE = re.compile(r"```.*?```", re.S)
files = [f for f in glob.glob("**/*.md", recursive=True)
         if not f.startswith((".terraform", "node_modules")) and "/.terraform/" not in f]


def slug(heading):
    """The anchor GitHub gives a heading."""
    h = heading.strip().lower()
    h = re.sub(r"[`*]", "", h)
    h = re.sub(r"[^\w\- ]", "", h)
    return h.replace(" ", "-")


def text(path):
    """A page without its code blocks."""
    with open(path) as page:
        return CODE.sub("", page.read())


anchors = {f: {slug(m) for m in re.findall(r"^#+ (.+)$", text(f), re.M)} for f in files}
links = {}
broken = []
for f in files:
    out = set()
    for target in re.findall(r"\]\(([^)\s]+)\)", text(f)):
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        path, _, anchor = target.partition("#")
        resolved = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else f
        if path and not os.path.exists(resolved):
            broken.append((f, target, "missing file"))
            continue
        if os.path.isdir(resolved) and os.path.exists(os.path.join(resolved, "README.md")):
            resolved = os.path.join(resolved, "README.md")
        if anchor and resolved.endswith(".md") and anchor not in anchors.get(resolved, set()):
            broken.append((f, target, "missing anchor"))
        if resolved.endswith(".md"):
            out.add(resolved)
    links[f] = out

seen = set()
stack = ["README.md"]
while stack:
    f = stack.pop()
    if f in seen:
        continue
    seen.add(f)
    stack.extend(links.get(f, ()))
unreachable = sorted(set(files) - seen)

for f, target, why in broken:
    print(f"{f}: {target}: {why}")
for f in unreachable:
    print(f"{f}: not reachable from README.md")
print(f"{len(files)} pages, {len(broken)} broken links, {len(unreachable)} unreachable pages")
sys.exit(1 if broken or unreachable else 0)
