#!/bin/bash
#
# Install and configure postfix so cron can actually deliver mail.
#
# WHY THIS IS NOT JUST "apt install postfix":
#   The IPT host is an EC2 instance. AWS blocks outbound port 25 on EC2 by
#   default, and mail sent directly from an EC2 IP to a real domain is rejected
#   or spam-filed even when the block is lifted. A default "Internet Site"
#   postfix would therefore accept every cron alert and then queue it forever --
#   the exact silent-discard failure this is meant to fix, relocated from
#   /dev/null to /var/spool/postfix.
#
#   So postfix is installed as a SATELLITE SYSTEM: it accepts local mail and
#   hands it to a smarthost on port 587 over TLS with SASL auth. Pick one:
#
#     Amazon SES      --relay email-smtp.<region>.amazonaws.com:587
#                     --user <SES SMTP username>   (NOT an AWS access key id;
#                     generate SMTP credentials in the SES console)
#                     --from must be an SES-VERIFIED identity, and the account
#                     must be out of the SES sandbox to mail arbitrary addresses.
#
#     Google Workspace relay
#                     --relay smtp-relay.gmail.com:587
#                     --user <workspace account>  --pass <app password>
#                     Admin console > Apps > Gmail > Routing > SMTP relay service.
#
#     Gmail account   --relay smtp.gmail.com:587
#                     --user you@vtecostudies.org --pass <16-char app password>
#                     --from must equal --user. Simplest, lowest volume ceiling.
#
# SAFE BY DEFAULT: prints a full plan and changes nothing. Re-run with --apply.
#
# Usage:
#   ./09_install_postfix.sh                      # dry run: report current state + plan
#   ./09_install_postfix.sh --status             # report only, no plan
#   ./09_install_postfix.sh --apply \
#        --relay email-smtp.us-east-1.amazonaws.com:587 \
#        --user AKIA...SMTPUSER --from ipt@vtecostudies.org
#   ./09_install_postfix.sh --test               # send a probe through the queue
#
#   Password: prefer the IPT_SMTP_PASS environment variable, or let the script
#   prompt. --pass on the command line is visible in ps(1) and shell history.
#
set -u
cd "$(dirname "$(readlink -f "$0")")" || exit 1

REPO_DIR="$(pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

APPLY=0
MODE=install                 # install | status | test
RELAY=""
SMTP_USER=""
SMTP_PASS="${IPT_SMTP_PASS:-}"
PASS_FROM_ARGV=0
FROM_ADDR=""
ROOT_ALIAS=""
TEST_TO=""
LOCAL_ONLY=0

# Default the alias / test recipient to the crontab's first MAILTO so there is
# one source of truth for "who gets alerted".
CRONTAB_REF="$REPO_DIR/05_root_crontab.txt"
DEFAULT_ALIAS="$(sed -n 's/^MAILTO=//p' "$CRONTAB_REF" 2>/dev/null | head -1 | tr -d '"'"'"'')"

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)      APPLY=1 ;;
        --status)     MODE=status ;;
        --test)       MODE=test; case "${2:-}" in -*|"") ;; *) TEST_TO="$2"; shift ;; esac ;;
        --relay)      RELAY="${2:-}"; shift ;;
        --user)       SMTP_USER="${2:-}"; shift ;;
        --pass)       SMTP_PASS="${2:-}"; PASS_FROM_ARGV=1; shift ;;
        --from)       FROM_ADDR="${2:-}"; shift ;;
        --alias)      ROOT_ALIAS="${2:-}"; shift ;;
        --local-only) LOCAL_ONLY=1 ;;
        -h|--help)    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)            echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

[ -n "$ROOT_ALIAS" ] || ROOT_ALIAS="$DEFAULT_ALIAS"
[ -n "$TEST_TO" ] || TEST_TO="$ROOT_ALIAS"

SUDO=sudo
[ "$(id -u)" = 0 ] && SUDO=""

