#!/bin/bash
#
# Install the SSH tunnel this IPT uses to read the LoonWeb Darwin Core views.
#
# WHY A TUNNEL. The LoonWeb database publishes four read-only views
# (loons.dwc_event / dwc_occurrence / dwc_emof / dwc_humboldt) that this IPT
# pulls as a SQL source. Rather than exposing Postgres on the public internet,
# the database host binds its port to 127.0.0.1 and this machine dials out over
# SSH. Consequences worth knowing:
#
#   * The IPT connects to localhost:6543 — there is no database hostname, no
#     DNS record, no TLS certificate and no firewall rule anywhere.
#   * The key installed on the far side may do exactly one thing: forward
#     127.0.0.1:6543. It has no shell and can run no command.
#   * The "ipt" database role has SELECT on the four views and nothing else —
#     it cannot read the base tables, which hold volunteer email addresses.
#
# WHAT THIS SCRIPT DOES
#   1. Generates this machine's tunnel identity key (once; never overwritten)
#   2. Records the database host's SSH host key, verified against a fingerprint
#   3. Writes and enables the loonweb-tunnel systemd unit
#   4. Proves the tunnel carries a real query
#
# THE ONE MANUAL STEP. After step 1 this script prints a public key. Someone
# with sudo on the database host must install it before the tunnel can connect:
#
#     sudo ./deploy/setup-ipt-tunnel.sh /tmp/ipt.pub     # in VCE_db_docker
#
# Re-run this script after that; it is idempotent and picks up where it left off.
#
# SAFE BY DEFAULT: prints a full plan and changes nothing. Re-run with --apply.
#
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1

APPLY=0
DB_HOST="${LOONWEB_DB_HOST:-vt.loonweb.org}"
TUNNEL_USER="${LOONWEB_TUNNEL_USER:-ipttunnel}"
LOCAL_PORT="${LOONWEB_LOCAL_PORT:-6543}"
REMOTE_PORT="${LOONWEB_REMOTE_PORT:-6543}"
DB_NAME="${LOONWEB_DB_NAME:-vt_loons}"
DB_USER="${LOONWEB_DB_USER:-ipt}"

# Read off /etc/ssh/ssh_host_ed25519_key.pub on vt.loonweb.org, 2026-09-10, and
# confirmed identical from an external ssh-keyscan. Pinning it here is what
# makes StrictHostKeyChecking=yes meaningful: without a known-good value, the
# first keyscan would trust whatever answered.
EXPECT_FP="${LOONWEB_HOST_FP:-SHA256:iXtYuez46m+P78iVU/L3YPzea9wdeyP7x9F9zHmCL+M}"

CONF_DIR="/etc/loonweb-tunnel"
KEY="$CONF_DIR/id_ed25519"
KNOWN="$CONF_DIR/known_hosts"
UNIT="/etc/systemd/system/loonweb-tunnel.service"

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)   APPLY=1 ;;
        --host)    DB_HOST="$2"; shift ;;
        -h|--help)
            sed -n '2,32p' "$0"
            echo "Usage: $0 [--apply] [--host <database-host>]"
            exit 0 ;;
        *) echo "Unknown argument: $1"; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 2; }

act() { if [ "$APPLY" -eq 1 ]; then echo "   DO   $*"; else echo "   PLAN $*"; fi; }
hr()  { echo; echo "── $* ──────────────────────────────────────────"; }

echo "════════════════════════════════════════════════════════════════"
echo " LoonWeb database tunnel"
echo "   database host   $DB_HOST"
echo "   ssh user        $TUNNEL_USER"
echo "   forward         127.0.0.1:$LOCAL_PORT -> 127.0.0.1:$REMOTE_PORT"
echo "   mode            $([ "$APPLY" -eq 1 ] && echo APPLY || echo 'PLAN ONLY (re-run with --apply)')"
echo "════════════════════════════════════════════════════════════════"

# ─── 1. Identity key ───────────────────────────────────────────────────────
hr "1. Tunnel identity key"

NEED_INSTALL=0
if [ -f "$KEY" ]; then
    echo "   exists: $KEY"
    echo "   $(ssh-keygen -lf "$KEY.pub" 2>/dev/null || echo '(cannot read public half)')"
