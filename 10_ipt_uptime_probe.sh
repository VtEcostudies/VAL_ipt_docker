#!/bin/bash
#
# Uptime probe for IPT. Silent while healthy; prints only when the state
# CHANGES, plus a periodic reminder while still down.
#
# WHY THIS IS NOT A BARE curl LINE IN THE CRONTAB:
#
#   1. WRONG TARGET. The original probed https://ipt.vtatlasoflife.org/, which
#      resolves to Cloudflare. This probe runs ON the IPT host, so the request
#      leaves from an AWS datacenter address, and Cloudflare's bot protection
#      answers those with 403. The probe reported "IPT DOWN" while the site was
#      serving real users perfectly -- a false alarm every 30 minutes.
#      It also made no sense as a round trip: host -> Cloudflare -> same host,
#      with Cloudflare's bot rules added as a failure mode for a check that
#      only needs to ask whether the local stack is serving.
#      Default target is now ipt.vtecostudies.org, which resolves straight to
#      the EC2 host with no proxy in between.
#
#   2. NO RETRY. One failed request is not an outage. A transient blip during
#      a container restart would page you.
#
#   3. MAIL ON EVERY PROBE. At */30 a weekend outage was ~100 mails per
#      recipient. This reports the TRANSITION -- once going down, once
#      recovering -- and then reminds every REMIND_HOURS so a long outage is
#      not silently forgotten either.
#
#   4. THE % TRAP. cron treats an unescaped '%' in a command as a newline, so
#      curl -w '%{http_code}' in a crontab truncates silently. In a script
#      there is no such trap, and we can report the actual HTTP code -- which
#      is what would have identified the 403 immediately.
#
# USAGE:
#   10_ipt_uptime_probe.sh                 probe, report only on state change
#   10_ipt_uptime_probe.sh --status        show current state, change nothing
#   10_ipt_uptime_probe.sh --verbose       always print the outcome
#   10_ipt_uptime_probe.sh --url URL       probe something else
#
# Exit: 0 when up, 1 when down (cron ignores this; the OUTPUT is the alert).
#
set -u

URL="${IPT_PROBE_URL:-https://ipt.vtecostudies.org/}"
STATE="${IPT_PROBE_STATE:-/var/lib/ipt_uptime.state}"
RETRIES="${IPT_PROBE_RETRIES:-3}"      # total attempts before declaring DOWN
RETRY_WAIT="${IPT_PROBE_RETRY_WAIT:-10}"
TIMEOUT="${IPT_PROBE_TIMEOUT:-20}"
REMIND_HOURS="${IPT_PROBE_REMIND_HOURS:-12}"
VERBOSE=0
MODE=probe

while [ $# -gt 0 ]; do
    case "$1" in
        --status)  MODE=status ;;
        --verbose) VERBOSE=1 ;;
        --url)     URL="${2:-}"; shift ;;
        --state)   STATE="${2:-}"; shift ;;
        -h|--help) sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

now="$(date +%s)"
stamp="$(date '+%F %T %Z')"

# State file holds:  <UP|DOWN> <epoch of last transition> <epoch of last report>
prev_state=""; since="$now"; last_report=0
if [ -r "$STATE" ]; then
    read -r prev_state since last_report < "$STATE" 2>/dev/null || true
    case "$since"       in ''|*[!0-9]*) since="$now" ;; esac
    case "$last_report" in ''|*[!0-9]*) last_report=0 ;; esac
fi

human_since() {
    local s=$(( now - since ))
    if   [ "$s" -ge 86400 ]; then echo "$((s/86400))d $(((s%86400)/3600))h"
    elif [ "$s" -ge 3600 ];  then echo "$((s/3600))h $(((s%3600)/60))m"
    else echo "$((s/60))m"; fi
}

if [ "$MODE" = status ]; then
    echo "probe target : $URL"
    echo "state file   : $STATE"
    if [ -n "$prev_state" ]; then
        echo "current      : $prev_state for $(human_since)"
    else
        echo "current      : (no state recorded yet)"
    fi
    exit 0
fi

# ---- probe, with retries ---------------------------------------------------
code=""; err=""; ok=0
attempt=1
while [ "$attempt" -le "$RETRIES" ]; do
    # -w writes the HTTP code to stdout; body is discarded. No -f: a 403 must be
    # reported AS 403, not collapsed into curl's generic exit 22.
    code="$(curl -sS -m "$TIMEOUT" -o /dev/null -w '%{http_code}' "$URL" 2>/tmp/.iptprobe.$$)"
    err="$(cat /tmp/.iptprobe.$$ 2>/dev/null)"; rm -f /tmp/.iptprobe.$$
    case "$code" in
        2??|30[12]) ok=1; break ;;
    esac
    [ "$attempt" -lt "$RETRIES" ] && sleep "$RETRY_WAIT"
    attempt=$((attempt + 1))
done

if [ "$ok" -eq 1 ]; then state=UP; else state=DOWN; fi

# ---- decide whether to say anything ---------------------------------------
changed=0
[ "$state" != "$prev_state" ] && changed=1
[ -z "$prev_state" ] && changed=1          # first ever run: establish a baseline
due_reminder=0
if [ "$state" = DOWN ] && [ "$changed" -eq 0 ] \
   && [ $(( now - last_report )) -ge $(( REMIND_HOURS * 3600 )) ]; then
    due_reminder=1
fi

[ "$changed" -eq 1 ] && since="$now"
report=$(( changed + due_reminder ))
[ "$VERBOSE" -eq 1 ] && report=1

if [ "$report" -gt 0 ]; then
    if [ "$state" = DOWN ]; then
        echo "IPT DOWN: $URL"
        echo "  checked  : $stamp"
        echo "  attempts : $RETRIES, ${RETRY_WAIT}s apart, ${TIMEOUT}s timeout each"
        echo "  http code: ${code:-<none>}"
        [ -n "$err" ] && echo "  curl says: $err"
        [ "$due_reminder" -eq 1 ] && echo "  still down after $(human_since) -- reminder every ${REMIND_HOURS}h"
        # 403 here almost always means the URL points at a Cloudflare-proxied
        # name: requests from this host are datacenter IPs and get bot-blocked.
        case "${code:-}" in
            403) echo "  NOTE: 403 from a Cloudflare-proxied hostname usually means"
                 echo "        bot protection blocking this host's datacenter IP, NOT"
                 echo "        an outage. Probe the origin name instead." ;;
            52?) echo "  NOTE: 52x is Cloudflare failing to reach the ORIGIN. The edge"
                 echo "        is fine; the container or nginx behind it is not." ;;
        esac
    elif [ -n "$prev_state" ] && [ "$prev_state" != UP ]; then
        echo "IPT RECOVERED: $URL"
        echo "  checked  : $stamp"
        echo "  http code: $code"
        echo "  was down for approximately $(human_since)"
    elif [ "$VERBOSE" -eq 1 ]; then
        echo "IPT up: $URL returned $code at $stamp"
    fi
    last_report="$now"
fi

# Best effort: an unwritable state file degrades to reporting on every probe,
# which is noisy but never silent. Never let it abort the check itself.
printf '%s %s %s\n' "$state" "$since" "$last_report" > "$STATE" 2>/dev/null \
  || echo "  (warning: cannot write state file $STATE -- every probe will report)"

[ "$state" = UP ] && exit 0 || exit 1
