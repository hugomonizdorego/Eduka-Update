#!/usr/bin/env bash
# Lightweight checks that do not modify the host operating system.
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d -t eus-tests.XXXXXXXX)"
cleanup() {
    [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]] && rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

shell_files=(
    install.sh
    uninstall.sh
    src/launcher/eduka-update-system.sh
    src/backend/eduka-update-system-root.sh
    tools/install-eduka-update-system-cubic.sh
)
for file in "${shell_files[@]}"; do
    bash -n "$PROJECT_DIR/$file"
done

PYTHONPYCACHEPREFIX="$TEST_DIR/pycache" python3 -m py_compile \
    "$PROJECT_DIR/src/gui/eduka-update-system-gui.py" \
    "$PROJECT_DIR/src/integration/eus-panel-status.py" \
    "$PROJECT_DIR/src/integration/eus_panel_indicator.py"

parser_result="$(python3 "$PROJECT_DIR/src/gui/eduka-update-system-gui.py" \
    --self-test "$PROJECT_DIR/tests/sample-updates.tsv")"
grep -q '"total": 4' <<<"$parser_result"
grep -q '"critical": 1' <<<"$parser_result"
grep -q '"medium": 1' <<<"$parser_result"
grep -q '"normal": 1' <<<"$parser_result"
grep -q '"flatpak": 1' <<<"$parser_result"

DESTDIR="$TEST_DIR/root" "$PROJECT_DIR/install.sh" --no-deps --no-services
test -x "$TEST_DIR/root/usr/local/bin/eduka-update-system"
test -x "$TEST_DIR/root/usr/local/libexec/eduka-update-system-gui"
test -L "$TEST_DIR/root/usr/local/bin/eduka-upgrade-action.sh"
test -r "$TEST_DIR/root/usr/share/applications/eduka-update-system.desktop"
test -r "$TEST_DIR/root/etc/eus/version"
grep -qx "VERSION='0.12'" "$TEST_DIR/root/etc/eus/version"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$PROJECT_DIR/data/applications/eduka-update-system.desktop"
    desktop-file-validate "$PROJECT_DIR/data/autostart/eduka-update-system-indicator.desktop"
    desktop-file-validate "$PROJECT_DIR/data/autostart/eduka-update-system-notifier.desktop"
fi

printf 'All EUS source checks passed.\n'
