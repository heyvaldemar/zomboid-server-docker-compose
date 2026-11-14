#!/bin/bash
# start.sh - start Project Zomboid with no password on a command line or in the logs.
#
# The image puts the admin password on the game's command line
# (-adminpassword), and the game's launcher prints every argument it gets
# ("pzexe: arg: ..."), so the password was in `docker compose logs`, in every
# process listing in the container and in `ps` on the host (CI run
# 43582000653 found it in all three). The image writes the rcon password into the server's ini with
# `sed -i`, which puts it on sed's command line for as long as that runs. The
# compose file now hands the image both empty, and this wrapper, its
# entrypoint, does their work and then runs the image's own entry.sh.
#
# THE RCON PASSWORD goes into Server/<SERVERNAME>.ini, RCONPassword=, written
# with bash builtins (no command line), on every start, and read back; the
# file is mode 600.
#
# THE ADMIN PASSWORD goes to the server's console, on stdin, and only when the
# server asks for it. A world without an admin account asks ("Enter new
# administrator password:", then "Confirm the password:"), and the answer is
# written to the console then, once per question. A world that has its admin
# account asks nothing, and nothing is written. Measured: Project Zomboid
# 42.20.4 creates the account from the console, and the value reached no log
# and no command line (CI run 43580564815).
#
# ONLY THE SERVER'S OWN QUESTION, AND ONLY BEFORE ANYONE CAN JOIN. Both
# questions are whole lines from the game's logger ("LOG : General f:0
# st:...> Enter new administrator password: "), printed while the world
# loads, before the server answers A2S_INFO and so before any player can be
# on. An answer is given only to a line of exactly that form, and only until
# the server first answers A2S_INFO (the question tools/healthcheck.sh asks,
# asked here every three seconds until it is answered): from then on nothing
# a player can get printed, a chat line or a name, makes the console receive
# the password.
#
# THE LOGS go through a filter that masks a password the image or the game
# would print, in case a later image prints one again.
#
# A STOP SAVES THE WORLD. See the end of this file.
#
# FAIL CLOSED. No rcon password, a password with a space, a quote, a
# backslash or a line break in it (the generator in .env.example makes letters
# and digits), an ini that cannot be written or does not read back: the
# container stops instead of starting a server without its passwords.
#
# Read whole before it runs: one brace group, ending in exit.
{
set -u
name="${SERVERNAME:-servertest}"
ini="/home/steam/Zomboid/Server/$name.ini"
fail() { echo "start.sh: $1; not starting a server without its passwords" >&2; rm -f "$ini.new"; exit 1; }
rpw="${PZT_RCON_PASSWORD:-}"
apw="${PZT_ADMIN_PASSWORD:-}"
unset PZT_RCON_PASSWORD PZT_ADMIN_PASSWORD
for v in "$rpw" "$apw"; do
  case "$v" in
    *[[:space:]]*|*\"*|*\'*|*\\*) fail "a password holds a space, a quote, a backslash or a line break (.env.example has a generator)" ;;
  esac
done
[ -n "$rpw" ] || fail "no rcon password (ZOMBOID_SERVER_RCON_PASSWORD)"

# The rcon password, into the ini, by bash builtins; the ini's other lines kept.
mkdir -p "${ini%/*}" || fail "cannot create ${ini%/*}"
out=""; put=0
if [ -f "$ini" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ ${line%$'\r'} == RCONPassword=* ]]; then
      [ "$put" = 0 ] && out+="RCONPassword=$rpw"$'\n'
      put=1; continue
    fi
    out+="$line"$'\n'
  done < "$ini"
fi
[ "$put" = 1 ] || out+="RCONPassword=$rpw"$'\n'
mask=$(umask); umask 077
if ! { printf '%s' "$out" > "$ini.new" && cat "$ini.new" > "$ini" && rm -f "$ini.new" && chmod 600 "$ini"; }; then
  fail "cannot write $ini"
