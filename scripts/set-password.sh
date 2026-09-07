#!/bin/bash
# set-password.sh <account> [password] — replace a Project Zomboid account password.
#
# WHY THIS EXISTS. Players change their own password in game with
#
#     /changepwd "oldpassword" "newpassword"
#
# and that is the normal route. This is for the one case it cannot cover: a
# forgotten password. The command requires the old one, and the stored value is
# a bcrypt hash, so nobody can read the old password back. It can only be
# replaced.
#
# WHY IT TALKS TO THE RUNNING SERVER instead of editing the database. The server
# holds accounts in SQLite and offers an admin command, setpassword, over rcon.
# Using it means the server does the hashing, in its own format, with no file
# edited underneath a process that has it open. Nothing here needs downtime.
#
# THE RCON REPLY ARRIVES ONE PACKET LATE. Project Zomboid answers command N when
# command N+1 is sent — measured, not folklore: sending players, setpassword,
# changepwd in a row returned nothing, then the player list, then setpassword's
# usage text. So a harmless second command is sent purely to flush the first
# one's reply. Without it this script would report success having read an empty
# packet.
#
# AND IT VERIFIES BY LOOKING. rcon returns no status worth trusting, so the
# bcrypt hash in the database is read before and after: if it did not change,
# this exits non-zero. A password tool that cannot tell success from silence is
# worse than none.
#
# The new password is printed once, to the terminal, and nowhere else. Secrets
# reach the helper container on stdin, never in argv or the environment, where
# docker inspect would keep them for the life of the container.
set -euo pipefail
cd "$(dirname "$0")/.."

ACCT=${1:?usage: set-password.sh <account> [password]}
PROJECT="${ZOMBOID_PROJECT:-zomboid}"
SAVE="$(grep -E '^ZOMBOID_SERVER_SAVE_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
SAVE="${SAVE:-servertest}"
DB="db/${SAVE}.db"
VOLUME="zomboid-server-data"
IMAGE="python:3.13-alpine"

cid="$(docker compose -p "$PROJECT" ps -q zomboid-server 2>/dev/null || true)"
[ -n "$cid" ] || { echo "the zomboid container is not running — this needs the live server"; exit 1; }

RCONPW="$(grep -E '^ZOMBOID_SERVER_RCON_PASSWORD=' .env | head -1 | cut -d= -f2-)"
[ -n "$RCONPW" ] || { echo "ZOMBOID_SERVER_RCON_PASSWORD is not set in .env"; exit 1; }

# Reads the stored hash for the account, from the volume, read-only.
stored_hash() {
  docker run --rm -v "$VOLUME":/data:ro "$IMAGE" python3 - "/data/$DB" "$ACCT" <<'PY'
import sqlite3, sys
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
r = c.execute("select password from whitelist where username = ?", (sys.argv[2],)).fetchone()
print(r[0] if r else "")
PY
}

# The account must already exist. setpassword on an unknown name reports
# nothing useful, and a typo would otherwise look exactly like success.
BEFORE="$(stored_hash)"
[ -n "$BEFORE" ] || { echo "no such account: $ACCT (looked in $DB)"; exit 1; }

NEWPW=${2:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}

echo "== setting the password for $ACCT"
printf '%s\n%s\n%s\n' "$RCONPW" "$ACCT" "$NEWPW" | \
docker run -i --rm --network "container:$cid" "$IMAGE" python -c '
import socket, struct, sys, re
rcon, acct, pw = (sys.stdin.readline().rstrip("\n") for _ in range(3))

def pkt(rid, typ, body):
    d = struct.pack("<ii", rid, typ) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(d)) + d

def read(s):
    n = struct.unpack("<i", s.recv(4))[0]
    d = b""
    while len(d) < n:
        d += s.recv(n - len(d))
    return struct.unpack("<ii", d[:8])[0], d[8:-2].decode("utf-8", "replace")

s = socket.create_connection(("127.0.0.1", 27015), timeout=15)
s.send(pkt(1, 3, rcon))
if read(s)[0] == -1:
    sys.exit("rcon refused the password")
s.send(pkt(2, 2, "setpassword \"%s\" \"%s\"" % (acct, pw)))
read(s)                       # stale reply belonging to the packet before this one
s.send(pkt(3, 2, "players"))  # sent only to flush the reply above
msg = read(s)[1].strip() or "(nothing)"
# The server echoes the new bcrypt hash back. It is not the password, but this
# script exists partly to keep such things out of scrollback, so it goes too.
msg = re.sub(r"\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}", "<hash>", msg)
print("   server said:", msg)
s.close()
'

# Give the server a moment to commit, then prove it by the stored hash.
AFTER="$BEFORE"
for _ in $(seq 1 15); do
  AFTER="$(stored_hash)"
  [ "$AFTER" != "$BEFORE" ] && break
  sleep 1
done

if [ "$AFTER" = "$BEFORE" ]; then
  echo "FAILED: the stored hash did not change — the password is unchanged"
  exit 1
fi

echo "== done. The stored hash changed. The new password, shown once:"
echo "   $NEWPW"
echo "   Tell the player to log in with it and then set their own:"
echo "   /changepwd \"thatpassword\" \"whatever they like\""
