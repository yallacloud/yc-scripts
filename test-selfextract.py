#!/usr/bin/env python3
"""Round-trip the built self-extractor exactly as the PowerShell decryptor does."""
import base64, hashlib, hmac, re, io, sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

ps1, zip_path, password = sys.argv[1:4]
s = io.open(ps1, encoding='ascii').read()

sha = re.search(r"\$ExpectedZipSha = '([0-9A-F]{64})'", s).group(1)
b64 = [l for l in s.split('\n') if len(l) > 500]
assert len(b64) == 1, "blob line not unique"
blob = base64.b64decode(b64[0])

def decrypt(blob, pw):
    assert blob[:4] == b'YCS1', 'bad magic'
    salt, iv, mac, ct = blob[4:20], blob[20:36], blob[36:68], blob[68:]
    dk = hashlib.pbkdf2_hmac('sha1', pw.encode(), salt, 200000, 64)
    calc = hmac.new(dk[32:], blob[:36] + ct, hashlib.sha256).digest()
    if not hmac.compare_digest(calc, mac):
        raise ValueError('Wrong password, or the file has been altered in transit.')
    d = Cipher(algorithms.AES(dk[:32]), modes.CBC(iv)).decryptor()
    p = d.update(ct) + d.finalize()
    return p[:-p[-1]]

out = decrypt(blob, password)
orig = open(zip_path,'rb').read()
assert out == orig, 'FAIL: decrypted bytes differ from the source zip'
assert hashlib.sha256(out).hexdigest().upper() == sha, 'FAIL: $ExpectedZipSha does not match'
print(f'[OK] correct password -> {len(out)} bytes, byte-identical to the source zip')
print(f'[OK] $ExpectedZipSha matches the decrypted zip')

try:
    decrypt(blob, password + 'x')
    print('[FAIL] a wrong password was accepted'); sys.exit(1)
except ValueError as e:
    print(f'[OK] wrong password rejected at the MAC: {e}')

tampered = bytearray(blob); tampered[-1] ^= 0xFF
try:
    decrypt(bytes(tampered), password)
    print('[FAIL] tampering was accepted'); sys.exit(1)
except ValueError:
    print('[OK] a flipped ciphertext bit is rejected at the MAC')

import zipfile, io as _io
z = zipfile.ZipFile(_io.BytesIO(out))
print(f'[OK] archive opens: {len(z.namelist())} files, testzip {z.testzip() or "clean"}')
print('RESULT: PASS')
