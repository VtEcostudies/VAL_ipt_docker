#!/bin/bash
#
# Read-only post-mortem for an IPT outage. Run on the IPT host as root:
#     sudo ./07_ipt_diagnose.sh [days_back]
#
# Makes no changes. Gathers, in order of usefulness:
#   1. container state and exit codes   (exit 137 = OOM-kill, 143 = SIGTERM,
#                                        0 = orderly shutdown, ie. something
#                                        stopped it rather than it crashing)
#   2. container stdout/stderr          (lost if anyone ran 'docker-compose down')
#   3. IPT's own application logs       (in the /usr/ipt bind mount, always survives)
#   4. docker daemon + kernel OOM + cron/reboot history
#   5. certbot and backup job logs
#
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1

days="${1:-3}"
since="${days} days ago"
IPT_DATA=/usr/ipt

hdr() { printf '\n\n===== %s =====\n' "$*"; }

hdr "1. CONTAINER STATE"
docker-compose ps 2>/dev/null
echo
docker ps -a --filter "name=ipt" --filter "name=nginx" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}'
echo
for c in $(docker ps -aq --filter "name=ipt" --filter "name=nginx"); do
    docker inspect -f '{{.Name}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} restarts={{.RestartCount}}' "$c"
done

hdr "2. CONTAINER LOGS (last $days days, error lines)"
for c in $(docker ps -aq --filter "name=ipt" --filter "name=nginx"); do
    echo "--- $(docker inspect -f '{{.Name}}' "$c") ---"
    docker logs --since "${days}d" --timestamps "$c" 2>&1 \
        | grep -iE 'error|exception|fatal|severe|out of memory|shutdown|refused' \
        | tail -40
done

hdr "3. IPT APPLICATION LOGS ($IPT_DATA/logs) - survives container recreation"
if [ -d "$IPT_DATA/logs" ]; then
    ls -lat "$IPT_DATA/logs" | head -20
    for f in "$IPT_DATA"/logs/*.log; do
        [ -f "$f" ] || continue
        hits=$(grep -icE 'error|exception|fatal|severe|out of memory' "$f" 2>/dev/null)
        [ "${hits:-0}" -gt 0 ] || continue
        echo "--- $f ($hits matching lines, last 25) ---"
        grep -iE 'error|exception|fatal|severe|out of memory' "$f" | tail -25
    done
else
    echo "NOT FOUND: $IPT_DATA/logs (is the /usr/ipt bind mount present?)"
fi

hdr "4a. DOCKER DAEMON (last $days days)"
journalctl -u docker.service --since "$since" --no-pager 2>/dev/null \
    | grep -iE 'ipt|nginx|oom|kill|die|stop|error' | tail -40

hdr "4b. KERNEL OOM KILLER"
journalctl -k --since "$since" --no-pager 2>/dev/null \
    | grep -iE 'oom|killed process|out of memory' | tail -20
dmesg -T 2>/dev/null | grep -iE 'oom|killed process' | tail -10

hdr "4c. REBOOTS"
last -x reboot 2>/dev/null | head -10

hdr "4d. CRON / SHUTDOWN / UNATTENDED UPGRADES"
grep -ihE 'cron.*(ipt|certs|backup)|shutdown|unattended' \
    /var/log/syslog /var/log/syslog.1 2>/dev/null | tail -40

hdr "5a. CERTBOT"
tail -40 /var/log/letsencrypt/letsencrypt.log 2>/dev/null
echo "--- cert job log ---"
tail -30 /var/log/ipt_certs.log 2>/dev/null || echo "(no /var/log/ipt_certs.log yet)"
echo "--- cert expiry ---"
certbot certificates 2>/dev/null | grep -E 'Certificate Name|Expiry'

hdr "5b. BACKUP JOB (unified: local rotation + S3 rotation)"
if [ -x ./aws_backups/backup_ipt_data.sh ]; then
    ./aws_backups/backup_ipt_data.sh --report 2>&1
else
    echo "(aws_backups/backup_ipt_data.sh not found)"
fi
echo "--- recent log detail ---"
for l in /usr/local/backups/vce_ipt_backup.log ./aws_backups/vce_ipt_backup.log; do
    [ -f "$l" ] || continue
    echo "--- $l ---"; tail -15 "$l"
done

hdr "5c. INSTALLED CRONTAB (compare against 05_root_crontab.txt)"
crontab -l 2>/dev/null

hdr "6. DISK"
df -kh /dev/root /var/lib/docker 2>/dev/null

printf '\n\nDone. Exit code 0 on a stopped container means an ORDERLY shutdown,\n'
printf 'not a crash - look at sections 4a/4c/4d for who asked it to stop.\n'
