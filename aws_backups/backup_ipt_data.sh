#!/bin/bash
#
# Unified IPT backup: tiered local rotation + mirrored S3 rotation + reporting.
#
# This one script REPLACES the two that used to run separately:
#   - /usr/local/backups/backup_ipt_data.sh  (dated tarball, NEVER pruned --
#     it accumulated one file per night from 2023 onward)
#   - aws_backups/copy_to_aws.sh             (one overwritten S3 object)
# See 08_install_backups.sh for the migration, which adopts those legacy
# vce_ipt_data_* archives into the layout below without deleting anything.
#
# LAYOUT -- local mirrors S3 exactly, same tiers, same promotion rules:
#   /usr/local/backups/daily/   ipt_data_YYYY-MM-DD.tar.gz   keep 7
#                      weekly/  ipt_data_YYYY-MM-DD.tar.gz   keep 4
#                      monthly/ ipt_data_YYYY-MM-DD.tar.gz   keep 3
#   s3://ipt.backups/  daily/ weekly/ monthly/                keep 14 / 8 / 12
#   val_ipt_latest.tar.gz -> daily/<newest>      (backward-compatible pointer)
#
# Local tiers are shallower than S3 on purpose: disk is finite and filling the
# root volume takes IPT down, while S3 holds the deep history cheaply. Local
# promotion uses a HARD LINK, so a weekly or monthly copy costs no extra disk
# until the daily one is pruned -- the local equivalent of S3's server-side copy.
#
# REPORTING (cron MAILTO carries the mail; see 05_root_crontab.txt):
#   - ANY failure prints to stdout, so cron mails it the moment it happens.
#   - A successful run is otherwise silent, EXCEPT on the weekly digest day,
#     when it prints an inventory summary. That digest is the "still working"
#     signal -- its ABSENCE means the job has stopped running at all, which is
#     how the old backup rotted unnoticed from 2024 to 2026.
#
# USAGE:
#   backup_ipt_data.sh                full nightly run (what cron calls)
#   backup_ipt_data.sh --report       print the digest now and exit
#   backup_ipt_data.sh --list         show local + S3 inventory and exit
#   backup_ipt_data.sh --upload-only  re-upload the newest local archive
#   backup_ipt_data.sh --prune-only   run rotation only, take no new backup
#   backup_ipt_data.sh --dry-run      go through the motions, change nothing
#
set -u

# ---- configuration (env vars override, which is how the tests drive it) ----
SRC_DIR="${IPT_BACKUP_SRC:-/usr/ipt}"
BACKUP_DIR="${IPT_BACKUP_DIR:-/usr/local/backups}"
S3_BASE="${IPT_BACKUP_S3:-s3://ipt.backups}"

KEEP_LOCAL_DAILY="${IPT_KEEP_LOCAL_DAILY:-7}"
KEEP_LOCAL_WEEKLY="${IPT_KEEP_LOCAL_WEEKLY:-4}"
KEEP_LOCAL_MONTHLY="${IPT_KEEP_LOCAL_MONTHLY:-3}"
KEEP_S3_DAILY="${IPT_KEEP_S3_DAILY:-14}"
KEEP_S3_WEEKLY="${IPT_KEEP_S3_WEEKLY:-8}"
KEEP_S3_MONTHLY="${IPT_KEEP_S3_MONTHLY:-12}"

WEEKLY_DOW="${IPT_WEEKLY_DOW:-7}"          # date +%u -- 7 = Sunday
MONTHLY_DOM="${IPT_MONTHLY_DOM:-01}"       # day-of-month promoted to monthly
DIGEST_DOW="${IPT_DIGEST_DOW:-1}"          # 1 = Monday
STALE_HOURS="${IPT_STALE_HOURS:-36}"       # warn if the PREVIOUS archive is older
MIN_BYTES="${IPT_MIN_BYTES:-10240}"        # archive smaller than this = broken source
SHRINK_PCT="${IPT_SHRINK_PCT:-50}"         # shrink beyond this vs previous = suspicious
VERIFY_ARCHIVE="${IPT_VERIFY_ARCHIVE:-1}"  # 0 disables the gzip integrity check

