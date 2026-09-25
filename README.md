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
docker compose -p zomboid ps          # healthy once ProjectZomboid64 is up
```

Players connect by address on 16261; the server is not in the public browser unless `.env` says so.

## What this file knows that a fresh one does not

**The save name is a directory, not a label.** `SERVERNAME` decides where the world lives on disk. Change it and Zomboid starts a new, empty world, leaving the old one orphaned with nothing pointing at it. The name players see is `DISPLAYNAME`, and that one is safe to change. This warning used to exist nowhere: a bare line in `.env`, and `.env` carries no comments into anything.

**No pipe character in the display name.** The image writes settings with `sed -i "s|^${1}=.*|${1}=${2}|"`, which uses `|` as its own delimiter, so a name containing one makes sed abort and the setting is silently never written. `Something | Zomboid` did exactly that.

**The game updates on every start, on purpose.** The image's entrypoint runs SteamCMD only when `FORCEUPDATE` is set. Without it the server never updates while every Steam client does, and the server then fails the anti-cheat file checksum and kicks players with "file doesn't match the one on the server" — which reads like a mod problem and is not one. A weekly restart meant to fix this restarted into the same old build for weeks before anyone read the build id. `scripts/refresh.sh` reads it before and after and says which one it ended on.

**Both game ports are forwarded.** 16261 is the handshake; 16262 is the direct connection every client is handed after it. Forward only the first and players connect, wait, and time out with nothing in the log.

**Both volumes are external, so `docker compose down -v` cannot delete the world.** `down -v` is the command everyone reaches for when a stack misbehaves. On a project-managed volume it removes every base and every character without asking. Creating the volumes by hand once is the price of not losing them by accident.

**Two minutes to stop.** The world is saved on the way out, and a large map with many loaded chunks takes well over the ten seconds docker allows by default. A SIGKILL in the middle of that is a corrupted save.

**The memory ceiling is measured, not guessed.** Peak 9.5 GB, resident 2.9 GB, on a world a group of four had explored for months. The world grows, so the ceiling sits well clear of the peak, and the JVM heap is bounded separately so the two cannot argue.

**The rcon reply arrives one packet late.** Project Zomboid answers command N when command N+1 is sent — measured, not folklore. Any tool that reads one reply per command reads an empty packet and reports success. `scripts/set-password.sh` sends a harmless second command to flush the first one's reply, and then does not trust the reply anyway: it reads the stored bcrypt hash before and after and exits non-zero if it did not change.

## Backups

`scripts/backup.sh` asks the running server to flush the world to disk over rcon, then archives the data volume. The archive is written as `.partial` and renamed only on success, so a backup interrupted halfway never carries the name a finished one has. Run it from cron; `ZOMBOID_BACKUP_DIR` says where the archives go.

Take one before every recreate that touches the world: an image update, a preset change, a save-name change you are about to regret.

## Administration

rcon stays inside the container; nothing on the host listens for it. Run a client in the container's namespace:

```bash
# in-game admin commands over rcon, password from .env
docker run --rm -i --network "container:$(docker compose -p zomboid ps -q zomboid-server)" \
  -e PW="$(grep ^ZOMBOID_SERVER_RCON_PASSWORD= .env | cut -d= -f2-)" python:3.13-alpine \
  python3 -c 'import socket,struct,os
def pkt(i,t,b): d=struct.pack("<ii",i,t)+b.encode()+b"\x00\x00"; return struct.pack("<i",len(d))+d
s=socket.create_connection(("127.0.0.1",27015),timeout=10)
s.sendall(pkt(1,3,os.environ["PW"])); s.recv(4096)
s.sendall(pkt(2,2,"players")); s.sendall(pkt(3,2,"players"))   # the second one flushes the first reply
print(s.recv(4096)[12:].decode(errors="replace"))'
```

`scripts/set-password.sh <account>` replaces a forgotten player password through the server, so the server does the hashing and no file is edited underneath a process that has it open.

## Updating

The pin lives in the `x-images` block at the top of the compose file, as an interpolation default, so a `git pull` delivers the version this repository has tested. Only the stable `NN.N.N-release` line is ever pinned: every Steam client is on it. The daily freshness check compares the pin against the newest stable tag on Docker Hub and goes red when a newer one exists. `./update.sh` does that on purpose: it moves to the latest release tag, refuses to cross a major unattended, and names any new required variable before anything has moved.

## Testing

`tests/e2e-healthcheck.sh` runs the health check in both directions against a fixture with no game download. CI runs it on every push alongside shell and workflow linting, a Trivy scan of the pinned image, and a daily check that the pin still resolves to what upstream publishes.

CI does not boot the game. The first start is a 10 GB SteamCMD download, and a test that pretends a runner does that in time is a test that never runs.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
