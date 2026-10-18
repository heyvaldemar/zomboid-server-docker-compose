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
#
#   scripts/refresh.sh             refresh if nobody is on
#   scripts/refresh.sh --dry-run   say what it would do, change nothing
#   scripts/refresh.sh --force     refresh even with players on, or unknown
set -u
cd "$(dirname "$0")/.." || exit 1

DRY_RUN=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

PROJECT="${ZOMBOID_PROJECT:-zomboid}"
COMPOSE="zomboid-server-docker-compose.yml"
MANIFEST='/home/steam/pz-dedicated/steamapps/appmanifest_380870.acf'

cid="$(docker compose -p "$PROJECT" ps -q zomboid-server 2>/dev/null || true)"
[ -n "$cid" ] || { echo "$(date '+%F %T') the server is not running; nothing to refresh"; exit 0; }

buildid() {
  docker exec "$cid" sh -c "grep -oE '\"buildid\"[^0-9]+[0-9]+' $MANIFEST 2>/dev/null | grep -oE '[0-9]+\$'" 2>/dev/null
}

# Anyone online? A2S_INFO on the game port, from inside the namespace; the
# reply carries the player count.
#
# AN UNANSWERED QUERY IS NOT AN EMPTY SERVER. This used to read one as zero,
# on the theory that the recreate below would heal a server that does not
# answer. But a server busy saving, or a query lost on the way, answers
# nothing too, and reading that as zero recreates the server under whoever is
# on it. On the machine this template comes from, the same assumption had
# three game stacks reading as empty whatever was happening on them, and the
# roll that would have recreated them under a full evening of players was
# stopped by hand. Now the query is asked three times, and a server that
# never answers is "?", skipped like an occupied one: this script exits 1 and
# says so, because a refresh that can never tell is a probe somebody should
# look at. --force refreshes anyway. tests/e2e-refresh.sh proves all of it.
players="$(docker run --rm --network "container:$cid" python:3.13-alpine python3 -c '
import socket
req = b"\xff\xff\xff\xff\x54Source Engine Query\x00"
for _ in range(3):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(6)
    try:
        s.sendto(req, ("127.0.0.1", 16261)); d, _ = s.recvfrom(4096)
        if d[4:5] == b"\x41":
            s.sendto(req + d[5:9], ("127.0.0.1", 16261)); d, _ = s.recvfrom(4096)
        b = d[6:]; p = b.split(b"\x00", 4)
        print(b[len(p[0]) + len(p[1]) + len(p[2]) + len(p[3]) + 4:][2])
        break
    except Exception:
        continue
    finally:
        s.close()
else:
    print("?")
' 2>/dev/null || echo "?")"
case "$players" in ''|*[!0-9]*) players="?" ;; esac
if [ "$players" = "?" ] && [ "$FORCE" != "true" ]; then
  echo "$(date '+%F %T') skip: the server did not answer the player query three times, so nobody can say who is on; --force refreshes anyway" >&2
  exit 1
fi
if [ "$players" != "?" ] && [ "$players" -gt 0 ] && [ "$FORCE" != "true" ]; then
  echo "$(date '+%F %T') skip: $players player(s) online"
  exit 0
fi
if [ "$DRY_RUN" = "true" ]; then
  echo "$(date '+%F %T') would refresh: players online: $players$([ "$FORCE" = "true" ] && echo ', forced')"
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
