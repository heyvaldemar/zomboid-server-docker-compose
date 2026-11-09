# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **The rcon example in the README hands the password to docker by name.** It ran `docker run … -e PW="$(grep … .env …)"`, which put the rcon password in the docker CLI's arguments, readable by every user on the host with `ps`. It now sets `PW` for that one command and passes `-e PW`. The jediacademy README carried the same command until its v1.3.0. Fleet conformance now reads README shell blocks and flags any value expanded into `-e NAME=`, so the shape cannot come back unseen.

## [1.3.0] - 2026-11-08

### Changed

- **The health check asks the server, not its process.** It looked for `ProjectZomboid` in `/proc`, which a hung or stopped server keeps. `tools/healthcheck.sh`, mounted read-only, now sends A2S_INFO to the game port and is healthy only on the server's reply (challenge handled, two tries, within 7 seconds); not rcon, which answers one packet late. It asks from inside the container, so it does not prove the ports are published on the host or open in a firewall; the README says so.
- **CI boots the real server on every push.** A new job installs the game, about 10 GB, creates the world, and proves the health check against it: red 45 seconds into the first start, green on the server's A2S answer, red with the server stopped by SIGSTOP while the old `/proc` check stays green, green again after SIGCONT. The stand-in test runs the check in the pinned image. The README said CI could not do this in time; it can.
- **The README names Docker Engine 29.4.2.** That release alone stops SteamCMD, which this image runs to install and update the game (measured on this template's pinned image in tf2-server-docker-compose run 42496129688): upgrade to 29.4.3 or later, which reverted the rule, or point the daemon's `seccomp-profile` at the profile 29.4.3 ships. Ubuntu 26.04's own `docker.io` (27.5.1) never had it; on GitHub Actions the ubuntu-26.04 runner image ships it ([actions/runner-images#14790](https://github.com/actions/runner-images/issues/14790), moving to 29.7.2 in [#15205](https://github.com/actions/runner-images/pull/15205)). Documentation only.
## [1.2.2] - 2026-11-02

### Fixed

- **A restart whose earlier build could not be read is no longer reported as an update.** When the build id before the recreate cannot be read, `scripts/refresh.sh` said "updated: build unknown -> N", claiming a change nobody could see. It now says "restarted, now on build N (the build before the restart could not be read)", as the server this template comes from does. `tests/e2e-refresh.sh` case 7; the released script fails it.

## [1.2.1] - 2026-11-02

### Fixed

- **Docker's own message is no longer reported as the new build.** After the recreate, `scripts/refresh.sh` reads the build again to say what happened. When the container is stopped under that exec, Docker prints "cannot exec in a stopped state" on stdout with exit 128 (measured on Docker 29.7.2), and the refresh reported "updated: build 100 -> cannot exec in a stopped state" and exited 0. The build is now a number from an exec that ended with 0, or unknown, and an unknown one after the recreate is the exit-1 "could not be read" it always was meant to be. `tests/e2e-refresh.sh` case 6 plays it through a wrapper around the real `docker`; the released script fails it. On the server this template comes from, a chat bot read a Docker error on stdout as part of a game's log.
- **Pin Freshness names the variable when the pin is ahead of the newest stable tag on Docker Hub.** The line read `${var}`, which is set only in the step before, so it began with a blank. It now says `ZOMBOID_SERVER_IMAGE_TAG`. Only the message changed; the check passes and fails as before.

## [1.2.0] - 2026-10-18

### Added

- **`scripts/refresh.sh --dry-run` and `--force`.** The first says what the refresh would do and changes nothing; the second refreshes with players on, or with nobody able to say.

### Changed

- **The freshness check has its own workflow, Pin Freshness.** It ran inside Deployment Verification, whose badge is the one at the top of this README. Across the fleet, nine red runs in ten were a pin one version behind - which the fleet's triage moves within the day - and a reader cannot tell that from a stack that does not boot. The badge now says whether the stack boots. The job itself is unchanged.

### Fixed

- **The weekly refresh no longer recreates a server that does not answer.** `scripts/refresh.sh` read an unanswered player query as zero players, so a server busy saving, or a lost packet, meant a recreate under whoever was on. It now asks three times, skips a server that never answers and exits 1 for it. The same assumption had three stacks reading as empty on the machine this template comes from. `tests/e2e-refresh.sh` runs in Deployment Verification; against the old script it never got past the silent server.
- **`update.sh` no longer stops without a word when a release adds a variable and no compose file requires one.** The search for `${VAR:?}` came back empty, and under `pipefail` that empty result ended the script with status 1 right after it listed the new variables.
- **`update.sh` stops on a `.env` it cannot read, before the checkout.** It used to fall through: every new required variable read as "not set", or, with none, the tree moved to the new tag and `docker compose up` failed on the permission. Now it names the file, its owner and mode, and changes nothing.

## [1.1.0] - 2026-09-07

### Added

- **`update.sh`: move between release tags on purpose.** It updates to the latest release (a combination this repository's CI has booted and smoke-tested), refuses to cross a major version unattended, refuses to run over local changes, and names any new required variable before anything has moved. `--dry-run` says what would happen.

west stable tag on Docker Hub.
- **Both volumes declared external**, so `docker compose down -v` cannot
  delete the world — every base, every character — or the 10 GB of game
  files.
- **The save name explained where it can be read.** `SERVERNAME` is the
  directory the world lives in; changing it starts a new, empty world and
  orphans the old one. The warning used to exist nowhere, because `.env`
  carries no comments into anything.
- **The game updated on every start.** The image runs SteamCMD only when
  `FORCEUPDATE` is set; without it every client moves on and the server kicks
  them with a checksum mismatch that reads like a mod problem.
  `scripts/refresh.sh` reads the build id before and after and says which one
  it ended on, instead of taking the restart as proof.
- **A backup that flushes the world first and never keeps a half-written
  name.** `scripts/backup.sh` asks the server to save over rcon, archives the
  data volume as `.partial`, and renames only on success.
- **A password tool that does not trust the rcon reply.** Project Zomboid
  answers command N when command N+1 is sent — measured. `scripts/
  set-password.sh` flushes the reply with a second command and then verifies
  by the stored bcrypt hash, exiting non-zero if it did not change.
- **Both game ports forwarded**, because 16262 is the direct connection every
  client is handed after the handshake, and forwarding only 16261 is a server
  players reach and then time out on.
- **An anchored health check** on `ProjectZomboid64`, which a comm file
  truncates to fifteen characters; **two minutes to stop**, because the world
  is saved on the way out; **measured limits**: peak 9.5 GB, resident 2.9 GB.
- **Deployment Verification CI**: shell and workflow linting, a Trivy scan of
  the pinned image, a daily freshness check on the pin, and the health-check
  suite. It deliberately does not boot the game: the first start is a 10 GB
  download.

[Unreleased]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.2.2...v1.3.0
[1.2.2]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/zomboid-server-docker-compose/releases/tag/v1.0.0
