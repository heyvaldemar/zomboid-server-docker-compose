#!/bin/bash
# Keep the server on the current game build, and say which build it ended on.
#
# WHY: when The Indie Stone pushes a patch, Steam updates every CLIENT
# automatically while the server sits on whatever it downloaded last. The
# client then fails the anti-cheat file checksum and is kicked with "file
# doesn't match the one on the server" — which reads like a mod problem and is
# not one.
#
# THE FIRST VERSION OF THIS WAS A NO-OP. It said "the image runs SteamCMD at
# container start, so a restart re-syncs the server" and simply restarted. That
# is false: the image calls steamcmd ONLY when FORCEUPDATE is set. So it ran
# every Monday for weeks, reported success, and changed nothing — found when a
# player was kicked and the server was on a build from twelve days earlier.
# FORCEUPDATE is set in the compose file now, and this script no longer takes
# the restart as proof of anything: it reads the build id before and after.
#
# Safe by design: skipped entirely if anyone is playing, and a backup is taken
# first.
set -u
cd "$(dirname "$0")/.." || exit 1

PROJECT="${ZOMBOID_PROJECT:-zomboid}"
COMPOSE="zomboid-server-docker-compose.yml"
MANIFEST='/home/steam/pz-dedicated/steamapps/appmanifest_380870.acf'

cid="$(docker compose -p "$PROJECT" ps -q zomboid-server 2>/dev/null || true)"
[ -n "$cid" ] || { echo "$(date '+%F %T') the server is not running; nothing to refresh"; exit 0; }

buildid() {
  docker exec "$cid" sh -c "grep -oE '\"buildid\"[^0-9]+[0-9]+' $MANIFEST 2>/dev/null | grep -oE '[0-9]+\$'" 2>/dev/null
}

# Anyone online? A2S_INFO on the game port, from inside the namespace. The
# reply carries the player count; an unreachable server is treated as empty,
# because the recreate below heals that too.
players="$(docker run --rm --network "container:$cid" python:3.13-alpine python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(6)
req = b"\xff\xff\xff\xff\x54Source Engine Query\x00"
try:
    s.sendto(req, ("127.0.0.1", 16261)); d, _ = s.recvfrom(4096)
    if d[4:5] == b"\x41":
        s.sendto(req + d[5:9], ("127.0.0.1", 16261)); d, _ = s.recvfrom(4096)
    b = d[6:]; p = b.split(b"\x00", 4)
    print(b[len(p[0]) + len(p[1]) + len(p[2]) + len(p[3]) + 4:][2])
except Exception:
    print(0)
' 2>/dev/null || echo 0)"
if [ "${players:-0}" -gt 0 ]; then
  echo "$(date '+%F %T') skip: $players player(s) online"
  exit 0
fi

scripts/backup.sh >/dev/null 2>&1 || echo "$(date '+%F %T') the backup did not complete; refreshing anyway" >&2

before="$(buildid)"
# up -d --force-recreate, NOT restart: a plain restart of a container created
# before a compose change would start the old configuration again.
docker compose -f "$COMPOSE" -p "$PROJECT" up -d --force-recreate zomboid-server
cid="$(docker compose -p "$PROJECT" ps -q zomboid-server)"

# WAIT FOR THE SIGNAL THAT ARRIVES EITHER WAY. Waiting for the build id to
# CHANGE idles the full timeout on every day the server was already current,
# which is most of them, and a weekly job that idles for twenty minutes when
# there is nothing to do is indistinguishable from one that has hung. The
# container reporting healthy means SteamCMD finished and the world loaded,
# whether or not anything was downloaded.
for _ in $(seq 1 90); do
  sleep 20
  [ "$(docker inspect "$cid" -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null)" = healthy ] && break
done
after="$(buildid)"

if [ -z "$after" ]; then
  echo "$(date '+%F %T') recreated, but the build id could not be read — check the container"
  exit 1
elif [ "$after" = "$before" ]; then
  echo "$(date '+%F %T') already current: build $after"
else
  echo "$(date '+%F %T') updated: build ${before:-unknown} -> $after"
fi
