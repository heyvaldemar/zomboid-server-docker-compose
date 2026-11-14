#!/bin/bash
# set-password.sh <account> [-] — replace a Project Zomboid account password.
#
# With no second argument a new password is generated. With - it is read from
# stdin (typed without echo at a terminal). A password given as the argument
# itself is refused: it would sit in the host's ps for as long as this runs,
# and in the shell's history after.
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
# OVER tools/rcon.sh, which reads the login's verdict (a wrong rcon password is
# an error, exit 1 here) and sends the command, which holds the new password,
# on stdin.
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

ACCT=${1:?usage: set-password.sh <account> [-]   (- reads the new password from stdin)}
case "${2:-}" in
  ""|-) ;;
  *) echo "set-password.sh: a password on the command line is visible in ps and in the shell's history;"
     echo "  run: scripts/set-password.sh $ACCT -   and type it, or leave it out for a generated one"
     exit 2 ;;
esac
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

# Reads the stored hash for the account, from the volume, read-only. -i hands
# the script below to python: without it docker gives the container no stdin,
# python read an empty script, every account looked missing, and this exited
# "no such account" on every run up to v1.3.1 (found when CI first ran it).
stored_hash() {
  docker run --rm -i -v "$VOLUME":/data:ro "$IMAGE" python3 - "/data/$DB" "$ACCT" <<'PY'
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

if [ "${2:-}" = - ]; then
  if [ -t 0 ]; then
    IFS= read -r -s -p "new password for $ACCT: " NEWPW; echo
  else
    IFS= read -r NEWPW || true
  fi
  [ -n "$NEWPW" ] || { echo "no password read from stdin"; exit 1; }
  case "$NEWPW" in *'"'*|*$'\r'*) echo "the password may not hold a double quote or a carriage return (the rcon command quotes it)"; exit 1 ;; esac
else
  NEWPW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
fi

echo "== setting the password for $ACCT"
reply="$(printf 'setpassword "%s" "%s"\n' "$ACCT" "$NEWPW" | tools/rcon.sh -)" || { echo "FAILED: rcon did not take the command (see above)"; exit 1; }
# The server may echo the new hash, or the password; neither goes to scrollback here.
reply="${reply//"$NEWPW"/<the new password>}"
# shellcheck disable=SC2016   # a bcrypt hash: the dollars are literal
echo "   server said: $(sed -E 's/[$]2[aby][$][0-9]{2}[$][./A-Za-z0-9]{53}/<hash>/g' <<<"${reply:-(nothing)}")"

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