DRY_RUN=0
TIERS="daily weekly monthly"

# ---- paths ----------------------------------------------------------------
LOG="$BACKUP_DIR/vce_ipt_backup.log"
STATUS="$BACKUP_DIR/backup_status.tsv"
LOCKFILE="$BACKUP_DIR/.backup.lock"
LATEST_LINK="$BACKUP_DIR/val_ipt_latest.tar.gz"
NAME_RE='^ipt_data_[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz$'
DATED_GLOB='ipt_data_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].tar.gz'

today="$(date +%F)"
dow="$(date +%u)"
dom="$(date +%d)"
ARCHIVE_NAME="ipt_data_${today}.tar.gz"
PRUNE_SAFE=1

# ---- output helpers -------------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()   { echo "$(ts) $*" >> "$LOG" 2>/dev/null; }
alert() { echo "$(ts) $*"; echo "$(ts) $*" >> "$LOG" 2>/dev/null; }
say()   { echo "$*"; echo "$*" >> "$LOG" 2>/dev/null; }

failures=0
fail() { failures=$((failures + 1)); alert "$@"; }

human() {
    local b="${1:-0}"
    case "$b" in ''|*[!0-9]*) echo "?"; return ;; esac
    if   [ "$b" -ge 1073741824 ]; then echo "$((b / 1073741824))G"
    elif [ "$b" -ge 1048576 ];    then echo "$((b / 1048576))M"
    elif [ "$b" -ge 1024 ];       then echo "$((b / 1024))K"
    else echo "${b}B"; fi
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then log "DRY-RUN: $*"; return 0; fi
    "$@"
}

have_aws() { command -v aws >/dev/null 2>&1; }

# A retention count must be a positive integer. A blank or non-numeric value
# (typo'd env var) previously made '[' error out and skip rotation silently;
# a value of 0 deleted EVERY archive. Both verified. Refuse instead.
valid_keep() { # valid_keep <value> <name>
    case "${1:-}" in
        ''|*[!0-9]*) fail "*** IPT BACKUP: $2='${1:-}' is not a number - rotation SKIPPED to avoid deleting archives ***"; return 1 ;;
        0)           fail "*** IPT BACKUP: $2=0 would delete every archive - rotation SKIPPED ***"; return 1 ;;
    esac
    return 0
}

keep_for() { # keep_for <local|s3> <tier>
    case "$1:$2" in
        local:daily)   echo "$KEEP_LOCAL_DAILY" ;;
        local:weekly)  echo "$KEEP_LOCAL_WEEKLY" ;;
        local:monthly) echo "$KEEP_LOCAL_MONTHLY" ;;
        s3:daily)      echo "$KEEP_S3_DAILY" ;;
        s3:weekly)     echo "$KEEP_S3_WEEKLY" ;;
        s3:monthly)    echo "$KEEP_S3_MONTHLY" ;;
    esac
}

# ---- AWS credentials under root's cron ------------------------------------
# aws_install/01_configure_aws_cli.sh runs 'aws configure set' WITHOUT sudo, so
# the keys live in /home/ubuntu/.aws. cron gives root HOME=/root, where there is
# no .aws, so uploads would fail nightly with "Unable to locate credentials".
setup_aws_creds() {
    [ -n "${AWS_ACCESS_KEY_ID:-}" ] && return 0
    [ -f "${HOME:-/root}/.aws/credentials" ] && return 0
    local d
    for d in /home/ubuntu/.aws "/home/${SUDO_USER:-ubuntu}/.aws"; do
        [ -f "$d/credentials" ] || continue
        export AWS_SHARED_CREDENTIALS_FILE="$d/credentials"
        [ -f "$d/config" ] && export AWS_CONFIG_FILE="$d/config"
        log "using AWS credentials from $d"
        return 0
    done
    return 0
}

