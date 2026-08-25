#!/bin/bash
# Start the IPT stack. Safe whether the containers are stopped, already running,
# or absent. This is the script 00_certs_do_all.sh's EXIT trap depends on to
# restore service, so it must not leave the site down.
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1

sudo docker-compose up -d && exit 0

# 'up -d' failed. The known cause here is docker-compose v1 (1.x) against a
# modern Docker Engine: whenever docker-compose.yml or the image has changed
# since the containers were built, 'up -d' takes the RECREATE path and aborts
# with "KeyError: 'ContainerConfig'" -- AFTER it has already killed both
# containers. Retrying 'up -d' hits the identical error; only down + up clears
# it, because that takes the fresh-create path instead.
echo "04: 'up -d' failed - retrying as a full recreate (down + up)" >&2
sudo docker-compose down
sudo docker-compose up -d
rc=$?
[ "$rc" -eq 0 ] && echo "04: recovered via down + up" >&2
exit "$rc"