FQDN="$(hostname -f 2>/dev/null || hostname)"
[ -n "$FQDN" ] || FQDN="localhost"

# ---------------------------------------------------------------- helpers ---
act() {
    if [ "$APPLY" -eq 1 ]; then
        $SUDO "$@" || { echo "    *** FAILED: $*"; return 1; }
    else
        echo "    would: $*"
    fi
}

# write_file PATH MODE  -- content on stdin. Backs up any existing file.
write_file() {
    local path="$1" mode="$2" body
    body="$(cat)"
    if [ "$APPLY" -eq 1 ]; then
        [ -f "$path" ] && $SUDO cp -p "$path" "$path.bak-$STAMP"
        printf '%s\n' "$body" | $SUDO tee "$path" >/dev/null || {
            echo "    *** FAILED to write $path"; return 1; }
        $SUDO chown root:root "$path"
        $SUDO chmod "$mode" "$path"
        echo "    wrote $path (mode $mode)"
    else
        echo "    would write $path (mode $mode):"
        printf '%s\n' "$body" | sed 's/^/        | /'
    fi
}

pconf() {  # pconf key value
    if [ "$APPLY" -eq 1 ]; then
        $SUDO postconf -e "$1 = $2" || echo "    *** FAILED: postconf $1"
    else
        echo "    would: postconf -e '$1 = $2'"
    fi
}

tcp_probe() {  # host port -- 0 if a TCP connection opens within 5s
    timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

mask() { case "${1:-}" in "") echo "(unset)" ;; *) echo "********(${#1} chars)" ;; esac; }

maillog() {  # print recent MTA log lines from wherever this host keeps them
    if [ -r /var/log/mail.log ]; then
        $SUDO tail -n "${1:-200}" /var/log/mail.log
    else
        $SUDO journalctl -u postfix --no-pager -n "${1:-200}" 2>/dev/null
    fi
}

# ------------------------------------------------------------ 0. preflight ---
echo "=============================================================="
case "$MODE" in
    status) echo " POSTFIX STATUS -- read only" ;;
    test)   echo " POSTFIX DELIVERY TEST -> $TEST_TO" ;;
    *)      if [ "$APPLY" -eq 1 ]; then echo " INSTALLING postfix as a mail relay client"
            else echo " DRY RUN -- nothing will change. Re-run with --apply to commit."; fi ;;
esac
echo "=============================================================="
echo

echo "0. Host"
echo "    fqdn:        $FQDN"
echo "    os:          $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
if command -v postconf >/dev/null 2>&1; then
    echo "    postfix:     installed ($(postconf -h mail_version 2>/dev/null || echo '?'))"
    echo "    relayhost:   $(postconf -h relayhost 2>/dev/null || echo '?')"
    echo "    sasl auth:   $(postconf -h smtp_sasl_auth_enable 2>/dev/null || echo '?')"
    echo "    service:     $(systemctl is-active postfix 2>/dev/null || echo unknown) / $(systemctl is-enabled postfix 2>/dev/null || echo unknown)"
    q="$(postqueue -p 2>/dev/null | tail -1)"
    echo "    queue:       ${q:-(empty)}"
else
    echo "    postfix:     NOT installed"
fi
if [ -x /usr/sbin/sendmail ]; then
    echo "    sendmail:    $(readlink -f /usr/sbin/sendmail)"
else
    echo "    sendmail:    MISSING -- cron is discarding every alert right now"
fi
for other in exim4 nullmailer ssmtp msmtp-mta; do
    if dpkg -s "$other" >/dev/null 2>&1; then
        echo "    *** NOTE: '$other' is installed. Installing postfix will replace it"
        echo "        as the system MTA. Confirm nothing else depends on it."
    fi
done
echo

# Only the last MAILTO wins for a given cron line; show who is actually targeted.
echo "0b. Alert recipients (from $CRONTAB_REF)"
if [ -f "$CRONTAB_REF" ]; then
    grep -n '^MAILTO=' "$CRONTAB_REF" | sed 's/^/      /'