# ---- inventory: local and S3 use the SAME shape ---------------------------
local_list() { # local_list <tier> -> full paths, newest date first
    ls -1 "$BACKUP_DIR/$1"/$DATED_GLOB 2>/dev/null | sort -r
}

s3_list() { # s3_list <tier> -> our archive names only, newest date first
    # Only ever list objects matching OUR dated name. Anything else in the
    # prefix -- a stray upload, a README, the legacy flat val_ipt_latest.tar.gz
    # -- must not consume the retention budget: counting foreign objects
    # silently evicts a real backup (verified: 14 real + 2 stray, keep=14, left
    # only 13 real archives).
    aws s3 ls "$S3_BASE/$1/" 2>/dev/null \
        | awk '{print $4}' | grep -vE '^$' | grep -E "$NAME_RE" | sort -r
}

prune_local_tier() { # prune_local_tier <tier> <keep>
    local tier="$1" keep="$2" n=0 removed=0 f
    valid_keep "$keep" "KEEP_LOCAL_${tier}" || return 1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        if [ "$n" -gt "$keep" ]; then
            if run rm -f "$f"; then removed=$((removed + 1)); log "pruned local $tier/$(basename "$f")"; fi
        fi
    done <<< "$(local_list "$tier")"
    [ "$removed" -gt 0 ] && log "local $tier: pruned $removed, kept $keep"
    return 0
}

prune_s3_tier() { # prune_s3_tier <tier> <keep>
    local tier="$1" keep="$2" names n=0 removed=0 name
    valid_keep "$keep" "KEEP_S3_${tier}" || return 1
    names="$(s3_list "$tier")" || return 0
    [ -n "$names" ] || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        n=$((n + 1))
        if [ "$n" -gt "$keep" ]; then
            if run aws s3 rm "$S3_BASE/$tier/$name" >/dev/null 2>&1; then
                removed=$((removed + 1)); log "pruned s3 $tier/$name"
            else
                fail "WARNING: could not prune s3 $tier/$name"
            fi
        fi
    done <<< "$names"
    [ "$removed" -gt 0 ] && log "s3 $tier: pruned $removed, kept $keep"
    return 0
}

prune_all() {
    if [ "$PRUNE_SAFE" -ne 1 ]; then
        alert "    Rotation withheld this run; every existing copy is retained."
        return 0
    fi
    local t
    for t in $TIERS; do prune_local_tier "$t" "$(keep_for local "$t")"; done
    if have_aws; then
        for t in $TIERS; do prune_s3_tier "$t" "$(keep_for s3 "$t")"; done
    fi
}

