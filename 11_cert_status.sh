#!/bin/bash
#
# Daily certificate status heartbeat. Prints a one-line VERDICT first, then a
# row per certbot lineage.
#
# WHY THIS IS A SCRIPT AND NOT A CRONTAB ONE-LINER:
#   cron puts the ENTIRE command string into the mail's Subject header. The
#   previous crontab line ended with:
#       || echo "CERT CHECK FAILED -- certbot produced no certificate output..."
#   so every healthy daily mail arrived with "CERT CHECK FAILED" in the
#   subject while the body listed perfectly valid certificates. A short script
#   name gives a neutral subject, and the verdict belongs on the first line of
#   the BODY where it can actually reflect what was found.
#
#   The '|| echo' itself was still necessary and is kept below in script form:
#   if certbot errors, grep matches nothing, cron mails nothing, and a broken
#   check is indistinguishable from a healthy one. This script always speaks.
#
# WHY 21 DAYS IS THE WARNING THRESHOLD:
#   Let's Encrypt issues 90-day certs; certbot renews at 30 days remaining.
#   00_certs_do_all.sh runs weekly, so a healthy system renews within about a
#   week of the window opening -- i.e. by roughly 23 days remaining. Still
#   holding a cert at 21 days means at least two renewal attempts have already
#   failed, which is the moment to look, not after it expires.
#
# USAGE:
#   11_cert_status.sh                 verdict + all lineages   (what cron runs)
#   11_cert_status.sh --quiet         print ONLY if something is wrong
#   11_cert_status.sh --warn-days N   change the warning threshold
#
# Exit: 0 all healthy, 1 warning or expired, 2 the check itself failed.
#
set -u

WARN_DAYS="${IPT_CERT_WARN_DAYS:-21}"
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --quiet)     QUIET=1 ;;
        --warn-days) WARN_DAYS="${2:-21}"; shift ;;
        -h|--help)   sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

if ! command -v certbot >/dev/null 2>&1; then
    echo "*** CERT CHECK FAILED: certbot is not installed on this host."
    exit 2
fi

raw="$(certbot certificates 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] || ! echo "$raw" | grep -q 'Certificate Name:'; then
    echo "*** CERT CHECK FAILED: certbot returned no certificate list (rc=$rc)."
    echo "    Investigate with:  sudo certbot certificates"
    echo
    echo "$raw" | sed 's/^/    /' | head -25
    exit 2
fi

now="$(date +%s)"
worst=99999; n=0; problems=0
rows=""

# certbot prints an indented block per lineage. Walk it, carrying the current
# name/domains until the Expiry Date line closes the record.
name=""; domains=""
while IFS= read -r line; do
    case "$line" in
        *"Certificate Name:"*) name="${line#*Certificate Name: }" ;;
        *"Domains:"*)          domains="${line#*Domains: }" ;;
        *"Expiry Date:"*)
            exp="${line#*Expiry Date: }"
            exp="${exp%% (*}"                     # strip the "(VALID: N days)" tail
            secs="$(date -d "$exp" +%s 2>/dev/null)" || secs=""
            if [ -n "$secs" ]; then
                days=$(( (secs - now) / 86400 ))
            else
                days=""
            fi
            n=$((n + 1))
            if [ -z "$days" ]; then
                flag="??"; problems=$((problems + 1))
            elif [ "$days" -lt 0 ]; then
                flag="EXPIRED"; problems=$((problems + 1))
            elif [ "$days" -lt "$WARN_DAYS" ]; then
                flag="WARN"; problems=$((problems + 1))
            else
                flag="ok"
            fi
            [ -n "$days" ] && [ "$days" -lt "$worst" ] && worst="$days"
            rows="$rows$(printf '  %-7s %-26s %5s d  %s  %s\n' \
                 "$flag" "$name" "${days:-?}" "${exp%% *}" "$domains")
"
            name=""; domains=""
            ;;
    esac
done <<< "$raw"

# Two lineages covering the same name means certbot renews both every cycle and
# it is ambiguous which one nginx is actually serving. Worth surfacing once.
dupes="$(echo "$raw" | sed -n 's/.*Domains: //p' | tr ' ' '\n' | sort | uniq -d | tr '\n' ' ')"

if [ "$problems" -eq 0 ] && [ "$QUIET" -eq 1 ]; then exit 0; fi

if [ "$problems" -eq 0 ]; then
    echo "CERTS OK -- $n lineage(s), soonest expiry in $worst days"
else
    echo "*** CERT PROBLEM -- $problems of $n lineage(s) need attention (soonest $worst days)"
fi
printf '%s' "$rows"

if [ -n "$dupes" ]; then
    echo
    echo "  NOTE: these names appear in more than one lineage: $dupes"
    echo "        Both get renewed every cycle, and which one nginx serves depends"
    echo "        on 03_cerbot_certs_copy.sh. Not urgent, but worth consolidating."
fi

if [ "$problems" -gt 0 ]; then
    echo
    echo "  Renewal runs weekly (Sun 04:30 UTC) via 00_certs_do_all.sh."
    echo "  A cert still under $WARN_DAYS days means renewal has already failed"
    echo "  more than once. Check:  sudo tail -100 /var/log/ipt_certs.log"
    exit 1
fi
exit 0