else
    echo "      (reference crontab not found)"
fi
echo "    root alias / test target: ${ROOT_ALIAS:-(none set -- pass --alias)}"
echo

[ "$MODE" = status ] && { echo "=============================================================="; exit 0; }

# ------------------------------------------------------------ delivery test --
run_test() {
    local to="$1"
    [ -n "$to" ] || { echo "    no recipient. Pass one: --test you@example.org"; return 2; }
    command -v postconf >/dev/null 2>&1 || { echo "    postfix is not installed yet."; return 2; }
    local msgid="ipt-postfix-test-$STAMP@$FQDN"
    echo "    sending probe, Message-Id <$msgid>"
    $SUDO /usr/sbin/sendmail -t <<EOM
To: $to
Subject: [IPT] postfix delivery test $STAMP
Message-Id: <$msgid>

This is 09_install_postfix.sh confirming that cron mail leaves $FQDN.

If you are reading this, backup failure alerts and the Monday backup digest
described in 05_root_crontab.txt can reach you.
EOM
    [ $? -eq 0 ] || { echo "    *** sendmail refused the message"; return 1; }

    # Postfix logs the queue id alongside the message-id, then logs that queue
    # id's final status. Poll for both rather than guessing at a fixed sleep.
    local qid="" status="" i
    for i in $(seq 1 15); do
        sleep 2
        qid="$(maillog 400 | grep -F "$msgid" | sed -n 's/.*\] \{0,1\}\([A-Za-z0-9]\{6,\}\): message-id=.*/\1/p' | tail -1)"
        [ -n "$qid" ] || qid="$(maillog 400 | grep -F "$msgid" | grep -oE '[A-Za-z0-9]{6,16}:' | tail -1 | tr -d ':')"
        [ -n "$qid" ] || continue
        status="$(maillog 400 | grep -F "$qid" | grep -oE 'status=[a-z]+.*' | tail -1)"
        [ -n "$status" ] && break
    done

    echo
    if [ -z "$qid" ]; then
        echo "    *** Could not find the message in the mail log."
        echo "        Check by hand:  sudo tail -50 /var/log/mail.log"
        return 1
    fi
    echo "    queue id: $qid"
    echo "    result:   ${status:-<no status logged yet>}"
    case "$status" in
        status=sent*)
            echo
            echo "    DELIVERED. cron alerting is live." ;;
        status=bounced*|status=deferred*)
            echo
            echo "    *** NOT DELIVERED. Relevant log lines:"
            maillog 400 | grep -F "$qid" | sed 's/^/        /'
            echo
            echo "    Common causes:"
            echo "      'Connection timed out' on :25   -> EC2 port 25 block; use a :587 smarthost"
            echo "      'no mechanism available'        -> libsasl2-modules missing"
            echo "      'authentication failed'         -> wrong SMTP credentials in /etc/postfix/sasl_passwd"
            echo "      'Email address not verified'    -> --from is not an SES-verified identity"
            echo "      'not authorized to send'        -> SES still in sandbox, or Workspace relay not allowing this sender"
            return 1 ;;
        *)
            echo "    Still in the queue. Watch it with:  sudo postqueue -p"
            return 1 ;;
    esac
    return 0
}

if [ "$MODE" = test ]; then
    echo "T. Delivery test"
    run_test "$TEST_TO"; rc=$?
    echo
    echo "=============================================================="
    exit $rc
fi

# ------------------------------------------------- 1. validate relay config --
echo "1. Relay configuration"
RELAY_HOST=""; RELAY_PORT=""
if [ "$LOCAL_ONLY" -eq 1 ]; then
    echo "    --local-only: postfix will accept mail and store it in /var/mail."
    echo "    *** Nothing will be sent off this host. Alerts only exist if someone"
    echo "        logs in and reads /var/mail/root. This is NOT alerting."
