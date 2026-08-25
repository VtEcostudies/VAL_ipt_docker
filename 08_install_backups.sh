#!/bin/bash
#
# Consolidate the two IPT backup processes into one, and adopt the pile of
# legacy archives into the tiered layout.
#
# BEFORE (two independent, diverged processes):
#   /usr/local/backups/backup_ipt_data.sh  -- wrote vce_ipt_data_<timestamp>.tar.gz
#                                             every night and NEVER pruned, so
#                                             archives accumulated from 2023 on
#   ~/val_ipt/aws_backups/{backup_ipt_data.sh,copy_to_aws.sh}  -- the repo copy
#
# AFTER (one, git-tracked):
#   code: ~/val_ipt/aws_backups/backup_ipt_data.sh
#   data: /usr/local/backups/{daily,weekly,monthly}/ipt_data_YYYY-MM-DD.tar.gz
#
# NOTHING IS EVER DELETED BY THIS SCRIPT. Legacy archives that do not earn a
# place in a retention tier are MOVED to /usr/local/backups/legacy_review/ for
# you to inspect and remove by hand. The superseded script is renamed aside.
#
# SAFE BY DEFAULT: prints a full plan and changes nothing. Re-run with --apply.
#
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

REPO_DIR="$(pwd)"
NEW_SCRIPT="$REPO_DIR/aws_backups/backup_ipt_data.sh"
DATA_DIR="${IPT_BACKUP_DIR:-/usr/local/backups}"
OLD_SCRIPT="$DATA_DIR/backup_ipt_data.sh"
REVIEW_DIR="$DATA_DIR/legacy_review"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Must match the retention the nightly script will enforce, or the first run
# after migration would immediately prune what we just adopted.
KEEP_DAILY="${IPT_KEEP_LOCAL_DAILY:-7}"
KEEP_WEEKLY="${IPT_KEEP_LOCAL_WEEKLY:-4}"
KEEP_MONTHLY="${IPT_KEEP_LOCAL_MONTHLY:-3}"
WEEKLY_DOW="${IPT_WEEKLY_DOW:-7}"
MONTHLY_DOM="${IPT_MONTHLY_DOM:-01}"

SUDO=sudo
[ "$(id -u)" = 0 ] && SUDO=""

act() {
    if [ "$APPLY" -eq 1 ]; then $SUDO "$@" || echo "    WARNING: failed: $*"
    else echo "    would: $*"; fi
}

human() {
    local b="${1:-0}"
    case "$b" in ''|*[!0-9]*) echo "?"; return ;; esac
    if   [ "$b" -ge 1073741824 ]; then echo "$((b / 1073741824))G"
    elif [ "$b" -ge 1048576 ];    then echo "$((b / 1048576))M"
    elif [ "$b" -ge 1024 ];       then echo "$((b / 1024))K"
    else echo "${b}B"; fi
}

echo "=============================================================="
if [ "$APPLY" -eq 1 ]; then echo " MIGRATING backups to a single tiered process"
else echo " DRY RUN -- nothing will change. Re-run with --apply to commit."; fi
echo "=============================================================="
echo

# ---------------------------------------------------------------- 1. layout
echo "1. Directory layout under $DATA_DIR"
for d in "$DATA_DIR" "$DATA_DIR/daily" "$DATA_DIR/weekly" "$DATA_DIR/monthly" "$REVIEW_DIR"; do
    if [ -d "$d" ]; then echo "    exists: $d"; else act mkdir -p "$d"; fi
done
echo

# ------------------------------------------------------- 2. superseded script
echo "2. Superseded script: $OLD_SCRIPT"
if [ -f "$OLD_SCRIPT" ] && [ ! -L "$OLD_SCRIPT" ]; then
    echo "    --- current contents, review before continuing ---"
    sed 's/^/    | /' "$OLD_SCRIPT"
    echo "    --------------------------------------------------"
    echo "    Replaced by $NEW_SCRIPT. Renaming aside, not deleting:"
    act mv "$OLD_SCRIPT" "$OLD_SCRIPT.superseded-$STAMP"
else
    echo "    not present (nothing to supersede)"
fi
echo

