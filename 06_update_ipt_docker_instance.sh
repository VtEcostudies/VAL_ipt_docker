#!/bin/bash
# Pull the IPT image pinned in docker-compose.yml and recreate the containers.
#
# This DOES destroy the running containers (and their 'docker logs' history) --
# that is required to pick up a new image or a docker-compose.yml change.
# IPT's own data and application logs live in the /usr/ipt bind mount and are
# untouched. Run this once after editing docker-compose.yml so the new
# restart/logging settings take effect.
#
# To upgrade the IPT: bump the gbif/ipt tag in docker-compose.yml (see the note
# there), take a backup, then run this.
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1

IPT_DATA=/usr/ipt
IPT_UID=999   # 'tomcat' inside gbif/ipt 3.3.x; older images ran as root

# Pull before 'down' so a failed pull leaves the site running. Only the ipt
# service: nginx-proxy is ':latest' and must not change as a side effect.
sudo docker-compose pull ipt || { echo "06: pull failed - nothing changed" >&2; exit 1; }

# gbif/ipt 3.3.x runs as uid 999, and an IPT that cannot write its data
# directory starts with no resources and a setup wizard. Fix ownership of
# anything not already 999 (idempotent; a no-op after the first run).
n=$(sudo find "$IPT_DATA" ! -uid "$IPT_UID" | wc -l)
if [ "$n" -gt 0 ]; then
    echo "06: chown $n paths in $IPT_DATA to $IPT_UID:$IPT_UID"
    sudo chown -R "$IPT_UID:$IPT_UID" "$IPT_DATA"
fi

sudo docker-compose down
sudo docker-compose up -d
sudo docker-compose ps