else
    if [ -z "$RELAY" ]; then
        echo "    *** No --relay given, and a bare Internet-Site postfix cannot"
        echo "        deliver from EC2 (outbound :25 is blocked by AWS)."
        echo
        echo "    Re-run with one of:"
        echo "      --relay email-smtp.us-east-1.amazonaws.com:587 --user <SES SMTP user> --from ipt@vtecostudies.org"
        echo "      --relay smtp-relay.gmail.com:587 --user <workspace acct> --from ipt@vtecostudies.org"
        echo "      --relay smtp.gmail.com:587 --user you@vtecostudies.org --from you@vtecostudies.org"
        echo "    or --local-only to install an MTA that deliberately delivers nowhere."
        [ "$APPLY" -eq 1 ] && { echo; echo "    Refusing to --apply without a delivery path."; exit 2; }
    else
        RELAY_HOST="${RELAY%%:*}"
        RELAY_PORT="${RELAY##*:}"
        [ "$RELAY_PORT" = "$RELAY_HOST" ] && RELAY_PORT=587
        echo "    smarthost:   $RELAY_HOST:$RELAY_PORT"

        if [ -n "$SMTP_USER" ]; then
            [ -n "$FROM_ADDR" ] || case "$SMTP_USER" in *@*) FROM_ADDR="$SMTP_USER" ;; esac
            echo "    sasl user:   $SMTP_USER"
            echo "    sasl pass:   $(mask "$SMTP_PASS")"
            [ "$PASS_FROM_ARGV" -eq 1 ] && echo "    *** --pass on the command line is visible in ps and shell history."
            if [ -z "$SMTP_PASS" ] && [ "$APPLY" -eq 1 ]; then
                if [ -t 0 ]; then
                    printf "    SMTP password for %s: " "$SMTP_USER"
                    read -rs SMTP_PASS; echo
                else
                    echo "    *** No password. Set IPT_SMTP_PASS or run interactively."; exit 2
                fi
            fi
        else
            echo "    sasl user:   (none -- unauthenticated relay)"
            echo "    Only correct for an internal relay that trusts this host by IP."
        fi

        if [ -z "$FROM_ADDR" ]; then
            echo "    *** No --from. Every mail would leave as root@$FQDN, which SES,"
            echo "        Google Workspace and Gmail all reject as an unauthorized sender."
            [ "$APPLY" -eq 1 ] && { echo "    Refusing to --apply. Pass --from <authorized address>."; exit 2; }
        else
            echo "    rewrite from: $FROM_ADDR   (envelope + From: header, all local mail)"
        fi

        printf "    reachability: "
        if [ "$RELAY_PORT" = 25 ]; then
            echo "port 25 -- on EC2 this is almost certainly blocked outbound"
        elif tcp_probe "$RELAY_HOST" "$RELAY_PORT"; then
            echo "$RELAY_HOST:$RELAY_PORT accepts connections"
        else
            echo "*** cannot reach $RELAY_HOST:$RELAY_PORT"
            echo "        Check the security group's outbound rules before continuing."
        fi
    fi
fi
echo

# --------------------------------------------------------- 2. package install --
echo "2. Packages"
# Preseed debconf first: without it apt opens an ncurses dialog and a
# non-interactive run (or a cron/ssh session) hangs on it forever.
PRESEED="postfix postfix/mailname string $FQDN
postfix postfix/main_mailer_type select $([ "$LOCAL_ONLY" -eq 1 ] && echo 'Local only' || echo 'Satellite system')
postfix postfix/relayhost string ${RELAY_HOST:+[$RELAY_HOST]:$RELAY_PORT}
postfix postfix/root_address string $ROOT_ALIAS
postfix postfix/destinations string $FQDN, localhost.localdomain, localhost"

if [ "$APPLY" -eq 1 ]; then
    printf '%s\n' "$PRESEED" | $SUDO debconf-set-selections
    echo "    debconf preseeded (no interactive dialog)"
