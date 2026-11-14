# Project Zomboid server using Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/zomboid-server-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/zomboid-server-docker-compose/actions/workflows/deployment-verification.yml)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14885/badge)](https://www.bestpractices.dev/projects/14885)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A private Project Zomboid co-op server, pinned by digest, with a persistent world that this file is arranged around not losing.

```bash
git clone https://github.com/heyvaldemar/zomboid-server-docker-compose
cd zomboid-server-docker-compose
cp .env.example .env && $EDITOR .env          # an admin password and an rcon password
docker volume create zomboid-server-data      # the world - see "the volumes", below
docker volume create zomboid-server-game      # the game files
docker compose -f zomboid-server-docker-compose.yml -p zomboid up -d
```

The first start downloads the game through SteamCMD, about 10 GB, then creates the world. Watch it:

```bash
docker compose -p zomboid logs -f zomboid-server
docker compose -p zomboid ps          # healthy once the server answers A2S_INFO
```

Players connect by address on 16261; the server is not in the public browser unless `.env` says so.

## What this file knows that a fresh one does not

**The save name is a directory, not a label.** `SERVERNAME` decides where the world lives on disk. Change it and Zomboid starts a new, empty world, leaving the old one orphaned with nothing pointing at it. The name players see is `DISPLAYNAME`, and that one is safe to change. This warning used to exist nowhere: a bare line in `.env`, and `.env` carries no comments into anything.

**No pipe character in the display name.** The image writes settings with `sed -i "s|^${1}=.*|${1}=${2}|"`, which uses `|` as its own delimiter, so a name containing one makes sed abort and the setting is silently never written. `Something | Zomboid` did exactly that.

**No password on a command line or in a log.** The image passes the admin password to the game as `-adminpassword`, and the game's launcher prints every argument it gets (`pzexe: arg: …`), so up to v1.3.1 the admin password was in `docker compose logs`, in every process listing in the container and in `ps` on the host, on every start (CI run 43582000653 found it in all three); the image also wrote the rcon password into the ini with `sed -i`, on sed's command line while that ran. The compose file now hands the image both empty. `tools/start.sh`, the entrypoint, writes the rcon password into `Server/<SERVERNAME>.ini` itself, and gives the admin password to the server's console, on stdin, only when the server asks for one: on a world without its admin account, which is the first start. It answers only the game's own question line, and only until the server first answers A2S_INFO, before which no player can be on, so nothing a player gets printed can draw the password out. The admin password in `.env` is used for nothing else; change the account's password in game with `/changepwd`, or with `scripts/set-password.sh admin -`. A password with a space, a quote, a backslash or a line break stops the start; the generator in `.env.example` makes letters and digits. CI gives each a value of its own and looks for both in the logs, the game's logs, every command line in the container and the host's `ps`, after the first start and after a restart, and logs in with both.

**The game updates on every start, on purpose.** The image's entrypoint runs SteamCMD only when `FORCEUPDATE` is set. Without it the server never updates while every Steam client does, and the server then fails the anti-cheat file checksum and kicks players with "file doesn't match the one on the server" — which reads like a mod problem and is not one. A weekly restart meant to fix this restarted into the same old build for weeks before anyone read the build id. `scripts/refresh.sh` reads it before and after and says which one it ended on.

**The refresh never recreates a server it cannot count.** `scripts/refresh.sh` recreates the container, which drops everyone on it, so it asks the server first, over A2S from inside its network namespace, and skips if anyone is on. It used to read a server that did not answer as empty. A server busy saving, or a query lost on the way, answers nothing too, and that reading recreated the server under whoever was playing. Now the query is asked three times; a server that never answers is skipped and the script exits 1, so a probe that can never tell gets noticed. `--force` refreshes anyway, `--dry-run` says what it would do. `tests/e2e-refresh.sh` proves both directions in CI against a stand-in server that answers with players, with nobody, or not at all.

**Both game ports are forwarded.** 16261 is the handshake; 16262 is the direct connection every client is handed after it. Forward only the first and players connect, wait, and time out with nothing in the log.

**Both volumes are external, so `docker compose down -v` cannot delete the world.** `down -v` is the command everyone reaches for when a stack misbehaves. On a project-managed volume it removes every base and every character without asking. Creating the volumes by hand once is the price of not losing them by accident.

**A stop saves the world, and has two minutes to.** Docker sends SIGTERM to the container's process 1. Up to v1.3.1 that was the image's entry script, which ignores it, so the server never heard of a stop: every `docker compose stop`, restart and update waited out the grace period and then killed it with SIGKILL, unsaved (`tests/clean-stop.sh` on v1.3.1: 122 seconds of a 120-second grace period, exit 137, no save). Now process 1 is `tools/start.sh`, which tells the server `quit` on its console, the command that saves the world and exits, and waits for its last lines to reach the logs. The grace period stays at two minutes: a large map with many loaded chunks takes well over the ten seconds docker allows by default, and a SIGKILL in the middle of a save is a corrupted save. CI restarts the real server and requires the quit inside the grace period, then stops it with `tests/clean-stop.sh`, which times the stop, reads the exit code from Docker's die event and needs the server's "Saving finish" in the log.

**The memory ceiling is measured, not guessed.** Peak 9.5 GB, resident 2.9 GB, on a world a group of four had explored for months. The world grows, so the ceiling sits well clear of the peak, and the JVM heap is bounded separately so the two cannot argue.

