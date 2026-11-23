#!/bin/bash
#
# Build a fresh Ubuntu 26.04 IPT host. Written 2026-11-23 to replace the 20.04
# inst_ipt_live; re-runnable, and the record of how the host is put together.
#
# Run ON THE NEW SERVER, from a clone of this repo at ~/val_ipt (the crontab
# and docs assume that path):
#     git clone https://github.com/VtEcostudies/VAL_ipt_docker.git ~/val_ipt
#     ~/val_ipt/14_install_new_server.sh            # status: what is / isn't done
#     ~/val_ipt/14_install_new_server.sh --apply    # do the missing steps
#
# WHAT IT INSTALLS (each step checks first, so re-running is safe)
#   - Docker Engine + compose plugin from Docker's apt repo, plus a
#     /usr/local/bin/docker-compose shim => 'docker compose --compatibility', so
#     the repo's scripts and the v1 container names (val_ipt_ipt_1) still work
#   - nginx + certbot + certbot's nginx plugin from Ubuntu; nginx/ipt.conf as
#     the only enabled site (TLS front end -- see the header of that file)
#   - AWS CLI v2 (nightly backup to s3://ipt.backups, which is in us-east-1;
#     credentials come from the instance role vce-backup-ipt-live, no keys)
#   - /usr/ipt owned by uid 999 (the IPT image's 'tomcat'), /usr/local/backups
#   - postgresql-client, so 12_install_loonweb_tunnel.sh can prove the tunnel
#   - root's crontab from 05_root_crontab.txt
#
# MIGRATION RUNBOOK (old host -> this one). Steps 1-4 do not touch the old host.
#   1. Copy from the old host, e.g. from a workstation:
#        ssh OLD 'sudo tar czf - -C / etc/letsencrypt etc/loonweb-tunnel' \
#          | ssh NEW 'sudo tar xzf - -C /'
#      /etc/letsencrypt must be here BEFORE --apply: 'nginx -t' needs the certs,
#      so the nginx step is skipped (and says so) without them.
#   2. ./14_install_new_server.sh --apply
#   3. Mail:   IPT_SMTP_PASS=... ./09_install_postfix.sh --apply  (args: ses-setup.sh)
#   4. Tunnel: ./12_install_loonweb_tunnel.sh --apply   (key copied in step 1)
#   5. CUTOVER: stop the IPT on the old host, copy /usr/ipt across, run
#      ./06_update_ipt_docker_instance.sh here, test with
#        curl --resolve ipt.vtatlasoflife.org:443:<this host's IP> https://ipt.vtatlasoflife.org/
#      then move the Elastic IP 54.202.72.31 to this instance.
#   6. AFTER the IP has moved (Let's Encrypt must reach this host on port 80):
#        sudo certbot reconfigure --cert-name ipt.vtatlasoflife.org --nginx
#        sudo certbot reconfigure --cert-name ipt.vtecostudies.org --nginx
#      Until then the copied renewal configs still say 'standalone', which can
#      no longer bind port 80. Renewal is due from about 2026-12-31.
#
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")" || exit 1
REPO="$(pwd)"

APPLY=0
case "${1:-}" in
    --apply) APPLY=1 ;;
    ""|--status) ;;
    *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac

IPT_UID=999
CERT_LIVE=/etc/letsencrypt/live/ipt.vtatlasoflife.org
export DEBIAN_FRONTEND=noninteractive
APT=(sudo -E apt-get -y -q -o DPkg::Lock::Timeout=600)

todo=0
hr()   { echo; echo "── $* ──────────────────────────────────────"; }
ok()   { echo "  ok    $*"; }
need() { echo "  TODO  $*"; todo=$((todo + 1)); }
doing(){ echo "  ...   $*"; }

. /etc/os-release
if [ "${VERSION_ID:-}" != "26.04" ]; then
    echo "This script is for Ubuntu 26.04; this is ${PRETTY_NAME:-unknown}." >&2
    exit 1
fi
[ "$REPO" = "/home/ubuntu/val_ipt" ] \
    || echo "  WARNING: repo is at $REPO, but the crontab expects /home/ubuntu/val_ipt"

