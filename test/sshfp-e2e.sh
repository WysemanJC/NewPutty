#!/bin/sh
# End-to-end test of SSHFP host key checking, using a local sshd and a
# fake DNS server. Linux only; needs root (it binds port 53 and uses a
# private mount namespace to point the resolver at the fake server).
#
# Usage: sudo test/sshfp-e2e.sh <build dir containing plink>

set -eu

BUILD=$(cd "$1" && pwd)
SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
HOST=sshfp-test.example
PORT=2222
pids=""
cleanup() { for p in $pids; do kill "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$WORK/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/otherkey"
mkdir -p /run/sshd
cat > "$WORK/sshd_config" <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $WORK/hostkey
PidFile $WORK/sshd.pid
CFG
/usr/sbin/sshd -f "$WORK/sshd_config" -D -e 2>"$WORK/sshd.log" &
pids="$pids $!"
sleep 0.5
kill -0 $! 2>/dev/null || { cat "$WORK/sshd.log"; exit 1; }

good=$(ssh-keygen -r $HOST -f "$WORK/hostkey.pub" | awk '$5 == 2 {print $4, $5, $6}')
bad=$(ssh-keygen -r $HOST -f "$WORK/otherkey.pub" | awk '$5 == 2 {print $4, $5, $6}')

printf 'nameserver 127.0.0.1\noptions trust-ad timeout:1 attempts:1\n' \
    > "$WORK/resolv.conf"

fail=0

# run_case <name> <fake-dns args> <expected regex> [<PUTTYDIR setup>
#          [<extra plink args>]]
# A case also fails if its output matches $reject (if set).
reject=""
run_case() {
    name=$1; dnsargs=$2; expect=$3
    eval "exec python3 -I '$SRC/test/fake_dns.py' --name $HOST $dnsargs" &
    dnspid=$!
    sleep 0.5
    mkdir -p "$WORK/pdir-$name"
    if [ -n "${4:-}" ]; then eval "$4"; fi
    out=$(PUTTYDIR="$WORK/pdir-$name" unshare -m sh -c "
        mount --bind '$WORK/resolv.conf' /etc/resolv.conf &&
        '$BUILD/plink' -batch -v -P $PORT -l nobody ${5:-} $HOST true" 2>&1 \
        </dev/null || true)
    kill $dnspid 2>/dev/null || true; wait $dnspid 2>/dev/null || true
    [ -n "${VERBOSE:-}" ] && printf '%s\n' "$out" | sed "s/^/    [$name] /"
    if printf '%s\n' "$out" | grep -Eq "$expect" &&
       ! { [ -n "$reject" ] && printf '%s\n' "$out" | grep -Eq "$reject"; }; then
        echo "PASS: $name"
    else
        echo "FAIL: $name (expected /$expect/)"
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=1
    fi
}

# PUTTYDIR setup: Default Settings with the given VerifyHostKeyDNS value.
dns_mode() {
    echo 'mkdir -p "$WORK/pdir-$name/sessions" && printf "{\"settings\": {\"VerifyHostKeyDNS\": '"$1"'}}\n" > "$WORK/pdir-$name/sessions/%44efault%20%53ettings.json"'
}

reject="Connection abandoned"
run_case validated-match-yes "--sshfp '$good' --ad" \
    "Host key accepted on the strength of a DNSSEC-validated SSHFP record" \
    "$(dns_mode 2)"
reject="Host key accepted"
# The default is "ask": even a validated match only informs the prompt.
run_case validated-match-default-asks "--sshfp '$good' --ad" \
    "host key matches DNS record \(DNSSEC-validated\)"
run_case validated-match-default-prompts "--sshfp '$good' --ad" \
    "Connection abandoned"
run_case unvalidated-match "--sshfp '$good'" \
    "host key matches DNS record \(not DNSSEC-validated\)"
run_case unvalidated-match-prompts "--sshfp '$good'" \
    "Connection abandoned"
run_case validated-mismatch "--sshfp '$bad' --ad" \
    "DNS FINGERPRINT MISMATCH"
run_case no-records "--ad" \
    "SSHFP: no matching-algorithm records in DNS"
reject="SSHFP: (host key|DNS|no matching)"
# A proxy that resolves host names itself: no SSHFP lookup, even with
# "yes" and a validated record on offer.
run_case proxy-resolves-names "--sshfp '$good' --ad" \
    "SSHFP: not checked, because host name lookups are left to the proxy" \
    "$(dns_mode 2)" "-proxycmd 'nc 127.0.0.1 $PORT'"
reject="SSHFP:"
run_case disabled-in-json-config "--sshfp '$good' --ad" \
    "Connection abandoned" \
    "$(dns_mode 0)"

# More PUTTYDIR setup helpers, run through run_case's eval (so $name
# is set, and the fake DNS server for the case is already running).

# write_defaults '<JSON object members>': Default Settings file.
write_defaults() {
    mkdir -p "$WORK/pdir-$name/sessions"
    printf '{"settings": {%s}}\n' "$1" \
        > "$WORK/pdir-$name/sessions/%44efault%20%53ettings.json"
}

# cache_hostkey: connect once and answer "y" to store the host key.
cache_hostkey() {
    printf 'y\n' | PUTTYDIR="$WORK/pdir-$name" unshare -m sh -c "
        mount --bind '$WORK/resolv.conf' /etc/resolv.conf &&
        '$BUILD/plink' -v -P $PORT -l nobody $HOST true" \
        > "$WORK/cache-$name.log" 2>&1 || true
    if ! [ -f "$WORK/pdir-$name/hostkeys.json" ]; then
        echo "SETUP FAILED: $name (host key not cached)"
        sed 's/^/    /' "$WORK/cache-$name.log"
        fail=1
    fi
}

require='write_defaults "\"RequireSSHFP\": 1"'
rejected='Host key rejected: "Require valid SSHFP" is set'

# "Require valid SSHFP": a key no record vouches for is refused outright,
# with no prompt...
reject="Connection abandoned"
run_case require-uncached-no-records "--ad" "$rejected" "$require"
# (Requiring SSHFP forces the lookup even when lookups are turned off.)
run_case require-overrides-never "--ad" \
    "SSHFP: no matching-algorithm records" \
    'write_defaults "\"VerifyHostKeyDNS\": 0, \"RequireSSHFP\": 1"'
# ... while a matching uncached key still gets the usual prompt.
reject="Host key rejected"
run_case require-uncached-match-prompts "--sshfp '$good'" \
    "Connection abandoned" "$require"
# It applies to cached keys too: looked up on every connection.
reject="Host key rejected|Connection abandoned"
run_case require-cached-match "--sshfp '$good'" \
    'Using username "nobody"' "cache_hostkey; $require"
reject='Using username'
run_case require-cached-no-records "--ad" \
    "$rejected" "cache_hostkey; $require"
run_case require-cached-mismatch "--sshfp '$bad' --ad" \
    "$rejected" "cache_hostkey; $require"
# Without it, a cached key costs no lookup at all.
reject="SSHFP:|Host key rejected|Connection abandoned"
run_case cached-no-lookup "--sshfp '$good'" \
    'Using username "nobody"' "cache_hostkey"

exit $fail