else
    echo "    would preseed debconf:"
    printf '%s\n' "$PRESEED" | sed 's/^/        | /'
fi
# libsasl2-modules is only a Recommends. Without it postfix fails auth with
# "no mechanism available" -- the single most common cause of a silent relay.
PKGS="postfix libsasl2-modules ca-certificates"
if [ "$APPLY" -eq 1 ]; then
    echo "    installing: $PKGS"
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
      && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PKGS \
      || { echo "    *** apt install failed"; exit 1; }
else
    echo "    would: apt-get update && apt-get install -y $PKGS"
    echo "    (libsasl2-modules is only a Recommends; without it SASL auth fails"
    echo "     with 'no mechanism available' and every alert silently defers)"
fi
echo

# ----------------------------------------------------------- 3. main.cf ------
echo "3. /etc/postfix/main.cf"
if [ "$APPLY" -eq 1 ] && [ -f /etc/postfix/main.cf ]; then
    $SUDO cp -p /etc/postfix/main.cf "/etc/postfix/main.cf.bak-$STAMP"
    echo "    backed up to /etc/postfix/main.cf.bak-$STAMP"
fi

write_file /etc/mailname 644 <<EOF
$FQDN
EOF

pconf myhostname     "$FQDN"
pconf myorigin       "/etc/mailname"
# Deliberately NOT listing the mail domain here: this host must never consider
# itself the final destination for vtecostudies.org mail.
pconf mydestination  "\$myhostname, localhost.localdomain, localhost"
# Listen on loopback only. Nothing off-box should be able to hand this MTA mail.
pconf inet_interfaces "loopback-only"
pconf inet_protocols  "ipv4"
pconf mynetworks      "127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128"

if [ "$LOCAL_ONLY" -eq 1 ]; then
    pconf relayhost ""
    pconf default_transport "local"
elif [ -n "$RELAY_HOST" ]; then
    # Bracketed: suppress the MX lookup and connect to this host as named.
    pconf relayhost "[$RELAY_HOST]:$RELAY_PORT"
    pconf smtp_tls_security_level "encrypt"
    pconf smtp_tls_CAfile         "/etc/ssl/certs/ca-certificates.crt"
    # Port 465 is implicit TLS, not STARTTLS.
    if [ "$RELAY_PORT" = 465 ]; then pconf smtp_tls_wrappermode "yes"; fi

    if [ -n "$SMTP_USER" ]; then
        pconf smtp_sasl_auth_enable        "yes"
        pconf smtp_sasl_password_maps      "hash:/etc/postfix/sasl_passwd"
        pconf smtp_sasl_security_options   "noanonymous"
        pconf smtp_sasl_tls_security_options "noanonymous"
    fi
fi

if [ -n "$FROM_ADDR" ]; then
    pconf sender_canonical_classes "envelope_sender, header_sender"
    pconf sender_canonical_maps    "regexp:/etc/postfix/sender_canonical"
    # Without this postfix only rewrites headers for unauthenticated clients,
    # so locally submitted cron mail would keep its root@host From: header.
    pconf local_header_rewrite_clients "static:all"
fi
echo

# ------------------------------------------------------ 4. credential files --
echo "4. Credentials and rewriting"
if [ -n "$SMTP_USER" ] && [ "$LOCAL_ONLY" -eq 0 ] && [ -n "$RELAY_HOST" ]; then
    if [ "$APPLY" -eq 1 ]; then
        # Never rendered to stdout: written straight to a 0600 root-owned file.
        printf '[%s]:%s %s:%s\n' "$RELAY_HOST" "$RELAY_PORT" "$SMTP_USER" "$SMTP_PASS" \
            | $SUDO tee /etc/postfix/sasl_passwd >/dev/null
        $SUDO chown root:root /etc/postfix/sasl_passwd
        $SUDO chmod 600 /etc/postfix/sasl_passwd
        $SUDO postmap hash:/etc/postfix/sasl_passwd
        $SUDO chmod 600 /etc/postfix/sasl_passwd.db
        $SUDO chown root:root /etc/postfix/sasl_passwd.db
        echo "    wrote /etc/postfix/sasl_passwd + .db (root:root 0600)"
    else
        echo "    would write /etc/postfix/sasl_passwd (root:root 0600):"
        echo "        | [$RELAY_HOST]:$RELAY_PORT $SMTP_USER:$(mask "$SMTP_PASS")"
        echo "    would: postmap hash:/etc/postfix/sasl_passwd"
    fi
    echo "    NOTE: the .db must stay 0600 -- it holds the SMTP password in the clear."