fi
umask "$mask"
have=0
while IFS= read -r line || [ -n "$line" ]; do
  [ "${line%$'\r'}" = "RCONPassword=$rpw" ] && have=1
done < "$ini"
[ "$have" = 1 ] || fail "$name.ini does not hold the rcon password after writing it"
echo "start.sh: the rcon password is in $name.ini"
export ADMINPASSWORD="" RCONPASSWORD=""

# The server's console: a pipe only this script and the server hold (opened,
# then unlinked), so the server's stdin is never at its end and nothing else
# can write to it.
fifo="/tmp/start-console.$$"
rm -f "$fifo"
mkfifo -m 600 "$fifo" || fail "cannot make the console pipe"
exec 3<>"$fifo" || fail "cannot open the console pipe"
rm -f "$fifo"

# Reads the server's output: answers the admin password questions while the
# server does not yet answer A2S_INFO, masks what the image or the game would
# print, and passes the rest through as it is.
console() {
  local line l asked=0 armed=1
  local question='^LOG +: General +f:0 st:[0-9,]+> (Enter new administrator password|Confirm the password): *$'
  while IFS= read -r line || [ -n "$line" ]; do
    l=${line%$'\r'}
    if [ "$armed" = 1 ] && [ -e "$upfile" ]; then armed=0; apw=""; fi
    if [ "$armed" = 1 ] && [[ $l =~ $question ]]; then
      if [ -n "$apw" ] && [ "$asked" -lt 2 ]; then
        printf '%s\n' "$apw" >&3
        asked=$((asked + 1))
      else
        echo "start.sh: the server asks for an admin password and has none to get (ZOMBOID_SERVER_ADMIN_PASSWORD); it waits here"
      fi
      [ "$asked" = 2 ] && { apw=""; armed=0; }
    fi
    printf '%s\n' "$line"
  done
}
filter() {
  exec sed -u -E \
    -e 's/((RCON)?Password=)[^ "]*/\1******/Ig' \
    -e 's/(-adminpassword[ =])[^ "]*/\1******/Ig' \
    -e '/arg: -adminpassword$/{n;s/(arg: ).*/\1******/;}'
}
if [ -n "$apw" ]; then
  echo "start.sh: the admin password goes to the console if the server asks for it (a world without its admin account)"
fi

# THE SERVER RUNS AS A CHILD OF THIS SCRIPT, which stays process 1, for two
# reasons. Docker's SIGTERM goes to process 1 only; the image's entry.sh, a
# bash script with no handler, ignores it there, so every stop, restart or
# update waited out the two-minute grace period and then killed the server
# with SIGKILL, unsaved (tests/clean-stop.sh: 122 s of 120, exit 137, run
# 43584727124). Here SIGTERM tells
# the server, on its console, to quit, which saves the world first (once it
# answers A2S_INFO; before that there is none in memory). And the
# kernel kills everything left in the container the moment process 1 exits,
# so this script waits for the server's last lines to pass the filter into
# the logs before it exits, with the server's own exit status.
upfile="/tmp/start-up.$$"; status="/tmp/start-status.$$"
rm -f "$upfile" "$status"
# THE SERVER IS UP once it answers A2S_INFO: players can join from then on,
# and a world is in memory to save.
( until bash /healthcheck.sh "${PORT:-16261}" >/dev/null 2>&1; do sleep 3; done; : > "$upfile" ) &
{ /server/scripts/entry.sh <&3 3<&- 2>&1; echo "$?" > "$status"; } | console | filter &
pl=$!
# shellcheck disable=SC2329   # run by the trap below
stop() {
  if [ -e "$upfile" ]; then
    echo "start.sh: stopping: the server is told to save the world and quit"
    printf 'quit\n' >&3
  else
    echo "start.sh: stopping before the server answers: no world is in memory to save yet"
  fi
}
trap stop TERM INT
while kill -0 "$pl" 2>/dev/null; do wait "$pl"; done
rc="$(cat "$status" 2>/dev/null)"
exit "${rc:-1}"
}
