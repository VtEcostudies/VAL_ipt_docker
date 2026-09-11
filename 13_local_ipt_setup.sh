#!/bin/bash
#
# Bring up a disposable local IPT and walk it through first-run setup.
#
# WHY. Importing a generated resource package, or pointing a <sqlsource> at a
# database, should be tried somewhere it cannot matter before it touches
# ipt.vtatlasoflife.org. This gives you that in one command, repeatably — the
# four-step setup wizard is driven over HTTP rather than clicked, so a reset and
# retry costs nothing and every run starts identical.
#
# The instance is pinned to the SAME IPT version as production (3.0.1). Testing
# an import against a different version proves nothing: resource.xml is
# XStream-serialized and its shape tracks the code.
#
# It is bound to 127.0.0.1 and set to TEST mode, so it cannot register anything
# with GBIF even if asked.
#
# Usage:
#   ./13_local_ipt_setup.sh              # up + setup (idempotent; skips if ready)
#   ./13_local_ipt_setup.sh --reset      # destroy the data directory and redo
#   ./13_local_ipt_setup.sh --down       # stop, keep data
#
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1

COMPOSE="docker compose -f docker-compose-local.yml"
BASE="${LOCAL_IPT_URL:-http://localhost:8088}"
DATA="$(pwd)/ipt_data_local"
JAR="$(mktemp -d)/c.txt"

ADMIN_EMAIL="${LOCAL_IPT_EMAIL:-jloomis@vtecostudies.org}"
ADMIN_PW="${LOCAL_IPT_PASSWORD:-LocalTest123!}"

say() { echo "  $*"; }
hr()  { echo; echo "── $* ──────────────────────────────────────"; }

case "${1:-}" in
  --down)  $COMPOSE down; exit 0 ;;
  --reset)
    hr "Resetting"
    $COMPOSE down 2>/dev/null
    # The IPT writes as uid 999; a plain rm as your user cannot remove those.
    docker run --rm -v "$(pwd):/w" --user 0 alpine:latest \
        sh -c 'rm -rf /w/ipt_data_local' 2>/dev/null
    say "data directory destroyed"
    ;;
esac

# ─── Up ────────────────────────────────────────────────────────────────────
hr "Starting the local IPT"

# The container runs as uid 999 (tomcat) and the bind mount inherits the host
# owner, so an unprepared directory is silently read-only to the IPT and the
# wizard rejects step 1 with no useful message.
if [ ! -d "$DATA" ]; then
    docker run --rm -v "$(pwd):/w" --user 0 alpine:latest \
        sh -c 'mkdir -p /w/ipt_data_local && chown 999:999 /w/ipt_data_local'
    say "created $DATA owned by uid 999"
fi

$COMPOSE up -d >/dev/null 2>&1 || { echo "Failed to start. Is the LoonWeb stack up?"; exit 1; }

for i in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/" 2>/dev/null)
    [ "$code" != "000" ] && break
    sleep 2
done
[ "${code:-000}" = "000" ] && { echo "IPT never answered on $BASE"; $COMPOSE logs --tail 20; exit 1; }

VERSION=$(curl -s --max-time 10 "$BASE/rss.do" | grep -o '<generator>[^<]*' | cut -d'>' -f2)
# rss.do only reports a generator once setup is done, so on a cold start
# $VERSION is empty and any comparison is meaningless. Read the version from the
# image tag instead, which is true before and after setup.
VERSION=${VERSION:-$(docker inspect ipt_local --format '{{.Config.Image}}' 2>/dev/null)}
say "running ${VERSION:-unknown}"

PROD_VERSION=$(curl -s --max-time 15 https://ipt.vtatlasoflife.org/rss.do 2>/dev/null \
                 | grep -o '<generator>[^<]*' | cut -d'>' -f2)
if [ -n "$PROD_VERSION" ]; then
    # "GBIF IPT 3.0.1-r2584670" vs "gbif/ipt:3.0.1" — compare the x.y.z only.
    pv=$(echo "$PROD_VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    lv=$(echo "$VERSION"      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$pv" ] && [ "$pv" = "$lv" ]; then
        say "matches production ($pv)"
    elif [ -n "$pv" ]; then
        say "WARNING: production runs $pv, this is ${lv:-unknown}"
        say "         pin image: gbif/ipt:$pv in docker-compose-local.yml"
    fi