# ------------------------------------------------- 3. adopt legacy archives
echo "3. Adopting legacy archives into the tiers"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Collect every candidate archive: the server's timestamped ones, any bare
# dated ones at the top level, and leftovers in the repo directory.
: > "$WORK/found"
for f in "$DATA_DIR"/vce_ipt_data_*.tar.gz \
         "$DATA_DIR"/ipt_data_*.tar.gz \
         "$DATA_DIR"/val_ipt_latest.tar.gz \
         "$REPO_DIR"/aws_backups/*.tar.gz; do
    [ -f "$f" ] || continue          # skips unmatched globs and symlinks' targets
    [ -L "$f" ] && continue          # never adopt the 'latest' symlink itself
    # Derive the archive's date: from the filename where possible, else mtime.
    b="$(basename "$f")"
    d=""
    case "$b" in
        vce_ipt_data_[0-9][0-9][0-9][0-9]_[0-9][0-9]_[0-9][0-9]-*)
            d="$(echo "$b" | sed -E 's/^vce_ipt_data_([0-9]{4})_([0-9]{2})_([0-9]{2})-.*/\1-\2-\3/')" ;;
        ipt_data_[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].tar.gz)
            d="$(echo "$b" | sed -E 's/^ipt_data_([0-9]{4}-[0-9]{2}-[0-9]{2})\.tar\.gz$/\1/')" ;;
    esac
    [ -n "$d" ] || d="$(date -r "$f" +%F)"
    printf '%s\t%s\t%s\n' "$d" "$(stat -c %s "$f")" "$f" >> "$WORK/found"
done

total_found="$(grep -c . "$WORK/found" 2>/dev/null || echo 0)"
if [ "$total_found" -eq 0 ]; then
    echo "    no legacy archives found -- nothing to adopt"
else
    total_bytes="$(awk -F'\t' '{s+=$2} END {print s+0}' "$WORK/found")"
    echo "    found $total_found archive(s), $(human "$total_bytes") total"

    # One archive per date: keep the LARGEST for that date (most complete run).
    sort -t"$(printf '\t')" -k1,1 -k2,2nr "$WORK/found" | awk -F'\t' '!seen[$1]++' \
        | sort -t"$(printf '\t')" -k1,1r > "$WORK/bydate"
    # Same-date losers go to review rather than being discarded.
    cut -f3 "$WORK/bydate" | sort > "$WORK/keepers"
    cut -f3 "$WORK/found"  | sort > "$WORK/all"
    comm -23 "$WORK/all" "$WORK/keepers" > "$WORK/dupes"

    n_dates="$(grep -c . "$WORK/bydate")"
    n_dupes="$(grep -c . "$WORK/dupes" 2>/dev/null || echo 0)"
    echo "    $n_dates distinct date(s); $n_dupes same-date duplicate(s) -> legacy_review/"

    # Select the dates each tier should hold, newest first.
    cut -f1 "$WORK/bydate" | head -n "$KEEP_DAILY" > "$WORK/t_daily"
    : > "$WORK/t_weekly"; : > "$WORK/t_monthly"
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        [ "$(date -d "$d" +%u 2>/dev/null)" = "$WEEKLY_DOW" ] && echo "$d" >> "$WORK/t_weekly"
        [ "$(date -d "$d" +%d 2>/dev/null)" = "$MONTHLY_DOM" ] && echo "$d" >> "$WORK/t_monthly"
    done <<< "$(cut -f1 "$WORK/bydate")"
    head -n "$KEEP_WEEKLY"  "$WORK/t_weekly"  > "$WORK/t_weekly.k";  mv "$WORK/t_weekly.k"  "$WORK/t_weekly"
    head -n "$KEEP_MONTHLY" "$WORK/t_monthly" > "$WORK/t_monthly.k"; mv "$WORK/t_monthly.k" "$WORK/t_monthly"

    echo "    tier selection: daily $(grep -c . "$WORK/t_daily") (keep $KEEP_DAILY), weekly $(grep -c . "$WORK/t_weekly") (keep $KEEP_WEEKLY), monthly $(grep -c . "$WORK/t_monthly") (keep $KEEP_MONTHLY)"
    echo

    n_adopt=0; n_review=0; b_review=0
    while IFS="$(printf '\t')" read -r d sz f; do
        [ -n "${d:-}" ] || continue
        canon="ipt_data_$d.tar.gz"
        primary=""; extras=""
        grep -qx "$d" "$WORK/t_daily"   && primary=daily
        if grep -qx "$d" "$WORK/t_weekly"; then
            [ -z "$primary" ] && primary=weekly || extras="$extras weekly"; fi
        if grep -qx "$d" "$WORK/t_monthly"; then
            [ -z "$primary" ] && primary=monthly || extras="$extras monthly"; fi

        if [ -z "$primary" ]; then
            echo "    review  $(basename "$f")  ($d, $(human "$sz")) - outside every retention tier"
            act mv -n "$f" "$REVIEW_DIR/"
            n_review=$((n_review + 1)); b_review=$((b_review + sz))
        else
            echo "    adopt   $(basename "$f")  ->  $primary/$canon${extras:+  (+linked into:$extras)}"
            act mv -n "$f" "$DATA_DIR/$primary/$canon"
            for t in $extras; do
                act ln -f "$DATA_DIR/$primary/$canon" "$DATA_DIR/$t/$canon"
            done
            n_adopt=$((n_adopt + 1))
        fi
    done < "$WORK/bydate"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        echo "    review  $(basename "$f")  - duplicate of another archive's date"
        act mv -n "$f" "$REVIEW_DIR/"
        n_review=$((n_review + 1)); b_review=$((b_review + $(stat -c %s "$f" 2>/dev/null || echo 0)))
    done < "$WORK/dupes"

    echo
    echo "    SUMMARY: $n_adopt adopted into tiers, $n_review moved to legacy_review/ ($(human "$b_review"))"
    echo "    Nothing was deleted. When you are satisfied, reclaim that space with:"
    echo "        sudo rm -rf $REVIEW_DIR"
