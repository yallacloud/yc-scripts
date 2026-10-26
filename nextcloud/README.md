# YallaCloud Nextcloud installer

Self-contained manual/userdata installer for Nextcloud on Ubuntu 24.04 LTS.

- `yc-nextcloud-install.sh` - the installer. Run as root, or embed/fetch via CloudStack userdata.
- Config: either edit the CONFIG block at the top, OR provide `/etc/yallacloud/nextcloud.conf`
  (KEY=value, no spaces) which the script sources and which OVERRIDES the CONFIG block.

## Tarball source (no download.nextcloud.com needed)

The 262 MB server tarball is published as a GitHub **release asset** on this repo:

    https://github.com/yallacloud/yc-scripts/releases/download/nc-latest/latest.tar.bz2
    https://github.com/yallacloud/yc-scripts/releases/download/nc-latest/latest.tar.bz2.sha256

Set `TARBALL_URL` to the release base and the installer pulls both over HTTPS
(verified against the sha256), skipping download.nextcloud.com:

    TARBALL_URL=https://github.com/yallacloud/yc-scripts/releases/download/nc-latest

## Userdata (cloud-init)

`yc-nextcloud-cloudinit.yaml` is the one cloud-init to paste at VM creation. Edit only the
"EDIT THESE" block (nothing is required; blank FQDN = sslip.io name). It writes
`/etc/yallacloud/nextcloud.conf`, fetches this installer from raw GitHub and runs it.

The helper commands (`yc-nc-ssl`, `yc-nc-domain`, `yc-nc-backup`, `yc-nc-datadisk`, `yallacloud`)
are embedded in the installer and written to `/usr/local/bin` on the VM - edit them there, not
as separate files.

## Notifications

- ntfy: status only, house format (`START / OK / FAILED BUILD nextcloud - <host>`), never secrets.
- ERP webhook: YC-EVENT v2 sections (`schema`, `vm`, `cloud`, `service`, `credentials`) plus the
  v1 top-level keys (STACK4-63 phase 1). Secrets only in `credentials`, only on `vm.deploy.completed`.
  A root-only copy of each event sent, and the ERP reply, is kept in `/root/yc-webhook-<event>.json|.resp`.

Guide: STACK4-60 Nextcloud Deployment - Auto and Manual.
