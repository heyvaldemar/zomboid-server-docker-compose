#!/bin/bash
# Does scripts/refresh.sh leave alone a server it cannot count?
#
# The refresh recreates the server, which drops everyone on it. It asks the
# server how many players are on first, over A2S from inside the server's
# network namespace, and skips if anyone is. The case this file exists for is
# the other one: a server that does not answer. It used to be read as empty,
# so a server busy saving, or a lost query, meant a recreate under whoever
# was playing. Now it is "?", skipped, and the script exits 1.
#
# No game download involved: the "server" is a few lines of Python that
# answer A2S_INFO with a chosen player count, with or without the challenge
# step, or not at all, and count the queries they receive.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

WORK="$(mktemp -d)"
PROJECTS=()
cleanup() {
  for p in ${PROJECTS[@]+"${PROJECTS[@]}"}; do docker compose -p "$p" -f "$WORK/fixture.yml" down -t 1 >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap cleanup EXIT

cat >"$WORK/fixture.yml" <<'YAML'
services:
  zomboid-server:
    image: python:3.13-alpine
    environment:
      MODE: ${MODE:-unset}
    command:
      - python3
      - -c
      - |
        import os, socket, struct
        mode = os.environ["MODE"]
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("0.0.0.0", 16261))
        n = 0
        while True:
            d, a = s.recvfrom(4096)
            n += 1
            open("/tmp/queries", "w").write(str(n))
            if mode == "silent":
                continue
            players = int(mode.split(":")[-1])
            challenge = mode.startswith("challenge:")
            if challenge and len(d) < 29:
                s.sendto(b"\xff\xff\xff\xffA" + struct.pack("<i", 1234), a)
                continue
            body = b"I\x11" + b"Fixture\x00map\x00zomboid\x00Project Zomboid\x00" + struct.pack("<H", 0) + bytes([players, 32, 0]) + b"dl\x00\x00"
            s.sendto(b"\xff\xff\xff\xff" + body, a)
YAML

# start MODE: a fixture project of its own, so each case reads a fresh server.
# Sets $p rather than printing it: called in $(...), the project would be added
# to PROJECTS in a subshell, and the cleanup would never see it.
start() {
  p="zomboid-refresh-$$-${#PROJECTS[@]}"
  PROJECTS+=("$p")
  MODE="$1" docker compose -p "$p" -f "$WORK/fixture.yml" up -d >/dev/null 2>&1 || { echo "cannot start the fixture"; exit 1; }
  # Ready means listening. The fixture writes nothing until it is asked, so
  # readiness is read from the socket table, not from the fixture's answers.
  for _ in $(seq 1 40); do
    docker compose -p "$p" -f "$WORK/fixture.yml" exec -T zomboid-server sh -c 'grep -q ":3F85 " /proc/net/udp' 2>/dev/null && break
    sleep 0.5
  done
}
started() { docker inspect -f '{{.Id}} {{.State.StartedAt}}' "$(docker compose -p "$1" -f "$WORK/fixture.yml" ps -q zomboid-server)"; }
queries() { docker compose -p "$1" -f "$WORK/fixture.yml" exec -T zomboid-server cat /tmp/queries 2>/dev/null || echo 0; }

# A refresh that goes ahead when it should not does not fail fast: it recreates
# the server and waits up to half an hour for it to come back healthy. The
# first version of this file, run against the old script, sat in that wait.
# Two minutes is far more than a skip takes, so past it is a failure.
refresh() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 scripts/refresh.sh "$@"; else scripts/refresh.sh "$@"; fi
}

echo "=== the refresh and the players on the server ==="
echo

# 1. Players on: skip, untouched.
start players:2; before="$(started "$p")"
out="$(ZOMBOID_PROJECT="$p" refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "skip: 2 player(s) online" <<<"$out"; then pass "two players on: skipped"; else fail "two players on: exit $rc, said: $out"; fi
if [ "$(started "$p")" = "$before" ]; then pass "two players on: the server was not recreated"; else fail "two players on: the server was recreated"; fi

# 2. The challenge step, which newer servers answer with first.
start challenge:3
out="$(ZOMBOID_PROJECT="$p" refresh 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "skip: 3 player(s) online" <<<"$out"; then pass "behind the A2S challenge: three players counted"; else fail "behind the A2S challenge: exit $rc, said: $out"; fi

# 3. THE CASE THIS FILE EXISTS FOR: no answer at all.
start silent; before="$(started "$p")"
out="$(ZOMBOID_PROJECT="$p" refresh 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "did not answer the player query" <<<"$out"; then pass "no answer: skipped, exit 1"; else fail "no answer: exit $rc, said: $out"; fi
if [ "$(started "$p")" = "$before" ]; then pass "no answer: the server was not recreated"; else fail "no answer: the server was recreated"; fi
# The control: it was the server's silence, not a probe that never reached it.
q="$(queries "$p")"
if [ "$q" = 3 ]; then pass "no answer: the server was asked three times"; else fail "no answer: the server was asked $q time(s), expected 3"; fi

# 4. Nobody on: the refresh goes ahead. --dry-run stops it short of the real
# recreate, which would download the game.
start players:0
out="$(ZOMBOID_PROJECT="$p" refresh --dry-run 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "would refresh: players online: 0" <<<"$out"; then pass "nobody on: it would refresh"; else fail "nobody on: exit $rc, said: $out"; fi

# 5. --force overrides an unknown count, and says that it did.
start silent
out="$(ZOMBOID_PROJECT="$p" refresh --dry-run --force 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q "would refresh: players online: ?, forced" <<<"$out"; then pass "no answer, --force: it would refresh"; else fail "no answer, --force: exit $rc, said: $out"; fi

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
