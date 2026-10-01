#!/usr/bin/env bash
# Remove Eduka-Update-System while preserving user-facing state by default.
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

DESTDIR="${DESTDIR:-}"
PURGE=0

usage() {
    cat <<'EOF'
Usage: sudo ./uninstall.sh [--purge] [--destdir DIR]

  --purge         Also remove EUS configuration, cached state and logs.
  --destdir DIR   Remove a previously staged installation below DIR.
EOF
}

while (($#)); do
    case "$1" in
        --purge) PURGE=1 ;;
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
    [[ -d "$DESTDIR" ]] || { printf 'DESTDIR does not exist: %s\n' "$DESTDIR" >&2; exit 66; }
    DESTDIR="$(cd -- "$DESTDIR" && pwd -P)"
elif ((EUID != 0)); then
    printf 'Run this uninstaller as root: sudo ./uninstall.sh\n' >&2
    exit 77
fi

target() { printf '%s%s' "$DESTDIR" "$1"; }

if [[ -z "$DESTDIR" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now eus-refresh.timer eus-sources.path >/dev/null 2>&1 || true
fi

files=(
    /usr/local/bin/eduka-update-system
    /usr/local/bin/eduka-upgrade-action.sh
    /usr/local/bin/eus-panel-status
    /usr/local/libexec/eduka-update-system-gui
    /usr/local/libexec/eduka-update-system-root
    /usr/local/libexec/eduka-update-system-tool
    /usr/lib/EUS-ICONS/eus_panel_indicator.py
    /usr/lib/EUS-ICONS/eus-i18n.json
    /usr/lib/EUS-ICONS/eus-icons.json
    /usr/lib/EUS-ICONS/eus-update-idle.png
    /usr/lib/EUS-ICONS/eus-update-available.png
    /usr/lib/EUS-ICONS/eus-update-running.gif
    /usr/lib/EUS-ICONS/eus-update-running.png
    /usr/lib/EUS-ICONS/eus-update-finished.png
    /usr/share/applications/eduka-update-system.desktop
    /usr/share/icons/hicolor/48x48/apps/eduka-update-system.png
    /usr/share/pixmaps/eduka-update-system.png
    /usr/share/polkit-1/actions/tl.edukasaun.eus.policy
    /etc/xdg/autostart/eduka-update-system-indicator.desktop
    /etc/xdg/autostart/eduka-update-system-notifier.desktop
    /etc/systemd/system/eus-refresh.service
    /etc/systemd/system/eus-refresh.timer
    /etc/systemd/system/eus-sources.path
    /etc/systemd/system/eus-sources-refresh.service
    /etc/systemd/system/eus-refresh.timer.d/override.conf
)

for file in "${files[@]}"; do
    rm -f -- "$(target "$file")"
done

if ((PURGE)); then
    purge_files=(
        /etc/eus/eus.conf
        /etc/eus/interval-hours
        /etc/eus/version
        /etc/eus/schedule
        /etc/eus/pause
        /var/lib/eus/apt-update.log
        /var/lib/eus/repair-report.json
        /var/lib/eus/updates.tsv
        /var/lib/eus/status
        /var/lib/eus/last-error
        /var/lib/eus/restart-required
        /var/lib/eus/history.tsv
        /var/log/eus/eus.log
    )
    for file in "${purge_files[@]}"; do
        rm -f -- "$(target "$file")"
    done
fi

directories=(
    /etc/systemd/system/eus-refresh.timer.d
    /usr/lib/EUS-ICONS
    /etc/eus
    /var/lib/eus
    /var/log/eus
)
for directory in "${directories[@]}"; do
    rmdir --ignore-fail-on-non-empty "$(target "$directory")" 2>/dev/null || true
done

if [[ -z "$DESTDIR" ]]; then
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache -f -q /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

if ((PURGE)); then
    printf 'Eduka-Update-System and its local state were removed.\n'
else
    printf 'Eduka-Update-System was removed; /etc/eus, /var/lib/eus and /var/log/eus were preserved.\n'
fi

