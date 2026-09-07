#!/bin/bash
# Archive the Project Zomboid world.
#
# Two things a plain `tar` of the volume gets wrong, both handled here:
#
# 1. THE WORLD IN MEMORY IS NEWER THAN THE WORLD ON DISK. The server writes
#    chunks as it goes and everything on shutdown; between those, an archive of
#    the directory is an archive of some earlier moment. So the server is asked
#    to flush first, over rcon, best effort: a flush that fails must not block
#    the backup, because a slightly stale backup beats none.
#
# 2. A BACKUP KILLED HALFWAY MUST NOT KEEP THE NAME A FINISHED ONE HAS. The
#    archive is written as <name>.partial and renamed only once tar has
#    succeeded. A container stopped mid-write, a full disk, a Ctrl-C: all leave
#    a .partial behind, and nothing that restores will ever pick it.
#
# Usage: scripts/backup.sh            (reads .env beside the compose file)
#   ZOMBOID_BACKUP_DIR   where archives go       (default ./backups)
#   ZOMBOID_BACKUP_KEEP  how many to keep        (default 14)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PROJECT="${ZOMBOID_PROJECT:-zomboid}"
BACKUP_DIR="${ZOMBOID_BACKUP_DIR:-./backups}"
KEEP="${ZOMBOID_BACKUP_KEEP:-14}"
VOLUME="zomboid-server-data"

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/zomboid-world-$(date +%Y%m%d-%H%M%S).tar.gz"

cid="$(docker compose -p "$PROJECT" ps -q zomboid-server 2>/dev/null || true)"
if [ -n "$cid" ]; then
  pw="$(grep -E '^ZOMBOID_SERVER_RCON_PASSWORD=' .env 2>/dev/null | head -1 | cut -d= -f2-)"
  if [ -n "$pw" ]; then
    # The password goes in on stdin, never in argv, where `docker inspect` and
    # `ps` would keep it. The server answers command N when N+1 arrives, so a
    # second command is sent to flush the first one's reply; nothing here reads
    # the reply anyway, but a client that waits for it hangs.
    printf '%s\n' "$pw" | docker run --rm -i --network "container:$cid" python:3.13-alpine python3 -c '
import socket, struct, sys, time
pw = sys.stdin.readline().rstrip("\n")
def pkt(i, t, b):
    d = struct.pack("<ii", i, t) + b.encode() + b"\x00\x00"
    return struct.pack("<i", len(d)) + d
try:
    s = socket.create_connection(("127.0.0.1", 27015), timeout=10)
    s.sendall(pkt(1, 3, pw)); s.recv(4096)
    s.sendall(pkt(2, 2, "save")); s.sendall(pkt(3, 2, "players"))
    time.sleep(3); s.close()
except Exception as e:
    print("flush skipped:", e, file=sys.stderr)
' || echo "the flush did not go through; archiving what is on disk" >&2
    sleep 2
  fi
fi

# Written as .partial; renamed only if tar succeeded.
if docker run --rm -v "$VOLUME":/data:ro -v "$(cd "$BACKUP_DIR" && pwd)":/out alpine:3.20 \
     tar -czf "/out/$(basename "$BACKUP_FILE").partial" -C /data . ; then
  mv "${BACKUP_FILE}.partial" "$BACKUP_FILE"
  echo "$(date '+%F %T') wrote $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
else
  mv "${BACKUP_FILE}.partial" "${BACKUP_FILE}.failed" 2>/dev/null
  echo "$(date '+%F %T') FAILED: tar did not complete; see ${BACKUP_FILE}.failed" >&2
  exit 1
fi

# Retention: the newest KEEP finished archives stay. .partial and .failed
# files are never counted and never kept.
# shellcheck disable=SC2012  # the names are this script's own, fixed pattern; no user input reaches them
ls -1t "$BACKUP_DIR"/zomboid-world-*.tar.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | while IFS= read -r old; do
  rm -f -- "$old"
done
find "$BACKUP_DIR" -name 'zomboid-world-*.tar.gz.partial' -mmin +60 -delete 2>/dev/null
exit 0
