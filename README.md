# Eduka-Update-System (EUS)

![Version](https://img.shields.io/badge/version-0.12-17845b)
![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)
![Platform](https://img.shields.io/badge/platform-Edukasaun%20OS%20%7C%20Debian-orange)

Eduka-Update-System is the graphical update manager for Edukasaun OS. It
presents APT and Flatpak updates in a compact Qt interface, classifies their
risk, integrates with Eduka-Panel, and performs privileged operations through
PolicyKit.

EUS is intentionally focused on software updates. System cleaning belongs to a
separate application.

## Main features

- Four ordered update groups: **Critical** (red), **Medium/Kernel** (yellow),
  **Regular** (green), and **Flatpak** (blue).
- Package purpose, addressed problem, postponement risk, recommendation,
  installed version, new version, and download size.
- Per-update progress bars with a formal completion state at 100%.
- A resizable native LXQt window with minimize/maximize support, scrolling,
  and X11/Wayland compatibility.
- A single-instance GUI: clicking the panel indicator raises the existing
  window instead of opening a duplicate.
- Eduka-Panel indicator shown only when an update is available.
- Update notification suppressed while the manager window is open.
- Restart detection and a ten-minute restart reminder when required.
- Installation-only history with success/failure status and a clear action.
- Automatic language selection from the session locale: English, Tetum,
  Portuguese, or Indonesian.
- Version shown in **About**; the public version is exactly `0.12`.

## Supported environment

The primary target is Edukasaun OS on a Debian base with LXQt. EUS supports
both X11 and Wayland Qt sessions. APT is required; Flatpak support is optional
at runtime.

## Install from source

```bash
git clone https://github.com/YOUR-ACCOUNT/eduka-update-system.git
cd eduka-update-system
sudo ./install.sh
```

Log out and back in after the first installation so LXQt starts the panel
indicator and background notifier. You can start EUS immediately with:

```bash
eduka-update-system --ui
```

Useful commands:

```bash
eduka-update-system --version
eduka-update-system --check-notify
systemctl status eus-refresh.timer
```

The installer preserves an existing `/etc/eus/eus.conf` and update interval.
Use `./install.sh --no-deps` when all runtime packages are already installed.

## Install inside Cubic

The self-contained installer is kept for ISO maintenance:

```bash
sudo bash tools/install-eduka-update-system-cubic.sh
```

It is generated from the same EUS 0.12 source and is useful when the repository
tree is not copied into the Cubic chroot.

## Remove

```bash
sudo ./uninstall.sh
```

Configuration, cached state, and logs are preserved by default. To remove them
too:

```bash
sudo ./uninstall.sh --purge
```

## Validate a checkout

```bash
make check
```

The checks validate Bash and Python syntax, exercise the update-list parser,
validate desktop files when the validator is installed, and stage a complete
installation in a temporary directory without changing the host system.

## Repository layout

| Path | Purpose |
| --- | --- |
| `src/gui/` | PyQt6 update-manager interface |
| `src/backend/` | privileged APT/Flatpak backend |
| `src/launcher/` | GUI launcher, watcher, notifications and restart reminders |
| `src/integration/` | Eduka-Panel status and indicator processes |
| `data/` | desktop, autostart, systemd and PolicyKit integration |
| `assets/` | application and state icons plus translations |
| `config/` | default EUS configuration |
| `tools/` | self-contained Cubic installer |
| `tests/` | non-destructive source checks and fixtures |

More details are in [Architecture](docs/ARCHITECTURE.md),
[Eduka-Panel integration](docs/EDUKA-PANEL-INTEGRATION.md), and
[Translations](docs/TRANSLATIONS.md).

## Security model

The GUI never runs as root. It asks PolicyKit to execute the small privileged
backend at `/usr/local/libexec/eduka-update-system-root`. The backend validates
its action and selected package names before invoking APT, Flatpak, systemd, or
reboot operations. Please report vulnerabilities privately as described in
[SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). By contributing, you agree that your
work may be distributed under GPL-3.0-or-later.

## License

Copyright © 2026 Edukasaun OS contributors. EUS is free software licensed under
the GNU General Public License, version 3 or later. See [LICENSE](LICENSE).

Edukasaun OS is developed for Timor-Leste by **STI, Digitalização & Mídia –
MCAS**, with **Grupo IDEA**.

> Edukasaun OS, husi Timor oan ba Timor oan.

