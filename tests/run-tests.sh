#!/usr/bin/env bash
# Checks that do not modify the host operating system.
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
    tools/build-cubic-installer.sh
    tools/get-eus.sh
    tools/screenshots.sh
    packaging/build-deb.sh
    packaging/debian/postinst
    packaging/debian/prerm
    packaging/debian/postrm
)
for file in "${shell_files[@]}"; do
    bash -n "$PROJECT_DIR/$file"
done
if find "$PROJECT_DIR" -path "$PROJECT_DIR/target" -prune -o -path "$PROJECT_DIR/.git" -prune -o \
        -name '*.py' -print | grep -q .; then
    printf 'Python sources found; EUS 0.17 is written in Rust.\n' >&2
    exit 1
fi

# Rust: unit tests and the integration tests (fake APT tree, local HTTP
# mirror, gpg) of the repository, keyring, release, kernel and cleaner code.
command -v cargo >/dev/null 2>&1 || { printf 'cargo is required for the tests.\n' >&2; exit 69; }
(cd "$PROJECT_DIR" && cargo test --workspace --locked --quiet)
(cd "$PROJECT_DIR" && cargo build --workspace --locked --quiet)
BIN_DIR="$PROJECT_DIR/target/debug"

help_text="$(bash "$PROJECT_DIR/src/launcher/eduka-update-system.sh" --help)"
grep -q -- "--fix-keys" <<<"$help_text"
"$BIN_DIR/eduka-update-system-tool" --help | grep -q 'continuous-stable'

parser_result="$("$BIN_DIR/eduka-update-system-gui" --self-test "$PROJECT_DIR/tests/sample-updates.tsv")"
grep -q '"total":4' <<<"$parser_result"
grep -q '"critical":1' <<<"$parser_result"
grep -q '"medium":1' <<<"$parser_result"
grep -q '"normal":1' <<<"$parser_result"
grep -q '"flatpak":1' <<<"$parser_result"
# 0.15 format: source package and kind columns, kernel category.
parser_result="$("$BIN_DIR/eduka-update-system-gui" --self-test "$PROJECT_DIR/tests/sample-updates-015.tsv")"
grep -q '"total":4' <<<"$parser_result"
grep -q '"kernel":1' <<<"$parser_result"
grep -q '"groups":3' <<<"$parser_result"

# Panel status file for Eduka-Panel.
XDG_RUNTIME_DIR="$TEST_DIR/run" "$BIN_DIR/eus-panel-status" available --count 3
grep -q '"state":"available","count":3' "$TEST_DIR/run/eduka-update-system/panel-status.json"

"$PROJECT_DIR/install.sh" --bindir "$BIN_DIR" --destdir "$TEST_DIR/root" --no-deps --no-services >/dev/null
for program in /usr/local/bin/eduka-update-system /usr/local/bin/eus-panel-status \
               /usr/local/libexec/eduka-update-system-gui /usr/local/libexec/eduka-update-system-tool \
               /usr/local/libexec/eduka-update-system-root /usr/local/libexec/eus-tray-indicator; do
    test -x "$TEST_DIR/root$program"
done
test -r "$TEST_DIR/root/etc/systemd/system/eus-sources.path"
grep -q 'AllowReleaseInfoChange::Codename "true"' "$TEST_DIR/root/etc/apt/apt.conf.d/52eduka-update-system"
test -L "$TEST_DIR/root/usr/local/bin/eduka-upgrade-action.sh"
test -r "$TEST_DIR/root/usr/share/applications/eduka-update-system.desktop"
grep -qx "VERSION='$(tr -d '[:space:]' <"$PROJECT_DIR/VERSION")'" "$TEST_DIR/root/etc/eus/version"
grep -q '^Exec=/usr/local/libexec/eus-tray-indicator' \
    "$TEST_DIR/root/etc/xdg/autostart/eduka-update-system-indicator.desktop"

if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$PROJECT_DIR/data/applications/eduka-update-system.desktop"
    desktop-file-validate "$PROJECT_DIR/data/autostart/eduka-update-system-indicator.desktop"
    desktop-file-validate "$PROJECT_DIR/data/autostart/eduka-update-system-notifier.desktop"
fi

printf 'All EUS checks passed.\n'