fi
echo

# -------------------------------------------------------------- 4. log merge
echo "4. Log history"
SRC_LOG="$REPO_DIR/aws_backups/vce_ipt_backup.log"
DST_LOG="$DATA_DIR/vce_ipt_backup.log"
if [ -f "$SRC_LOG" ]; then
    # Idempotent: only append lines the destination does not already have, so a
    # second --apply run cannot duplicate history.
    if [ -f "$DST_LOG" ] && grep -qxFf "$SRC_LOG" "$DST_LOG" 2>/dev/null; then
        echo "    repo log history already present in $DST_LOG"
    else
        echo "    appending repo log history to $DST_LOG"
        act sh -c "cat '$SRC_LOG' >> '$DST_LOG'"
    fi
    echo "    (the repo copy stays git-tracked but is no longer written to)"
else
    echo "    no repo log to merge"
fi
echo

# ---------------------------------------------------------------- 5. verify
echo "5. Verifying the unified script"
if [ -x "$NEW_SCRIPT" ]; then
    echo "    $NEW_SCRIPT is executable"
    if [ "$APPLY" -eq 1 ]; then
        echo "    --- resulting inventory ---"
        $SUDO "$NEW_SCRIPT" --list 2>&1 | sed 's/^/      /'
    fi
else
    echo "    *** ERROR: $NEW_SCRIPT missing or not executable ***"; exit 1
fi
echo

# --------------------------------------------------------------- 6. crontab
echo "6. Crontab"
echo "    Install the entries from 05_root_crontab.txt with:  sudo crontab -e"
echo "    The backup line must read:"
echo "        0 2 * * * $NEW_SCRIPT"
echo "    Any older line calling $OLD_SCRIPT must be REMOVED, or both processes"
echo "    run and fight over $DATA_DIR."
echo "    Currently installed:"
$SUDO crontab -l 2>/dev/null | grep -nE 'backup|aws' | sed 's/^/      /' || echo "      (none found)"
echo

# ------------------------------------------------------------------ 7. mail
echo "7. Mail delivery (everything alerts through cron MAILTO)"
# Debian/Ubuntu cron hands mail to /usr/sbin/sendmail. With no MTA installed it
# silently discards every alert and every weekly digest.
if [ -x /usr/sbin/sendmail ] || command -v sendmail >/dev/null 2>&1; then
    echo "    sendmail present -- cron can deliver mail"
else
    echo "    *** WARNING: no sendmail found. cron CANNOT deliver mail, so every"
    echo "        failure alert and the weekly digest would be silently discarded."
    echo "        Install one, e.g.:  sudo apt install postfix   (or msmtp-mta)"
fi
echo

echo "=============================================================="
if [ "$APPLY" -eq 1 ]; then
    echo " Migration applied. Verify with:  sudo $NEW_SCRIPT --report"
else
    echo " Dry run complete. Re-run with --apply when the above looks right."
fi
echo "=============================================================="
