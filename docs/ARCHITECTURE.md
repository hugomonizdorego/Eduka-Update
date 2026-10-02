# Architecture

EUS separates display, session integration, and privileged package management.

## Components

| Component | Installed location | Responsibility |
| --- | --- | --- |
| Launcher/watcher | `/usr/local/bin/eduka-update-system` | start or raise the GUI, check notifications, run the watcher, and remind about restart |
| PyQt6 GUI | `/usr/local/libexec/eduka-update-system-gui` | display, select, describe, and sequence updates |
| Root backend | `/usr/local/libexec/eduka-update-system-root` | refresh APT metadata, install validated selections, schedule/pause checks, kernels, key repair, clear history, and restart |
| Maintenance helper | `/usr/local/libexec/eduka-update-system-tool` | parse APT sources and keyrings, detect duplicates and key errors, list kernels (read-only, unprivileged); repair keys/duplicates, add keys, plan kernel changes (only when called by the root backend) |
| Panel status writer | `/usr/local/bin/eus-panel-status` | atomically publish panel state for the current user |
| Panel indicator | `/usr/lib/EUS-ICONS/eus_panel_indicator.py` | show the tray icon only when updates exist and raise EUS when activated |
| Refresh timer | `eus-refresh.timer` | periodically refresh system update metadata (skipped while paused) |
| Sources watcher | `eus-sources.path` | refresh after repositories or keys change, e.g. added in a terminal |

## State files

The privileged backend owns shared state under `/var/lib/eus`:

- `updates.tsv`: categorized APT and system Flatpak updates;
- `status`: current backend status;
- `last-error`: most recent backend error;
- `restart-required`: normalized restart marker; and
- `history.tsv`: actual installation outcomes only;
- `apt-update.log`: output of the last `apt-get update`, read by Key Fix; and
- `repair-report.json`: result of the last Key Fix / Add Key / Add Repo operation; and
- `os-upgrade`: result of the last new-Debian-release check (`available`,
  `current_codename`, `target_codename`, versions).

Configuration in `/etc/eus`: `schedule` and `interval-hours` (check
schedule; the timer drop-in lives in
`/etc/systemd/system/eus-refresh.timer.d/override.conf`) and `pause`
(`PAUSED_UNTIL` epoch). Backups of changed APT files go to
`/var/backups/eus/<timestamp>/`.

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
root backend. The backend validates the requested action and identifiers; the
helper validates again (names, URIs, kernel plans simulated with `apt-get -s`)
and is executed with `python3 -I` so the caller's environment cannot inject
modules. Do
not move this validation into the GUI, because the GUI is outside the trust
boundary.


## Keyring placement

| Repository | Key goes to |
| --- | --- |
| `Signed-By` file owned by a package (usually `/usr/share/keyrings`) | never edited; the package is reinstalled; if the key is still missing, a copy plus the key is written to `/etc/apt/keyrings/<repo>.gpg` and `Signed-By` is repointed |
| `Signed-By` file not owned by a package | merged into that file |
| third-party, no `Signed-By` | `/etc/apt/keyrings/<repo>.gpg`, and `Signed-By` is added |
| distribution (Debian/Edukasaun/Ubuntu), no `Signed-By` | archive keyring package, then `/etc/apt/trusted.gpg.d/eus-<key>.gpg` |
| key embedded in a `.sources` file | reported; replace it with Add Key |

## OS upgrade

1. `os-check` (after every refresh) reads `dists/stable/Release` from the
   Debian mirror in use and compares it with the codename/version in APT's
   lists.
2. `os-plan` checks `dists/<new suite>/InRelease` for every repository.
   Distribution repositories without it block the upgrade; third-party ones
   are kept on their suite.
3. `os-upgrade` (root): disk-space and plan check, full upgrade of the current
   release, `os-switch` (backup + rewrite), `apt-get update` (restore on
   failure or key errors), `upgrade --without-new-pkgs`, `full-upgrade`.

## Clean-up

`eduka-update-system-tool scan-clean` lists what can be freed (system items
are read unprivileged; per-user caches are scanned as the user).
`clean-user` empties the user's caches without root; `clean-system` runs as
root through the backend's `clean` action. After `upgrade-apt`,
`install-apt`, kernel installation/removal and the OS upgrade, the backend
runs `clean-system autoremove configs apt-cache` unless `AUTO_CLEAN=0` in
`/etc/eus/eus.conf`. Other options there: `AUTO_UPGRADE=off|security|all`
and `TIMESHIFT_SNAPSHOT=0|1`; ignored updates are listed in
`/etc/eus/ignored-updates`.
