#!/bin/bash
# admin-password.sh <account> - is the password on stdin the account's password?
#
# Reads the account's stored hash from the world's database in the volume,
# read-only, and checks the password against it with bcrypt, in a throwaway
# container. Prints which way it matched, never the value. Project Zomboid
# may store bcrypt of the password itself or of its MD5; either is that
# password, and the answer names which. A password the server never got
# matches neither.
#
# Exit 0 a match, 1 no match, 2 cannot tell (no account, no database, no bcrypt).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
acct="${1:?usage: admin-password.sh <account>   (the password on stdin)}"
save="$(sed -n 's/^ZOMBOID_SERVER_SAVE_NAME=//p' .env 2>/dev/null | head -1)"
save="${save:-servertest}"
PY=python:3.13-alpine@sha256:7984cf56ceaddebe4fefeb75d64000b9f45d8b77b11a09b24524da6cdc3af0c8
pw=""; IFS= read -r pw || true
[ -n "$pw" ] || { echo "admin-password: no password on stdin" >&2; exit 2; }
# shellcheck disable=SC2016   # the python is single-quoted on purpose: it reads its own argv
check='import sqlite3, sys, hashlib, bcrypt
pw = sys.stdin.readline().rstrip("\n").encode()
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
r = c.execute("select password from whitelist where username = ?", (sys.argv[2],)).fetchone()
if not r or not r[0]:
    print("admin-password: no account %s, or no hash for it" % sys.argv[2]); sys.exit(2)
h = r[0].encode()
if bcrypt.checkpw(pw, h):
    print("admin-password: the stored hash is bcrypt of this password"); sys.exit(0)
if bcrypt.checkpw(hashlib.md5(pw).hexdigest().encode(), h):
    print("admin-password: the stored hash is bcrypt of this password'"'"'s MD5"); sys.exit(0)
print("admin-password: the stored hash is not this password"); sys.exit(1)'
printf '%s\n' "$pw" | docker run --rm -i -e PIP_ROOT_USER_ACTION=ignore -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
  -v zomboid-server-data:/data:ro "$PY" \
  sh -c 'pip install -q bcrypt==4.3.0 >/dev/null 2>&1 || { echo "admin-password: cannot install bcrypt" >&2; exit 2; }; exec python3 -c "$1" "$2" "$3"' \
  sh "$check" "/data/db/$save.db" "$acct"
