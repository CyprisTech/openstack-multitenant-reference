#!/usr/bin/env python3
"""Documentation links check: every relative link and anchor resolves, and every Markdown page
is reachable from README.md. Exits with status 1 otherwise. Run from the repository root."""
import re, os, glob, sys
root='.'
files=[f for f in glob.glob('**/*.md',recursive=True) if not f.startswith(('.terraform','node_modules')) and '/.terraform/' not in f]
def slug(h):
    h=h.strip().lower()
    h=re.sub(r'[`*]','',h)
    h=re.sub(r'[^\w\- ]','',h)
    return h.replace(' ','-')
anchors={}
for f in files:
    txt=open(f).read()
    txt_nc=re.sub(r'```.*?```','',txt,flags=re.S)
    anchors[f]={slug(m) for m in re.findall(r'^#+ (.+)$',txt_nc,re.M)}
links={}
broken=[]
for f in files:
    txt=re.sub(r'```.*?```','',open(f).read(),flags=re.S)
    out=set()
    for t in re.findall(r'\]\(([^)\s]+)\)',txt):
        if t.startswith(('http://','https://','mailto:')): continue
        path,_,anc=t.partition('#')
        tgt=os.path.normpath(os.path.join(os.path.dirname(f),path)) if path else f
        if path and not os.path.exists(tgt):
            broken.append((f,t,'missing file')); continue
        if os.path.isdir(tgt):
            for c in ('README.md',):
                if os.path.exists(os.path.join(tgt,c)): tgt=os.path.join(tgt,c)
        if anc and tgt.endswith('.md') and anc not in anchors.get(tgt,set()):
            broken.append((f,t,'missing anchor'))
        if tgt.endswith('.md'): out.add(tgt)
    links[f]=out
seen=set(); stack=['README.md']
while stack:
    f=stack.pop()
    if f in seen: continue
    seen.add(f); stack.extend(links.get(f,()))
unreachable=sorted(set(files)-seen)
for f,t,why in broken: print(f"{f}: {t}: {why}")
for f in unreachable: print(f"{f}: not reachable from README.md")
print(f"{len(files)} pages, {len(broken)} broken links, {len(unreachable)} unreachable pages")
sys.exit(1 if broken or unreachable else 0)
