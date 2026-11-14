#!/bin/bash
# rcon.sh - one console command to the running server over rcon, its reply on stdout.
#
#   tools/rcon.sh players
#   tools/rcon.sh save
#   printf '%s\n' 'setpassword "name" "new"' | tools/rcon.sh -   # a command that holds a secret
#
# THE LOGIN ANSWER IS TWO PACKETS. Project Zomboid answers the login
# (SERVERDATA_AUTH) with an empty RESPONSE_VALUE, type 0, and then the
# verdict, AUTH_RESPONSE, type 2, whose id is -1 when the password is wrong.
# A client that reads one packet after the login never sees the verdict: it
# cannot tell a refused password from an accepted one, and every read after it
# is one packet behind. That unread verdict is the "reply one packet late" the
# README described up to v1.3.1. Here the login is read to its verdict, and a
# refused password exits 3.
#
# NOT IN THE GAME'S IMAGE, which has no python3. A throwaway python container
# joins the server's network namespace, so rcon is never published on the host.
#
# THE PASSWORD AND THE COMMAND TRAVEL ON STDIN, never in argv, where `ps` on
# the host would show them. The password is read from .env, the file the
# server got it from (ZOMBOID_ENV_FILE to read another).
#
# THE END OF A REPLY: read until the server has been quiet for a second and a
# half, so a long reply is not cut short.
#
# Exit 0 a reply, 2 no server or no answer, 3 the password refused.
#
# Read whole before it runs: one brace group, ending in exit.
{
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
ENVF="${ZOMBOID_ENV_FILE:-.env}"
PROJECT="${ZOMBOID_PROJECT:-zomboid}"
PY=python:3.13-alpine@sha256:7984cf56ceaddebe4fefeb75d64000b9f45d8b77b11a09b24524da6cdc3af0c8
[ "$#" -gt 0 ] || { echo "usage: tools/rcon.sh <command...>   or   tools/rcon.sh -   (the command on stdin)" >&2; exit 2; }
cmd=""
if [ "$1" = - ]; then IFS= read -r cmd || true; else cmd="$*"; fi
[ -n "$cmd" ] || { echo "rcon.sh: no command" >&2; exit 2; }
pw="$(sed -n 's/^ZOMBOID_SERVER_RCON_PASSWORD=//p' "$ENVF" 2>/dev/null | tail -1)"
[ -n "$pw" ] || { echo "rcon.sh: ZOMBOID_SERVER_RCON_PASSWORD is not set in $ENVF" >&2; exit 2; }
cid="$(docker compose -p "$PROJECT" ps -q zomboid-server 2>/dev/null)"
[ -n "$cid" ] || { echo "rcon.sh: the zomboid container is not running" >&2; exit 2; }
printf '%s\n%s\n' "$pw" "$cmd" | docker run --rm -i --network "container:$cid" "$PY" python3 -c '
import socket, struct, sys
pw = sys.stdin.readline().rstrip("\n")
cmd = sys.stdin.readline().rstrip("\n")
def pkt(i, t, b):
    d = struct.pack("<ii", i, t) + b.encode() + b"\x00\x00"
    return struct.pack("<i", len(d)) + d
def recvn(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError("the server closed the connection")
        b += c
    return b
def read(s):
    n = struct.unpack("<i", recvn(s, 4))[0]
    d = recvn(s, n)
    i, t = struct.unpack("<ii", d[:8])
    return i, t, d[8:-2].decode("utf-8", "replace")
out = []
try:
    s = socket.create_connection(("127.0.0.1", 27015), timeout=10)
    s.sendall(pkt(1, 3, pw))
    while True:
        i, t, _ = read(s)
        if t == 2:
            break
    if i == -1:
        print("rcon.sh: the server refused the rcon password", file=sys.stderr)
        sys.exit(3)
    s.sendall(pkt(2, 2, cmd))
    out.append(read(s)[2])
    s.settimeout(1.5)
    while True:
        try:
            out.append(read(s)[2])
        except (socket.timeout, EOFError):
            break
except (OSError, EOFError) as e:
    print("rcon.sh: no answer: %s" % e, file=sys.stderr)
    sys.exit(2)
reply = "".join(out).rstrip("\n")
if reply:
    print(reply)
'
exit $?
}
