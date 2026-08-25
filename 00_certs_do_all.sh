#!/bin/bash
#
# Monthly certificate renewal for ipt.vtatlasoflife.org / ipt.vtecostudies.org.
# Installed in root's crontab -- see 05_root_crontab.txt.
#
# WHY THIS IS NO LONGER AN '&&' CHAIN
#   The original was a single chain:
#       down && certbot renew && certs copy && up
#   Any non-zero step aborted the chain BEFORE the bring-up, leaving IPT down
#   (showing as "Exited (0)") until a human noticed. The bring-up now runs from
#   an EXIT trap, so service is restored whether the renewal succeeded, failed,
#   or this script was killed partway through.
#
set -u

# cron runs with CWD=$HOME, but docker-compose must run beside docker-compose.yml.
cd "$(dirname "$(readlink -f "$0")")" || {
    echo "certs: FATAL - cannot cd to script directory" >&2
    exit 1
}

log() { echo "$(date '+%F %T') certs: $*"; }

status=0

bring_up() {
    local rc=$?
    trap - EXIT
    log "restoring IPT service"
    if sudo ./04_ipt_docker_up.sh; then
        log "IPT is up"
    else
        log "*** ERROR: FAILED TO BRING IPT UP - MANUAL INTERVENTION REQUIRED ***"
        rc=1
    fi
    if [ "$rc" -ne 0 ] || [ "$status" -ne 0 ]; then exit 1; fi
    exit 0
}

# Armed BEFORE the first stop, so every exit path from here on restores service.
# INT/TERM/HUP are listed explicitly: a bare 'trap ... EXIT' does NOT fire when
# bash is killed by a signal, which would leave IPT stopped if this job were
# killed or the host began shutting down mid-cycle. Verified by test.
trap bring_up EXIT INT TERM HUP

run_step() {  # run_step <description> <script>
    local desc="$1" script="$2" rc
    log "$desc"
    sudo "./$script"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "ERROR: $script failed (rc=$rc)"
        status=1
    fi
    return "$rc"
}

run_step "stopping IPT so certbot --standalone can bind port 80" 01_ipt_docker_down.sh
run_step "renewing certificates"                                 02_certbot_renew.sh
run_step "copying certificates into place for nginx-proxy"       03_cerbot_certs_copy.sh

log "cert cycle finished (status=$status)"
# EXIT trap runs bring_up from here.
