# Porthole

A native Mac app for a Docker server's containers and logs, over SSH. Made to replace Dozzle on an Unraid server, with the log viewer my other Mac apps use ([LogKit](https://github.com/matguitarist/LogKit)). Nothing is installed on the server: Porthole runs the `docker` command there through `ssh`.

In English and French. macOS 26 or later.

## What it does

- **Containers**: every container with its icon, health, CPU and memory. Start, stop (after a confirmation) and restart, and open its web page from Unraid's template.
- **Logs**: live, with levels found in most formats (level words like `INF` or `[Warning]`, JSON, logfmt, access logs, tracebacks), filters, search, and folded repeats. A compose stack reads as one log, in time order.
- **Docker insights**: a crash with what its exit code means, a failing health check with its last output, a restart loop.
- **Overview** (⌘0): the server's load and disks, what needs a look, the last day's starts, crashes and health changes, and every container's warnings and errors over 24 hours.
- **Alerts**: on the Mac, and on your phone through Gotify (sent from the server), when a container crashes, runs out of memory, turns unhealthy, keeps restarting, or logs new errors. Click one to see that container's problems.
- **Ignore known noise**: select a line and choose Ignore Messages Like This. The lines stay, dimmed, and stop counting as problems.
- **Clear logs on the server**, one container or all of them, to start from a clean slate.
- **Menu bar icon** with the server's state; with it on, Porthole keeps watching after the window closes.
- **Updates** through Sparkle, from this repository's releases.

## Setup

1. Install Porthole from the [latest release](https://github.com/matguitarist/Porthole/releases/latest).
2. Make sure `ssh <address> docker ps` works from Terminal, with a key (no password prompt).
3. In Settings › Server, enter the SSH address (`root@192.168.40.210`, or a `Host` from `~/.ssh/config`) and the key file, then Test Connection.

### Icons

Porthole takes a container's icon from its `net.unraid.docker.icon` label, then its Unraid template. For anything else, put `/boot/config/plugins/porthole/icons.json` on the server:

```json
{
  "containers": { "LocalProxy": "https://cdn.jsdelivr.net/gh/selfhst/icons/png/nginx.png" },
  "prefixes": { "azeroth-survivors-cmangos-": "/boot/config/plugins/porthole/icons/cmangos.png" }
}
```

A value is a URL or a file on the server.

## The agent: the server from anywhere

`agent/` is a small Rust server (axum and bollard) that runs on the Docker server as a 4 MB container. It serves a web page with the overview and every container's live log, on a phone too, and an HTTP API. It reads levels with the same rules as the Mac app.

```sh
agent/deploy.sh                        # build for linux/amd64, copy over SSH, start "porthole-agent" on port 7080
PORTHOLE_ACTIONS=1 agent/deploy.sh     # also allow Start, Stop and Restart from the page
```

It is read only unless `PORTHOLE_ACTIONS=1`. Put it behind Cloudflare Access (or another login) before giving it a public address; `PORTHOLE_TOKEN` adds a token of its own. The API: `/api/info`, `/api/containers`, `/api/containers/<name>/logs?tail=1000` (server-sent events, or `since=<unix seconds>`), `/api/host`, `/api/problems`, and `POST /api/containers/<name>/<start|stop|restart>`.

## Building

```sh
./build.sh --open                      # build, sign and install ~/Applications/Porthole.app, then open it
swift test --skip Live                 # unit tests
tools/selftest.sh                      # the app's real functions on sample data
tools/snap.sh                          # light and dark snapshots of every page (APP_LANGUAGE=fr for French)
tools/l10n-check.sh                    # every string has its French translation
(cd agent && cargo test)               # the agent
```

`CLAUDE.md` has the rest: layout, checks, design rules. `docs/STORIES.md` lists what's built and what's next.
