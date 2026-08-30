# yc-scripts

The `C:\Scripts` payload for YallaCloud Windows Server templates (2016-2025).

Every VM built from a YallaCloud template pulls this on first boot via cloud-init
and replaces its `C:\Scripts` with it. That is the whole purpose of this repo:
the template ships whatever it was sealed with, and this is what makes a freshly
deployed VM current.

## Files

| File | What it is |
|---|---|
| `YallaCloud-CScripts-latest.zip` | The payload. Filename is FIXED and must never change. |
| `YallaCloud-CScripts-latest.sha256` | Its SHA256. Fetched at run time, so nothing else has to change. |
| `Update-YcScripts.ps1` | Reference copy of the installer that consumes the two files above. Also ships inside the zip. |
| `Extract-YcScripts.ps1` | The same payload, AES-256 encrypted, for handing to someone off this repo. Password-protected; see below. |

**Zip layout is FLAT** - the scripts sit at the zip root, not under a `Scripts/`
folder. `Update-YcScripts.ps1` copies the extract root into `C:\Scripts`, so a
nested folder lands everything one level too deep. Manual restore is therefore
`Expand-Archive -DestinationPath C:\Scripts`, not `C:\`.

## The encrypted copy

`Extract-YcScripts.ps1` carries the same payload AES-256 encrypted, for the times it has to
travel by a route that is not this repo.

**It is a script, not a zip, and that is deliberate.** Windows PowerShell 5.1 cannot open a
password-protected zip: `Expand-Archive` has no password parameter and
`System.IO.Compression.ZipFile` does not implement the decryption. A `.zip` encrypted with
WinZip AES would need 7-Zip installed on the target, and a freshly deployed Server 2016 has
nothing. So the archive carries its own decryptor:

```powershell
powershell -ExecutionPolicy Bypass -File .\Extract-YcScripts.ps1
```

It prompts for the password (masked), extracts to `C:\Scripts`, and needs nothing installed.
`-Destination D:\Staging` extracts somewhere else to inspect first; `-SaveZipOnly` just writes
the plain zip.

Crypto: PBKDF2-HMAC-SHA1 200,000 rounds to a 64-byte key (AES-256-CBC + a separate
HMAC-SHA256 key), 16-byte random salt. The MAC is checked **before** any decryption, so a wrong
password or a tampered file fails cleanly instead of producing rubbish. PBKDF2-HMAC-SHA1 is not
an upgrade oversight: Server 2016 ships .NET 4.6.2, where `Rfc2898DeriveBytes` has no SHA256
overload.

**The password is not in this repo and never will be.** It travels by a different route than
the download. Rebuild with `build-selfextract.py`; `test-selfextract.py` round-trips it and
proves a wrong password and a flipped bit are both rejected.

## Why this repo is public

The guests download with **no credentials**. A token would have to sit on every
public-facing Windows server, could be revoked or expire, and would grant read to
the whole repo. That is a moving part in something that must not need touching.

The payload was scanned before publishing: no keys, no credentials, no public IPs.
The only internal reference was a set of `source_url` fields in `MANIFEST.json`
pointing at a build host that is not reachable from the deployment range anyway.
Those were removed. The remaining `10.0.0.x` / `10.20.0.x` strings are usage
examples in help text.

## Updating the payload

Push two files. Nothing else - not the URL, not the cloud-init user data, not the
templates.

```
1. Rebuild YallaCloud-CScripts-latest.zip     (keep the filename EXACTLY)
2. sha256sum -> YallaCloud-CScripts-latest.sha256
3. git commit -am "payload YYYY-MM-DD" && git push
```

`raw.githubusercontent.com` caches for roughly 5 minutes. A VM deployed inside that
window can still get the previous payload. If that matters, wait 5 minutes before
deploying.

## What the guests fetch

```
https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip
https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256
```

Both URLs are permanent. They are baked into the sealed templates.

## Integrity, honestly

The `.sha256` sidecar catches a truncated or corrupted download and proves the zip
and hash came from the same push. It is **not** tamper protection: anyone who can
write to this repo can write both files. What protects this payload is who has
write access here. Keep that list short.

`Update-YcScripts.ps1` verifies the hash, then does a FULL OVERWRITE: every file
in `C:\Scripts` that is not in this payload is deleted, so a script removed from
the payload disappears from the VM instead of lingering as a stale command on the
PATH.

**No backup is kept.** Nothing named `C:\Scripts.bak-*` is ever created. A rollback
copy is staged in `%windir%\Temp` for the duration of the run and deleted at the
end, pass or fail - so the gate can still roll back a rejected payload, but nothing
accumulates on the VM.

Three directories are kept by default, named in `-Keep`:

    virtio  Sysinternals  DiagTools

They hold vendor binaries and drivers - roughly 1.7 GB - that this payload
deliberately does not ship. Deleting them is NOT recoverable from a 737 KB zip.
Pass `-Keep @()` to wipe `C:\Scripts` completely and leave only the payload.
