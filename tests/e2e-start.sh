#!/bin/bash
# Does tools/start.sh keep both passwords off every command line and out of
# the logs, in the pinned image, and still give the server both?
#
# It runs in the image the compose file pins, as the compose file runs it
# (bash /start.sh as the entrypoint, as root), with a stand-in for the
# image's entry.sh (tests/fixtures/fake-entry.sh) that asks the console for
# the admin password as Project Zomboid does, and prints the lines the image
# and the game print with passwords in them:
#
#   a first start    no ini, a world without its admin account: the ini holds
#                    the rcon password, mode 600; both questions answered with
#                    the admin password, nothing more on the console; the
#                    image is handed both empty and neither PZT_ variable
#   a second start   an ini with other lines and an old rcon password, a world
#                    with its admin account: the password replaced once, the
#                    other lines kept, nothing written to the console
#   the filter       neither value in docker logs, though the stand-in prints
#                    both in the image's and the game's forms
#   not the question  its words in a chat line or a bare line, and the
#                    question in the game's form once the server answers:
#                    nothing written
#   no admin password, and the server asks: it is told so and waits; nothing
#                    is written
#   a stop         SIGTERM once the server answers: it is told to quit
#                    on its console, saves, exits 0, well inside the grace
#                    period, and its last line reaches docker logs
#   fail closed      no rcon password, a space, a quote, a backslash, a line
#                    break: exit 1 before the image's entry.sh runs
#
# The real server is the game job in .github/workflows/deployment-verification.yml,
# with tests/secret-probe.sh.
# shellcheck disable=SC2015   # pass and fail always exit 0, so "A && pass || fail" is if-then-else here
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASSED=0; FAILED=0
pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
IMAGE=$(grep -m1 -oE '\$\{ZOMBOID_SERVER_IMAGE_TAG:-.*' zomboid-server-docker-compose.yml | sed -E -e ':a' -e 's/\$\{[A-Z0-9_]+:-([^{}]*)\}/\1/' -e 'ta')
W="$(mktemp -d)"; chmod 755 "$W"
NAME="zomboid-start-$$"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1; docker volume rm -f "$NAME" >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
umask 077
APW="a$(openssl rand -hex 12)"; RPW="r$(openssl rand -hex 12)"
printf '%s\n%s\n' "$APW" "$RPW" > "$W/values.grep"
printf 'argv\t%s\nini\t%s\n' "$APW" "$RPW" > "$W/values"
chmod 644 "$W/values"
mkdir -m 777 "$W/out"
docker volume create "$NAME" >/dev/null

run() {  # mode, then NAME=value for the environment: runs start.sh with the stand-in; sets rc, logs
  local mode="$1" detach=""; shift
  [ "$mode" = run ] && detach=-d
  rm -f "$W/out/"*
  docker rm -f "$NAME" >/dev/null 2>&1
  # The values go in through the environment of docker itself (export is a
  # builtin, and -e NAME carries no value), as compose hands them over.
  ( for kv in "$@"; do export "${kv?}"; done; docker run $detach --name "$NAME" --platform linux/amd64 --entrypoint /bin/bash \
    -e MODE="$mode" -e SERVERNAME=servertest -e PZT_ADMIN_PASSWORD -e PZT_RCON_PASSWORD \
    -v "$NAME:/home/steam/Zomboid" \
    -v "$PWD/tools/start.sh:/start.sh:ro" \
    -v "$PWD/tests/fixtures/fake-entry.sh:/server/scripts/entry.sh:ro" \
    -v "$PWD/tests/fixtures/fake-healthcheck.sh:/healthcheck.sh:ro" \
    -v "$W/values:/fixture/values:ro" -v "$W/out:/fixture/out" \
    "$IMAGE" /start.sh >/dev/null 2>&1 )
  rc=$(docker inspect "$NAME" --format '{{.State.ExitCode}}')
  logs="$(docker logs "$NAME" 2>&1)"
}
inside() { docker run --rm --platform linux/amd64 -v "$NAME:/z" --entrypoint /bin/sh "$IMAGE" -c "$1"; }
leaked() { grep -c -F -f "$W/values.grep" <<<"$logs"; }

echo "=== tools/start.sh, in the pinned image, with a stand-in for entry.sh ==="
echo