else
    act "mkdir -p $CONF_DIR"
    act "ssh-keygen -t ed25519 -f $KEY -N '' -C '$(hostname -f 2>/dev/null || hostname) loonweb tunnel'"
    NEED_INSTALL=1
    if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$CONF_DIR" && chmod 0750 "$CONF_DIR"
        # No passphrase: systemd starts this unattended at boot.
        ssh-keygen -q -t ed25519 -f "$KEY" -N '' \
            -C "$(hostname -f 2>/dev/null || hostname) loonweb tunnel"
        chmod 0600 "$KEY"; chmod 0644 "$KEY.pub"
        echo "   created"
    fi
fi

# ─── 2. Host key ───────────────────────────────────────────────────────────
hr "2. Database host key"

scan_fp() {
    ssh-keyscan -t ed25519 "$DB_HOST" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}'
}

if [ -f "$KNOWN" ] && grep -q . "$KNOWN" 2>/dev/null; then
    HAVE_FP=$(ssh-keygen -lf "$KNOWN" 2>/dev/null | awk '{print $2}' | head -1)
    echo "   recorded: $HAVE_FP"
    [ "$HAVE_FP" = "$EXPECT_FP" ] \
        && echo "   matches the pinned fingerprint" \
        || { echo; echo "   MISMATCH — pinned $EXPECT_FP"; echo "   Refusing to continue."; exit 3; }
else
    LIVE_FP=$(scan_fp)
    if [ -z "$LIVE_FP" ]; then
        echo "   Could not reach $DB_HOST on port 22."
        [ "$APPLY" -eq 1 ] && exit 3
    elif [ "$LIVE_FP" != "$EXPECT_FP" ]; then
        echo "   scanned  $LIVE_FP"
        echo "   pinned   $EXPECT_FP"
        echo
        echo "   MISMATCH. Either the host key was rotated (update LOONWEB_HOST_FP)"
        echo "   or something is intercepting the connection. Refusing to continue."
        exit 3
    else
        echo "   scanned $LIVE_FP — matches the pinned fingerprint"
        act "ssh-keyscan -t ed25519 $DB_HOST > $KNOWN"
        if [ "$APPLY" -eq 1 ]; then
            ssh-keyscan -t ed25519 "$DB_HOST" > "$KNOWN" 2>/dev/null
            chmod 0644 "$KNOWN"; echo "   recorded"
        fi
    fi
fi

# ─── 3. Is our key installed on the far side? ──────────────────────────────
hr "3. Access to $DB_HOST"

CAN_CONNECT=0
if [ -f "$KEY" ] && [ -f "$KNOWN" ]; then
    if ssh -q -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
           -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=yes \
           -i "$KEY" -O check "$TUNNEL_USER@$DB_HOST" 2>/dev/null; then
        CAN_CONNECT=1
    else
        # A forced-command key refuses to run anything, so a clean "permission
        # denied" and a refused command look different: test the forward itself.
        if timeout 15 ssh -N -f -o BatchMode=yes -o ConnectTimeout=10 \
                -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
                -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=yes \
                -i "$KEY" -L "127.0.0.1:$((LOCAL_PORT+10000)):127.0.0.1:$REMOTE_PORT" \
                "$TUNNEL_USER@$DB_HOST" 2>/dev/null; then
            CAN_CONNECT=1
            pkill -f "127.0.0.1:$((LOCAL_PORT+10000)):127.0.0.1:$REMOTE_PORT" 2>/dev/null
        fi
    fi
fi

if [ "$CAN_CONNECT" -eq 1 ]; then
    echo "   the far side accepts our key"
else
    echo "   the far side does NOT accept our key yet"
    NEED_INSTALL=1
fi

if [ "$NEED_INSTALL" -eq 1 ]; then
    echo
    echo "   ┌─ MANUAL STEP ────────────────────────────────────────────────┐"
    echo "   │ Send this PUBLIC key to whoever administers $DB_HOST."
    echo "   │ It is not secret — email or paste is fine."
    echo "   └──────────────────────────────────────────────────────────────┘"
    echo
    if [ -f "$KEY.pub" ]; then sed 's/^/      /' "$KEY.pub"; else
        echo "      (run with --apply first to generate it)"; fi
    echo
    echo "   They run, in the VCE_db_docker checkout on $DB_HOST:"
    echo "      sudo ./deploy/setup-ipt-tunnel.sh /tmp/ipt.pub"
    echo
    echo "   Then re-run this script."
fi