# ---- reporting ------------------------------------------------------------
print_inventory() {
    local t keep cnt newest total=0 sz f free legacy
    say "--- local ($BACKUP_DIR) ---"
    for t in $TIERS; do
        keep="$(keep_for local "$t")"
        cnt="$(local_list "$t" | grep -c .)"
        newest="$(local_list "$t" | head -1)"
        sz=0
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            sz=$(( sz + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
        done <<< "$(local_list "$t")"
        total=$(( total + sz ))
        say "  $t: $cnt archives (keep $keep)  $(human "$sz")  newest: $(basename "${newest:-(none)}")"
    done
    free="$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
    say "  total archives: $(human "$total")   free on volume: $(human $(( ${free:-0} * 1024 )))"

    # Legacy archives sitting at the top level mean the migration has not run.
    legacy="$(ls -1 "$BACKUP_DIR"/vce_ipt_data_*.tar.gz "$BACKUP_DIR"/$DATED_GLOB 2>/dev/null | grep -c .)"
    if [ "${legacy:-0}" -gt 0 ]; then
        say "  *** $legacy un-migrated archive(s) at the top level of $BACKUP_DIR."
        say "      They are NOT rotated. Run 08_install_backups.sh to adopt them."
    fi

    if have_aws; then
        say "--- s3 ($S3_BASE) ---"
        for t in $TIERS; do
            keep="$(keep_for s3 "$t")"
            cnt="$(s3_list "$t" | grep -c .)"
            newest="$(s3_list "$t" | head -1)"
            say "  $t: $cnt objects (keep $keep)   newest: ${newest:-(none)}"
        done
    else
        say "--- s3: aws CLI not found, skipped ---"
    fi
}

print_digest() {
    say "=========================================================="
    say " IPT BACKUP DIGEST - $(hostname) - $(date '+%F %T')"
    say "=========================================================="
    if [ -f "$STATUS" ]; then
        local ok bad
        ok="$(tail -7 "$STATUS"  | awk -F'\t' '$2=="OK" {n++} END {print n+0}')"
        bad="$(tail -7 "$STATUS" | awk -F'\t' '$2!="OK" {n++} END {print n+0}')"
        say "last 7 recorded runs: $ok OK, $bad not OK"
        say "--- recent runs ---"
        tail -7 "$STATUS" | awk -F'\t' '{printf "  %s  %-8s  %-8s  s3:%s\n", $1, $2, $3, $4}'
    else
        say "no run history yet ($STATUS missing)"
    fi
    print_inventory
    say "=========================================================="
    say "This digest is the 'backups are alive' signal. If it stops"
    say "arriving, the cron job has stopped running -- investigate."
}

record_status() { # record_status <result> <size> <s3result>
    [ "$DRY_RUN" -eq 1 ] && return 0
    printf '%s\t%s\t%s\t%s\n' "$(ts)" "$1" "$2" "$3" >> "$STATUS" 2>/dev/null
    if [ -f "$STATUS" ] && [ "$(wc -l < "$STATUS")" -gt 400 ]; then
        tail -200 "$STATUS" > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"
    fi
}

# ---- argument handling ----------------------------------------------------
MODE=run
while [ $# -gt 0 ]; do
    case "$1" in
        --report)      MODE=report ;;
        --list)        MODE=list ;;
        --upload-only) MODE=upload ;;
        --prune-only)  MODE=prune ;;
        --dry-run)     DRY_RUN=1 ;;
        -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$BACKUP_DIR" 2>/dev/null
if [ ! -d "$BACKUP_DIR" ] || [ ! -w "$BACKUP_DIR" ]; then
    echo "$(ts) *** IPT BACKUP FAILED: $BACKUP_DIR is missing or not writable ***"
    exit 1
fi
for t in $TIERS; do mkdir -p "$BACKUP_DIR/$t" 2>/dev/null; done

setup_aws_creds

case "$MODE" in
    report) print_digest; exit 0 ;;
    list)   print_inventory; exit 0 ;;
esac

# ---- single-instance lock -------------------------------------------------
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    alert "*** IPT BACKUP SKIPPED: another run holds $LOCKFILE ***"
    exit 1
fi