run prompt PZT_ADMIN_PASSWORD="$APW" PZT_RCON_PASSWORD="$RPW"
[ "$rc" = 0 ] && grep -q '^fake-entry: done' <<<"$logs" && [ "$(grep -c 'the last lines, ' <<<"$logs")" = 500 ] && pass "a first start: the image's entry.sh ran, and all 500 of its last lines reached docker logs" || fail "a first start: exit $rc, $(grep -c 'the last lines, ' <<<"$logs") of 500 last lines: $(tail -2 <<<"$logs" | tr '\n' '|')"
inside 'cat /z/Server/servertest.ini' | grep -qxF "RCONPassword=$RPW" && pass "the ini holds the rcon password" || fail "the ini does not hold the rcon password"
m="$(inside 'stat -c %a /z/Server/servertest.ini')"
[ "$m" = 600 ] && pass "the ini is mode 600" || fail "the ini is mode $m"
[ "$(grep -c -xF "first $APW" "$W/out/answers")" = 1 ] && [ "$(grep -c -xF "second $APW" "$W/out/answers")" = 1 ] && pass "both questions got the admin password, from the console" || fail "the questions got: $(sed -E 's/ .*/ <something>/' "$W/out/answers" | tr '\n' ' ')"
grep -q '^extra' "$W/out/answers" && fail "something more was written to the console" || pass "nothing more on the console"
grep -qx 'ADMINPASSWORD set, empty' "$W/out/env" && grep -qx 'RCONPASSWORD set, empty' "$W/out/env" && pass "the image got ADMINPASSWORD and RCONPASSWORD empty" || fail "the image got: $(tr '\n' ' ' < "$W/out/env")"
grep -qx 'PZT_ADMIN_PASSWORD unset' "$W/out/env" && grep -qx 'PZT_RCON_PASSWORD unset' "$W/out/env" && pass "and no PZT_ variable" || fail "the image got: $(tr '\n' ' ' < "$W/out/env")"
n="$(leaked)"
[ "$n" = 0 ] && grep -q 'pzexe: arg: \*\*\*\*\*\*' <<<"$logs" && grep -q 'RCONPassword=\*\*\*\*\*\*' <<<"$logs" && pass "no value in docker logs; the stand-in's lines are masked" || fail "docker logs: $n lines with a value"

inside "printf 'Public=false\r\nRCONPassword=old\nMaxPlayers=8\n' > /z/Server/servertest.ini"
run none PZT_ADMIN_PASSWORD="$APW" PZT_RCON_PASSWORD="$RPW"
ini="$(inside 'cat /z/Server/servertest.ini')"
[ "$rc" = 0 ] && [ "$(grep -c '^RCONPassword=' <<<"$ini")" = 1 ] && grep -qxF "RCONPassword=$RPW" <<<"$ini" && grep -q '^Public=false' <<<"$ini" && grep -qx 'MaxPlayers=8' <<<"$ini" && pass "a second start: the rcon password replaced once, the other lines kept" || fail "a second start: exit $rc, ini: $(sed -E 's/^(RCONPassword=).*/\1<v>/' <<<"$ini" | tr '\r\n' '| ')"
[ ! -s "$W/out/answers" ] && pass "a world with its admin account: nothing written to the console" || fail "the console got: $(sed -E 's/ .*/ <something>/' "$W/out/answers" | tr '\n' ' ')"
[ "$(leaked)" = 0 ] && pass "no value in docker logs" || fail "docker logs: $(leaked) lines with a value"

run inject PZT_ADMIN_PASSWORD="$APW" PZT_RCON_PASSWORD="$RPW"
[ "$rc" = 0 ] && [ ! -s "$W/out/answers" ] && pass "the question's words from a player, and the question once the server answers: nothing written" || fail "not the question: exit $rc, the console got: $(sed -E 's/ .*/ <something>/' "$W/out/answers" 2>/dev/null | tr '\n' ' ')"

run prompt PZT_ADMIN_PASSWORD= PZT_RCON_PASSWORD="$RPW"
[ ! -s "$W/out/answers" ] && grep -q 'asks for an admin password and has none' <<<"$logs" && pass "no admin password and the server asks: it is told so, nothing written" || fail "no admin password: $(grep start.sh <<<"$logs" | tail -2)"

run run PZT_ADMIN_PASSWORD="$APW" PZT_RCON_PASSWORD="$RPW"
for _ in $(seq 1 40); do docker logs "$NAME" 2>&1 | grep -q 'the server is up' && break; sleep 0.5; done
sleep 5   # start.sh asks the (fake) health check every three seconds
t0=$SECONDS; docker stop -t 60 "$NAME" >/dev/null; secs=$((SECONDS - t0))
rc=$(docker inspect "$NAME" --format '{{.State.ExitCode}}'); logs="$(docker logs "$NAME" 2>&1)"
[ "$rc" = 0 ] && [ "$secs" -le 15 ] && grep -q 'told to save the world and quit' <<<"$logs" && grep -q '^fake-entry: saving the world and quitting' <<<"$logs" && pass "a stop: told to quit on the console, saved, exit 0 in ${secs}s, its last line in docker logs" || fail "a stop: exit $rc in ${secs}s: $(tail -3 <<<"$logs" | tr '\n' '|')"

for bad in "" "a b" 'a"b' "a'b" 'a\b' $'a\nb' $'a\tb'; do
  run none PZT_ADMIN_PASSWORD="$APW" PZT_RCON_PASSWORD="$bad"
  shown="$(printf '%q' "$bad")"
  [ "$rc" = 1 ] && ! grep -q '^fake-entry' <<<"$logs" && grep -q 'not starting a server without its passwords' <<<"$logs" && pass "rcon password $shown: exit 1, entry.sh never ran" || fail "rcon password $shown: exit $rc"
done
run none PZT_ADMIN_PASSWORD="a b" PZT_RCON_PASSWORD="$RPW"
[ "$rc" = 1 ] && ! grep -q '^fake-entry' <<<"$logs" && pass "an admin password with a space: exit 1" || fail "an admin password with a space: exit $rc"

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