# ─── 4. systemd unit ───────────────────────────────────────────────────────
hr "4. systemd unit"

read -r -d '' UNIT_BODY <<UNITEOF || true
[Unit]
Description=SSH tunnel to the LoonWeb Postgres read-only views (GBIF IPT source)
Documentation=file://$(pwd)/12_install_loonweb_tunnel.sh
After=network-online.target
Wants=network-online.target

[Service]
Type=exec

# ExitOnForwardFailure: fail loudly rather than holding a live SSH session with
#   a dead forward, which looks healthy and serves nothing.
# ServerAlive*: notice a silently dropped connection in ~90s instead of hanging
#   until TCP eventually gives up.
# -N: request no command, so the forced command on the far side never runs.
ExecStart=/usr/bin/ssh -N \\
    -i $KEY \\
    -o UserKnownHostsFile=$KNOWN \\
    -o StrictHostKeyChecking=yes \\
    -o IdentitiesOnly=yes \\
    -o ExitOnForwardFailure=yes \\
    -o ServerAliveInterval=30 \\
    -o ServerAliveCountMax=3 \\
    -o TCPKeepAlive=yes \\
    -L 127.0.0.1:$LOCAL_PORT:127.0.0.1:$REMOTE_PORT \\
    $TUNNEL_USER@$DB_HOST

Restart=always
RestartSec=15

User=root
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadOnlyPaths=$CONF_DIR
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
UNITEOF

if [ -f "$UNIT" ] && [ "$(cat "$UNIT")" = "$UNIT_BODY" ]; then
    echo "   $UNIT is already current"
else
    act "write $UNIT"
    if [ "$APPLY" -eq 1 ]; then
        printf '%s\n' "$UNIT_BODY" > "$UNIT"
        chmod 0644 "$UNIT"
        systemctl daemon-reload
        echo "   written"
    fi
fi

if [ "$APPLY" -eq 1 ] && [ "$CAN_CONNECT" -eq 1 ]; then
    act "systemctl enable --now loonweb-tunnel"
    systemctl enable --now loonweb-tunnel >/dev/null 2>&1
    sleep 3
    systemctl is-active --quiet loonweb-tunnel \
        && echo "   running" \
        || { echo "   FAILED to start:"; journalctl -u loonweb-tunnel -n 15 --no-pager | sed 's/^/      /'; }
elif [ "$CAN_CONNECT" -eq 0 ]; then
    echo "   not starting the unit — the far side does not accept our key yet"
fi

# ─── 5. Prove it ───────────────────────────────────────────────────────────
hr "5. Verification"

if [ "$APPLY" -eq 1 ] && systemctl is-active --quiet loonweb-tunnel 2>/dev/null; then
    if command -v psql >/dev/null; then
        echo "   Enter the ipt database password (on $DB_HOST at /root/.loonweb_ipt_password):"
        if psql "host=127.0.0.1 port=$LOCAL_PORT dbname=$DB_NAME user=$DB_USER connect_timeout=10" \
                -t -A -c 'SELECT count(*) FROM loons.dwc_event' 2>&1 | sed 's/^/      dwc_event rows: /'; then :; fi
    else
        ss -lnt 2>/dev/null | grep -q "127.0.0.1:$LOCAL_PORT" \
            && echo "   tunnel is listening on 127.0.0.1:$LOCAL_PORT (psql not installed; skipping query)" \
            || echo "   WARNING: nothing is listening on 127.0.0.1:$LOCAL_PORT"
    fi
else
    echo "   (skipped — tunnel not running)"
fi

cat <<DONE

════════════════════════════════════════════════════════════════
 IPT source settings   (Administration -> Manage Resources -> add source)
   Source type    Database
   Database type  PostgreSQL
   Host           localhost
   Port           $LOCAL_PORT
   Database       $DB_NAME
   User           $DB_USER
   Password       on $DB_HOST at /root/.loonweb_ipt_password
   JDBC           jdbc:postgresql://localhost:$LOCAL_PORT/$DB_NAME

 Operating
   systemctl status loonweb-tunnel
   journalctl -u loonweb-tunnel -n 50 --no-pager
   systemctl restart loonweb-tunnel

 The database side lives in VCE_db_docker:
   deploy/setup-ipt-tunnel.sh      installs this machine's key, restricted
   db_both/db_ipt/README.md        section 4, the whole design
════════════════════════════════════════════════════════════════
DONE
