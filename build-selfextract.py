#!/usr/bin/env python3
"""Rebuild Extract-YcScripts.ps1 around a new payload zip.

Wire format (must match the decryptor in the .ps1):
    'YCS1' | salt[16] | iv[16] | hmac[32] | ciphertext
    key material = PBKDF2-HMAC-SHA1(pass, salt, 200000) -> 64 bytes
                   [0:32] AES-256 key, [32:64] HMAC-SHA256 key
    hmac covers blob[0:36] + ciphertext
"""
import base64, hashlib, hmac, os, re, sys, io
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

zip_path, tpl_path, out_path, password = sys.argv[1:5]

data = open(zip_path,'rb').read()
zsha = hashlib.sha256(data).hexdigest().upper()

salt, iv = os.urandom(16), os.urandom(16)
dk  = hashlib.pbkdf2_hmac('sha1', password.encode('utf-8'), salt, 200000, 64)
key, mk = dk[:32], dk[32:]

pad = 16 - (len(data) % 16)
enc = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
ct  = enc.update(data + bytes([pad])*pad) + enc.finalize()

head = b'YCS1' + salt + iv
mac  = hmac.new(mk, head + ct, hashlib.sha256).digest()
blob = head + mac + ct
b64  = base64.b64encode(blob).decode('ascii')

s = io.open(tpl_path, encoding='ascii').read()
s = re.sub(r"(\$ExpectedZipSha = ')[0-9A-F]{64}(')", r"\g<1>"+zsha+r"\g<2>", s, count=1)
lines = s.split('\n')
hits = [i for i,l in enumerate(lines) if len(l) > 500]
assert len(hits) == 1, f"expected exactly one blob line, found {len(hits)}"
lines[hits[0]] = b64
io.open(out_path,'w',encoding='ascii',newline='\r\n').write('\n'.join(lines))
print(f"zip {len(data)} bytes  sha {zsha}")
print(f"blob {len(blob)} bytes -> {out_path} ({os.path.getsize(out_path)} bytes)")
