#!/bin/bash
# Stop the IPT stack. Frees ports 80/443 so certbot --standalone can bind them.
#
# 'stop', not 'down': 'down' DESTROYS the containers and with them the
# 'docker logs' history you need to diagnose an outage. 'stop' keeps the
# containers and their logs; 04_ipt_docker_up.sh restarts them either way.
# Use 06_update_ipt_docker_instance.sh when you genuinely need to recreate
# containers (after an image pull or a docker-compose.yml change).
cd "$(dirname "$(readlink -f "$0")")" || exit 1
sudo docker-compose stop