else
    echo "    no SASL credentials to write"
fi

if [ -n "$FROM_ADDR" ]; then
    write_file /etc/postfix/sender_canonical 644 <<EOF
# Rewrite EVERY local sender to an address the smarthost is authorized to send
# as. Cron submits mail as root@$FQDN, which SES / Workspace / Gmail all reject.
/^.+\$/    $FROM_ADDR
EOF
fi
echo

# ------------------------------------------------------------- 5. aliases ----
echo "5. /etc/aliases"
if [ -n "$ROOT_ALIAS" ]; then
    if [ "$APPLY" -eq 1 ]; then
        $SUDO cp -p /etc/aliases "/etc/aliases.bak-$STAMP" 2>/dev/null
        $SUDO sed -i '/^root:/d' /etc/aliases 2>/dev/null
        printf 'root: %s\n' "$ROOT_ALIAS" | $SUDO tee -a /etc/aliases >/dev/null
        $SUDO newaliases
        echo "    root -> $ROOT_ALIAS"
    else
        echo "    would set:  root: $ROOT_ALIAS   (then newaliases)"
    fi
    echo "    This catches system mail addressed to root. cron's own alerts go to"
    echo "    the MAILTO in the crontab, which is set independently."
else
    echo "    no alias target (pass --alias) -- root's mail would stay on the box"
fi
echo

# -------------------------------------------------------------- 6. service ---
echo "6. Service"
act systemctl enable postfix
# restart, not reload: inet_interfaces changes need a full restart.
act systemctl restart postfix
if [ "$APPLY" -eq 1 ]; then
    sleep 2
    echo "    active:  $(systemctl is-active postfix)"
    echo "    enabled: $(systemctl is-enabled postfix)"
    $SUDO postfix check 2>&1 | sed 's/^/    postfix check: /'
    if [ -x /usr/sbin/sendmail ]; then
        echo "    sendmail: $(readlink -f /usr/sbin/sendmail) -- cron can hand off mail"
    else
        echo "    *** sendmail still missing after install"; exit 1
    fi
fi
echo

# ---------------------------------------------------------------- 7. verify --
echo "7. End-to-end verification"
if [ "$APPLY" -eq 1 ] && [ "$LOCAL_ONLY" -eq 0 ]; then
    run_test "$TEST_TO"; TEST_RC=$?
else
    TEST_RC=0
    echo "    would send a probe to $TEST_TO and follow it through the mail log"
fi
echo

echo "=============================================================="
if [ "$APPLY" -eq 1 ]; then
    if [ "${TEST_RC:-1}" -eq 0 ] && [ "$LOCAL_ONLY" -eq 0 ]; then
        echo " Postfix installed and mail VERIFIED end to end."
        echo " Re-check the whole backup story with:  ./08_install_backups.sh"
    else
        echo " Postfix installed, but delivery is NOT yet confirmed."
        echo " Until a test message reaches an inbox, alerting is still dark."
        echo "   sudo postqueue -p              # what is stuck"
        echo "   sudo tail -50 /var/log/mail.log"
        echo "   ./09_install_postfix.sh --test $TEST_TO"
    fi
else
    echo " Dry run complete. Re-run with --apply when the above looks right."
fi
echo "=============================================================="
