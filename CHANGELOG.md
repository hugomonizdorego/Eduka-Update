# Changelog

All notable changes to Eduka-Update-System are documented here. The project
uses a single public version number without a build suffix.

## 0.14 — 2026-10-02

### Added

- Keyring placement rules: EUS determines whether a repository's key belongs
  in a package keyring (`/usr/share/keyrings`, never edited — the package is
  reinstalled, or a copy is made in `/etc/apt/keyrings` and `Signed-By` is
  repointed), in the repository's own `Signed-By` keyring, in a new
  `/etc/apt/keyrings/<repo>.gpg` with `Signed-By` (third-party repositories),
  or in `/etc/apt/trusted.gpg.d` (distribution repositories only).
- Key Fix **Repositories** tab: origin (Debian, Debian security, Edukasaun OS,
  Ubuntu, third-party), suite, signing keyring and its location type, and
  status of every repository; every keyring is listed with its role and users.
- Automatic signing-key search on the repository site and the keyservers,
  accepted only when the key matches the ID reported by APT.
- **Add Repo** dialog and `--add-repo`: add a repository, refresh it in
  isolation, find and install its key, set `Signed-By`, verify, roll back on
  failure.
- **Upgrade OS**: detection of a new Debian stable base, repository plan
  (switch / keep third-party / unchanged), guarded upgrade with backup and
  automatic restore, banner, menu, notification, `--check-os` and
  `--upgrade-os`.
- Notification when a repository needs a GPG key.

### Fixed

- APT prints `Err:` for signature failures too; those repositories were
  reported as unreachable instead of missing a key.
- Key Fix crashed when downloading a missing key (`msg()` keyword clash).
- Keyserver results are now verified against the requested key ID.

## 0.13 — 2026-10-01

### Added

- **Kernel** menu: Kernel Manager dialog to install a new kernel (optionally
  with headers) or remove kernels. Kernels older than the running one are
  marked *Old kernel — safe to remove* after a restart; the running kernel and
  the kernel metapackage are protected, and removals are simulated first. A
  one-time notification after booting a new kernel points to old kernels.
- **Key Fix** menu: repairs missing/expired repository keys (keyserver, with an
  HTTPS fallback), the legacy `trusted.gpg` keyring, armored or damaged
  keyrings and permissions, reinstalls the archive keyring, and fixes
  duplicate repository entries (`.list` and deb822 `.sources`) with backups.
- **Add Key** menu: manual GPG key installation from a file, HTTPS URL or key
  ID, optionally adding the repository with `Signed-By` without duplicates.
- Automatic refresh when repositories or keys are added in a terminal
  (`eus-sources.path`); the open window reloads when the state changes.
- Update schedule (interval up to weekly, or daily at a fixed time) and
  pausing automatic checks and notifications for 1–365 days.
- Terminal commands: `--open`, `--list-kernels`, `--install-kernel`,
  `--remove-kernel`, `--remove-old-kernels`, `--fix-keys`,
  `--fix-duplicates`, `--add-key`, `--pause`, `--resume`, `--schedule`.
- `.deb` packaging (`make deb`, installable with `apt install ./…deb`, also in
  the Cubic chroot) and a generated self-contained Cubic installer.

### Changed

- Redesigned interface: menu bar, branded header, status card with category
  counters, action banners (paused, repository problems, old kernels,
  restart), resizable list/description split, and log viewer. History lists
  the newest entries first and includes kernel operations.
- A failing or unreachable repository no longer aborts the whole update
  check; EUS continues with the available package lists and reports the
  problem, telling network failures apart from key problems.

### Fixed

- Update classification ran several `apt-cache` processes per package and
  took minutes with many updates; it now uses one batched query (seconds).
- APT download/install progress never reached the GUI because the progress
  stream inherited APT's log redirection.
- Installing selected updates used `apt-get install`, which marked upgraded
  dependencies as manually installed; it now uses `--only-upgrade`.
- Error dialogs could show a stale message from an earlier operation, or a
  server error after authentication was cancelled.
- Scripts in the repository were not executable, so `sudo ./install.sh` and
  `make check` failed.
- Installing updates no longer runs a redundant second full refresh.

## 0.12 — 2026-10-01

### Added

- Per-item update progress with percentage from 1% through 100% and a formal
  completed state.
- Two-state update check action: **Check for Updates** before the first manual
  scan and **Check Again** afterward.
- An About dialog containing the EUS version.
- Installation-only history showing the affected updates and success/failure,
  plus a clear-history action.
- Locale-aware last-check text with weekday, date, and time but no year.

### Changed

- Refined the compact LXQt interface and native window management.
- Moved progress feedback into the update rows instead of a separate bottom
  progress bar.
- Suppressed update notifications while the EUS window is already open.
- Ensured the Eduka-Panel icon appears only while updates are available.
- Made Flatpak metadata and update operations asynchronous and failure-tolerant
  so the GUI remains responsive.
- Removed all build sub-numbers; the displayed version is exactly `0.12`.

### Fixed

- Corrected the PyQt6 `QTreeWidget.setFirstColumnSpanned()` API call.
- Prevented duplicate EUS windows and duplicate notification action labels.
- Restored scrolling for long update lists.
- Restored native minimize/maximize controls on LXQt, X11, and Wayland.
- Corrected the update-description group title placement.

## 0.11

- Introduced the Eduka-Panel indicator, restart reminders, application icons,
  automatic translation data, and categorized update descriptions.

## 0.9

- Initial public graphical update-manager design.

