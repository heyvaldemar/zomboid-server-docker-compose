#!/bin/bash
# Archive the Project Zomboid world.
#
# Two things a plain `tar` of the volume gets wrong, both handled here:
#
# 1. THE WORLD IN MEMORY IS NEWER THAN THE WORLD ON DISK. The server writes
#    chunks as it goes and everything on shutdown; between those, an archive of
#    the directory is an archive of some earlier moment. So the server is asked
#    to save first, over rcon (tools/rcon.sh), and the archive waits for the
#    server's own "Saving finish". A save that fails must not block the
#    backup, because a slightly stale backup beats none, but it is said, and
#    the script exits 3.
#
# 2. A BACKUP KILLED HALFWAY MUST NOT KEEP THE NAME A FINISHED ONE HAS. The
#    archive is written as <name>.partial and renamed only once tar has
#    succeeded. A container stopped mid-write, a full disk, a Ctrl-C: all leave
#    a .partial behind, and nothing that restores will ever pick it.
#
# Usage: scripts/backup.sh            (reads .env beside the compose file)
#   exit 0 saved (or the server is stopped) and archived, 1 the archive failed,
#   3 archived, but the running server did not confirm a save
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
unsaved=0
if [ -n "$cid" ]; then
  # The save, and proof of it: the server writes "Saving finish" to its log
  # once the world is on disk. tools/rcon.sh reads the login's verdict, so a
  # wrong rcon password is an error here, not a save that silently never
  # happened. Up to v1.3.1 this sent "save" after reading half the login
  # answer and never looked whether anything was saved.
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  saved=0
  if tools/rcon.sh save >/dev/null; then
    for _ in $(seq 1 60); do
      docker logs --since "$since" "$cid" 2>&1 | grep -q "Saving finish" && { saved=1; break; }
      sleep 1
    done
  fi
  if [ "$saved" = 1 ]; then
    echo "$(date '+%F %T') the server saved the world (Saving finish)"
  else
    echo "$(date '+%F %T') WARNING: the server did not confirm a save within 60 seconds; archiving what is on disk, and exiting 3" >&2
    unsaved=1
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
[ "$unsaved" = 0 ] || exit 3
exit 0
