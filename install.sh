#!/usr/bin/env bash
# Install Eduka-Update-System from a source checkout.
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DESTDIR="${DESTDIR:-}"
INSTALL_DEPS=1
ENABLE_SERVICES=1
BIN_DIR="${EUS_BIN_DIR:-$PROJECT_DIR/target/release}"
PROGRAMS=(eduka-update-system-gui eduka-update-system-tool eus-panel-status eus-tray-indicator)

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [OPTIONS]

Options:
  --bindir DIR    Take the Rust programs from DIR (default: target/release,
                  built with cargo when they are missing).
  --no-deps       Do not install Debian runtime dependencies.
  --no-services   Do not enable or start the refresh timer.
  --destdir DIR   Stage files below DIR instead of installing to /.
  -h, --help      Show this help text.

DESTDIR can also be supplied as an environment variable. A staged install
never installs packages or starts services.
EOF
}

while (($#)); do
    case "$1" in
        --no-deps) INSTALL_DEPS=0 ;;
        --no-services) ENABLE_SERVICES=0 ;;
        --bindir)
            (($# >= 2)) || { printf 'Missing value for --bindir.\n' >&2; exit 64; }
            BIN_DIR="$2"
            shift
            ;;
        --destdir)
            (($# >= 2)) || { printf 'Missing value for --destdir.\n' >&2; exit 64; }
            DESTDIR="$2"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done

if [[ -n "$DESTDIR" ]]; then
    DESTDIR="$(mkdir -p -- "$DESTDIR" && cd -- "$DESTDIR" && pwd -P)"
    INSTALL_DEPS=0
    ENABLE_SERVICES=0
elif ((EUID != 0)); then
    printf 'Run this installer as root: sudo ./install.sh\n' >&2
    exit 77
fi

target() { printf '%s%s' "$DESTDIR" "$1"; }

install_file() {
    local mode="$1" source="$2" destination="$3"
    install -D -m "$mode" "$PROJECT_DIR/$source" "$(target "$destination")"
}

install_if_missing() {
    local mode="$1" source="$2" destination="$3" resolved
    resolved="$(target "$destination")"
    if [[ ! -e "$resolved" ]]; then
        install_file "$mode" "$source" "$destination"
    fi
}

if ((INSTALL_DEPS)); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    mapfile -t dependencies < <(sed -E '/^[[:space:]]*(#|$)/d' "$PROJECT_DIR/requirements-system.txt")
    apt-get install -y --no-install-recommends "${dependencies[@]}"
fi

# The programs are written in Rust; build them when no binaries are supplied.
missing=0
for program in "${PROGRAMS[@]}"; do
    [[ -x "$BIN_DIR/$program" ]] || missing=1
done
if ((missing)); then
    if [[ "$BIN_DIR" != "$PROJECT_DIR/target/release" ]] || ! command -v cargo >/dev/null 2>&1; then
        printf 'The EUS programs were not found in %s.\n' "$BIN_DIR" >&2
        printf 'Install Rust 1.92 or newer (rustup.rs) plus pkg-config and libfontconfig-dev, then run this\n' >&2
        printf 'installer again, or install the prebuilt .deb package.\n' >&2
        exit 69
    fi
    printf 'Building the EUS programs with cargo (this takes a few minutes)...\n'
    (cd "$PROJECT_DIR" && cargo build --release --locked)
fi
install_binary() {
    install -D -m 0755 "$BIN_DIR/$1" "$(target "$2")"
}

install_file 0755 src/launcher/eduka-update-system.sh /usr/local/bin/eduka-update-system
install_binary eus-panel-status /usr/local/bin/eus-panel-status
install_binary eduka-update-system-gui /usr/local/libexec/eduka-update-system-gui
install_file 0755 src/backend/eduka-update-system-root.sh /usr/local/libexec/eduka-update-system-root
install_binary eduka-update-system-tool /usr/local/libexec/eduka-update-system-tool
install_binary eus-tray-indicator /usr/local/libexec/eus-tray-indicator

for asset in "$PROJECT_DIR"/assets/eus-icons/*; do
    install -D -m 0644 "$asset" "$(target "/usr/lib/EUS-ICONS/${asset##*/}")"
done

install_file 0644 assets/icons/hicolor/48x48/apps/eduka-update-system.png /usr/share/icons/hicolor/48x48/apps/eduka-update-system.png
install_file 0644 assets/pixmaps/eduka-update-system.png /usr/share/pixmaps/eduka-update-system.png
install_file 0644 data/applications/eduka-update-system.desktop /usr/share/applications/eduka-update-system.desktop
install_file 0644 data/autostart/eduka-update-system-indicator.desktop /etc/xdg/autostart/eduka-update-system-indicator.desktop
install_file 0644 data/autostart/eduka-update-system-notifier.desktop /etc/xdg/autostart/eduka-update-system-notifier.desktop
install_file 0644 data/polkit/tl.edukasaun.eus.policy /usr/share/polkit-1/actions/tl.edukasaun.eus.policy
install_file 0644 data/systemd/eus-refresh.service /etc/systemd/system/eus-refresh.service
install_file 0644 data/systemd/eus-refresh.timer /etc/systemd/system/eus-refresh.timer
install_file 0644 data/systemd/eus-sources.path /etc/systemd/system/eus-sources.path
install_file 0644 data/systemd/eus-sources-refresh.service /etc/systemd/system/eus-sources-refresh.service

install_file 0644 data/apt/52eduka-update-system /etc/apt/apt.conf.d/52eduka-update-system
install_if_missing 0644 config/eus.conf /etc/eus/eus.conf
install_if_missing 0644 config/interval-hours /etc/eus/interval-hours
install -D -m 0644 "$PROJECT_DIR/VERSION" "$(target /etc/eus/version.raw)"
{
    printf "VERSION='%s'\n" "$(tr -d '[:space:]' <"$PROJECT_DIR/VERSION")"
} >"$(target /etc/eus/version)"
chmod 0644 "$(target /etc/eus/version)"
rm -f -- "$(target /etc/eus/version.raw)"

install -d -m 0755 "$(target /var/lib/eus)" "$(target /var/log/eus)"
ln -sfn eduka-update-system "$(target /usr/local/bin/eduka-upgrade-action.sh)"

# Remove the Python programs of EUS 0.16 and older.
rm -f -- "$(target /usr/lib/EUS-ICONS/eus_panel_indicator.py)"

if [[ -z "$DESTDIR" ]]; then
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache -f -q /usr/share/icons/hicolor >/dev/null 2>&1 || true
    # Edukasaun OS release policy: Debian repositories follow "stable".
    /usr/local/libexec/eduka-update-system-tool continuous-stable --apply \
        >/dev/null 2>&1 || true
    if ((ENABLE_SERVICES)) && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        # In a chroot such as Cubic, systemctl enables the units and skips starting them.
        systemctl enable --now eus-refresh.timer eus-sources.path
    fi
fi

printf 'Eduka-Update-System %s installed successfully%s.\n' \
    "$(tr -d '[:space:]' <"$PROJECT_DIR/VERSION")" \
    "${DESTDIR:+ in $DESTDIR}"

