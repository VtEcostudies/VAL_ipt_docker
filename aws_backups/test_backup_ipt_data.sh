#!/bin/bash
#
# Self-contained test suite for backup_ipt_data.sh.
#
# Runs entirely in a temp directory against a MOCK aws CLI -- it never touches
# /usr/ipt, /usr/local/backups, or the real S3 bucket, and needs no credentials.
# Run it on the host before trusting the backup, and after any edit:
#
#     ./aws_backups/test_backup_ipt_data.sh
#
# Exits 0 if every case passes, 1 otherwise.
#
set -u

BK="$(dirname "$(readlink -f "$0")")/backup_ipt_data.sh"
[ -x "$BK" ] || { echo "cannot find $BK"; exit 1; }

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT
pass=0; fail=0

ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
check(){ [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: expected '$3', got '$2'"; }
has()  { echo "$2" | grep -q "$3" && ok "$1" || bad "$1"; }
hasnt(){ echo "$2" | grep -q "$3" && bad "$1" || ok "$1"; }

mkdir -p "$TD/bin" "$TD/src/ipt/resources" "$TD/dest" "$TD/s3"
echo config > "$TD/src/ipt/config.properties"
head -c 100000 /dev/urandom > "$TD/src/ipt/resources/data.bin"

cat > "$TD/bin/aws" <<'AWS'
#!/bin/bash
ROOT="${FAKE_S3_ROOT}"
[ "${FAKE_S3_FAIL:-0}" = 1 ] && { echo "mock aws: denied" >&2; exit 1; }
[ "${FAKE_LS_FAIL:-0}" = 1 ] && [ "$2" = ls ] && { echo "mock aws: RequestTimeout" >&2; exit 1; }
sub="$1"; shift; [ "$sub" = s3 ] || exit 0
op="$1"; shift
path_of() { echo "$ROOT/${1#s3://}"; }
case "$op" in
  cp) src="$1"; dst="$2"; d="$(path_of "$dst")"; mkdir -p "$(dirname "$d")"
      case "$src" in s3://*) cp "$(path_of "$src")" "$d" ;; *) cp "$src" "$d" ;; esac ;;
  ls) d="$(path_of "$1")"; [ -d "$d" ] || exit 0
      for f in "$d"/*; do [ -e "$f" ] || continue
        printf '2026-01-01 02:00:00 %10d %s\n' "$(stat -c %s "$f")" "$(basename "$f")"; done ;;
  rm) rm -f "$(path_of "$1")" ;;
esac
AWS
chmod +x "$TD/bin/aws"

export FAKE_S3_ROOT="$TD/s3" PATH="$TD/bin:$PATH"
export IPT_BACKUP_SRC="$TD/src/ipt" IPT_BACKUP_DIR="$TD/dest" IPT_BACKUP_S3="s3://ipt.backups"
export IPT_DIGEST_DOW=9   # keep successful runs silent unless a test wants the digest

reset()   { rm -rf "$TD/dest" "$TD/s3"; mkdir -p "$TD/dest"/{daily,weekly,monthly} "$TD/s3"; }
seedloc() { mkdir -p "$TD/dest/$1"; for d in $2; do head -c 60000 /dev/urandom > "$TD/dest/$1/ipt_data_$d.tar.gz"; done; }
seeds3()  { mkdir -p "$TD/s3/ipt.backups/$1"; for d in $2; do touch "$TD/s3/ipt.backups/$1/ipt_data_$d.tar.gz"; done; }
nloc()    { ls -1 "$TD/dest/$1"/ipt_data_*.tar.gz 2>/dev/null | wc -l; }
ns3()     { ls -1 "$TD/s3/ipt.backups/$1" 2>/dev/null | grep -c '^ipt_data_'; }
# NB: 'seq -w' pads to the width of the LARGEST value, so 'seq -w 1 9' yields
# 1..9 UNPADDED and would build non-canonical names the script rightly ignores.
days()    { local i; for i in $(seq 1 "$2"); do printf '%s-%02d\n' "$1" "$i"; done; }

echo "=== backup_ipt_data.sh test suite ==="

# --- basics ---------------------------------------------------------------
reset; "$BK" >/dev/null 2>&1
check "writes the archive into daily/"    "$(nloc daily)" "1"
check "uploads to s3 daily/"              "$(ns3 daily)"  "1"
[ -L "$TD/dest/val_ipt_latest.tar.gz" ] && ok "latest symlink created" || bad "latest symlink missing"
check "latest points into daily/"         "$(readlink "$TD/dest/val_ipt_latest.tar.gz" | cut -d/ -f1)" "daily"

rm -rf "$TD/restore"; mkdir -p "$TD/restore"
tar -xzf "$TD/dest/val_ipt_latest.tar.gz" -C "$TD/restore" 2>/dev/null
diff -r "$TD/src/ipt" "$TD/restore/ipt" >/dev/null 2>&1 && ok "archive restores byte-identically" || bad "restored tree differs"

# --- local tiered rotation, mirroring s3 ----------------------------------
reset; seedloc daily "$(days 2026-08 12)"
IPT_KEEP_LOCAL_DAILY=7 "$BK" >/dev/null 2>&1
check "local daily rotation keeps N"      "$(nloc daily)" "7"

reset; seedloc weekly "$(days 2026-06 9)"
IPT_KEEP_LOCAL_WEEKLY=4 "$BK" >/dev/null 2>&1
check "local weekly rotation keeps N"     "$(nloc weekly)" "4"

reset; seedloc monthly "$(days 2026-05 8)"
IPT_KEEP_LOCAL_MONTHLY=3 "$BK" >/dev/null 2>&1
check "local monthly rotation keeps N"    "$(nloc monthly)" "3"

# --- promotion, local and s3 ----------------------------------------------
reset
IPT_WEEKLY_DOW=$(date +%u) IPT_MONTHLY_DOM=$(date +%d) "$BK" >/dev/null 2>&1
check "promotes locally to weekly"        "$(nloc weekly)"  "1"
check "promotes locally to monthly"       "$(nloc monthly)" "1"
check "promotes to s3 weekly"             "$(ns3 weekly)"   "1"
check "promotes to s3 monthly"            "$(ns3 monthly)"  "1"
a="$(stat -c %i "$TD/dest/daily"/ipt_data_*.tar.gz)"
b="$(stat -c %i "$TD/dest/weekly"/ipt_data_*.tar.gz)"
check "local promotion is a hard link (no extra disk)" "$a" "$b"

# --- s3 rotation ----------------------------------------------------------
reset; seeds3 daily "$(days 2026-07 20)"
IPT_KEEP_S3_DAILY=14 "$BK" >/dev/null 2>&1
check "s3 daily rotation keeps N"         "$(ns3 daily)" "14"

reset; seeds3 daily "$(days 2026-08 14)"
touch "$TD/s3/ipt.backups/daily/zzz_stray.txt" "$TD/s3/ipt.backups/daily/aaa_readme.md" \
      "$TD/s3/ipt.backups/daily/val_ipt_latest.tar.gz"
IPT_KEEP_S3_DAILY=14 "$BK" >/dev/null 2>&1
check "foreign objects don't evict backups" "$(ns3 daily)" "14"
check "foreign objects left untouched"      "$(ls -1 "$TD/s3/ipt.backups/daily" | grep -vc '^ipt_data_')" "3"

reset; seeds3 daily "$(days 2026-08 20)"
before="$(ns3 daily)"
FAKE_LS_FAIL=1 IPT_KEEP_S3_DAILY=5 "$BK" >/dev/null 2>&1
check "unreadable s3 listing deletes nothing" "$(ns3 daily)" "$((before + 1))"

# --- alerting -------------------------------------------------------------
reset; out="$("$BK" 2>&1)"
check "successful run is silent"          "${#out}" "0"

reset; out="$(FAKE_S3_FAIL=1 "$BK" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "s3 failure exits non-zero" || bad "s3 failure exited 0"
has  "s3 failure prints an alert" "$out" "S3 upload"
check "local archive kept despite s3 failure" "$(nloc daily)" "1"

# --- the data-loss guards -------------------------------------------------
reset; seedloc daily "$(days 2026-08 7)"; seeds3 daily "$(days 2026-08 14)"
mkdir -p "$TD/empty"
bl="$(nloc daily)"; bs="$(ns3 daily)"
out="$(IPT_BACKUP_SRC="$TD/empty" "$BK" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "empty source exits non-zero" || bad "empty source exited 0"
has   "empty source alerts" "$out" "empty or unmounted"
check "empty source prunes NO local archives" "$(nloc daily)" "$bl"
check "empty source prunes NO s3 objects"     "$(ns3 daily)"  "$bs"
ls "$TD/dest/daily"/*.partial >/dev/null 2>&1 && bad "left a .partial behind" || ok "no .partial left behind"

reset; seedloc daily "$(days 2026-08 5)"
head -c 4000000 /dev/urandom > "$TD/src/ipt/resources/data.bin"
IPT_KEEP_LOCAL_DAILY=7 "$BK" >/dev/null 2>&1
bl="$(nloc daily)"
head -c 200000 /dev/urandom > "$TD/src/ipt/resources/data.bin"   # 4M -> 200K
out="$(IPT_KEEP_LOCAL_DAILY=1 "$BK" 2>&1)"
has   "drastic shrink alerts"        "$out" "shrank"
has   "shrink withholds rotation"    "$out" "ROTATION IS SKIPPED"
check "shrink keeps every older archive despite KEEP=1" "$(nloc daily)" "$bl"
head -c 100000 /dev/urandom > "$TD/src/ipt/resources/data.bin"

for v in abc 0 -1; do
  reset; seedloc daily "$(days 2026-08 10)"; b="$(nloc daily)"
  out="$(IPT_KEEP_LOCAL_DAILY="$v" "$BK" 2>&1)"
  check "bad retention '$v' deletes nothing" "$(( $(nloc daily) - 1 ))" "$b"
  has   "bad retention '$v' alerts" "$out" "rotation SKIPPED"
done

reset; out="$(IPT_BACKUP_SRC=/nonexistent "$BK" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "missing source exits non-zero" || bad "missing source exited 0"
has   "missing source prints an alert" "$out" "FAILED"

# --- housekeeping ---------------------------------------------------------
reset; touch "$TD/dest/daily/ipt_data_2026-01-01.tar.gz.partial" "$TD/dest/ipt_data_2026-01-02.tar.gz.partial"
"$BK" >/dev/null 2>&1
ls "$TD/dest"/*.partial "$TD/dest/daily"/*.partial >/dev/null 2>&1 && bad "orphaned .partial not swept" || ok "orphaned .partial files swept"

reset; seedloc daily 2026-08-01
touch -d "5 days ago" "$TD/dest/daily/ipt_data_2026-08-01.tar.gz"
out="$("$BK" 2>&1)"
has   "missed nightly runs are reported" "$out" "runs have been missed"

reset; head -c 60000 /dev/urandom > "$TD/dest/vce_ipt_data_2024_01_01-02_00_00.tar.gz"
out="$("$BK" --list 2>&1)"
has   "un-migrated legacy archives are flagged" "$out" "un-migrated"

# --- modes ----------------------------------------------------------------
reset; "$BK" >/dev/null 2>&1
before="$(find "$TD/dest" "$TD/s3" -type f | sort | md5sum)"
"$BK" --dry-run >/dev/null 2>&1
check "--dry-run changes nothing" "$(find "$TD/dest" "$TD/s3" -type f | sort | md5sum)" "$before"

reset; seedloc daily "$(days 2026-08 12)"
IPT_KEEP_LOCAL_DAILY=7 "$BK" --prune-only >/dev/null 2>&1
check "--prune-only rotates without a new backup" "$(nloc daily)" "7"

reset; "$BK" >/dev/null 2>&1
has  "--report prints a digest"   "$("$BK" --report 2>&1)" "IPT BACKUP DIGEST"
has  "--list prints inventory"    "$("$BK" --list   2>&1)" "local ("
"$BK" --bogus >/dev/null 2>&1; check "unknown option rejected" "$?" "2"

reset; "$BK" >/dev/null 2>&1
( flock 9; sleep 2 ) 9>"$TD/dest/.backup.lock" &
sleep 0.3
out="$("$BK" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q SKIPPED && ok "concurrent run is locked out" || bad "lock did not hold"
wait 2>/dev/null

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
