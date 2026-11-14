#!/bin/bash
# A stand-in for the image's /server/scripts/entry.sh, for tests/e2e-start.sh.
# Not the game. It reports what tools/start.sh handed it, asks the console for
# the admin password the way Project Zomboid does when MODE=prompt, prints the
# lines the image and the game print with passwords in them (from
# /fixture/values, which only the test mounts), and writes what it read to
# /fixture/out.
#
# MODE=prompt   a world without its admin account: two questions, then a look
#               for anything more on the console
# MODE=none     a world with its admin account: no question, the same look
# MODE=run      the server comes up (the fake health check answers from then
#               on) and the console is read until quit, which "saves the
#               world" and exits 0
# MODE=inject   no real question: the question's words inside a chat line,
#               then the server up, then the question in the game's own form,
#               too late; none may be answered
out=/fixture/out
: > "$out/env"
for n in ADMINPASSWORD RCONPASSWORD PZT_ADMIN_PASSWORD PZT_RCON_PASSWORD; do
  if [ -n "${!n+x}" ]; then echo "$n set, $([ -n "${!n}" ] && echo "with a value" || echo empty)" >> "$out/env"; else echo "$n unset" >> "$out/env"; fi
done
: > "$out/answers"
if [ "${MODE:-none}" = prompt ]; then
  echo "LOG  : General      f:0 st:1> User 'admin' not found, creating it"
  echo "LOG  : General      f:0 st:1> Enter new administrator password: "
  IFS= read -r -t 5 a && printf 'first %s\n' "$a" >> "$out/answers"
  echo "LOG  : General      f:0 st:2> Confirm the password: "
  IFS= read -r -t 5 b && printf 'second %s\n' "$b" >> "$out/answers"
fi
if [ "${MODE:-none}" = inject ]; then
  echo "LOG  : Chat         f:0 st:3> [Player]: Enter new administrator password: "
  echo "Enter new administrator password: "
  IFS= read -r -t 2 x && printf 'injected %s\n' "$x" >> "$out/answers"
  echo "LOG  : General      f:0 st:4> the server is up"
  : > /tmp/fake-up; sleep 5
  echo "LOG  : General      f:0 st:5> Enter new administrator password: "
  IFS= read -r -t 2 y && printf 'late %s\n' "$y" >> "$out/answers"
fi
# Anything more on the console would be read as a server command.
IFS= read -r -t 2 extra && printf 'extra %s\n' "$extra" >> "$out/answers"
# What the image and the game print, values in place, for the filter.
while IFS=$'\t' read -r kind v; do
  case "$kind" in
    argv) printf 'pzexe: arg: -adminpassword\npzexe: arg: %s\n' "$v"
          printf 'ARGS -adminpassword %s -servername x\n' "$v" ;;
    ini)  printf 'sed -i s|^RCONPassword=.*|RCONPassword=%s|\n' "$v" ;;
  esac
done < /fixture/values
if [ "${MODE:-none}" = run ]; then
  echo "LOG  : General      f:0 st:6> the server is up"
  : > /tmp/fake-up
  while IFS= read -r c; do
    [ "$c" = quit ] && { echo "fake-entry: saving the world and quitting"; exit 0; }
    echo "fake-entry: a console command"
  done
  echo "fake-entry: the console ended"
  exit 3
fi
# A burst of output just before the exit, as a server's last lines before it
# stops: all of it, and the line after it, must reach docker logs.
for i in $(seq 1 500); do echo "LOG  : General      f:0 st:9> the last lines, $i"; done
echo "fake-entry: done"
