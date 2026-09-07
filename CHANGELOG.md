# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

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

[Unreleased]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/zomboid-server-docker-compose/releases/tag/v1.0.0
