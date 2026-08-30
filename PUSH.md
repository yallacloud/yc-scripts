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

Run the self-check that ships with it:

```powershell
powershell -ExecutionPolicy Bypass -File .\test-activate.ps1
```

It must print `RESULT: PASS`. A payload that fails the gate must not be pushed -
every VM built after the push pulls it on first boot.

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
