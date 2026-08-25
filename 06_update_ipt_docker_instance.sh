#!/bin/bash
# Pull a newer gbif/ipt image and recreate the containers.
#
# This DOES destroy the running containers (and their 'docker logs' history) --
# that is required to pick up a new image or a docker-compose.yml change.
# IPT's own data and application logs live in the /usr/ipt bind mount and are
# untouched. Run this once after editing docker-compose.yml so the new
# restart/logging settings take effect.
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1
sudo docker-compose down
sudo docker pull gbif/ipt:latest
sudo docker-compose up -d
sudo docker-compose ps