**The health check asks the server, not its process.** `tools/healthcheck.sh`, mounted read-only, sends A2S_INFO, the Steam query every server browser sends, to the game port and is healthy only on the server's reply. Up to v1.2.2 it looked for `ProjectZomboid` in `/proc`, and a hung or stopped server keeps its process. It does not use rcon, which answers one packet late (below). While SteamCMD downloads and the world loads, nothing answers, so the check is red then. Each check ends within 7 seconds, inside the 10 Docker gives it. **It asks from inside the container**: healthy proves the server answers there, not that the ports are published on the host or open in your firewall; joining from outside is the test of that.

**The rcon login answers twice.** Project Zomboid answers the login with an empty packet and then the verdict, whose id is -1 when the password is wrong. A client that reads one packet after the login cannot tell a refused password from an accepted one, and every reply after it is read one packet behind. Up to v1.3.1 this README described that as the server answering command N when command N+1 is sent; it was the unread verdict (corrected 2026-11-14). `tools/rcon.sh` reads the login to its verdict, exits 3 on a refused password, and reads each command's own reply; CI sends `players` and needs the player list back at once, and needs a wrong password refused. `scripts/set-password.sh` does not trust the reply either way: it reads the stored bcrypt hash before and after and exits non-zero if it did not change.

**Docker Engine 29.4.2 stops SteamCMD, and only that release does.** Its default seccomp profile answers the 32-bit `socketcall` system call with "not implemented" ([moby/moby#52506](https://github.com/moby/moby/issues/52506); for GitHub Actions, the ubuntu-26.04 runner image ships it: [actions/runner-images#14790](https://github.com/actions/runner-images/issues/14790), with the move to 29.7.2 in [actions/runner-images#15205](https://github.com/actions/runner-images/pull/15205)), and SteamCMD is a 32-bit program that makes every socket with it. With Steam and the network both up, it prints `!!! Fatal Error: Steamcmd needs to be online to update.` or `CreateBoundSocket: failed to create socket, error [no name available] (38)`, and the game is never installed or updated. Measured in [a CI run on GitHub's ubuntu-26.04 runner, which ships 29.4.2](https://github.com/heyvaldemar/tf2-server-docker-compose/blob/main/docs/evidence/docker-29.4.2-socketcall.md): SteamCMD failed in this template's pinned image there, and logged in once the daemon had the profile Docker 29.4.3 ships. 29.4.3 reverted the rule, and Ubuntu 26.04's own `docker.io` (27.5.1) never had it. Check with `docker version --format '{{.Server.Version}}'` and upgrade; until you can, point [`seccomp-profile` in `daemon.json`](https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file) at [moby/profiles seccomp v0.2.3](https://github.com/moby/profiles/blob/836ae4d37ef2ec995c77c99fc55f5b5f3af3a897/seccomp/default.json) and restart Docker.

## Backups

`scripts/backup.sh` asks the running server to flush the world to disk over rcon, then archives the data volume. The archive is written as `.partial` and renamed only on success, so a backup interrupted halfway never carries the name a finished one has. Run it from cron; `ZOMBOID_BACKUP_DIR` says where the archives go.

Take one before every recreate that touches the world: an image update, a preset change, a save-name change you are about to regret.

## Administration

rcon stays inside the container; nothing on the host listens for it. `tools/rcon.sh` runs a client in the container's network namespace (a throwaway python container: the game's image has no python3), with the password from `.env` on its stdin:

```bash
tools/rcon.sh players
tools/rcon.sh save            # the world to disk; the server logs "Saving finish"
```

A command that holds a secret goes on stdin: `printf '%s\n' '<command>' | tools/rcon.sh -`. `scripts/backup.sh` asks for a save the same way and archives once the server has logged "Saving finish"; if it never does, the archive is still written and the script exits 3.

`scripts/set-password.sh <account>` replaces a forgotten player password through the server, so the server does the hashing and no file is edited underneath a process that has it open. It makes a new password and prints it once; `scripts/set-password.sh <account> -` reads the one you choose from stdin, without echo at a terminal. A password given as the argument itself is refused: `ps` would show it while the script runs, and the shell's history would keep it.

## Updating

The pin lives in the `x-images` block at the top of the compose file, as an interpolation default, so a `git pull` delivers the version this repository has tested. Only the stable `NN.N.N-release` line is ever pinned: every Steam client is on it. The daily freshness check compares the pin against the newest stable tag on Docker Hub and goes red when a newer one exists. `./update.sh` does that on purpose: it moves to the latest release tag, refuses to cross a major unattended, and names any new required variable before anything has moved.

## Testing

CI installs the game from Steam and boots it on every push, about 10 GB and a new world, then: samples the health check 45 seconds in and needs it red; waits for it to go green on the server's A2S answer; checks the admin account's stored hash against the admin password and logs in to rcon with the rcon password, a wrong one refused for each; runs the backup and `scripts/set-password.sh` with every command line watched; restarts the server and checks it asked for no password; **stops the server** with SIGSTOP and needs it red while the old `/proc` check stays green, and green again after SIGCONT. Through all of it `tests/secret-probe.sh` gives each password a value of its own and fails on either in `docker compose logs`, the game's own logs, a command line in the container or the host's `ps`, naming the place and never the value.

`tests/e2e-healthcheck.sh` runs the health check in the pinned image against a stand-in that answers A2S_INFO, answers after a challenge, answers after a challenge with a newline byte in it only to the query sent as one datagram, stays silent, or is not there: healthy, healthy, healthy, unhealthy within 7 seconds, unhealthy. `tests/e2e-start.sh` runs the entrypoint in the pinned image with a stand-in for the image's `entry.sh` that asks for the admin password the way the game does. CI runs it on every push alongside shell and workflow linting, a Trivy scan of the pinned image, and a daily check that the pin still resolves to what upstream publishes.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · CNCF Ambassador · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