fi

# ─── Setup wizard ──────────────────────────────────────────────────────────
LANDING=$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 "$BASE/")
if [ -z "$LANDING" ] || ! echo "$LANDING" | grep -q setup; then
    hr "Already set up"
    say "$BASE"
    say "sign in as $ADMIN_EMAIL"
    exit 0
fi

hr "Running the setup wizard"

# Every POST must echo the CSRFtoken cookie back as a form field.
csrf() { awk '/CSRFtoken/{print $7}' "$JAR" 2>/dev/null; }
prime() { curl -s -c "$JAR" -b "$JAR" --max-time 15 "$BASE/$1" -o /dev/null; }
post()  { local path="$1"; shift
          curl -s -c "$JAR" -b "$JAR" --max-time 30 -o /dev/null -w '%{http_code}' \
               "$@" -d "CSRFtoken=$(csrf)" "$BASE/$path"; }

# A step is judged by whether the wizard MOVED ON, not by the HTTP code: step 1
# can return 500 while having created the data directory perfectly well, and a
# 302 can still land back on the same step.
# MUST follow redirects. "/" always 302s to setupDataDirectory.do, which then
# forwards internally to whichever step is actually outstanding — so reading
# only the first Location makes every step look like step 1 forever.
at_step() { curl -sL -o /dev/null -w '%{url_effective}' --max-time 15 \
              --cookie-jar /dev/null "$BASE/" \
              | grep -oE 'setup[A-Za-z]*\.do' | head -1; }
# A step succeeded if the wizard is no longer ASKING for it. Comparing before
# and after does not work: a fresh container may already have completed a step
# before the first probe, and the IPT returns 500 on step 1 while having done
# the work. The page it is asking for is the only reliable signal.
step() {
    local label="$1" path="$2"; shift 2
    local code after
    if [ "$(at_step)" != "$path" ]; then
        say "$label already done"
        return 0
    fi
    code=$(post "$path" "$@")
    after=$(at_step)
    if [ "$after" = "$path" ]; then
        say "$label FAILED (HTTP $code) — still being asked for $path"
        echo
        echo "  Finish by hand at $BASE, or inspect:"
        echo "    docker logs ipt_local 2>&1 | tail -30"
        exit 1
    fi
    say "$label ok${after:+ — next: $after}"
}

prime "setupDataDirectory.do"
step "1/4 data directory  " setupDataDirectory.do -d 'dataDirPath=/srv/ipt' -d 'save=Save'
step "2/4 administrator   " setupDefaultAdministrator.do \
        -d "user.email=$ADMIN_EMAIL" -d 'user.firstname=Local' -d 'user.lastname=Test' \
        -d "user.password=$ADMIN_PW" -d "password2=$ADMIN_PW" -d 'save=Save'
# TEST, never Production: a throwaway instance must not be able to register a
# dataset with GBIF.
step "3/4 mode = Test     " setupMode.do -d 'modeSelected=Test' -d 'save=Save' 

LANDING=$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 "$BASE/")
if echo "${LANDING:-}" | grep -q setup; then
    say "4/4 still at: $LANDING — finish by hand at $BASE"
else
    say "4/4 complete"
fi

