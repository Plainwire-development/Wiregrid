#!/usr/bin/env python3
from pathlib import Path
import re, sys
root=Path(__file__).resolve().parent.parent
proto=(root/'lib/wiregrid/foreign/protocol.ex').read_text()
header=(root/'native/c/include/wiregrid.h').read_text()
csrc=(root/'native/c/src/wiregrid.c').read_text()

def die(msg):
    print('foreign-check:',msg,file=sys.stderr); raise SystemExit(1)

m=re.search(r'@version\s+(\d+)',proto)
if not m: die('missing Elixir protocol version')
version=int(m.group(1))
h=re.search(r'#define\s+WG_PROTOCOL_VERSION\s+(\d+)',header)
if not h or int(h.group(1))!=version: die('protocol version mismatch')

ops=dict(re.findall(r'^\s*([a-z_]+):\s*(\d+),?$', re.search(r'@ops\s+%\{(.*?)\n\s*\}', proto, re.S).group(1), re.M))
fields=dict(re.findall(r'^\s*([a-z_]+):\s*(\d+),?$', re.search(r'@fields\s+%\{(.*?)\n\s*\}', proto, re.S).group(1), re.M))
for name,value in ops.items():
    macro='WG_OP_'+name.upper()
    cm=re.search(r'#define\s+'+re.escape(macro)+r'\s+(\d+)',csrc)
    if not cm or cm.group(1)!=value: die(f'operation mismatch: {name}')
for name,value in fields.items():
    macro='WG_F_'+name.upper()
    cm=re.search(r'#define\s+'+re.escape(macro)+r'\s+(\d+)',csrc)
    if not cm or cm.group(1)!=value: die(f'field mismatch: {name}')

if len(set(ops.values())) != len(ops): die('duplicate operation id')
if len(set(fields.values())) != len(fields): die('duplicate field id')
print(f'foreign-check: ok (protocol {version}, {len(ops)} ops, {len(fields)} fields)')
