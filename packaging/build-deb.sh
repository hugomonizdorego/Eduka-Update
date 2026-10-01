#!/usr/bin/env bash
# Build an installable .deb of Eduka-Update-System from this checkout.
# Usage: packaging/build-deb.sh [OUTPUT_DIR]      (default: dist/)
# Install (also inside the Cubic chroot terminal):
#   apt install ./eduka-update-system_<version>_all.deb
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUTPUT_DIR="${1:-$PROJECT_DIR/dist}"
VERSION="$(tr -d '[:space:]' <"$PROJECT_DIR/VERSION")"
PACKAGE='eduka-update-system'
MAINTAINER="${DEB_MAINTAINER:-Edukasaun OS contributors <noreply@localhost>}"

command -v dpkg-deb >/dev/null 2>&1 || { printf 'dpkg-deb is required.\n' >&2; exit 69; }
mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd -P)"
STAGE="$(mktemp -d -t eus-deb.XXXXXXXX)"
trap 'rm -rf -- "$STAGE"' EXIT
ROOT="$STAGE/root"

# Reuse the source installer so the package and `sudo ./install.sh` stay identical.
DESTDIR="$ROOT" bash "$PROJECT_DIR/install.sh" --no-deps --no-services >/dev/null

# Packaged systemd units belong in /usr/lib; /etc stays free for administrator overrides
# such as the schedule drop-in written by EUS itself.
install -d -m 0755 "$ROOT/usr/lib/systemd/system"
for unit in eus-refresh.service eus-refresh.timer eus-sources.path eus-sources-refresh.service; do
    mv -- "$ROOT/etc/systemd/system/$unit" "$ROOT/usr/lib/systemd/system/$unit"
done
rmdir -- "$ROOT/etc/systemd/system" "$ROOT/etc/systemd"
# Created and owned by postinst / the backend at runtime, not by dpkg.
rm -f -- "$ROOT/etc/eus/interval-hours"
rmdir -- "$ROOT/var/lib/eus" "$ROOT/var/log/eus" "$ROOT/var/lib" "$ROOT/var/log" "$ROOT/var"
find "$ROOT" -name __pycache__ -prune -exec rm -rf -- {} +

install -D -m 0644 "$PROJECT_DIR/LICENSE" "$ROOT/usr/share/doc/$PACKAGE/copyright"
install -m 0644 "$PROJECT_DIR/README.md" "$PROJECT_DIR/CHANGELOG.md" "$ROOT/usr/share/doc/$PACKAGE/"

install -d -m 0755 "$ROOT/DEBIAN"
installed_size="$(du -sk --exclude=DEBIAN "$ROOT" | awk '{print $1}')"
sed -e "s/@VERSION@/$VERSION/" -e "s/@INSTALLED_SIZE@/$installed_size/" \
    -e "s|@MAINTAINER@|$MAINTAINER|" \
    "$PROJECT_DIR/packaging/debian/control.in" >"$ROOT/DEBIAN/control"
for script in postinst prerm postrm; do
    install -m 0755 "$PROJECT_DIR/packaging/debian/$script" "$ROOT/DEBIAN/$script"
done
printf '/etc/eus/eus.conf\n' >"$ROOT/DEBIAN/conffiles"
(cd "$ROOT" && find . -path ./DEBIAN -prune -o -type f -print0 | sort -z | \
    xargs -0 md5sum | sed 's|  \./|  |') >"$ROOT/DEBIAN/md5sums"
chmod 0644 "$ROOT/DEBIAN/control" "$ROOT/DEBIAN/conffiles" "$ROOT/DEBIAN/md5sums"

deb="$OUTPUT_DIR/${PACKAGE}_${VERSION}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$deb" >/dev/null
printf '%s\n' "$deb"