# ─── Core types and extensions ─────────────────────────────────────────────
#
# A fresh IPT 3.0.1 cannot install its first extension through the web UI.
# ExtensionsAction.list() derives lastSynchronised by looping over INSTALLED
# extensions; with none installed it stays null, and extensions.ftl line 226
# does ${lastSynchronised?datetime?...} with no null guard, so FreeMarker throws
# and the page renders without the install list. The button that would fix it
# lives on the page that will not render — a genuine chicken-and-egg.
#
# ExtensionsAction.save() installs from a plain url parameter, which sidesteps
# it. Installing these four also makes the instance able to map the LoonWeb
# resource package at all.
# Needs an authenticated session.
csrf_login() {
    rm -f "$JAR"
    curl -s -c "$JAR" -b "$JAR" --max-time 15 "$BASE/login.do" -o "$JAR.html"
    local t
    t=$(grep -oE 'name="csrfToken"[^>]*value="[^"]*"' "$JAR.html" 2>/dev/null \
          | grep -oE 'value="[^"]*"' | cut -d'"' -f2)
    curl -s -c "$JAR" -b "$JAR" --max-time 20 -o /dev/null \
         -d "email=$ADMIN_EMAIL" -d "password=$ADMIN_PW" -d "csrfToken=$t" "$BASE/login.do"
    rm -f "$JAR.html"
}
csrf_login

hr "Installing core types and extensions"

REGISTRY="${LOCAL_IPT_REGISTRY:-https://gbrds.gbif-uat.org/registry/extensions.json}"
WANT_FILE=$(mktemp)
curl -sL --max-time 60 "$REGISTRY" -o "$WANT_FILE.json" 2>/dev/null

python3 - "$WANT_FILE.json" > "$WANT_FILE" <<'PYEOF'
import json, sys
want = {
  'http://rs.tdwg.org/dwc/terms/Event':                        'Event core',
  'http://rs.tdwg.org/dwc/terms/Occurrence':                   'Occurrence',
  'http://rs.iobis.org/obis/terms/ExtendedMeasurementOrFact':  'eMoF',
  'http://rs.tdwg.org/eco/terms/Event':                        'Humboldt',
}
try:
    for e in json.load(open(sys.argv[1]))['extensions']:
        i = e.get('identifier', '')
        if i in want and e.get('isLatest'):
            print(f"{want[i]}|{e['url']}")
except Exception:
    pass
PYEOF

if [ -s "$WANT_FILE" ]; then
    while IFS='|' read -r name url; do
        [ -n "$url" ] || continue
        code=$(curl -sL -c "$JAR" -b "$JAR" --max-time 180 -o /dev/null -w '%{http_code}' \
                 --data-urlencode "url=$url" -d "save=Save" "$BASE/admin/extension.do")
        printf "  %-12s HTTP %s\n" "$name" "$code"
    done < "$WANT_FILE"
    n=$(docker exec ipt_local sh -c 'ls /srv/ipt/config/.extensions/ 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r')
    say "installed: ${n:-0} extension definitions"
else
    say "could not read $REGISTRY — install core types by hand at $BASE/admin/extensions.do"
fi
rm -f "$WANT_FILE" "$WANT_FILE.json"

# ─── Verify ────────────────────────────────────────────────────────────────
hr "Verifying"
rm -f "$JAR"; prime "login.do"
LOGIN=$(post login.do -d "email=$ADMIN_EMAIL" -d "password=$ADMIN_PW")
say "login            HTTP $LOGIN"
say "manage page      HTTP $(curl -sL -c "$JAR" -b "$JAR" -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/manage/")"

if docker exec ipt_local getent hosts db_vt >/dev/null 2>&1; then
    say "db_vt reachable  yes (SQL sources can use host db_vt port 5432)"
else
    say "db_vt reachable  NO — start the LoonWeb stack and re-run"
fi

cat <<DONE

════════════════════════════════════════════════════════════════
 $BASE
   user      $ADMIN_EMAIL
   password  $ADMIN_PW          (throwaway; local only)

 Import a generated package:
   cd ~/Docker/VCE_db_docker/db_both/db_ipt
   ./build_ipt_resource.sh --source file --out /tmp/pkg
   # then: Manage Resources -> create a new resource -> upload the zip

 For a SQL-source test, generate against the container network — the host's
 6543 is bound to 127.0.0.1 and is not reachable from inside a container:
   IPT_DB_HOST=db_vt IPT_DB_PORT=5432 IPT_DB_PASSWORD=... \\
     ./build_ipt_resource.sh --source sql --out /tmp/pkg

 Reset:  ./13_local_ipt_setup.sh --reset
════════════════════════════════════════════════════════════════
DONE
