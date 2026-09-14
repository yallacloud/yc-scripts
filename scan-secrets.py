#!/usr/bin/env python3
"""Refuse to publish a secret. yc-scripts is PUBLIC: guests fetch the payload with no
credential, so anything committed here is world-readable forever.

Microsoft-published GVLK client keys are allowed - they are public by design and the
licensing table needs them. EVERY OTHER product key is a finding: MAKs live in the
estate key store and are pasted per build, never committed.

Findings are not automatically leaks - read each one and decide. The point is that
nobody gets to push without having looked."""
import os,re,sys
# Run from the repo root, or pass directories:  python3 scan-secrets.py [dir ...]
# Exits 1 if anything needs a human verdict, so it can gate a push.
ROOTS = sys.argv[1:] or [os.path.dirname(os.path.abspath(__file__))]
SKIP_DIR={'.git'}
SKIP_EXT={'.zip','.png','.jpg','.exe','.dll','.iso','.gz'}

# Microsoft-PUBLISHED GVLK client keys are public by design and are allowed.
GVLK=set("""TVRH6-WHNXV-R9WG3-9XRFY-MY832 D764K-2NDRG-47T6Q-P8T8W-YP6DF XGN3F-F394H-FD2MY-PP6FD-8MCRC
VDYBN-27WPP-V4HQT-9VMD4-VMK7H WX4NM-KYWYW-QJJR4-XV3QB-6VM33 NTBV8-9K7Q8-V27C6-M2BTV-KHMXV
N69G4-B89J2-4G8F4-WWYCC-J464C WMDGN-G9PQG-XVVXX-R3X43-63DFG WVDHN-86M7X-466P6-VHXV7-YY726
WC2BQ-8NRM3-FDDYY-2BFGV-KHKQY CB7KF-BWN84-R7R2Y-793K2-8XDDG D2N9P-3P6X9-2R39C-7RTCD-MDVJX
W3GGN-FT8W3-Y4M27-J84CP-Q3VJ9""".split())
PLACEHOLDER=re.compile(r'^(X{5}|A{5}|ABCDE|AAAAA|00000|11111)',re.I)

KEY=re.compile(r'\b[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}\b')
RULES=[
 ('PRIVATE KEY',      re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY')),
 ('assigned password',re.compile(r'(?i)\b(?:password|passwd|pwd|secret|apikey|api_key|token)\s*=\s*["\']([^"\'\s]{8,})["\']')),
 ('bearer token',     re.compile(r'(?i)bearer\s+[A-Za-z0-9._\-]{20,}')),
 ('long hex secret',  re.compile(r'\b[0-9a-f]{40,}\b')),
 ('AWS key id',       re.compile(r'\bAKIA[0-9A-Z]{16}\b')),
 ('github PAT',       re.compile(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b')),
 ('private IPv4',     re.compile(r'\b(?:10\.15\.|10\.61\.|10\.10\.200\.)\d{1,3}\.?\d{0,3}\b')),
]
ALLOW_HEX=re.compile(r'(?i)(sha\d*|hash|digest|checksum|thumbprint|fingerprint|manifest|ExpectHash|[0-9A-F]{64}\s+\S+\.zip)')

hits={}
def add(cat,path,ln,txt):
    hits.setdefault(cat,[]).append((path,ln,txt.strip()[:130]))

for root in ROOTS:
    for dp,dns,fns in os.walk(root):
        dns[:]=[d for d in dns if d not in SKIP_DIR]
        for fn in fns:
            if os.path.splitext(fn)[1].lower() in SKIP_EXT: continue
            p=os.path.join(dp,fn)
            try: t=open(p,encoding='utf-8',errors='replace').read()
            except Exception: continue
            for i,line in enumerate(t.splitlines(),1):
                for k in KEY.findall(line):
                    if k in GVLK or PLACEHOLDER.match(k): continue
                    add('PRODUCT KEY (non-GVLK)',p,i,line)
                for cat,rx in RULES:
                    m=rx.search(line)
                    if not m: continue
                    if cat=='long hex secret' and ALLOW_HEX.search(line): continue
                    if cat=='assigned password':
                        v=m.group(1)
                        if re.match(r'^(\$|<|PUT-|CHANGE|auto$|\.\\|C:\\|/|https?:)',v) or v.lower() in ('true','false','none',''): continue
                        if '$' in v: continue
                    add(cat,p,i,line)

if not hits:
    print("CLEAN - nothing found"); sys.exit(0)
for cat,rows in hits.items():
    print("=== %s : %d ===" % (cat,len(rows)))
    seen=set()
    for p,ln,txt in rows[:14]:
        k=(p,txt)
        if k in seen: continue
        seen.add(k)
        print("  %s:%d  %s" % (p.replace('/tmp/kit','[payload]').replace('/home/claude/yc-scripts','[repo]'),ln,txt))
    if len(rows)>14: print("  ... %d more" % (len(rows)-14))
print()
print("%d finding(s) need a verdict. Nothing is published until each one is explained." % sum(len(v) for v in hits.values()))
sys.exit(1)
