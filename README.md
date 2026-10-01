# Eduka-Update-System (EUS)

![Version](https://img.shields.io/badge/version-0.13-17845b)
![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)
![Platform](https://img.shields.io/badge/platform-Edukasaun%20OS%20%7C%20Debian-orange)

Eduka-Update-System is the graphical update manager for Edukasaun OS. It
presents APT and Flatpak updates in a Qt interface, classifies their risk,
manages kernels, repairs APT repository keys, integrates with Eduka-Panel,
and performs privileged operations through PolicyKit.

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
- Version shown in **About**; the public version is exactly `0.13`.

### Menus added in 0.13

| Menu | What it does |
| --- | --- |
| **Kernel** | Opens the Kernel Manager. Lists installed kernels as *In use*, *Old kernel — safe to remove*, *New — restart to use* or *Leftover configuration*; installs a new kernel (optionally with matching headers) and removes old kernels. The running kernel and the kernel metapackage can never be removed. After a new kernel is installed and the computer restarts, the previous kernel is marked *Old kernel* automatically and a one-time notification points to it. |
| **Key Fix** | Diagnoses and repairs repository signing problems: downloads missing (`NO_PUBKEY`) or expired keys from the keyserver into the right keyring (the repository's `Signed-By` file when it has one), migrates the deprecated `/etc/apt/trusted.gpg`, converts armored `.gpg` files, fixes permissions, quarantines damaged keyrings, reinstalls the distribution archive keyring, and disables duplicate repository entries. Unreachable repositories are reported separately. Backups go to `/var/backups/eus/`. |
| **Add Key** | Installs a GPG key manually from a file, an HTTPS URL, or a key ID. Without a repository the key is trusted globally (`/etc/apt/trusted.gpg.d/NAME.gpg`, useful for repositories added in a terminal); with a repository EUS writes a deb822 `NAME.sources` with `Signed-By: /etc/apt/keyrings/NAME.gpg` and never creates a duplicate entry. Secret keys are refused. |
| **Settings** | Check every 1/3/6/12/24/48 hours or weekly, or once a day at a chosen time; pause automatic checks and notifications for 1–365 days, and resume at any time. |

Repositories or keys added **in a terminal** (`add-apt-repository`, a new
`*.list`/`*.sources` file, a key in `/etc/apt/keyrings`, …) are detected by
`eus-sources.path`, which triggers a fresh update scan automatically; an open
EUS window reloads by itself.

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
eduka-update-system --open kernel            # or key-fix, add-key, settings
eduka-update-system --list-kernels
eduka-update-system --remove-old-kernels
eduka-update-system --install-kernel linux-image-amd64 --headers
eduka-update-system --fix-keys
eduka-update-system --fix-duplicates
eduka-update-system --add-key vendor ./vendor.asc https://repo.example.org/apt stable main
eduka-update-system --pause 7                # --resume to undo
eduka-update-system --schedule daily 08:30   # or: --schedule interval 12
systemctl status eus-refresh.timer eus-sources.path
```

The installer preserves an existing `/etc/eus/eus.conf` and update interval.
Use `./install.sh --no-deps` when all runtime packages are already installed.

## Install the .deb package (recommended, also inside Cubic)

Build the package from a checkout (needs only `dpkg-deb`):

```bash
make deb          # -> dist/eduka-update-system_0.13_all.deb
```

A prebuilt package is also kept in `releases/`. Copy it into the Cubic
chroot (drag it into the Cubic terminal window) and install it with APT so
the dependencies are resolved:

```bash
apt install ./eduka-update-system_0.13_all.deb
```

The package enables `eus-refresh.timer` and `eus-sources.path` without
starting them, which is what a chroot needs; they start on the first boot.
Remove with `apt remove eduka-update-system` (or `apt purge` to also delete
`/etc/eus`, `/var/lib/eus` and `/var/log/eus`).

## Install inside Cubic without the package

The self-contained installer embeds the whole source tree:

```bash
bash tools/install-eduka-update-system-cubic.sh            # with dependencies
bash tools/install-eduka-update-system-cubic.sh --no-deps  # files only
```

Regenerate it after changing the source with `make cubic-installer`
(`make check` fails when it is stale).

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
| `src/backend/` | privileged APT/Flatpak backend and the repository/key/kernel helper |
| `src/launcher/` | GUI launcher, watcher, notifications and restart reminders |
| `src/integration/` | Eduka-Panel status and indicator processes |
| `data/` | desktop, autostart, systemd and PolicyKit integration |
| `assets/` | application and state icons plus translations |
| `config/` | default EUS configuration |
| `tools/` | self-contained Cubic installer and its generator |
| `packaging/` | `.deb` builder and maintainer scripts |
| `releases/` | prebuilt `.deb` package |
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

