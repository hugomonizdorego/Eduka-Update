# Eduka-Panel integration

The tray icon `/usr/local/libexec/eus-tray-indicator` (Rust,
StatusNotifierItem) is a session process started by
`eduka-update-system-indicator.desktop`. It runs once per session.

Eduka-Panel can also show the state itself: it is published in
`$XDG_RUNTIME_DIR/eduka-update-system/panel-status.json`

```json
{"version":1,"state":"available","count":5,"progress":-1,"message":"","updated_at":1791900000}
```

with the icons, `eus-icons.json` and the translations `eus-i18n.json` in
`/usr/lib/EUS-ICONS`. The Python widget module `eus_panel_indicator.py` of
EUS 0.16 and older no longer exists; read the state file instead.

## Visibility rules

- No update: no EUS icon is shown.
- One or more updates: show `eus-update-available.png`.
- Update installation running: show the running animation when the tray
  implementation supports it, otherwise the static running icon.
- Installation finished: briefly use the finished state before refreshing.

Activating the indicator calls `eduka-update-system --ui`. The launcher uses a
single-instance socket, so an existing manager window is raised instead of a
new one being created.

The watcher does not send an update notification while the GUI instance is
open. This avoids the confusing case where clicking a notification appears to
open the update manager twice.

## Status command

Session-aware components can publish state with:

```bash
eus-panel-status available --count 5
eus-panel-status running --count 5 --progress 40
eus-panel-status finished --message "Updates completed"
eus-panel-status idle
```

Do not start the indicator as root. It must run within the LXQt user session so
it can access the correct system tray and notification service.

