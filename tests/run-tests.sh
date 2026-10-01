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
    tools/build-cubic-installer.sh
    packaging/build-deb.sh
    packaging/debian/postinst
    packaging/debian/prerm
    packaging/debian/postrm
)
for file in "${shell_files[@]}"; do
    bash -n "$PROJECT_DIR/$file"
done

PYTHONPYCACHEPREFIX="$TEST_DIR/pycache" python3 -m py_compile \
    "$PROJECT_DIR/src/gui/eduka-update-system-gui.py" \
    "$PROJECT_DIR/src/integration/eus-panel-status.py" \
    "$PROJECT_DIR/src/integration/eus_panel_indicator.py" \
    "$PROJECT_DIR/src/backend/eduka-update-system-tool.py"

# Repository, keyring and kernel helper on a fake APT tree.
PYTHONPYCACHEPREFIX="$TEST_DIR/pycache" python3 "$PROJECT_DIR/tests/test_tool.py" >/dev/null
help_text="$(bash "$PROJECT_DIR/src/launcher/eduka-update-system.sh" --help)"
grep -q -- "--fix-keys" <<<"$help_text"

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
test -x "$TEST_DIR/root/usr/local/libexec/eduka-update-system-tool"
test -r "$TEST_DIR/root/etc/systemd/system/eus-sources.path"
test -L "$TEST_DIR/root/usr/local/bin/eduka-upgrade-action.sh"
test -r "$TEST_DIR/root/usr/share/applications/eduka-update-system.desktop"
test -r "$TEST_DIR/root/etc/eus/version"
grep -qx "VERSION='0.13'" "$TEST_DIR/root/etc/eus/version"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$PROJECT_DIR/data/applications/eduka-update-system.desktop"
    desktop-file-validate "$PROJECT_DIR/data/autostart/eduka-update-system-indicator.desktop"
    desktop-file-validate "$PROJECT_DIR/data/autostart/eduka-update-system-notifier.desktop"
fi

# The generated Cubic installer must match the current source tree.
EUS_INSTALL_ROOT="$TEST_DIR/cubic" bash "$PROJECT_DIR/tools/install-eduka-update-system-cubic.sh" >/dev/null
cmp -s "$PROJECT_DIR/src/gui/eduka-update-system-gui.py" "$TEST_DIR/cubic/usr/local/libexec/eduka-update-system-gui" || {
    printf 'tools/install-eduka-update-system-cubic.sh is stale; run tools/build-cubic-installer.sh\n' >&2
    exit 1
}

if command -v dpkg-deb >/dev/null 2>&1; then
    deb="$(bash "$PROJECT_DIR/packaging/build-deb.sh" "$TEST_DIR/deb")"
    dpkg-deb --field "$deb" Version | grep -qx "$(tr -d '[:space:]' <"$PROJECT_DIR/VERSION")"
    contents="$(dpkg-deb --contents "$deb")"
    grep -q './usr/local/libexec/eduka-update-system-tool' <<<"$contents"
fi

printf 'All EUS source checks passed.\n'
