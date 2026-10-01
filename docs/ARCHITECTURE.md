# Architecture

EUS separates display, session integration, and privileged package management.

## Components

| Component | Installed location | Responsibility |
| --- | --- | --- |
| Launcher/watcher | `/usr/local/bin/eduka-update-system` | start or raise the GUI, check notifications, run the watcher, and remind about restart |
| PyQt6 GUI | `/usr/local/libexec/eduka-update-system-gui` | display, select, describe, and sequence updates |
| Root backend | `/usr/local/libexec/eduka-update-system-root` | refresh APT metadata, install validated selections, set interval, clear history, and restart |
| Panel status writer | `/usr/local/bin/eus-panel-status` | atomically publish panel state for the current user |
| Panel indicator | `/usr/lib/EUS-ICONS/eus_panel_indicator.py` | show the tray icon only when updates exist and raise EUS when activated |
| Refresh timer | `eus-refresh.timer` | periodically refresh system update metadata |

## State files

The privileged backend owns shared state under `/var/lib/eus`:

- `updates.tsv`: categorized APT and system Flatpak updates;
- `status`: current backend status;
- `last-error`: most recent backend error;
- `restart-required`: normalized restart marker; and
- `history.tsv`: actual installation outcomes only.

The complete log is `/var/log/eus/eus.log`. Per-session indicator state and
the GUI single-instance socket use the logged-in user's runtime directory.

## Update flow

1. The systemd timer or GUI requests a metadata refresh.
2. PolicyKit authenticates a privileged backend call when needed.
3. The backend refreshes APT, scans security/policy/kernel metadata, checks
   Flatpak sources, and atomically writes `updates.tsv`.
4. The GUI reads the snapshot and displays groups in risk order.
5. The user selects updates and the GUI executes APT and Flatpak operations
   outside the UI thread while mapping progress to individual rows.
6. The backend records only real installation outcomes in history.
7. EUS refreshes the list, updates the panel state, and prompts for restart if
   the system requires one.

## Trust boundary

Package names and Flatpak references cross from an unprivileged GUI into the
root backend. The backend validates the requested action and identifiers. Do
not move this validation into the GUI, because the GUI is outside the trust
boundary.

