# Eduka-Panel integration

The panel indicator is a session process started by
`eduka-update-system-indicator.desktop`.

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