# Sweep .partial files orphaned by an earlier interrupted run (reboot, SIGKILL).
# Safe here: the lock guarantees no other run owns one, and this run has not
# created its own yet. Left alone they accumulate a full tarball per incident.
for orphan in "$BACKUP_DIR"/daily/*.tar.gz.partial "$BACKUP_DIR"/*.tar.gz.partial; do
    [ -e "$orphan" ] || continue
    log "removing orphaned partial $(basename "$orphan")"
    rm -f "$orphan"
done

if [ "$MODE" = prune ]; then
    prune_all
    exit "$( [ "$failures" -eq 0 ] && echo 0 || echo 1 )"
fi

# ---- promotion + upload ---------------------------------------------------
promote_local() { # hard-link today's daily archive into the tiers it belongs to
    local src="$1" base tier dest
    base="$(basename "$src")"
    for tier in $( [ "$dow" = "$WEEKLY_DOW" ] && echo weekly; [ "$dom" = "$MONTHLY_DOM" ] && echo monthly ); do
        dest="$BACKUP_DIR/$tier/$base"
        # Hard link: same data, no extra disk, and pruning the daily copy does
        # not remove the content while this link survives. Fall back to a real
        # copy if the tiers ever land on different filesystems.
        if run ln -f "$src" "$dest" 2>/dev/null || run cp -f "$src" "$dest"; then
            log "promoted local -> $tier/$base"
        else
            fail "WARNING: could not promote $base into local $tier"
        fi
    done
}

upload_and_promote() { # upload_and_promote <local archive path>
    local src="$1" base s3_daily tier
    base="$(basename "$src")"
    s3_daily="$S3_BASE/daily/$base"

    if ! have_aws; then
        fail "*** IPT BACKUP: aws CLI not found, offsite copy SKIPPED ***"
        return 1
    fi
    if run aws s3 cp "$src" "$s3_daily" >> "$LOG" 2>&1; then
        log "uploaded $base -> $s3_daily"
    else
        fail "*** IPT BACKUP: S3 upload of $base FAILED (see $LOG) ***"
        return 1
    fi
    # Server-side copy into the other tiers -- no second upload, mirroring the
    # hard link used locally.
    for tier in $( [ "$dow" = "$WEEKLY_DOW" ] && echo weekly; [ "$dom" = "$MONTHLY_DOM" ] && echo monthly ); do
        if run aws s3 cp "$s3_daily" "$S3_BASE/$tier/$base" >> "$LOG" 2>&1; then
            log "promoted s3 -> $tier/$base"
        else
            fail "WARNING: could not promote $base into s3 $tier"
        fi
    done
    return 0
}

if [ "$MODE" = upload ]; then
    newest="$(local_list daily | head -1)"
    if [ -z "$newest" ]; then
        alert "*** IPT BACKUP: no local archive to upload ***"; exit 1
    fi
    upload_and_promote "$newest"
    exit "$( [ "$failures" -eq 0 ] && echo 0 || echo 1 )"
fi

# ---- nightly run ----------------------------------------------------------
archive="$BACKUP_DIR/daily/$ARCHIVE_NAME"
tmp="$archive.partial"
log "=== backup run start: $SRC_DIR -> $archive ==="

if [ ! -d "$SRC_DIR" ]; then
    fail "*** IPT BACKUP FAILED: source $SRC_DIR does not exist ***"
    record_status FAIL 0 skipped
    exit 1
fi

newest_existing="$(local_list daily | head -1)"
prev_size=0
if [ -n "$newest_existing" ]; then
    prev_size="$(stat -c %s "$newest_existing" 2>/dev/null || echo 0)"
    # Staleness must be measured against the PREVIOUS archive. Measuring the one
    # this run just wrote made the check dead code -- its age is always 0.
    prev_age_h=$(( ( $(date +%s) - $(stat -c %Y "$newest_existing") ) / 3600 ))
    if [ "$prev_age_h" -gt "$STALE_HOURS" ]; then
        fail "WARNING: previous archive is ${prev_age_h}h old (> ${STALE_HOURS}h) - nightly runs have been missed, is cron firing?"
    fi

    # Free-space guard. Filling the root volume would take IPT down, which is
    # precisely what this tooling exists to prevent.
    need_kb=$(( $(du -k "$newest_existing" | cut -f1) * 2 ))
    free_kb="$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}')"
    if [ "${free_kb:-0}" -lt "$need_kb" ]; then
        fail "*** IPT BACKUP FAILED: only $(human $((free_kb * 1024))) free in $BACKUP_DIR, need ~$(human $((need_kb * 1024))) ***"
        alert "    Lower the KEEP_LOCAL_* retention or clear space, then rerun."
        record_status FAIL 0 skipped
        exit 1
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would tar $SRC_DIR -> $archive"
    rc=0
else
    tar -czf "$tmp" -C "$(dirname "$SRC_DIR")" "$(basename "$SRC_DIR")" >> "$LOG" 2>&1
    rc=$?
fi

case "$rc" in
    0) log "tar OK" ;;
    1) log "tar OK with warnings (files changed during read)" ;;
    *) rm -f "$tmp"
       fail "*** IPT BACKUP FAILED: tar exited $rc - previous archives left intact ***"
       alert "    See $LOG for tar's output."
       record_status FAIL 0 skipped
       exit "$rc" ;;
esac

# ---- validate the archive BEFORE it is allowed to displace anything --------
# tar exits 0 on an EMPTY source directory, producing a ~113-byte tarball. If
# /usr/ipt is present but unpopulated (bind mount failed, data moved aside
# during recovery, IPT reinstalled) that junk archive would be recorded OK,
# uploaded, and used to rotate away every real copy locally AND in S3 over the
# following nights -- silently. Verified end-to-end. Never trust tar's exit
# status alone. Checks run on $tmp, before the mv.
if [ "$DRY_RUN" -eq 0 ]; then
    new_size="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"

    if [ "$new_size" -lt "$MIN_BYTES" ]; then
        rm -f "$tmp"
        fail "*** IPT BACKUP FAILED: archive is only $(human "$new_size") (floor $(human "$MIN_BYTES")) ***"
        alert "    $SRC_DIR is empty or unmounted. Nothing was rotated; existing archives are intact."
        record_status FAIL "$(human "$new_size")" skipped
        exit 1
    fi

    if [ "$VERIFY_ARCHIVE" = 1 ] && ! gzip -t "$tmp" 2>>"$LOG"; then
        rm -f "$tmp"
        fail "*** IPT BACKUP FAILED: archive failed its integrity check (truncated or corrupt) ***"
        alert "    Nothing was rotated; existing archives are intact. See $LOG."
        record_status FAIL "$(human "$new_size")" skipped
        exit 1
    fi

    # A large shrink may be legitimate (IPT log rotation lives under /usr/ipt),
    # so keep and upload the archive -- but do NOT prune. Pruning is the only
    # destructive act here; gate it on confidence and let a human decide.
    if [ "$prev_size" -gt 0 ] && [ "$(( new_size * 100 / prev_size ))" -lt "$SHRINK_PCT" ]; then
        PRUNE_SAFE=0
        fail "*** IPT BACKUP WARNING: archive shrank to $(human "$new_size") from $(human "$prev_size") ***"
        alert "    Archive kept, but ROTATION IS SKIPPED so no older copy is lost."
        alert "    Confirm $SRC_DIR is intact, then rerun, or raise IPT_SHRINK_PCT if expected."
    fi

    mv -f "$tmp" "$archive"
    ln -sfn "daily/$ARCHIVE_NAME" "$LATEST_LINK"
fi

size_bytes="$(stat -c %s "$archive" 2>/dev/null || echo 0)"

promote_local "$archive"

s3_state=OK
upload_and_promote "$archive" || s3_state=FAILED

prune_all

# ---- record + report ------------------------------------------------------
if [ "$failures" -eq 0 ]; then
    record_status OK "$(human "$size_bytes")" "$s3_state"
    log "=== backup run OK: $ARCHIVE_NAME $(human "$size_bytes"), s3 $s3_state ==="
else
    record_status PARTIAL "$(human "$size_bytes")" "$s3_state"
    alert "    Local archive $ARCHIVE_NAME ($(human "$size_bytes")) was written; $failures problem(s) above."
    log "=== backup run finished with $failures problem(s) ==="
fi

# Weekly digest: the "still working" signal. Absence of it is the alarm.
if [ "$dow" = "$DIGEST_DOW" ] && [ "$failures" -eq 0 ]; then
    print_digest
fi

exit "$( [ "$failures" -eq 0 ] && echo 0 || echo 1 )"
