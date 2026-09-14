# Maintaining this repo

The repo is **public**. That is deliberate and must stay that way: guests download
the payload with no credentials, so a private repo breaks every sealed template.
See "Why this repo is public" in README.md.

## The update loop

Everything a VM sees is these two files. Nothing else ever changes - not the URL,
not the cloud-init user data, not the sealed templates.

    YallaCloud-CScripts-latest.zip
    YallaCloud-CScripts-latest.sha256

To publish a new payload:

```bash
./build-payload.sh /path/to/Scripts     # rebuilds the zip + sha sidecar
git commit -am "payload $(date +%F)"
git push
```

`build-payload.sh` keeps the filename fixed on purpose and writes the zip FLAT
(scripts at the zip root, not under a `Scripts/` folder) because
`Update-YcScripts.ps1` copies the extract root into `C:\Scripts`.

## Before pushing a payload

### 1. Prove you are not publishing a secret

    python3 scan-secrets.py

**This repo is PUBLIC.** Guests fetch the payload over plain HTTPS with no credential, so
anything committed here is world-readable forever and stays in the git history after it is
deleted. The scanner must exit 0.

What it allows, and why: Microsoft-published **GVLK** client keys are public by design and
the licensing table needs them. Everything else that looks like a product key is a finding.

What must NEVER be committed:

- **SQL Server MAKs.** They live in the estate key store and are pasted into the build
  userdata per build. The builder userdata itself is not in this repo for the same reason -
  it also carries the webhook secret.
- **Windows MAKs.** Same rule. The GVLKs in `_yc-licensing.ps1` are not MAKs.
- Any password, API key, bearer token, webhook secret or private key.
- The firewall `chadmin` password and the OPNsense API key/secret - these are YallaCloud's
  own standing estate credentials and belong in no document at all.

A finding is not automatically a leak - read each one and decide. The point is that nobody
pushes without having looked.

### 2. Run the payload's own self-check


```powershell
powershell -ExecutionPolicy Bypass -File .\test-activate.ps1
powershell -ExecutionPolicy Bypass -File .\Yc-VmBuild.ps1 -SelfCheck
```

It must end with `all checks passed` and no `FAIL` line. A payload that fails the
gate must not be pushed - every VM built after the push pulls it on first boot.

Run it on a Windows guest, not on the build host: the script exercises PowerShell
5.1 behaviour and the licensing shapes, so a Linux checkout cannot execute it.

## After pushing

Confirm both URLs answer anonymously - log out, or use a private window:

    https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.zip
    https://raw.githubusercontent.com/yallacloud/yc-scripts/main/YallaCloud-CScripts-latest.sha256

`raw.githubusercontent.com` caches for roughly 5 minutes. A VM deployed inside
that window still gets the previous payload. Wait it out before deploying if the
change matters.

## Push credentials

Pushing needs a fine-grained PAT scoped to this repository only, with
`Contents: Read and write`. It is stored on the maintainer's machine and read at
run time. It is never committed here, never written into a script, and never
placed on a VM - the download side of this repo uses no credential at all, so
revoking the token cannot break a deployed VM or a sealed template.

## One-time, on the template side

Bake `userdata-yc-deploy-fixes.txt` into the templates as the cloud-init user data.
It is frozen: two constant URLs, no hash, no credential. It never needs editing again.
