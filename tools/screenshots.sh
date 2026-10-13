#!/usr/bin/env bash
# English screenshots of every page of the update manager, made from the
# fixtures in tests/fixtures (nothing on the host is read or changed).
# Usage: tools/screenshots.sh [OUTPUT_DIR]   (default: docs/screenshots)
# Needs xvfb-run; the GUI is taken from target/release (or EUS_BIN_DIR).
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUTPUT_DIR="${1:-$PROJECT_DIR/docs/screenshots}"
GUI="${EUS_BIN_DIR:-$PROJECT_DIR/target/release}/eduka-update-system-gui"
FX="$PROJECT_DIR/tests/fixtures"
command -v xvfb-run >/dev/null 2>&1 || { printf 'xvfb-run is required (apt install xvfb).\n' >&2; exit 69; }
[[ -x "$GUI" ]] || { printf 'Missing %s; run make build first.\n' "$GUI" >&2; exit 69; }
mkdir -p -- "$OUTPUT_DIR"
EMPTY="$(mktemp -d -t eus-shots.XXXXXXXX)"
trap 'rm -rf -- "$EMPTY"' EXIT

shot() {
    # shot NAME [VAR=value ...] -- GUI-ARGUMENTS
    local name="$1"
    shift
    local settings=()
    while (($#)) && [[ "$1" != -- ]]; do
        settings+=("$1")
        shift
    done
    shift
    env -i PATH="$PATH" HOME="$EMPTY" XDG_RUNTIME_DIR="$EMPTY" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
        EUS_TSV_FILE="$FX/updates.tsv" EUS_STATE_FILE="$FX/status" EUS_VERSION_FILE="$EMPTY/none" \
        EUS_PAUSE_FILE="$EMPTY/none" EUS_RESTART_FILE="$EMPTY/none" EUS_OS_UPGRADE_FILE="$EMPTY/none" \
        EUS_CONFIG_FILE="$EMPTY/none" EUS_SCHEDULE_FILE="$EMPTY/none" EUS_IGNORE_FILE="$FX/ignored-updates" \
        EUS_HEALTH_FILE="$FX/health.json" EUS_HEALTH_FIXTURE="$FX/health.json" \
        EUS_KERNEL_FIXTURE="$FX/kernels.json" EUS_CLEAN_FIXTURE="$FX/clean.json" \
        EUS_OS_PLAN_FIXTURE="$FX/os-plan.json" EUS_REPOSITORIES_FIXTURE="$FX/repositories.json" \
        EUS_HISTORY_FILE="$FX/update-history.tsv" EUS_LOG_FILE="$EMPTY/none" \
        EUS_DISABLE_USER_FLATPAK=1 EUS_APT_ROOT="$EMPTY/root" "${settings[@]}" \
        xvfb-run -a -s '-screen 0 1280x800x24' "$GUI" --screenshot "$OUTPUT_DIR/$name.png" "$@" >/dev/null 2>&1
    printf '%s\n' "$OUTPUT_DIR/$name.png"
}

shot home --
shot updates -- --open updates
shot major-update EUS_OS_UPGRADE_FILE="$FX/os-major" -- --open updates
shot health -- --open health
shot maintenance -- --open maintenance
shot cleaner -- --open cleaner
shot kernels -- --open kernels
shot software-sources -- --open sources
shot key-fix -- --open keyfix
shot add-repository -- --open addrepo
shot add-key -- --open addkey
shot upgrade-os EUS_OS_UPGRADE_FILE="$FX/os-upgrade" -- --open upgrade
shot settings-schedule -- --open prefs
shot settings-automation EUS_SETTINGS_TAB=1 -- --open prefs
shot history -- --open history
shot about -- --open about
