# Changelog

All notable changes to Eduka-Update-System are documented here. The project
uses a single public version number without a build suffix.

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

