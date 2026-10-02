#!/bin/bash
# Download and install the Eduka-Update-System .deb from GitHub.
# Works in the Cubic chroot terminal and on an installed Edukasaun OS (as root):
#
#   wget -qO /tmp/get-eus.sh https://raw.githubusercontent.com/hugomonizdorego/Eduka-Update/main/tools/get-eus.sh
#   bash /tmp/get-eus.sh
#
# Environment:
#   EUS_REF=<branch or tag>   take the package from this branch/tag instead of the latest release
#   EUS_DEB_URL=<url>         install exactly this .deb
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

REPO='hugomonizdorego/Eduka-Update'
ASSET='eduka-update-system_all.deb'

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo 'Run as root (in Cubic the terminal is already root): sudo bash get-eus.sh' >&2
    exit 1
fi

download() {
    # download URL FILE -> 0 on success
    if command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 -O "$2" "$1"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$2" "$1"
    else
        echo 'wget or curl is required: apt-get install -y wget' >&2
        return 1
    fi
}

WORK="$(mktemp -d -t eus-get.XXXXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT
DEB="$WORK/$ASSET"

candidates=()
if [[ -n "${EUS_DEB_URL:-}" ]]; then
    candidates+=("$EUS_DEB_URL")
elif [[ -n "${EUS_REF:-}" ]]; then
    candidates+=("https://raw.githubusercontent.com/$REPO/$EUS_REF/releases/$ASSET")
else
    candidates+=("https://github.com/$REPO/releases/latest/download/$ASSET"
                 "https://raw.githubusercontent.com/$REPO/main/releases/$ASSET")
fi

source_url=''
for url in "${candidates[@]}"; do
    echo "Downloading $url"
    if download "$url" "$DEB" && [[ -s "$DEB" ]]; then
        source_url="$url"
        break
    fi
done
[[ -n "$source_url" ]] || { echo 'ERROR: the package could not be downloaded.' >&2; exit 1; }

# Verify the checksum published next to the package when there is one.
if download "${source_url%/*}/SHA256SUMS" "$WORK/SHA256SUMS" 2>/dev/null && \
   grep -q " $ASSET\$" "$WORK/SHA256SUMS"; then
    (cd "$WORK" && grep " $ASSET\$" SHA256SUMS | sha256sum -c -) || {
        echo 'ERROR: checksum mismatch; the download is incomplete or was modified.' >&2
        exit 1
    }
fi

dpkg-deb --field "$DEB" Package Version
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y "$DEB"
echo
echo "Installed: $(eduka-update-system --version)"
echo 'Start it from the menu (Eduka-Update-System) or with: eduka-update-system'
