# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **The admin password is no longer on the game's command line or in `docker compose logs`.** The image passed it as `-adminpassword`, and the game's launcher prints every argument it gets (`pzexe: arg: …`), so on every start it was in `docker compose logs`, on the command line of the game's processes, readable by every process in the container, and in `ps` on the host (CI run 43582000653 found it in all three). `tools/start.sh` is now the entrypoint. The image gets the password empty; the server gets it on its console, on stdin, and only when it asks for one, which is on a world without its admin account, the first start. Only the game's own question line counts, and only until the server first answers A2S_INFO, before which no player can be on; text a player can get printed never draws the password out (`tests/e2e-start.sh` plants both). Project Zomboid 42.20.4 creates the account from the console; CI checks the account's stored hash against the password. **If you posted this server's logs anywhere, change the admin password** (`/changepwd` in game, or `scripts/set-password.sh admin -`): docker keeps earlier starts' output in its log files until they rotate out.
- **The rcon password is no longer on a command line.** The image wrote it into the ini with `sed -i`, which held it in sed's arguments while that ran. `tools/start.sh` writes it with bash builtins, reads it back and leaves the ini mode 600; CI logs in to rcon with it, and a wrong one is refused.
- **`scripts/set-password.sh` no longer takes a password as its argument.** A player password given as `set-password.sh <account> <password>` was in the host's `ps` for as long as the script ran and stayed in the shell's history. That form now exits 2 and changes nothing; with no second argument a password is generated, as before, and `-` reads one from stdin, without echo at a terminal.
- **CI looks for both passwords everywhere they leaked to.** `tests/secret-probe.sh` gives each a value of its own and fails on either in `docker compose logs`, the game's own logs (`server-console.txt`, `Logs/`, and after a restart the archived logs), any command line in the container or the host's `ps`, after the first start and after a restart, and on the command lines while the backup and `set-password.sh` run. It names the variable and the place, never the value. On the commit before this fix it is red (run 43582000653).

### Changed

- **A password with a space, a quote, a backslash or a line break stops the start.** The log filter masks a value up to the next space or quote, so such a password could not be kept out of the logs whole; the generator in `.env.example` makes letters and digits, so a password made with it is unaffected.

### Fixed

- **Stopping the server saves the world.** Docker sends SIGTERM to the container's process 1, which was the image's entry script; it ignores SIGTERM there, and nothing passed it on, so every stop, restart and update waited out the two-minute grace period and then killed the server with SIGKILL, with no save on the way out: `tests/clean-stop.sh` on v1.3.1 measured 122 seconds of a 120-second grace period, exit 137 after Docker's SIGKILL, and no "Saving finish" (run 43584727124); with this release, 11 seconds, exit 0, and the server's "Saving finish" (run 43585544267). `tools/start.sh` is process 1 now: on SIGTERM it tells the server `quit` on its console (once the server answers A2S_INFO; before that no world is in memory), which saves the world and exits, and it waits for the server's last lines to reach `docker compose logs` before it exits with the server's status; the kernel would otherwise cut them off. CI restarts the real server and requires the quit inside the grace period, and `tests/clean-stop.sh` stops it and needs exit 0 or 143, no SIGKILL and the server's "Saving finish".
- **rcon logins are read to their verdict, and a wrong password is an error.** Project Zomboid answers a login with an empty packet and then the verdict (id -1 for a wrong password). The README's example, `scripts/backup.sh` and `scripts/set-password.sh` read one packet after the login, so a wrong rcon password passed as a login and every reply after it was read one packet behind. `tools/rcon.sh` reads the login to its verdict, exits 3 on a refused password and reads each command's own reply; all three use it now. CI needs the player list back for `players` at once, and a wrong password refused.
- **The backup proves the save it asks for.** `scripts/backup.sh` sent `save` and archived after three seconds whatever had happened. It now waits for the server's own "Saving finish" in its log; without it the archive is still written, the script says so and exits 3. CI runs it on the real server and needs the line.
- **`scripts/set-password.sh` works.** It read the account's stored hash with `docker run … python3 - <<'PY'` and no `-i`, so docker gave the container no stdin, python ran an empty script, and the script answered "no such account" for every account, every time. It now passes `-i`. CI had never run it; it now sets the admin password with it on the real server, watched by the probe, and checks the stored hash afterwards.
- **Corrected: rcon never answered one packet late.** The README, the health check's comments and this changelog (the v1.1.0 entry: "answers command N when command N+1 is sent — measured") said Project Zomboid answers rcon command N when N+1 is sent. What was measured was a client reading one packet of a two-packet login answer: the verdict, unread, put every later reply one behind. The v1.1.0 entry below is left as written.
- **The health check could cut its own request in two.** bash writes printf's output line by line, so the query echoing the server's challenge went out as two datagrams whenever the challenge held a newline byte (0x0a), and that try went unanswered. The request now goes to a file first and out in one write. `tests/e2e-healthcheck.sh` proves it against a stand-in whose challenge holds one: the v1.3.1 check sends 26 and 3 bytes and stays unhealthy, this one one datagram of 29.

- **An index pushed again over the same build is no longer reported as drift.** The daily pin check compared each pin with the digest the tag's index has now and failed on any difference, so a publisher re-pushing the index over the very same images (a platform added, an attestation rewritten) turned it red for an image nobody rebuilt, and no pin would ever move to turn it green. It now also compares the linux/amd64 build under both digests, the one CI runs and proves: the same build passes with a notice naming both digests, a new build fails as drift exactly as before, and a build that cannot be read still fails.

## [1.3.1] - 2026-11-08

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

[Unreleased]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.2.2...v1.3.0
[1.2.2]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/zomboid-server-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/zomboid-server-docker-compose/releases/tag/v1.0.0
