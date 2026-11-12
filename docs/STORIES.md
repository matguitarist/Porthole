# Porthole — User stories

Porthole started on 2026-11-11 as a replacement for Dozzle: the Unraid server's containers and logs in a native Mac app, over SSH, with LogKit's viewer.
There is no brief or screen index; these stories record what was built and what comes next. The roadmap is the "Porthole Roadmap" project in Thimble.
Snapshot pages are named in `Screens:` and are built by snapshot mode (`tools/snap.sh`).

---

## M1 Containers and logs (0.1.0)

### S-001 Connect to the server
As the user, I enter the server's SSH address and key file in Settings › Server, and Porthole lists its containers with nothing installed on the server.
Screens: settings-server
Acceptance:
- [self] Porthole connects and lists the sample containers.
- [live] `PORTHOLE_LIVE=1 swift test --filter Live` lists the real server's containers.
- Test Connection reports the number of containers or the error.
Built: one SSH ControlMaster for every command; ssh is spawned disclaimed, so macOS Local Network privacy doesn't block it after a rebuild.
Status: done

### S-002 Read a container's log live
As the user, I pick a container and read its log as it's written, with levels found in most formats (level words, JSON, logfmt, access logs, tracebacks), filters, search, and folded repeats.
Screens: uptime-kuma, seerr, tautulli
Acceptance:
- [unit] Level detection for every format in `LogLineTests`.
- [self] Streams the container's log and reads levels from the app's own words.
Status: done

### S-003 Docker insights
As the user, I see why a container is in trouble: a crash with its exit code, a failing health check with its last output, a restart loop.
Screens: tautulli, mangosd
Acceptance:
- [self] An unhealthy container, three restarts in an hour, and a crash each get an insight.
Status: done

### S-004 Start, stop, and restart
As the user, I start, stop (after a confirmation), or restart the selected container from the toolbar or the Container menu.
Acceptance:
- [self] Start starts it; Stop asks first, then stops it.
Status: done

### S-005 Usage and web page
As the user, I see each container's CPU and memory, and open its web page from Unraid's template.
Acceptance:
- [self] Usage arrives for running containers; the web page comes from Unraid's template.
Status: done

## M2 Watching the server (0.1.0)

### S-006 Overview
As the user, I open the Overview (⌘0) and see the server's load, its disks, what needs a look, the last day's events, and every container's warnings and errors; a row opens that container's problems of the last day.
Screens: overview
Acceptance:
- [self] The overview shows the load and disks, lists containers with errors first, and those that need a look.
- [self] A problem row opens the container's warnings and errors.
Status: done

### S-007 Icons
As the user, every container shows its icon: from its label, its Unraid template, or `/boot/config/plugins/porthole/icons.json` on the server.
Status: done

### S-008 Clear logs on the server
As the user, I empty one container's log, or all of them, on the server, after a confirmation, to start from a clean slate.
Acceptance:
- [self] Clear All Logs asks first; clearing a log removes its problems.
- [unit] A running container stops, its log empties, then it starts again; one that won't stop keeps its log.
Built: Docker 29 breaks `docker logs --tail` for a container whose log file is emptied while it runs, until it restarts, and the hung reads spin dockerd (2026-11-11). So a running container is stopped around the clear.
Status: done

### S-009 Alerts
As the user, I get a notification on the Mac, and on my phone through Gotify, when a container crashes, runs out of memory, turns unhealthy, keeps restarting, or logs new errors; clicking it opens that container's problems.
Screens: settings-alerts
Acceptance:
- [self] A crash sends one alert, not two (15 minutes of quiet per alert).
- The Gotify token is kept in the keychain; Send Test reports the result.
Status: done

### S-010 Ignore known noise
As the user, I select a log line and choose "Ignore Messages Like This…"; those lines stay in the log, dimmed, but no longer count as problems or send alerts. Settings › Ignored lists the rules.
Screens: settings-ignored
Acceptance:
- [self] An ignore rule stops counting its messages; removing it counts them again.
Status: done

### S-011 Compose stacks
As the user, I open a compose stack and read its containers' logs as one, in time order, with each line's container as its source.
Screens: stack-media
Acceptance:
- [unit] The merged command sorts the earlier lines by time, then follows.
- [self] A stack's log merges its containers.
Status: done

### S-012 Menu bar
As the user, a menu bar icon shows the server's state; its panel shows the load, what needs a look, and the top problems. With it on, Porthole keeps watching after the window closes.
Screens: menubar
Status: done

### S-013 Settings, menus, and updates
As the user, I open Porthole at login, choose how often it scans for problems, and get updates through Sparkle; every action has a menu item and a shortcut.
Screens: settings-general, settings-updates
Status: done

## M3 Away from the Mac

### S-014 The agent and its web page
As the user, I open a web page from anywhere and see the server's overview and every container's live log, with levels, filters, and search, on a phone too.
Acceptance:
- [unit] `cargo test` in `agent/`: the Rust parser reads levels like the Mac app; host load from /proc; the token check.
- The image builds for linux/amd64 and reports healthy.
- `agent/deploy.sh` installs it on Unraid as `porthole-agent`, read only unless `PORTHOLE_ACTIONS=1`.
Status: deployed on the server at :7080 (needs the owner: a Cloudflare hostname and Access)

### S-015 French
As the user, with my Mac in French, Porthole speaks French.
Acceptance:
- Every string in the app has a French translation in `Localization/Localizable.xcstrings`.
- [snap] The overview and Settings in French (`APP_LANGUAGE=fr tools/snap.sh`).
- `tools/l10n-check.sh` prints L10N PASS.
Built: Docker's own status text ("Up 6 hours") stays as Docker writes it.
Status: done