# ---- 1. Ubuntu packages ----------------------------------------------------
hr "1. Ubuntu packages"
PKGS=(nginx certbot python3-certbot-nginx postgresql-client unzip curl ca-certificates)
missing=()
for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ ${#missing[@]} -eq 0 ]; then
    ok "installed: ${PKGS[*]}"
elif [ $APPLY -eq 1 ]; then
    doing "apt update + full-upgrade + install ${missing[*]}"
    "${APT[@]}" update && "${APT[@]}" full-upgrade && "${APT[@]}" install "${missing[@]}" \
        || { echo "  apt failed" >&2; exit 1; }
    ok "installed: ${missing[*]}"
else
    need "install ${missing[*]}"
fi

# ---- 2. Docker Engine + compose plugin -------------------------------------
hr "2. Docker"
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    ok "$(docker --version), $(docker compose version --short 2>/dev/null | sed 's/^/compose /')"
elif [ $APPLY -eq 1 ]; then
    doing "adding Docker's apt repo for $VERSION_CODENAME"
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $VERSION_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    "${APT[@]}" update && "${APT[@]}" install docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin || { echo "  docker install failed" >&2; exit 1; }
    sudo systemctl enable --now docker
    ok "$(docker --version)"
else
    need "install Docker Engine + compose plugin from download.docker.com"
fi

SHIM=/usr/local/bin/docker-compose
SHIM_BODY='#!/bin/sh
# Installed by val_ipt/14_install_new_server.sh. The repo scripts call
# docker-compose (v1); --compatibility keeps v1 container names (val_ipt_ipt_1).
exec docker compose --compatibility "$@"'
if [ -f "$SHIM" ] && [ "$(cat "$SHIM")" = "$SHIM_BODY" ]; then
    ok "docker-compose shim -> 'docker compose --compatibility'"
elif [ $APPLY -eq 1 ]; then
    printf '%s\n' "$SHIM_BODY" | sudo tee "$SHIM" >/dev/null && sudo chmod 755 "$SHIM"
    ok "wrote $SHIM"
else
    need "write $SHIM"
fi

# ---- 3. AWS CLI v2 ---------------------------------------------------------
hr "3. AWS CLI"
if command -v aws >/dev/null; then
    ok "$(aws --version 2>&1 | cut -d' ' -f1)"
elif [ $APPLY -eq 1 ]; then
    tmp="$(mktemp -d)"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$tmp/awscli.zip" \
        && unzip -q "$tmp/awscli.zip" -d "$tmp" && sudo "$tmp/aws/install" >/dev/null \
        || { echo "  AWS CLI install failed" >&2; rm -rf "$tmp"; exit 1; }
    rm -rf "$tmp"
    ok "$(aws --version 2>&1 | cut -d' ' -f1)"
else
    need "install AWS CLI v2"
fi
if sudo test -f /root/.aws/config; then
    ok "/root/.aws/config present"
elif [ $APPLY -eq 1 ]; then
    sudo install -d -m 700 /root/.aws
    printf '[default]\nregion = us-east-1\n' | sudo tee /root/.aws/config >/dev/null
    ok "/root/.aws/config: region us-east-1 (ipt.backups)"
else
    need "/root/.aws/config with region us-east-1"
fi
if sudo test -f /root/.aws/credentials; then
    echo "  WARNING: /root/.aws/credentials exists; it overrides the instance role"
fi

# ---- 4. Directories --------------------------------------------------------
hr "4. Directories"
if [ -d /usr/ipt ] && [ "$(stat -c %u /usr/ipt)" = "$IPT_UID" ]; then
    ok "/usr/ipt (uid $IPT_UID)"
elif [ $APPLY -eq 1 ]; then
    sudo install -d -o "$IPT_UID" -g "$IPT_UID" -m 755 /usr/ipt
    ok "created /usr/ipt owned by $IPT_UID"
else
    need "create /usr/ipt owned by $IPT_UID"
fi
if [ -d /usr/local/backups ]; then
    ok "/usr/local/backups"
elif [ $APPLY -eq 1 ]; then
    sudo install -d -m 755 /usr/local/backups && ok "created /usr/local/backups"
else
    need "create /usr/local/backups"
fi
[ -L "$REPO/ipt_backups" ] || { [ $APPLY -eq 1 ] && ln -sfn /usr/local/backups "$REPO/ipt_backups"; }

# ---- 5. nginx site ---------------------------------------------------------
hr "5. nginx (TLS front end)"
SITE=/etc/nginx/sites-available/ipt
if ! sudo test -f "$CERT_LIVE/fullchain.pem"; then
    need "copy /etc/letsencrypt from the old host first (runbook step 1); nginx step skipped"
elif sudo cmp -s "$REPO/nginx/ipt.conf" "$SITE" && [ -L /etc/nginx/sites-enabled/ipt ] \
     && [ ! -e /etc/nginx/sites-enabled/default ]; then
    ok "site 'ipt' installed and enabled; 'default' disabled"
elif [ $APPLY -eq 1 ]; then
    sudo install -m 644 "$REPO/nginx/ipt.conf" "$SITE"
    sudo ln -sfn "$SITE" /etc/nginx/sites-enabled/ipt
    sudo rm -f /etc/nginx/sites-enabled/default
    if sudo nginx -t 2>&1 | sed 's/^/        /'; then
        sudo systemctl reload nginx && ok "site 'ipt' enabled, nginx reloaded"
    else
        echo "  nginx -t FAILED -- not reloaded" >&2; exit 1
    fi
else
    need "install nginx/ipt.conf as $SITE, disable 'default'"
fi

# ---- 6. root crontab -------------------------------------------------------
hr "6. root crontab"
if sudo crontab -l 2>/dev/null | cmp -s - "$REPO/05_root_crontab.txt"; then
    ok "matches 05_root_crontab.txt"
elif [ $APPLY -eq 1 ]; then
    sudo crontab "$REPO/05_root_crontab.txt" && ok "installed 05_root_crontab.txt"
else
    need "install 05_root_crontab.txt as root's crontab"
fi

hr "Summary"
if [ $APPLY -eq 0 ] && [ $todo -gt 0 ]; then
    echo "  $todo step(s) to do. Re-run with --apply."
elif [ $todo -gt 0 ]; then
    echo "  $todo step(s) still need attention (see TODO above)."
else
    echo "  Host setup complete. Next: runbook steps 3-6 in this script's header."
fi
