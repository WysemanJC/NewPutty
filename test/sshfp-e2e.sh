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

# run_case <name> <fake-dns args> <expected regex> [<PUTTYDIR setup>]
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
        '$BUILD/plink' -batch -v -P $PORT -l nobody $HOST true" 2>&1 \
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

reject="Connection abandoned"
run_case validated-match "--sshfp '$good' --ad" \
    "Host key accepted on the strength of a DNSSEC-validated SSHFP record"
reject="Host key accepted"
run_case unvalidated-match "--sshfp '$good'" \
    "host key matches DNS record \(not DNSSEC-validated\)"
run_case unvalidated-match-prompts "--sshfp '$good'" \
    "Connection abandoned"
run_case validated-mismatch "--sshfp '$bad' --ad" \
    "DNS FINGERPRINT MISMATCH"
run_case no-records "--ad" \
    "SSHFP: no matching-algorithm records in DNS"
reject="SSHFP:"
run_case disabled-in-json-config "--sshfp '$good' --ad" \
    "Connection abandoned" \
    'mkdir -p "$WORK/pdir-$name/sessions" && printf "{\"settings\": {\"VerifyHostKeyDNS\": 0}}\n" > "$WORK/pdir-$name/sessions/%44efault%20%53ettings.json"'

exit $fail
