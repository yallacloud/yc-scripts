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

## Userdata (cloud-init) - minimal

cloud-init writes `/etc/yallacloud/nextcloud.conf` and a start hook that fetches this
script from raw GitHub and runs it. See `yc-nc-userdata.yaml.example`.
