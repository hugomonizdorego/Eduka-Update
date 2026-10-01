#!/bin/bash
# Eduka-Update-System (EUS) 0.12 installer for Edukasaun OS / Debian 13.
# Run as root inside Cubic: bash install-eduka-update-system.sh
# Test only: EUS_INSTALL_ROOT=/tmp/eus-root bash install-eduka-update-system.sh

set -Eeuo pipefail

INSTALL_ROOT="${EUS_INSTALL_ROOT:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
EUS_VERSION='0.12'

target() {
    printf '%s%s' "$INSTALL_ROOT" "$1"
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]] && [[ -z "$INSTALL_ROOT" ]]; then
    echo "ERROR: Run this installer as root (sudo bash $0)." >&2
    exit 1
fi

echo "Installing Eduka-Update-System ${EUS_VERSION}..."

if [[ -z "$INSTALL_ROOT" ]] && command -v dpkg-query >/dev/null 2>&1; then
    missing=()
    for package in python3-pyqt6 qt6-qpa-plugins qt6-svg-plugins qt6-wayland libnotify-bin \
        pkexec lxqt-policykit needrestart flatpak desktop-file-utils hicolor-icon-theme; do
        if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -q 'installed$'; then
            missing+=("$package")
        fi
    done
    if ((${#missing[@]})); then
        apt-get -o Acquire::Retries=3 update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
    if ! /usr/bin/python3 -c 'from PyQt6.QtWidgets import QApplication' 2>/dev/null; then
        echo 'ERROR: PyQt6 could not be loaded after dependency installation.' >&2
        exit 70
    fi
fi

install -d -m 0755 \
    "$(target /usr/local/bin)" \
    "$(target /usr/local/libexec)" \
    "$(target /etc/eus)" \
    "$(target /etc/xdg/autostart)" \
    "$(target /usr/share/applications)" \
    "$(target /usr/share/icons/hicolor/48x48/apps)" \
    "$(target /usr/share/icons/hicolor/scalable/apps)" \
    "$(target /usr/share/pixmaps)" \
    "$(target /usr/lib/EUS-ICONS)" \
    "$(target /usr/share/polkit-1/actions)" \
    "$(target /etc/systemd/system)" \
    "$(target /var/lib/eus)" \
    "$(target /var/log/eus)"

for existing in \
    "$(target /usr/local/bin/eduka-update-system)" \
    "$(target /usr/local/libexec/eduka-update-system-root)" \
    "$(target /usr/local/libexec/eduka-update-system-gui)"; do
    if [[ -f "$existing" && ! -L "$existing" ]]; then
        cp -a "$existing" "${existing}.backup-${STAMP}"
    fi
done

# Keep the old scalable icon recoverable, while making the EUS 0.12 PNG canonical.
old_svg="$(target /usr/share/icons/hicolor/scalable/apps/eduka-update-system.svg)"
if [[ -f "$old_svg" && ! -L "$old_svg" ]]; then
    mv "$old_svg" "${old_svg}.backup-${STAMP}"
fi

install -m 0644 /dev/stdin "$(target /etc/eus/version)" <<EUS_VERSION_FILE
VERSION=${EUS_VERSION}
EUS_VERSION_FILE

if [[ ! -f "$(target /etc/eus/eus.conf)" ]]; then
    install -m 0644 /dev/stdin "$(target /etc/eus/eus.conf)" <<'EUS_CONFIG'
# Eduka-Update-System configuration
OS_RELEASE_PACKAGE='edukasaun-release'
CHECK_INTERVAL_SECONDS=60
EUS_CONFIG
fi

# Migrate only the previous EUS default; preserve an administrator's custom value.
if grep -qx 'CHECK_INTERVAL_SECONDS=300' "$(target /etc/eus/eus.conf)"; then
    sed -i 's/^CHECK_INTERVAL_SECONDS=300$/CHECK_INTERVAL_SECONDS=60/' \
        "$(target /etc/eus/eus.conf)"
fi

if [[ ! -f "$(target /etc/eus/interval-hours)" ]]; then
    printf '6\n' >"$(target /etc/eus/interval-hours)"
    chmod 0644 "$(target /etc/eus/interval-hours)"
fi

install -m 0755 /dev/stdin "$(target /usr/local/libexec/eduka-update-system-root)" <<'EUS_ROOT_HELPER'
#!/bin/bash
# Privileged helper for Eduka-Update-System 0.12. Do not launch directly.

set -u
umask 022
export PATH='/usr/sbin:/usr/bin:/sbin:/bin'

STATE_DIR='/var/lib/eus'
LOG_DIR='/var/log/eus'
LOG_FILE="$LOG_DIR/eus.log"
LOCK_FILE='/run/lock/eduka-update-system.lock'
CONFIG_FILE='/etc/eus/eus.conf'
TSV_FILE="$STATE_DIR/updates.tsv"
STATUS_FILE="$STATE_DIR/status"
ERROR_FILE="$STATE_DIR/last-error"
INTERVAL_FILE='/etc/eus/interval-hours'
RESTART_FILE="$STATE_DIR/restart-required"
OS_RELEASE_PACKAGE='edukasaun-release'

ACTION="${1:-}"
LOCALE_CODE="${2:-en}"
shift $(( $# >= 2 ? 2 : $# ))
EXTRA_ARGS=("$@")

case "$LOCALE_CODE" in
    tet)
        P_LOCK='Prosesu EUS seluk hela ona.'
        P_REFRESH='Atualiza lista pakote...'
        P_CALCULATE='Fahe atualizasaun tuir kategoria...'
        P_UPGRADE='Instala atualizasaun sistema...'
        P_SELECTED='Instala atualizasaun nebe hili...'
        P_FLATPAK='Instala atualizasaun Flatpak...'
        P_SETTINGS='Rai konfigurasaun EUS...'
        P_DOWNLOAD='Download pakote'
        P_PACKAGE_PROGRESS='Prosesu pakote'
        P_CLEAR_HISTORY='Hamoos istoria atualizasaun...'
        P_REBOOT='Hahu fali sistema...'
        P_DONE='Remata.'
        ;;
    pt)
        P_LOCK='Outro processo do EUS ja esta em execucao.'
        P_REFRESH='Atualizando as listas de pacotes...'
        P_CALCULATE='Organizando atualizacoes por categoria...'
        P_UPGRADE='Instalando atualizacoes do sistema...'
        P_SELECTED='Instalando as atualizacoes selecionadas...'
        P_FLATPAK='Instalando atualizacoes Flatpak...'
        P_SETTINGS='Salvando configuracoes do EUS...'
        P_DOWNLOAD='Baixando pacotes'
        P_PACKAGE_PROGRESS='Processando pacotes'
        P_CLEAR_HISTORY='Limpando o historico de atualizacoes...'
        P_REBOOT='Reiniciando o sistema...'
        P_DONE='Concluido.'
        ;;
    id)
        P_LOCK='Proses EUS lain sedang berjalan.'
        P_REFRESH='Memperbarui daftar paket...'
        P_CALCULATE='Membagi pembaruan berdasarkan kategori...'
        P_UPGRADE='Memasang pembaruan sistem...'
        P_SELECTED='Memasang pembaruan yang dipilih...'
        P_FLATPAK='Memasang pembaruan Flatpak...'
        P_SETTINGS='Menyimpan pengaturan EUS...'
        P_DOWNLOAD='Mengunduh paket'
        P_PACKAGE_PROGRESS='Memproses paket'
        P_CLEAR_HISTORY='Membersihkan riwayat pembaruan...'
        P_REBOOT='Memulai ulang sistem...'
        P_DONE='Selesai.'
        ;;
    *)
        P_LOCK='Another EUS process is already running.'
        P_REFRESH='Refreshing package lists...'
        P_CALCULATE='Organizing updates by category...'
        P_UPGRADE='Installing system updates...'
        P_SELECTED='Installing selected updates...'
        P_FLATPAK='Installing Flatpak updates...'
        P_SETTINGS='Saving EUS settings...'
        P_DOWNLOAD='Downloading packages'
        P_PACKAGE_PROGRESS='Processing packages'
        P_CLEAR_HISTORY='Clearing update history...'
        P_REBOOT='Restarting the system...'
        P_DONE='Complete.'
        ;;
esac

progress() {
    printf '%s\n# %s\n' "$1" "$2"
}

log_header() {
    printf '\n[%s] %s\n' "$(date --iso-8601=seconds)" "$*" >>"$LOG_FILE"
}

fail() {
    local message="$1"
    printf '%s\n' "$message" >"$ERROR_FILE"
    chmod 0644 "$ERROR_FILE"
    printf '100\n# ERROR: %s\n' "$message"
    printf '[%s] ERROR: %s\n' "$(date --iso-8601=seconds)" "$message" >>"$LOG_FILE"
    exit 1
}

write_state() {
    local state="$1" count="$2" fingerprint="$3" release_upgrade="$4" download_bytes="$5"
    local tmp
    refresh_restart_state
    tmp="$(mktemp "$STATE_DIR/status.XXXXXX")"
    {
        printf 'state=%s\n' "$state"
        printf 'count=%s\n' "$count"
        printf 'fingerprint=%s\n' "$fingerprint"
        printf 'release_upgrade=%s\n' "$release_upgrade"
        printf 'download_bytes=%s\n' "$download_bytes"
        printf 'restart_required=%s\n' "$RESTART_REQUIRED"
        printf 'restart_reason=%s\n' "$RESTART_REASON"
        printf 'restart_packages=%s\n' "$RESTART_PACKAGES"
        printf 'restart_boot_id=%s\n' "$RESTART_BOOT_ID"
        printf 'checked_at=%s\n' "$(date +%s)"
    } >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$STATUS_FILE"
}

sanitize_field() {
    local value="$1"
    value="${value//$'\t'/ }"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    printf '%s' "$value"
}

refresh_restart_state() {
    local required=0 reason='none' packages='' boot_id='unknown'
    local marker package_marker report kstate latest_path latest_name latest_kernel running_kernel tmp

    [[ -r /proc/sys/kernel/random/boot_id ]] && boot_id="$(</proc/sys/kernel/random/boot_id)"
    for marker in /run/reboot-required /var/run/reboot-required; do
        if [[ -e "$marker" ]]; then
            required=1
            reason='package-manager'
            break
        fi
    done
    for package_marker in /run/reboot-required.pkgs /var/run/reboot-required.pkgs; do
        if [[ -r "$package_marker" ]]; then
            packages="$(tr '\n' ',' <"$package_marker" | sed 's/,$//')"
            break
        fi
    done

    if [[ "$required" -eq 0 ]] && command -v needrestart >/dev/null 2>&1; then
        report="$(NEEDRESTART_MODE=l timeout 30 needrestart -b -k 2>/dev/null || true)"
        kstate="$(awk -F': *' '/^NEEDRESTART-KSTA:/ {print $2; exit}' <<<"$report")"
        if [[ "$kstate" == 2 || "$kstate" == 3 ]]; then
            required=1
            reason='kernel'
            packages="$(awk -F': *' '/^NEEDRESTART-KEXP:/ {print $2; exit}' <<<"$report")"
        fi
    fi

    if [[ "$required" -eq 0 ]] && \
       ! { command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet; }; then
        latest_path="$(readlink -f /vmlinuz 2>/dev/null || true)"
        latest_name="${latest_path##*/}"
        latest_kernel="${latest_name#vmlinuz-}"
        running_kernel="$(uname -r 2>/dev/null || true)"
        if [[ -n "$latest_kernel" && "$latest_name" == vmlinuz-* && \
              -n "$running_kernel" && "$latest_kernel" != "$running_kernel" ]]; then
            required=1
            reason='kernel-image'
            packages="$latest_kernel"
        fi
    fi

    RESTART_REQUIRED="$required"
    RESTART_REASON="$(sanitize_field "$reason")"
    RESTART_PACKAGES="$(sanitize_field "$packages")"
    RESTART_BOOT_ID="$(sanitize_field "$boot_id")"
    tmp="$(mktemp "$STATE_DIR/restart-required.XXXXXX")"
    {
        printf 'required=%s\n' "$RESTART_REQUIRED"
        printf 'reason=%s\n' "$RESTART_REASON"
        printf 'packages=%s\n' "$RESTART_PACKAGES"
        printf 'boot_id=%s\n' "$RESTART_BOOT_ID"
        printf 'checked_at=%s\n' "$(date +%s)"
    } >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$RESTART_FILE"
}

is_medium_package() {
    case "$1" in
        linux-*|firmware-*|intel-microcode*|amd64-microcode*|grub-*|initramfs-*|systemd*|udev*|libc6*|libstdc++6*|dbus*|apt*|dpkg*|sudo*|polkit*|openssh-*|network-manager*|xserver-xorg*|mesa-*|libgl*|lxqt-*|pcmanfm-qt*|calamares*) return 0 ;;
        *) return 1 ;;
    esac
}

human_size_to_bytes() {
    local input="$1"
    awk -v text="$input" 'BEGIN {
        gsub(/,/, ".", text)
        if (match(text, /[0-9.]+/)) number=substr(text, RSTART, RLENGTH); else number=0
        upper=toupper(text)
        multiplier=1
        if (upper ~ /T(I)?B/) multiplier=1099511627776
        else if (upper ~ /G(I)?B/) multiplier=1073741824
        else if (upper ~ /M(I)?B/) multiplier=1048576
        else if (upper ~ /K(I)?B/) multiplier=1024
        printf "%.0f", number * multiplier
    }'
}

append_system_flatpaks() {
    local target="$1" row app_id app_name candidate human_size description installed size
    declare -A installed_versions=()
    command -v flatpak >/dev/null 2>&1 || return 0
    # Metadata refresh is bounded so a stalled remote cannot block EUS forever.
    timeout --kill-after=5s 45s flatpak update --system --appstream --noninteractive \
        >>"$LOG_FILE" 2>&1 || true
    while IFS=$'\t' read -r app_id installed; do
        [[ -n "$app_id" ]] && installed_versions["$app_id"]="${installed:--}"
    done < <(timeout --kill-after=2s 10s flatpak list --system \
        --columns=application,version 2>/dev/null || true)
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        IFS=$'\t' read -r app_id app_name candidate human_size description <<<"$row"
        [[ "$app_id" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]+$ && "$app_id" == *.* ]] || continue
        installed="${installed_versions[$app_id]:--}"
        size="$(human_size_to_bytes "${human_size:-0}")"
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        [[ -n "${description:-}" ]] || description='Flatpak application or runtime update'
        [[ -n "${app_name:-}" && "$app_name" != "$app_id" ]] && description="$app_name — $description"
        installed="$(sanitize_field "$installed")"
        candidate="$(sanitize_field "${candidate:--}")"
        description="$(sanitize_field "$description")"
        printf 'flatpak\tflatpak-system\t%s\t%s\t%s\t%s\t%s\n' \
            "$app_id" "$installed" "$candidate" "$size" "$description" >>"$target"
    done < <(LC_ALL=C timeout --kill-after=3s 15s flatpak remote-ls --system --updates \
        --columns=application,name,version,download-size,description 2>/dev/null | sort -u || true)
}

calculate_updates() {
    local simulation tsv_tmp count fingerprint release_upgrade download_bytes
    local package line installed candidate metadata size description category policy priority section
    local installed_release candidate_release

    simulation="$(mktemp)"
    tsv_tmp="$(mktemp "$STATE_DIR/updates.XXXXXX")"

    if ! LC_ALL=C apt-get -s -o Debug::NoLocking=1 full-upgrade >"$simulation" 2>>"$LOG_FILE"; then
        rm -f "$simulation" "$tsv_tmp"
        write_state error 0 none 0 0
        fail 'APT could not calculate the available updates. See /var/log/eus/eus.log.'
    fi

    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        line="$(awk -v wanted="$package" '$1 == "Inst" && $2 == wanted {print; exit}' "$simulation")"
        installed="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || printf '-')"
        candidate="$(LC_ALL=C apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
        [[ -n "$candidate" && "$candidate" != '(none)' ]] || candidate='-'
        metadata="$(LC_ALL=C apt-cache --no-all-versions show "$package" 2>/dev/null || true)"
        size="$(awk -F': ' '/^Size: / {print $2; exit}' <<<"$metadata")"
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        description="$(awk -F': ' '/^Description(-[A-Za-z_@.-]+)?: / {print $2; exit}' <<<"$metadata")"
        priority="$(awk -F': ' '/^Priority: / {print $2; exit}' <<<"$metadata")"
        section="$(awk -F': ' '/^Section: / {print $2; exit}' <<<"$metadata")"
        [[ -n "$description" ]] || description='System package update'

        policy="$(LC_ALL=C apt-cache policy "$package" 2>/dev/null || true)"
        if [[ "$package" == "$OS_RELEASE_PACKAGE" ]] || \
           grep -qiE 'security|Debian-Security' <<<"$line" || \
           { [[ "$candidate" != '-' ]] && grep -A6 -F "$candidate" <<<"$policy" | grep -qiE 'security|Debian-Security'; }; then
            category='critical'
        elif is_medium_package "$package" || [[ "$priority" == 'required' || "$priority" == 'important' || "$section" == 'kernel' ]]; then
            category='medium'
        else
            category='normal'
        fi

        installed="$(sanitize_field "$installed")"
        candidate="$(sanitize_field "$candidate")"
        description="$(sanitize_field "$description")"
        printf '%s\tapt\t%s\t%s\t%s\t%s\t%s\n' \
            "$category" "$package" "$installed" "$candidate" "$size" "$description" >>"$tsv_tmp"
    done < <(awk '/^Inst / {print $2}' "$simulation" | sort -u)

    append_system_flatpaks "$tsv_tmp"
    count="$(awk 'END {print NR+0}' "$tsv_tmp")"
    download_bytes="$(awk -F '\t' '{sum += $6} END {printf "%.0f", sum+0}' "$tsv_tmp")"
    if [[ "$count" -gt 0 ]]; then
        fingerprint="$(sha256sum "$tsv_tmp" | awk '{print $1}')"
    else
        fingerprint='none'
    fi

    release_upgrade=0
    if dpkg-query -W -f='${db:Status-Status}' "$OS_RELEASE_PACKAGE" 2>/dev/null | grep -q 'installed$'; then
        installed_release="$(dpkg-query -W -f='${Version}' "$OS_RELEASE_PACKAGE" 2>/dev/null || true)"
        candidate_release="$(LC_ALL=C apt-cache policy "$OS_RELEASE_PACKAGE" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
        if [[ -n "$installed_release" && -n "$candidate_release" && "$candidate_release" != '(none)' ]] && \
           dpkg --compare-versions "$candidate_release" gt "$installed_release"; then
            release_upgrade=1
        fi
    fi

    chmod 0644 "$tsv_tmp"
    mv -f "$tsv_tmp" "$TSV_FILE"
    rm -f "$simulation" "$ERROR_FILE"
    write_state ok "$count" "$fingerprint" "$release_upgrade" "$download_bytes"
}

apt_progress_stream() {
    local download_base="${1:-10}" download_span="${2:-50}"
    local install_base="${3:-65}" install_span="${4:-25}"
    local kind subject percent description whole mapped label
    while IFS=: read -r kind subject percent description; do
        whole="${percent%%.*}"
        [[ "$whole" =~ ^[0-9]+$ ]] || continue
        (( whole > 100 )) && whole=100
        case "$kind" in
            dlstatus)
                mapped=$((download_base + (whole * download_span / 100)))
                label="$P_DOWNLOAD"
                ;;
            pmstatus)
                mapped=$((install_base + (whole * install_span / 100)))
                label="$P_PACKAGE_PROGRESS"
                ;;
            pmerror|error)
                mapped="$install_base"
                label="$P_PACKAGE_PROGRESS"
                ;;
            *) continue ;;
        esac
        description="${description//$'\r'/ }"
        description="${description//$'\n'/ }"
        printf '%s\n# %s: %s%% — %s\n' "$mapped" "$label" "$whole" "${description:-$subject}"
    done
}

apt_update_command() {
    apt-get -o Acquire::Retries=3 -o APT::Status-Fd=3 update \
        >>"$LOG_FILE" 2>&1 3> >(apt_progress_stream 8 55 63 1)
}

refresh_lists() {
    progress 8 "$P_REFRESH"
    log_header 'APT and Flatpak metadata refresh with category scan'
    if ! apt_update_command; then
        write_state error 0 none 0 0
        fail 'APT package-list refresh failed. Check the network and repository configuration.'
    fi
    progress 68 "$P_CALCULATE"
    calculate_updates
    progress 100 "$P_DONE"
}

apt_upgrade_command() {
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Acquire::Retries=3 \
        -o APT::Status-Fd=3 \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        "$@" >>"$LOG_FILE" 2>&1 3> >(apt_progress_stream 26 40 66 26)
}

upgrade_all_apt() {
    progress 5 "$P_REFRESH"
    log_header 'Full APT upgrade selected in EUS'
    apt_update_command || \
        fail 'APT package-list refresh failed. Check the network and repository configuration.'
    progress 26 "$P_UPGRADE"
    apt_upgrade_command full-upgrade -y || \
        fail 'The system upgrade did not finish successfully. See /var/log/eus/eus.log.'
    progress 92 "$P_CALCULATE"
    calculate_updates
    progress 100 "$P_DONE"
}

install_selected_apt() {
    local package
    local -a selected=()
    declare -A seen=()

    ((${#EXTRA_ARGS[@]} > 0)) || fail 'No APT update package was selected.'
    ((${#EXTRA_ARGS[@]} <= 500)) || fail 'Too many package arguments.'
    progress 5 "$P_REFRESH"
    log_header "Selected APT upgrade (${#EXTRA_ARGS[@]} requested)"
    apt_update_command || \
        fail 'APT package-list refresh failed. Check the network and repository configuration.'
    progress 18 "$P_CALCULATE"
    calculate_updates

    for package in "${EXTRA_ARGS[@]}"; do
        [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ ]] || fail "Invalid package name: $package"
        [[ -z "${seen[$package]:-}" ]] || continue
        if ! awk -F '\t' -v wanted="$package" '$2=="apt" && $3==wanted {found=1} END {exit(found ? 0 : 1)}' "$TSV_FILE"; then
            fail "Package is no longer in the available update set: $package"
        fi
        selected+=("$package")
        seen[$package]=1
    done

    progress 34 "$P_SELECTED"
    apt_upgrade_command install -y "${selected[@]}" || \
        fail 'One or more selected updates could not be installed. See /var/log/eus/eus.log.'
    progress 92 "$P_CALCULATE"
    calculate_updates
    progress 100 "$P_DONE"
}

install_system_flatpaks() {
    local ref
    local -a selected=()
    declare -A seen=()
    command -v flatpak >/dev/null 2>&1 || fail 'Flatpak is not installed.'
    ((${#EXTRA_ARGS[@]} > 0)) || fail 'No Flatpak update was selected.'
    ((${#EXTRA_ARGS[@]} <= 300)) || fail 'Too many Flatpak arguments.'
    log_header "Selected system Flatpak upgrade (${#EXTRA_ARGS[@]} requested)"
    for ref in "${EXTRA_ARGS[@]}"; do
        [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]+$ ]] || fail "Invalid Flatpak reference: $ref"
        [[ -z "${seen[$ref]:-}" ]] || continue
        if ! awk -F '\t' -v wanted="$ref" '$2=="flatpak-system" && $3==wanted {found=1} END {exit(found ? 0 : 1)}' "$TSV_FILE"; then
            fail "Flatpak is no longer in the available update set: $ref"
        fi
        selected+=("$ref")
        seen[$ref]=1
    done
    progress 20 "$P_FLATPAK"
    timeout --kill-after=10s 3600s flatpak update --system --noninteractive -y \
        "${selected[@]}" >>"$LOG_FILE" 2>&1 || \
        fail 'One or more Flatpak updates could not be installed. See /var/log/eus/eus.log.'
    progress 88 "$P_CALCULATE"
    calculate_updates
    progress 100 "$P_DONE"
}

set_interval() {
    local hours="${EXTRA_ARGS[0]:-}"
    case "$hours" in 1|3|6|12|24) ;; *) fail 'Invalid update-check interval.' ;; esac
    progress 25 "$P_SETTINGS"
    install -d -m 0755 /etc/systemd/system/eus-refresh.timer.d
    {
        printf '[Timer]\n'
        printf 'OnUnitActiveSec=\n'
        printf 'OnUnitActiveSec=%sh\n' "$hours"
    } >/etc/systemd/system/eus-refresh.timer.d/override.conf
    printf '%s\n' "$hours" >"$INTERVAL_FILE"
    chmod 0644 "$INTERVAL_FILE" /etc/systemd/system/eus-refresh.timer.d/override.conf
    if [[ -d /run/systemd/system ]]; then
        systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
        systemctl restart eus-refresh.timer >>"$LOG_FILE" 2>&1 || true
    fi
    progress 100 "$P_DONE"
}

clear_history() {
    progress 20 "$P_CLEAR_HISTORY"
    : >"$LOG_FILE"
    chmod 0644 "$LOG_FILE"
    rm -f -- "$ERROR_FILE"
    progress 100 "$P_DONE"
}

perform_reboot() {
    progress 10 "$P_REBOOT"
    log_header 'System restart confirmed by the user through EUS'
    sync
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --message='Restart requested by Eduka-Update-System' reboot || \
            fail 'The system restart request failed.'
    else
        /sbin/reboot || fail 'The system restart request failed.'
    fi
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo 'This helper must run as root.' >&2
    exit 77
fi

case "$ACTION" in
    refresh|upgrade-apt|install-apt|install-flatpak-system|set-interval|clear-history|reboot) ;;
    *) echo 'Invalid EUS privileged action.' >&2; exit 64 ;;
esac

[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
install -d -m 0755 "$STATE_DIR" "$LOG_DIR" /run/lock
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"
exec 9>"$LOCK_FILE"
flock -n 9 || fail "$P_LOCK"

case "$ACTION" in
    refresh) refresh_lists ;;
    upgrade-apt) upgrade_all_apt ;;
    install-apt) install_selected_apt ;;
    install-flatpak-system) install_system_flatpaks ;;
    set-interval) set_interval ;;
    clear-history) clear_history ;;
    reboot) perform_reboot ;;
esac
EUS_ROOT_HELPER

install -m 0755 /dev/stdin "$(target /usr/local/bin/eduka-update-system)" <<'EUS_LAUNCHER'
#!/bin/bash
# User-facing launcher, terminal fallback, and session update notifier.

set -u
export PATH='/usr/local/bin:/usr/bin:/bin'

APP_NAME='Eduka-Update-System'
VERSION='0.12'
GUI='/usr/local/libexec/eduka-update-system-gui'
PYTHON='/usr/bin/python3'
ROOT_HELPER='/usr/local/libexec/eduka-update-system-root'
STATE_FILE='/var/lib/eus/status'
RESTART_FILE='/var/lib/eus/restart-required'
TSV_FILE='/var/lib/eus/updates.tsv'
CONFIG_FILE='/etc/eus/eus.conf'
VERSION_FILE='/etc/eus/version'
CHECK_INTERVAL_SECONDS=60
RESTART_REMINDER_SECONDS=600
EUS_ICON_AVAILABLE='/usr/lib/EUS-ICONS/eus-update-available.png'
EUS_ICON_FINISHED='/usr/lib/EUS-ICONS/eus-update-finished.png'
PANEL_STATUS='/usr/local/bin/eus-panel-status'

[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
[[ -r "$VERSION_FILE" ]] && source "$VERSION_FILE"

detect_language() {
    local value="${LC_ALL:-${LC_MESSAGES:-${LANGUAGE:-${LANG:-en}}}}"
    value="${value%%:*}"
    value="${value,,}"
    case "$value" in
        tet*) LANG_CODE='tet' ;;
        pt*) LANG_CODE='pt' ;;
        id*|in*) LANG_CODE='id' ;;
        *) LANG_CODE='en' ;;
    esac
}

load_messages() {
    case "$LANG_CODE" in
        tet)
            CHECKING='Verifika atualizasaun...'
            AVAILABLE='%s atualizasaun disponivel: %s kritiku, %s importante, %s regular no %s Flatpak.'
            NO_UPDATE='Edukasaun OS atualizadu ona.'
            ASK='Instala atualizasaun hotu? [y/N] '
            DONE='Atualizasaun remata.'
            OPEN='Loke Jestór Atualizasaun'
            RELEASE_AVAILABLE='Versaun foun Edukasaun OS disponivel.'
            RESTART_TITLE='Presiza hahu fali sistema'
            RESTART_BODY='Atualizasaun importante instala ona. Rai servisu hotu no hahu fali sistema atu aplika mudansa.'
            RESTART_NOW='Hahu Fali Agora'
            GUI_ERROR='EUS la bele loke. Haree log iha ~/.local/state/eus/gui-launch.log.'
            ;;
        pt)
            CHECKING='Verificando atualizacoes...'
            AVAILABLE='%s atualizacoes disponiveis: %s criticas, %s importantes, %s regulares e %s Flatpak.'
            NO_UPDATE='O Edukasaun OS ja esta atualizado.'
            ASK='Instalar todas as atualizacoes? [y/N] '
            DONE='Atualizacao concluida.'
            OPEN='Abrir Gestor de Atualizações'
            RELEASE_AVAILABLE='Uma nova versao do Edukasaun OS esta disponivel.'
            RESTART_TITLE='E necessario reiniciar o sistema'
            RESTART_BODY='Foram instaladas atualizacoes importantes. Salve o trabalho e reinicie para aplicar as alteracoes.'
            RESTART_NOW='Reiniciar agora'
            GUI_ERROR='Nao foi possivel abrir o EUS. Consulte ~/.local/state/eus/gui-launch.log.'
            ;;
        id)
            CHECKING='Memeriksa pembaruan...'
            AVAILABLE='%s pembaruan tersedia: %s kritis, %s menengah, %s biasa, dan %s Flatpak.'
            NO_UPDATE='Edukasaun OS sudah terbaru.'
            ASK='Pasang semua pembaruan? [y/N] '
            DONE='Pembaruan selesai.'
            OPEN='Buka Pengelola Pembaruan'
            RELEASE_AVAILABLE='Versi baru Edukasaun OS tersedia.'
            RESTART_TITLE='Sistem perlu dimulai ulang'
            RESTART_BODY='Pembaruan penting telah dipasang. Simpan pekerjaan lalu mulai ulang untuk menerapkan perubahan.'
            RESTART_NOW='Mulai Ulang Sekarang'
            GUI_ERROR='EUS tidak dapat dibuka. Periksa ~/.local/state/eus/gui-launch.log.'
            ;;
        *)
            CHECKING='Checking for updates...'
            AVAILABLE='%s updates available: %s critical, %s important, %s regular, and %s Flatpak.'
            NO_UPDATE='Edukasaun OS is up to date.'
            ASK='Install all updates? [y/N] '
            DONE='Update complete.'
            OPEN='Open Update Manager'
            RELEASE_AVAILABLE='A new Edukasaun OS version is available.'
            RESTART_TITLE='System restart required'
            RESTART_BODY='Important updates were installed. Save your work and restart to apply the changes.'
            RESTART_NOW='Restart Now'
            GUI_ERROR='EUS could not be opened. Check ~/.local/state/eus/gui-launch.log.'
            ;;
    esac
}

current_boot_id() {
    [[ -r /proc/sys/kernel/random/boot_id ]] && cat /proc/sys/kernel/random/boot_id || printf 'unknown'
}

restart_is_required() {
    local required=0 saved_boot='' current_boot key value
    if [[ -r "$RESTART_FILE" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                required) [[ "$value" == 0 || "$value" == 1 ]] && required="$value" ;;
                boot_id) saved_boot="$value" ;;
            esac
        done <"$RESTART_FILE"
    elif [[ -e /run/reboot-required || -e /var/run/reboot-required ]]; then
        required=1
    fi
    [[ "$required" -eq 1 ]] || return 1
    current_boot="$(current_boot_id)"
    [[ -z "$saved_boot" || "$saved_boot" == 'unknown' || "$saved_boot" == "$current_boot" ]]
}

panel_status() {
    [[ -x "$PANEL_STATUS" ]] || return 0
    "$PANEL_STATUS" "$@" >/dev/null 2>&1 || true
}

eus_runtime_dir() {
    local candidate="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [[ ! -d "$candidate" || ! -w "$candidate" ]]; then
        candidate="${TMPDIR:-/tmp}/eus-runtime-$(id -u)"
    fi
    printf '%s/eduka-update-system' "$candidate"
}

eus_gui_is_running() {
    local pid_file pid command_line
    pid_file="$(eus_runtime_dir)/gui.pid"
    [[ -r "$pid_file" ]] || return 1
    read -r pid <"$pid_file" || return 1
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || {
        rm -f -- "$pid_file"
        return 1
    }
    command_line="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$command_line" == *'/eduka-update-system-gui'* ]]; then
        return 0
    fi
    rm -f -- "$pid_file"
    return 1
}

launch_gui_detached() {
    if command -v setsid >/dev/null 2>&1; then
        setsid -f /usr/local/bin/eduka-update-system --ui >/dev/null 2>&1
    else
        nohup /usr/local/bin/eduka-update-system --ui >/dev/null 2>&1 &
    fi
}

launch_gui() {
    local state_dir log_file attempt_log preferred_platform rc
    if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        terminal_update
        return
    fi
    state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/eus"
    log_file="$state_dir/gui-launch.log"
    mkdir -p "$state_dir"
    preferred_platform="${QT_QPA_PLATFORM:-}"
    if [[ -z "$preferred_platform" && -n "${WAYLAND_DISPLAY:-}" && \
          "${XDG_SESSION_TYPE:-}" == wayland ]]; then
        preferred_platform='wayland'
    fi
    {
        printf '\n[%s] Launching EUS %s\n' "$(date --iso-8601=seconds)" "$VERSION"
        printf 'DISPLAY=%s WAYLAND_DISPLAY=%s QT_QPA_PLATFORM=%s\n' \
            "${DISPLAY:-}" "${WAYLAND_DISPLAY:-}" "${preferred_platform:-auto}"
    } >>"$log_file"
    if [[ ! -x "$GUI" || ! -x "$PYTHON" ]]; then
        printf 'Missing GUI executable or Python interpreter.\n' >>"$log_file"
        command -v notify-send >/dev/null 2>&1 && notify-send --urgency=critical \
            --icon="$EUS_ICON_AVAILABLE" "$APP_NAME" "$GUI_ERROR"
        return 70
    fi
    if ! "$PYTHON" -c 'from PyQt6.QtWidgets import QApplication' >>"$log_file" 2>&1; then
        printf 'PyQt6 import failed.\n' >>"$log_file"
        command -v notify-send >/dev/null 2>&1 && notify-send --urgency=critical \
            --icon="$EUS_ICON_AVAILABLE" "$APP_NAME" "$GUI_ERROR"
        return 70
    fi
    attempt_log="$(mktemp "$state_dir/gui-attempt.XXXXXX")" || return 70
    if [[ -n "$preferred_platform" ]]; then
        QT_AUTO_SCREEN_SCALE_FACTOR=1 QT_QPA_PLATFORM="$preferred_platform" \
            "$PYTHON" "$GUI" >"$attempt_log" 2>&1
    else
        QT_AUTO_SCREEN_SCALE_FACTOR=1 "$PYTHON" "$GUI" >"$attempt_log" 2>&1
    fi
    rc=$?
    cat "$attempt_log" >>"$log_file"
    if [[ "$rc" -ne 0 && -n "${DISPLAY:-}" && "$preferred_platform" != xcb ]] && \
       grep -Eqi 'qt\.qpa|platform plugin|could not connect to display' "$attempt_log"; then
        printf '[%s] Retrying with Qt XCB platform.\n' "$(date --iso-8601=seconds)" >>"$log_file"
        : >"$attempt_log"
        QT_AUTO_SCREEN_SCALE_FACTOR=1 QT_QPA_PLATFORM=xcb "$PYTHON" "$GUI" >"$attempt_log" 2>&1
        rc=$?
        cat "$attempt_log" >>"$log_file"
    fi
    rm -f -- "$attempt_log"
    if [[ "$rc" -ne 0 ]]; then
        command -v notify-send >/dev/null 2>&1 && notify-send --urgency=critical \
            --icon="$EUS_ICON_AVAILABLE" "$APP_NAME" "$GUI_ERROR"
    fi
    return "$rc"
}

read_state() {
    UPDATE_STATE='unknown'; UPDATE_COUNT=0; UPDATE_FINGERPRINT='none'; RELEASE_UPGRADE=0
    [[ -r "$STATE_FILE" ]] || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            state) UPDATE_STATE="$value" ;;
            count) [[ "$value" =~ ^[0-9]+$ ]] && UPDATE_COUNT="$value" ;;
            fingerprint) [[ "$value" =~ ^[a-f0-9]+$|^none$ ]] && UPDATE_FINGERPRINT="$value" ;;
            release_upgrade) [[ "$value" == 0 || "$value" == 1 ]] && RELEASE_UPGRADE="$value" ;;
        esac
    done <"$STATE_FILE"
    [[ "$UPDATE_STATE" == 'ok' ]]
}

invoke_root() {
    local action="$1"; shift
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$ROOT_HELPER" "$action" "$LANG_CODE" "$@"
    elif command -v pkexec >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        pkexec "$ROOT_HELPER" "$action" "$LANG_CODE" "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$ROOT_HELPER" "$action" "$LANG_CODE" "$@"
    else
        return 77
    fi
}

category_counts() {
    CRITICAL=0; MEDIUM=0; NORMAL=0; FLATPAK=0
    [[ -r "$TSV_FILE" ]] || return
    CRITICAL="$(awk -F '\t' '$1=="critical" {n++} END {print n+0}' "$TSV_FILE")"
    MEDIUM="$(awk -F '\t' '$1=="medium" {n++} END {print n+0}' "$TSV_FILE")"
    NORMAL="$(awk -F '\t' '$1=="normal" {n++} END {print n+0}' "$TSV_FILE")"
    FLATPAK="$(awk -F '\t' '$1=="flatpak" {n++} END {print n+0}' "$TSV_FILE")"
}

terminal_update() {
    printf '\nEduka-Update-System %s\n%s\n' "$VERSION" "$CHECKING"
    # The Eduka-Panel indicator is reserved for confirmed available updates.
    panel_status hidden
    if ! invoke_root refresh; then
        panel_status hidden
        return 1
    fi
    read_state || return 1
    user_flatpak_fingerprint
    local total remaining
    total=$((UPDATE_COUNT + USER_FLATPAK_COUNT))
    if [[ "$total" -eq 0 ]]; then
        panel_status hidden
        printf '%s\n' "$NO_UPDATE"
        return 0
    fi
    panel_status available --count "$total"
    category_counts
    FLATPAK=$((FLATPAK + USER_FLATPAK_COUNT))
    [[ "$RELEASE_UPGRADE" -eq 1 ]] && printf '%s\n' "$RELEASE_AVAILABLE"
    printf "$AVAILABLE\n" "$total" "$CRITICAL" "$MEDIUM" "$NORMAL" "$FLATPAK"
    [[ -r "$TSV_FILE" ]] && awk -F '\t' '{printf "  [%s] %s: %s -> %s\n", $1, $3, $4, $5}' "$TSV_FILE"
    local answer
    read -r -p "$ASK" answer
    case "${answer,,}" in y|yes|s|sim|sin|o|oui|i|iya) ;; *) return 0 ;; esac
    if (( CRITICAL + MEDIUM + NORMAL > 0 )); then
        invoke_root upgrade-apt || return 1
    fi
    mapfile -t system_flatpaks < <(awk -F '\t' '$2=="flatpak-system" {print $3}' "$TSV_FILE" 2>/dev/null)
    if ((${#system_flatpaks[@]})); then
        invoke_root install-flatpak-system "${system_flatpaks[@]}" || return 1
    fi
    command -v flatpak >/dev/null 2>&1 && flatpak update --user --noninteractive -y >/dev/null 2>&1 || true
    # Recalculate the list so a stale icon cannot remain after installation.
    if invoke_root refresh >/dev/null; then
        read_state || true
        user_flatpak_fingerprint
        remaining=$((UPDATE_COUNT + USER_FLATPAK_COUNT))
        if (( remaining > 0 )); then
            panel_status available --count "$remaining"
        else
            panel_status hidden
        fi
    else
        panel_status hidden
    fi
    printf '%s\n' "$DONE"
    restart_is_required && printf '%s\n' "$RESTART_BODY"
}

user_flatpak_fingerprint() {
    USER_FLATPAK_COUNT=0; USER_FLATPAK_HASH='none'
    command -v flatpak >/dev/null 2>&1 || return 0
    local list
    list="$(LC_ALL=C timeout --kill-after=2s 10s flatpak remote-ls --user --updates --cached --columns=application 2>/dev/null | \
        awk '$0 ~ /^[A-Za-z0-9][A-Za-z0-9._+-]*\.[A-Za-z0-9._+-]+$/ {print}' | sort -u || true)"
    [[ -n "$list" ]] || return 0
    USER_FLATPAK_COUNT="$(awk 'NF {n++} END {print n+0}' <<<"$list")"
    USER_FLATPAK_HASH="$(sha256sum <<<"$list" | awk '{print $1}')"
}

send_update_notification() {
    command -v notify-send >/dev/null 2>&1 || return 0
    if eus_gui_is_running; then
        panel_status hidden
        return 0
    fi
    read_state || true
    user_flatpak_fingerprint
    local cache_dir last_file old body combined total urgency
    cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/eus"
    last_file="$cache_dir/last-notified"
    mkdir -p "$cache_dir"
    total=$((UPDATE_COUNT + USER_FLATPAK_COUNT))
    if [[ "$total" -eq 0 ]]; then
        rm -f "$last_file"
        panel_status hidden
        return 0
    fi
    # While the manager is open, its own window is the update notification.
    # Hide the panel indicator and avoid creating another desktop notification.
    if eus_gui_is_running; then
        panel_status hidden
        return 0
    fi
    panel_status available --count "$total"
    combined="${VERSION}-${UPDATE_FINGERPRINT}-${USER_FLATPAK_HASH}"
    old=''; [[ -r "$last_file" ]] && old="$(<"$last_file")"
    [[ "$old" == "$combined" ]] && return 0
    category_counts
    FLATPAK=$((FLATPAK + USER_FLATPAK_COUNT))
    printf -v body "$AVAILABLE" "$total" "$CRITICAL" "$MEDIUM" "$NORMAL" "$FLATPAK"
    [[ "$RELEASE_UPGRADE" -eq 1 ]] && body="$RELEASE_AVAILABLE $body"
    urgency='normal'
    ((CRITICAL > 0)) && urgency='critical'
    if notify-send --help 2>&1 | grep -q -- '--action'; then
        (
            action="$(notify-send --app-name="$APP_NAME" --icon="$EUS_ICON_AVAILABLE" \
                --urgency="$urgency" --expire-time=30000 \
                --hint=string:desktop-entry:eduka-update-system \
                --action="default=$OPEN" \
                "$APP_NAME" "$body" 2>/dev/null || true)"
            [[ "$action" == 'default' ]] && launch_gui_detached
        ) &
    else
        notify-send --app-name="$APP_NAME" --icon="$EUS_ICON_AVAILABLE" \
            --urgency="$urgency" --expire-time=30000 "$APP_NAME" "$body" || true
    fi
    printf '%s\n' "$combined" >"$last_file"
}

send_restart_notification() {
    command -v notify-send >/dev/null 2>&1 || return 0
    local cache_dir stamp_file now last action
    cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/eus"
    stamp_file="$cache_dir/restart-last-notified"
    mkdir -p "$cache_dir"
    if ! restart_is_required; then
        rm -f "$stamp_file"
        return 0
    fi
    now="$(date +%s)"
    last=0
    [[ -r "$stamp_file" ]] && last="$(<"$stamp_file")"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last >= RESTART_REMINDER_SECONDS )) || return 0
    printf '%s\n' "$now" >"$stamp_file"
    if notify-send --help 2>&1 | grep -q -- '--action'; then
        (
            action="$(notify-send --app-name="$APP_NAME" --icon="$EUS_ICON_FINISHED" \
                --urgency=normal --expire-time=60000 \
                --hint=string:desktop-entry:eduka-update-system \
                --action="default=$RESTART_NOW" \
                "$RESTART_TITLE" "$RESTART_BODY" 2>/dev/null || true)"
            [[ "$action" == 'default' ]] && \
                /usr/local/bin/eduka-update-system --restart >/dev/null 2>&1
        ) &
    else
        notify-send --app-name="$APP_NAME" --icon="$EUS_ICON_FINISHED" \
            --urgency=normal --expire-time=60000 "$RESTART_TITLE" "$RESTART_BODY" || true
    fi
}

watch_updates() {
    local cache_dir lock_file
    cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/eus"
    mkdir -p "$cache_dir"
    lock_file="$cache_dir/notifier.lock"
    exec 8>"$lock_file"
    flock -n 8 || exit 0
    sleep 5
    while true; do
        send_update_notification
        send_restart_notification
        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

detect_language
load_messages

case "${1:---ui}" in
    --ui)
        launch_gui
        ;;
    --terminal|--run) terminal_update ;;
    --check-notify) send_update_notification; send_restart_notification ;;
    --watch) watch_updates ;;
    --restart) invoke_root reboot ;;
    --version) printf 'Eduka-Update-System %s\n' "$VERSION" ;;
    *) printf 'Usage: %s [--ui|--terminal|--check-notify|--watch|--restart|--version]\n' "$0" >&2; exit 64 ;;
esac
EUS_LAUNCHER

install -m 0755 /dev/stdin "$(target /usr/local/libexec/eduka-update-system-gui)" <<'EUS_GUI'
#!/usr/bin/python3
"""Minimal Qt 6 interface for Eduka-Update-System 0.12."""

from __future__ import annotations

import html
import json
import locale
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

try:
    locale.setlocale(locale.LC_TIME, "")
except locale.Error:
    pass

TSV_FILE = Path(os.environ.get("EUS_TSV_FILE", "/var/lib/eus/updates.tsv"))
STATE_FILE = Path(os.environ.get("EUS_STATE_FILE", "/var/lib/eus/status"))
ERROR_FILE = Path(os.environ.get("EUS_ERROR_FILE", "/var/lib/eus/last-error"))
LOG_FILE = Path(os.environ.get("EUS_LOG_FILE", "/var/log/eus/eus.log"))
HISTORY_FILE = Path(os.environ.get(
    "EUS_HISTORY_FILE",
    str(Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
        / "eus" / "update-history.tsv"),
))
VERSION_FILE = Path(os.environ.get("EUS_VERSION_FILE", "/etc/eus/version"))
INTERVAL_FILE = Path(os.environ.get("EUS_INTERVAL_FILE", "/etc/eus/interval-hours"))
RESTART_FILE = Path(os.environ.get("EUS_RESTART_FILE", "/var/lib/eus/restart-required"))
ROOT_HELPER = "/usr/local/libexec/eduka-update-system-root"
PANEL_STATUS = "/usr/local/bin/eus-panel-status"
EUS_VERSION = "0.12"
EUS_APP_ICON = "/usr/share/icons/hicolor/48x48/apps/eduka-update-system.png"
EUS_ICON_DIR = "/usr/lib/EUS-ICONS"
EUS_ICON_IDLE = f"{EUS_ICON_DIR}/eus-update-idle.png"
EUS_ICON_AVAILABLE = f"{EUS_ICON_DIR}/eus-update-available.png"
EUS_ICON_RUNNING_GIF = f"{EUS_ICON_DIR}/eus-update-running.gif"
EUS_ICON_RUNNING_FALLBACK = f"{EUS_ICON_DIR}/eus-update-running.png"
EUS_ICON_FINISHED = f"{EUS_ICON_DIR}/eus-update-finished.png"
EUS_TRANSLATIONS = f"{EUS_ICON_DIR}/eus-i18n.json"
EUS_ICON_MANIFEST = f"{EUS_ICON_DIR}/eus-icons.json"


def parse_size(value: str) -> int:
    text = value.strip().upper().replace(",", ".")
    match = re.search(r"([0-9]+(?:\.[0-9]+)?)", text)
    if not match:
        return 0
    number = float(match.group(1))
    multipliers = {"KB": 1024, "KIB": 1024, "MB": 1024**2, "MIB": 1024**2,
                   "GB": 1024**3, "GIB": 1024**3, "TB": 1024**4, "TIB": 1024**4}
    for unit, multiplier in multipliers.items():
        if unit in text:
            return max(0, int(number * multiplier))
    return max(0, int(number))


def parse_updates(path: Path) -> list[dict]:
    records: list[dict] = []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return records
    for line in lines:
        fields = line.split("\t", 6)
        if len(fields) != 7:
            continue
        category, source, name, installed, candidate, size, description = fields
        if category not in {"critical", "medium", "normal", "flatpak"}:
            continue
        if source not in {"apt", "flatpak-system", "flatpak-user"}:
            continue
        try:
            size_bytes = max(0, int(size))
        except ValueError:
            size_bytes = parse_size(size)
        records.append({"category": category, "source": source, "name": name,
                        "installed": installed, "candidate": candidate,
                        "size": size_bytes, "description": description})
    return records


def scan_user_flatpaks() -> list[dict]:
    if os.environ.get("EUS_DISABLE_USER_FLATPAK") == "1":
        return []
    installed_versions: dict[str, str] = {}
    try:
        installed_result = subprocess.run(
            ["flatpak", "list", "--user", "--columns=application,version"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            encoding="utf-8", errors="replace", timeout=6, check=False,
        )
        for installed_line in installed_result.stdout.splitlines():
            parts = installed_line.split("\t", 1)
            if parts and parts[0].strip():
                installed_versions[parts[0].strip()] = parts[1].strip() if len(parts) > 1 else "—"
        result = subprocess.run(
            ["flatpak", "remote-ls", "--user", "--updates", "--cached",
             "--columns=application,name,version,download-size,description"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            encoding="utf-8", errors="replace", timeout=8, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    records = []
    for line in result.stdout.splitlines():
        fields = line.split("\t", 4)
        if len(fields) < 3 or not fields[0].strip():
            continue
        fields += [""] * (5 - len(fields))
        app_id, app_name, candidate, size, description = [x.strip() for x in fields]
        if "." not in app_id or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]+", app_id):
            continue
        installed = installed_versions.get(app_id, "—")
        description = description or "Flatpak application or runtime update"
        if app_name and app_name != app_id:
            description = f"{app_name} — {description}"
        records.append({"category": "flatpak", "source": "flatpak-user", "name": app_id,
                        "installed": installed, "candidate": candidate or "—",
                        "size": parse_size(size), "description": description})
    return records


if len(sys.argv) >= 3 and sys.argv[1] == "--self-test":
    updates = parse_updates(Path(sys.argv[2]))
    result = {"total": len(updates), "bytes": sum(x["size"] for x in updates)}
    for category in ("critical", "medium", "normal", "flatpak"):
        result[category] = sum(x["category"] == category for x in updates)
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0)


try:
    from PyQt6.QtCore import QProcess, QProcessEnvironment, QSize, Qt, QTimer
    from PyQt6.QtGui import QBrush, QColor, QFont, QIcon, QKeySequence, QShortcut
    from PyQt6.QtNetwork import QLocalServer, QLocalSocket
    from PyQt6.QtWidgets import (
        QAbstractItemView, QApplication, QCheckBox, QComboBox, QDialog, QDialogButtonBox, QFrame,
        QHBoxLayout, QHeaderView, QLabel, QMainWindow, QMessageBox,
        QPlainTextEdit, QProgressBar, QPushButton, QSizePolicy,
        QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget,
    )
except ImportError as exc:
    print(f"PyQt6 is required for the EUS graphical interface: {exc}", file=sys.stderr)
    raise SystemExit(70)


MESSAGES = {
    "en": {
        "subtitle": "Software updates for Edukasaun OS",
        "available": "Software updates are available for this computer",
        "release_available": "A new Edukasaun OS version is available",
        "current": "Edukasaun OS is up to date",
        "empty": "No update information yet. Select Check for Updates.",
        "critical": "Critical updates", "medium": "Important system updates",
        "normal": "Regular updates", "flatpak": "Flatpak application updates",
        "package": "Package or application", "installed": "Installed",
        "new": "New version", "size": "Size", "progress": "Progress",
        "selected": "{count} selected · Download size: {size}",
        "last_check": "Last checked: {time}", "select_all": "Select all",
        "details": "Update description and risk", "choose": "Select an update to view its purpose and risk.",
        "check_updates": "Check for Updates", "check_again": "Check Again",
        "install": "Install Updates", "settings": "Settings",
        "history": "History", "about": "About", "close": "Close",
        "minimize": "Minimize", "maximize_restore": "Maximize or restore",
        "checking": "Checking repositories and classifying updates…",
        "installing": "Installing the selected updates…", "saving": "Saving EUS settings…",
        "confirm_title": "Confirm updates", "confirm": "Install {count} selected updates ({size})?",
        "success": "Selected updates were installed successfully.",
        "failed": "The operation did not complete.", "auth": "Administrator authentication was cancelled or failed.",
        "timeout": "The update process stopped responding and was safely terminated. Check the network and try again.",
        "settings_title": "EUS Settings", "interval": "Automatic check interval",
        "notifications": "Show desktop update notifications", "hours": "Every {hours} hours",
        "save": "Save", "cancel": "Cancel", "history_title": "EUS Update History",
        "no_history": "No EUS history is available yet.", "clear_history": "Clear History",
        "clear_history_confirm": "Permanently clear the EUS update history?",
        "history_cleared": "The update history has been cleared.",
        "history_success": "Installed successfully", "history_failed": "Installation failed",
        "complete_progress": "100% — Complete", "failed_progress": "Failed",
        "about_title": "About Eduka-Update-System", "about_version": "Version",
        "about_body": "The official update manager for Edukasaun OS. EUS manages APT system packages and Flatpak applications with clear update categories and risk information.",
        "source_apt": "APT system package", "source_flatpak-system": "System Flatpak",
        "source_flatpak-user": "User Flatpak",
        "purpose": "Package purpose", "fixes": "What this update addresses", "danger": "Risk if postponed",
        "fix_critical": "Addresses published security vulnerabilities or an essential Edukasaun OS release component.",
        "risk_critical": "High risk: delaying it can leave the computer exposed to known attacks or serious faults.",
        "fix_medium": "Improves an important system component, kernel, driver, boot process, hardware support, or core library.",
        "risk_medium": "Medium risk: delaying it can preserve crashes, hardware problems, compatibility issues, or instability.",
        "fix_normal": "Provides regular bug fixes, compatibility improvements, translations, or feature maintenance.",
        "risk_normal": "Low risk: it may be postponed briefly, but installation is recommended for reliability.",
        "fix_flatpak": "Updates the sandboxed application or runtime with fixes and improvements supplied by its Flatpak remote.",
        "risk_flatpak": "Application risk: postponing may leave app-specific bugs, security issues, or runtime incompatibility.",
        "recommendation": "Recommendation",
        "recommend_critical": "Install as soon as possible. Save important work first; a restart may be requested.",
        "recommend_medium": "Install when current work is saved. Kernel, driver, or core updates may require a restart.",
        "recommend_normal": "Install during routine maintenance to keep the system reliable.",
        "recommend_flatpak": "Install when the application is not in use, then reopen it after updating.",
        "restart_pending": "Restart required to finish applying updates",
        "restart_title": "Restart required",
        "restart_body": "The updates finished successfully, but important system changes are waiting for a restart. Save your work before continuing.",
        "restart_now": "Restart Now", "restart_later": "Later",
        "restart_may_be_required": "This selection contains a kernel or core-system update. A restart may be required afterward.",
        "partial_warning": "APT may install required dependencies together with the selected packages.",
    },
    "id": {
        "subtitle": "Pembaruan perangkat lunak Edukasaun OS",
        "available": "Pembaruan perangkat lunak tersedia untuk komputer ini",
        "release_available": "Versi baru Edukasaun OS tersedia",
        "current": "Edukasaun OS sudah terbaru",
        "empty": "Belum ada informasi pembaruan. Pilih Periksa Pembaruan.",
        "critical": "Pembaruan kritis", "medium": "Pembaruan sistem menengah",
        "normal": "Pembaruan biasa", "flatpak": "Pembaruan aplikasi Flatpak",
        "package": "Paket atau aplikasi", "installed": "Terpasang",
        "new": "Versi baru", "size": "Ukuran", "progress": "Progres",
        "selected": "{count} dipilih · Ukuran unduhan: {size}",
        "last_check": "Terakhir diperiksa: {time}", "select_all": "Pilih semua",
        "details": "Deskripsi dan risiko pembaruan", "choose": "Pilih pembaruan untuk melihat fungsi dan risikonya.",
        "check_updates": "Periksa Pembaruan", "check_again": "Periksa Lagi",
        "install": "Pasang Pembaruan", "settings": "Pengaturan",
        "history": "Riwayat", "about": "Tentang", "close": "Tutup",
        "minimize": "Minimalkan", "maximize_restore": "Maksimalkan atau pulihkan",
        "checking": "Memeriksa repositori dan membagi kategori pembaruan…",
        "installing": "Memasang pembaruan yang dipilih…", "saving": "Menyimpan pengaturan EUS…",
        "confirm_title": "Konfirmasi pembaruan", "confirm": "Pasang {count} pembaruan yang dipilih ({size})?",
        "success": "Pembaruan yang dipilih berhasil dipasang.",
        "failed": "Operasi tidak berhasil diselesaikan.", "auth": "Autentikasi administrator dibatalkan atau gagal.",
        "timeout": "Proses pembaruan berhenti merespons dan dihentikan dengan aman. Periksa jaringan lalu coba lagi.",
        "settings_title": "Pengaturan EUS", "interval": "Interval pemeriksaan otomatis",
        "notifications": "Tampilkan notifikasi pembaruan desktop", "hours": "Setiap {hours} jam",
        "save": "Simpan", "cancel": "Batal", "history_title": "Riwayat Pembaruan EUS",
        "no_history": "Belum ada riwayat EUS.", "clear_history": "Bersihkan Riwayat",
        "clear_history_confirm": "Bersihkan seluruh riwayat pembaruan EUS secara permanen?",
        "history_cleared": "Riwayat pembaruan telah dibersihkan.",
        "history_success": "Berhasil dipasang", "history_failed": "Pemasangan gagal",
        "complete_progress": "100% — Selesai", "failed_progress": "Gagal",
        "about_title": "Tentang Eduka-Update-System", "about_version": "Versi",
        "about_body": "Pengelola pembaruan resmi untuk Edukasaun OS. EUS menangani paket sistem APT dan aplikasi Flatpak dengan kategori serta informasi risiko yang jelas.",
        "source_apt": "Paket sistem APT", "source_flatpak-system": "Flatpak sistem",
        "source_flatpak-user": "Flatpak pengguna",
        "purpose": "Fungsi paket", "fixes": "Masalah yang ditangani", "danger": "Risiko jika ditunda",
        "fix_critical": "Menangani kerentanan keamanan yang telah diketahui atau komponen rilis Edukasaun OS yang sangat penting.",
        "risk_critical": "Risiko tinggi: penundaan dapat membuat komputer tetap terbuka terhadap serangan atau kerusakan serius.",
        "fix_medium": "Memperbaiki komponen sistem penting, kernel, driver, proses boot, dukungan perangkat keras, atau pustaka inti.",
        "risk_medium": "Risiko menengah: penundaan dapat mempertahankan crash, masalah perangkat keras, kompatibilitas, atau ketidakstabilan.",
        "fix_normal": "Memberikan perbaikan bug biasa, kompatibilitas, terjemahan, atau pemeliharaan fitur.",
        "risk_normal": "Risiko rendah: dapat ditunda sebentar, tetapi tetap disarankan untuk menjaga keandalan.",
        "fix_flatpak": "Memperbarui aplikasi atau runtime terisolasi dengan perbaikan dari repositori Flatpak-nya.",
        "risk_flatpak": "Risiko aplikasi: penundaan dapat mempertahankan bug, masalah keamanan, atau ketidakcocokan runtime aplikasi tersebut.",
        "recommendation": "Rekomendasi",
        "recommend_critical": "Pasang secepatnya. Simpan pekerjaan penting terlebih dahulu karena mulai ulang mungkin diperlukan.",
        "recommend_medium": "Pasang setelah pekerjaan disimpan. Pembaruan kernel, driver, atau komponen inti mungkin memerlukan mulai ulang.",
        "recommend_normal": "Pasang saat pemeliharaan rutin agar sistem tetap andal.",
        "recommend_flatpak": "Pasang ketika aplikasi tidak digunakan, lalu buka kembali aplikasi setelah diperbarui.",
        "restart_pending": "Mulai ulang diperlukan untuk menyelesaikan pembaruan",
        "restart_title": "Sistem perlu dimulai ulang",
        "restart_body": "Pembaruan selesai, tetapi perubahan sistem penting masih menunggu mulai ulang. Simpan pekerjaan sebelum melanjutkan.",
        "restart_now": "Mulai Ulang Sekarang", "restart_later": "Nanti",
        "restart_may_be_required": "Pilihan ini berisi pembaruan kernel atau sistem inti. Mulai ulang mungkin diperlukan setelahnya.",
        "partial_warning": "APT dapat memasang dependensi yang diperlukan bersama paket pilihan.",
    },
    "pt": {
        "subtitle": "Atualizacoes de software do Edukasaun OS",
        "available": "Atualizacoes de software estao disponiveis para este computador",
        "release_available": "Uma nova versao do Edukasaun OS esta disponivel",
        "current": "O Edukasaun OS ja esta atualizado",
        "empty": "Ainda nao ha informacoes. Selecione Verificar atualizacoes.",
        "critical": "Atualizacoes criticas", "medium": "Atualizacoes importantes do sistema",
        "normal": "Atualizacoes regulares", "flatpak": "Atualizacoes de aplicativos Flatpak",
        "package": "Pacote ou aplicativo", "installed": "Instalado", "new": "Nova versao", "size": "Tamanho", "progress": "Progresso",
        "selected": "{count} selecionadas · Download: {size}", "last_check": "Ultima verificacao: {time}",
        "select_all": "Selecionar tudo", "details": "Descricao e risco da atualizacao",
        "choose": "Selecione uma atualizacao para ver sua finalidade e risco.",
        "check_updates": "Verificar atualizacoes", "check_again": "Verificar novamente",
        "install": "Instalar Atualizacoes", "settings": "Configuracoes",
        "history": "Historico", "about": "Sobre", "close": "Fechar", "minimize": "Minimizar",
        "maximize_restore": "Maximizar ou restaurar", "checking": "Verificando repositorios e classificando atualizacoes…",
        "installing": "Instalando as atualizacoes selecionadas…", "saving": "Salvando configuracoes do EUS…",
        "confirm_title": "Confirmar atualizacoes", "confirm": "Instalar {count} atualizacoes selecionadas ({size})?",
        "success": "As atualizacoes selecionadas foram instaladas.", "failed": "A operacao nao foi concluida.",
        "timeout": "O processo de atualizacao deixou de responder e foi encerrado com seguranca. Verifique a rede e tente novamente.",
        "auth": "A autenticacao do administrador foi cancelada ou falhou.", "settings_title": "Configuracoes do EUS",
        "interval": "Intervalo da verificacao automatica", "notifications": "Mostrar notificacoes de atualizacao",
        "hours": "A cada {hours} horas", "save": "Salvar", "cancel": "Cancelar",
        "history_title": "Historico de Atualizacoes EUS", "no_history": "Ainda nao existe historico do EUS.",
        "clear_history": "Limpar Historico",
        "clear_history_confirm": "Limpar permanentemente todo o historico de atualizacoes do EUS?",
        "history_cleared": "O historico de atualizacoes foi limpo.",
        "history_success": "Instalada com sucesso", "history_failed": "Falha na instalacao",
        "complete_progress": "100% — Concluido", "failed_progress": "Falhou",
        "about_title": "Sobre o Eduka-Update-System", "about_version": "Versao",
        "about_body": "O gestor oficial de atualizacoes do Edukasaun OS. O EUS gere pacotes APT e aplicativos Flatpak com categorias e informacoes de risco claras.",
        "source_apt": "Pacote de sistema APT", "source_flatpak-system": "Flatpak do sistema",
        "source_flatpak-user": "Flatpak do usuario", "purpose": "Finalidade do pacote",
        "fixes": "Problema tratado", "danger": "Risco se for adiado",
        "fix_critical": "Corrige vulnerabilidades de seguranca publicadas ou um componente essencial da versao Edukasaun OS.",
        "risk_critical": "Risco alto: o adiamento pode manter o computador exposto a ataques ou falhas graves conhecidas.",
        "fix_medium": "Melhora um componente importante, kernel, driver, inicializacao, suporte de hardware ou biblioteca principal.",
        "risk_medium": "Risco medio: o adiamento pode manter falhas, problemas de hardware, compatibilidade ou instabilidade.",
        "fix_normal": "Fornece correcoes regulares de erros, compatibilidade, traducoes ou manutencao de recursos.",
        "risk_normal": "Risco baixo: pode ser adiada brevemente, mas a instalacao e recomendada para confiabilidade.",
        "fix_flatpak": "Atualiza o aplicativo isolado ou runtime com correcoes fornecidas pelo repositorio Flatpak.",
        "risk_flatpak": "Risco do aplicativo: adiar pode manter erros, problemas de seguranca ou incompatibilidade de runtime.",
        "recommendation": "Recomendacao",
        "recommend_critical": "Instale o mais rapidamente possivel. Salve o trabalho, pois pode ser necessario reiniciar.",
        "recommend_medium": "Instale depois de salvar o trabalho. Kernel, drivers ou componentes principais podem exigir reinicio.",
        "recommend_normal": "Instale durante a manutencao regular para manter o sistema confiavel.",
        "recommend_flatpak": "Instale quando o aplicativo nao estiver em uso e abra-o novamente depois.",
        "restart_pending": "E necessario reiniciar para concluir as atualizacoes",
        "restart_title": "E necessario reiniciar",
        "restart_body": "As atualizacoes terminaram, mas alteracoes importantes aguardam uma reinicializacao. Salve seu trabalho.",
        "restart_now": "Reiniciar agora", "restart_later": "Mais tarde",
        "restart_may_be_required": "A selecao inclui uma atualizacao do kernel ou do sistema principal. Pode ser necessario reiniciar.",
        "partial_warning": "O APT pode instalar dependencias necessarias junto com os pacotes selecionados.",
    },
    "tet": {
        "subtitle": "Atualizasaun software ba Edukasaun OS",
        "available": "Atualizasaun software disponivel ba komputadór ida-ne'e",
        "release_available": "Versaun foun Edukasaun OS disponivel",
        "current": "Edukasaun OS atualizadu ona", "empty": "Informasaun seidauk iha. Hili Verifika Atualizasaun.",
        "critical": "Atualizasaun kritiku", "medium": "Atualizasaun sistema importante",
        "normal": "Atualizasaun regular", "flatpak": "Atualizasaun aplikasaun Flatpak",
        "package": "Pakote ka aplikasaun", "installed": "Instaladu", "new": "Versaun foun", "size": "Tamañu", "progress": "Progresu",
        "selected": "Hili {count} · Tamañu download: {size}", "last_check": "Verifikasaun ikus: {time}",
        "select_all": "Hili hotu", "details": "Deskrisaun no risku atualizasaun",
        "choose": "Hili atualizasaun ida atu haree nia funsaun no risku.",
        "check_updates": "Verifika Atualizasaun", "check_again": "Verifika Fali",
        "install": "Instala Atualizasaun", "settings": "Konfigurasaun",
        "history": "Istoria", "about": "Konaba", "close": "Taka", "minimize": "Hakiak",
        "maximize_restore": "Haboot ka fila ba tamañu normal", "checking": "Verifika repositoriu no fahe atualizasaun tuir kategoria…",
        "installing": "Instala atualizasaun nebe hili…", "saving": "Rai konfigurasaun EUS…",
        "confirm_title": "Konfirma atualizasaun", "confirm": "Instala atualizasaun {count} nebe hili ({size})?",
        "success": "Atualizasaun nebe hili instala ho susesu.", "failed": "Operasaun la remata ho susesu.",
        "timeout": "Prosesu atualizasaun para responde no EUS taka ho seguru. Verifika rede no koko fali.",
        "auth": "Autentikasaun administradór kansela ka falla.", "settings_title": "Konfigurasaun EUS",
        "interval": "Intervalu verifikasaun automatiku", "notifications": "Hatudu notifikasaun atualizasaun desktop",
        "hours": "Kada oras {hours}", "save": "Rai", "cancel": "Kansela",
        "history_title": "Istoria Atualizasaun EUS", "no_history": "Istoria EUS seidauk iha.",
        "clear_history": "Hamoos Istoria",
        "clear_history_confirm": "Hamoos permanentemente istoria atualizasaun EUS hotu?",
        "history_cleared": "Istoria atualizasaun hamoos ona.",
        "history_success": "Instala ho susesu", "history_failed": "Instalasaun falla",
        "complete_progress": "100% — Remata", "failed_progress": "Falla",
        "about_title": "Konaba Eduka-Update-System", "about_version": "Versaun",
        "about_body": "Jestór atualizasaun ofisiál ba Edukasaun OS. EUS jere pakote sistema APT no aplikasaun Flatpak ho kategoria no informasaun risku nebe klaru.",
        "source_apt": "Pakote sistema APT", "source_flatpak-system": "Flatpak sistema",
        "source_flatpak-user": "Flatpak utilizadór", "purpose": "Funsaun pakote",
        "fixes": "Problema nebe atualizasaun hadi'a", "danger": "Risku se atraza",
        "fix_critical": "Hadi'a vulnerabilidade seguransa publika ka komponente esensial husi versaun Edukasaun OS.",
        "risk_critical": "Risku aas: atrazu bele husik komputadór nakloke ba atake ka falla grave nebe koñesidu ona.",
        "fix_medium": "Hadi'a komponente importante, kernel, driver, prosesu boot, hardware ka biblioteka prinsipál.",
        "risk_medium": "Risku klaran: atrazu bele halo crash, problema hardware, kompatibilidade ka instabilidade kontinua.",
        "fix_normal": "Fo korresaun bug regular, kompatibilidade, tradusaun ka manutensaun funsaun.",
        "risk_normal": "Risku ki'ik: bele atraza badak, maibe rekomenda instala atu sistema konfiavel.",
        "fix_flatpak": "Atualiza aplikasaun ka runtime izoladu ho korresaun husi repositoriu Flatpak.",
        "risk_flatpak": "Risku aplikasaun: atrazu bele husik bug, problema seguransa ka runtime la kompatível.",
        "recommendation": "Rekomendasaun",
        "recommend_critical": "Instala lalais. Rai uluk servisu importante tanba bele presiza hahu fali sistema.",
        "recommend_medium": "Instala depoisde rai servisu. Kernel, driver ka komponente prinsipál bele presiza hahu fali.",
        "recommend_normal": "Instala iha manutensaun regular atu sistema nafatin konfiavel.",
        "recommend_flatpak": "Instala bainhira aplikasaun la uza hela, depois loke fali aplikasaun.",
        "restart_pending": "Presiza hahu fali sistema atu remata atualizasaun",
        "restart_title": "Presiza hahu fali sistema",
        "restart_body": "Atualizasaun remata ona, maibe mudansa sistema importante hein hahu fali. Rai uluk ita-nia servisu.",
        "restart_now": "Hahu Fali Agora", "restart_later": "Depois",
        "restart_may_be_required": "Pakote hili inklui kernel ka sistema prinsipál. Depois bele presiza hahu fali.",
        "partial_warning": "APT bele instala mos dependensia nebe pakote hili presiza.",
    },
}

CATEGORY_COLORS = {
    "critical": ("#D92D20", "#FFF1F0", "#7A271A"),
    "medium": ("#E6A700", "#FFF8E1", "#7A4D00"),
    "normal": ("#169B62", "#ECFDF3", "#075E3B"),
    "flatpak": ("#1677D2", "#EFF8FF", "#0B4A82"),
}


def language_code() -> str:
    raw = os.environ.get("LC_ALL") or os.environ.get("LC_MESSAGES") or os.environ.get("LANGUAGE") or os.environ.get("LANG")
    if not raw:
        raw = locale.getlocale()[0] or "en"
    raw = raw.split(":", 1)[0].lower()
    if raw.startswith("tet"):
        return "tet"
    if raw.startswith("pt"):
        return "pt"
    if raw.startswith(("id", "in")):
        return "id"
    return "en"


def read_key_values(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip().strip("'\"")
    except OSError:
        pass
    return result


def current_boot_id() -> str:
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    except OSError:
        return "unknown"


def restart_is_required(state: dict[str, str] | None = None) -> bool:
    data = read_key_values(RESTART_FILE)
    required = data.get("required", (state or {}).get("restart_required", "0"))
    saved_boot = data.get("boot_id", (state or {}).get("restart_boot_id", ""))
    if required != "1":
        return False
    return not saved_boot or saved_boot == "unknown" or saved_boot == current_boot_id()


def restart_sensitive_package(record: dict) -> bool:
    if record.get("source") != "apt":
        return False
    name = str(record.get("name", ""))
    return bool(re.match(
        r"^(linux-|firmware-|intel-microcode|amd64-microcode|systemd|udev|libc6|grub-|initramfs-)",
        name,
    ))


def set_panel_status(state: str, *, count: int = 0, progress: int = -1) -> None:
    if not os.path.isfile(PANEL_STATUS) or not os.access(PANEL_STATUS, os.X_OK):
        return
    args = [PANEL_STATUS, state]
    if count > 0:
        args.extend(["--count", str(count)])
    if progress >= 0:
        args.extend(["--progress", str(max(0, min(100, progress)))])
    try:
        subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=2, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass


def format_bytes(value: int) -> str:
    size = float(max(0, value))
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return "0 B"


def format_last_check(timestamp: int) -> str:
    """Format the last check in the system locale without displaying a year."""
    return datetime.fromtimestamp(timestamp).strftime("%A, %d %B · %H:%M")


def history_field(value: object) -> str:
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def append_update_history(records: list[dict], success: bool) -> None:
    """Record installation results only; repository refreshes are never history entries."""
    if not records:
        return
    try:
        HISTORY_FILE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
        status = "success" if success else "failed"
        with HISTORY_FILE.open("a", encoding="utf-8") as stream:
            for record in records:
                stream.write("\t".join((
                    timestamp,
                    status,
                    history_field(record.get("source", "")),
                    history_field(record.get("name", "")),
                    history_field(record.get("installed", "—")),
                    history_field(record.get("candidate", "—")),
                )) + "\n")
        HISTORY_FILE.chmod(0o600)
    except OSError:
        pass


def gui_runtime_dir() -> Path:
    configured = os.environ.get("XDG_RUNTIME_DIR")
    if configured and Path(configured).is_dir() and os.access(configured, os.W_OK):
        base = Path(configured)
    else:
        normal = Path("/run/user") / str(os.getuid())
        base = normal if normal.is_dir() and os.access(normal, os.W_OK) else Path(tempfile.gettempdir()) / f"eus-runtime-{os.getuid()}"
    return base / "eduka-update-system"


INSTANCE_NAME = f"eduka-update-system-{os.getuid()}"


def request_existing_window() -> bool:
    socket = QLocalSocket()
    socket.connectToServer(INSTANCE_NAME)
    if not socket.waitForConnected(350):
        return False
    socket.write(b"show\n")
    socket.flush()
    socket.waitForBytesWritten(350)
    socket.disconnectFromServer()
    return True


def gui_pid_is_live() -> bool:
    pid_file = gui_runtime_dir() / "gui.pid"
    try:
        pid = int(pid_file.read_text(encoding="ascii").strip())
        os.kill(pid, 0)
        command_line = (Path("/proc") / str(pid) / "cmdline").read_bytes()
        return b"eduka-update-system-gui" in command_line
    except (OSError, ValueError):
        return False


class UpdateWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.lang = language_code()
        self.msg = MESSAGES[self.lang]
        version_data = read_key_values(VERSION_FILE)
        self.version = version_data.get("VERSION", EUS_VERSION)
        self.records: list[dict] = []
        self.package_items: list[QTreeWidgetItem] = []
        self.progress_widgets: dict[tuple[str, str], QProgressBar] = {}
        self.active_progress_keys: list[tuple[str, str]] = []
        self.process: QProcess | None = None
        self.current_command: dict | None = None
        self.pending_commands: list[dict] = []
        self.process_buffer = ""
        self.operation_kind = ""
        self.install_had_kernel = False
        self.process_was_timed_out = False
        self.process_timeout = QTimer(self)
        self.process_timeout.setSingleShot(True)
        self.process_timeout.timeout.connect(self.stop_stalled_process)
        self.progress_animation = QTimer(self)
        self.progress_animation.setInterval(650)
        self.progress_animation.timeout.connect(self.advance_row_progress)
        self.setWindowTitle("Eduka-Update-System")
        self.setWindowIcon(QIcon(EUS_APP_ICON))
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.resize(780, 560)
        self.setMinimumSize(640, 460)
        self.build_ui()
        self.apply_style()
        self.setup_window_shortcuts()
        self.load_updates()

    def t(self, key: str, **values) -> str:
        return self.msg[key].format(**values)

    def setup_window_shortcuts(self) -> None:
        self.fullscreen_shortcut = QShortcut(QKeySequence("F11"), self)
        self.fullscreen_shortcut.activated.connect(self.toggle_fullscreen)
        self.minimize_shortcut = QShortcut(QKeySequence("Ctrl+M"), self)
        self.minimize_shortcut.activated.connect(self.showMinimized)
        self.escape_shortcut = QShortcut(QKeySequence("Escape"), self)
        self.escape_shortcut.activated.connect(self.leave_fullscreen)

    def toggle_fullscreen(self) -> None:
        self.showNormal() if self.isFullScreen() else self.showFullScreen()

    def leave_fullscreen(self) -> None:
        if self.isFullScreen():
            self.showNormal()

    def build_ui(self) -> None:
        central = QWidget()
        self.setCentralWidget(central)
        outer = QVBoxLayout(central)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        header = QFrame(objectName="header")
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(16, 9, 16, 9)
        header_layout.setSpacing(10)
        icon = QLabel()
        icon.setPixmap(QIcon(EUS_APP_ICON).pixmap(QSize(36, 36)))
        header_layout.addWidget(icon)
        title_box = QVBoxLayout()
        title_box.setSpacing(0)
        title_box.addWidget(QLabel("Eduka-Update-System", objectName="appTitle"))
        title_box.addWidget(QLabel(self.t("subtitle"), objectName="subtitle"))
        header_layout.addLayout(title_box, 1)
        outer.addWidget(header)

        body = QWidget(objectName="body")
        body_layout = QVBoxLayout(body)
        body_layout.setContentsMargins(14, 11, 14, 11)
        body_layout.setSpacing(8)

        status_row = QHBoxLayout()
        status_column = QVBoxLayout()
        status_column.setSpacing(2)
        self.status_title = QLabel(objectName="statusTitle")
        self.last_checked = QLabel(objectName="muted")
        self.progress_detail = QLabel(objectName="progressDetail")
        self.progress_detail.setWordWrap(True)
        self.progress_detail.hide()
        status_column.addWidget(self.status_title)
        status_column.addWidget(self.last_checked)
        status_column.addWidget(self.progress_detail)
        status_row.addLayout(status_column, 1)
        body_layout.addLayout(status_row)

        self.tree = QTreeWidget(objectName="updatesTree")
        self.tree.setColumnCount(5)
        self.tree.setHeaderLabels([self.t("package"), self.t("installed"), self.t("new"),
                                   self.t("size"), self.t("progress")])
        self.tree.setRootIsDecorated(True)
        self.tree.setUniformRowHeights(True)
        self.tree.setAlternatingRowColors(False)
        self.tree.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOn)
        self.tree.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)
        self.tree.setVerticalScrollMode(QAbstractItemView.ScrollMode.ScrollPerPixel)
        self.tree.setMinimumHeight(150)
        header_view = self.tree.header()
        header_view.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        header_view.setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        header_view.setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        header_view.setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        header_view.setSectionResizeMode(4, QHeaderView.ResizeMode.Fixed)
        self.tree.setColumnWidth(4, 154)
        self.tree.itemChanged.connect(self.selection_changed)
        self.tree.currentItemChanged.connect(self.show_description)
        body_layout.addWidget(self.tree, 1)

        selection_row = QHBoxLayout()
        self.select_all = QCheckBox(self.t("select_all"))
        self.select_all.setChecked(True)
        self.select_all.stateChanged.connect(self.toggle_all)
        self.selection_label = QLabel(objectName="selectionLabel")
        selection_row.addWidget(self.select_all)
        selection_row.addWidget(self.selection_label, 1)
        body_layout.addLayout(selection_row)

        details = QFrame(objectName="detailsBox")
        details_layout = QVBoxLayout(details)
        details_layout.setContentsMargins(10, 8, 10, 9)
        details_layout.setSpacing(5)
        details_title = QLabel(self.t("details"), objectName="detailsTitle")
        details_layout.addWidget(details_title)
        self.description = QLabel(self.t("choose"))
        self.description.setTextFormat(Qt.TextFormat.RichText)
        self.description.setWordWrap(True)
        self.description.setMinimumHeight(62)
        details_layout.addWidget(self.description)
        body_layout.addWidget(details)

        actions = QHBoxLayout()
        self.about_button = QPushButton(self.t("about"), objectName="secondaryButton")
        self.settings_button = QPushButton(self.t("settings"), objectName="secondaryButton")
        self.history_button = QPushButton(self.t("history"), objectName="secondaryButton")
        self.check_button = QPushButton(self.t("check_updates"), objectName="secondaryButton")
        self.install_button = QPushButton(self.t("install"), objectName="primaryButton")
        self.close_button = QPushButton(self.t("close"), objectName="secondaryButton")
        self.about_button.clicked.connect(self.show_about)
        self.settings_button.clicked.connect(self.show_settings)
        self.history_button.clicked.connect(self.show_history)
        self.check_button.clicked.connect(self.check_updates)
        self.install_button.clicked.connect(self.install_updates)
        self.close_button.clicked.connect(self.close)
        actions.addWidget(self.about_button)
        actions.addWidget(self.settings_button)
        actions.addWidget(self.history_button)
        actions.addStretch(1)
        actions.addWidget(self.check_button)
        actions.addWidget(self.install_button)
        actions.addWidget(self.close_button)
        body_layout.addLayout(actions)
        outer.addWidget(body, 1)

    def apply_style(self) -> None:
        self.setStyleSheet(
            """
            QMainWindow, QWidget#body { background: #F3F3F3; color: #202020; }
            QFrame#header { background: qlineargradient(x1:0, y1:0, x2:0, y2:1,
                stop:0 #FFFFFF, stop:1 #F5F7F6); border-bottom: 1px solid #C9CECC; }
            QLabel#appTitle { color: #202020; font-size: 15px; font-weight: 600; }
            QLabel#subtitle { color: #686868; font-size: 10px; }
            QLabel#statusTitle { color: #202020; font-size: 13px; font-weight: 600; }
            QLabel#muted { color: #747474; font-size: 10px; }
            QLabel#progressDetail { color: #505050; font-size: 10px; }
            QLabel#selectionLabel { color: #444444; }
            QTreeWidget#updatesTree { background: #FFFFFF; border: 1px solid #C7CBC9;
                border-radius: 3px; outline: 0; font-size: 11px; }
            QTreeWidget#updatesTree::item { min-height: 30px; border-bottom: 1px solid #E8E8E8; }
            QTreeWidget#updatesTree::item:selected { background: #D9E8E3; color: #202020; }
            QHeaderView::section { background: qlineargradient(x1:0, y1:0, x2:0, y2:1,
                stop:0 #FAFAFA, stop:1 #E5E7E6); color: #333333; border: 0;
                border-right: 1px solid #D2D2D2; border-bottom: 1px solid #C8C8C8;
                padding: 5px 7px; font-weight: 600; }
            QFrame#detailsBox { background: qlineargradient(x1:0, y1:0, x2:0, y2:1,
                stop:0 #FFFFFF, stop:1 #FAFBFA); border: 1px solid #C7CBC9; border-radius: 3px; }
            QLabel#detailsTitle { color: #242424; font-weight: 600; border: 0; }
            QPushButton { min-height: 29px; padding: 0 11px; border-radius: 3px; }
            QPushButton#secondaryButton { background: qlineargradient(x1:0, y1:0, x2:0, y2:1,
                stop:0 #FFFFFF, stop:1 #ECEEED); color: #252525; border: 1px solid #B8BCBA; }
            QPushButton#secondaryButton:hover { border-color: #8F9692; }
            QPushButton#secondaryButton:pressed { background: #E2E5E3; padding-top: 1px; }
            QPushButton#primaryButton { background: qlineargradient(x1:0, y1:0, x2:0, y2:1,
                stop:0 #2B8A66, stop:1 #1F7254); color: #FFFFFF; border: 1px solid #185E44; }
            QPushButton#primaryButton:hover { background: #1C684C; }
            QPushButton#primaryButton:pressed { background: #185C44; padding-top: 1px; }
            QPushButton#primaryButton:disabled { background: #B8C9C2; border-color: #A9BBB4; }
            QWidget#rowProgressContainer { background: transparent; }
            QProgressBar#rowProgress { border: 1px solid #9DB5AA; border-radius: 4px;
                background: #E7EEEA; color: #173E2F; text-align: center;
                font-size: 9px; font-weight: 600; min-height: 14px; max-height: 14px; }
            QProgressBar#rowProgress::chunk { background: #199B61; border-radius: 2px; }
            QDialog { background: #F3F3F3; }
            QComboBox { min-height: 27px; padding: 0 6px; border: 1px solid #BDBDBD;
                border-radius: 3px; background: #FFFFFF; }
            """
        )

    def read_state(self) -> dict[str, str]:
        return read_key_values(STATE_FILE)

    def load_updates(self, update_panel: bool = True) -> None:
        system_records = parse_updates(TSV_FILE)
        user_records = scan_user_flatpaks()
        known = {(r["source"], r["name"]) for r in system_records}
        self.records = system_records + [r for r in user_records if (r["source"], r["name"]) not in known]
        state = self.read_state()
        self.tree.blockSignals(True)
        self.tree.clear()
        self.package_items.clear()
        self.progress_widgets.clear()
        groups = {key: [r for r in self.records if r["category"] == key]
                  for key in ("critical", "medium", "normal", "flatpak")}
        first_package_item = None
        for category in ("critical", "medium", "normal", "flatpak"):
            records = groups[category]
            if not records:
                continue
            if self.tree.topLevelItemCount() > 0:
                spacer = QTreeWidgetItem([""])
                spacer.setFlags(Qt.ItemFlag.NoItemFlags)
                spacer.setSizeHint(0, QSize(0, 8 if category != "flatpak" else 12))
                self.tree.addTopLevelItem(spacer)
            _color, pale, dark = CATEGORY_COLORS[category]
            group = QTreeWidgetItem([f"●  {self.t(category)}  ({len(records)})"])
            group.setFlags(Qt.ItemFlag.ItemIsEnabled)
            group.setForeground(0, QBrush(QColor(dark)))
            group.setBackground(0, QBrush(QColor(pale)))
            font = QFont()
            font.setBold(True)
            font.setPointSize(10)
            group.setFont(0, font)
            self.tree.addTopLevelItem(group)
            # setFirstColumnSpanned() belongs to QTreeWidgetItem in Qt 6.
            group.setFirstColumnSpanned(True)
            for record in records:
                item = QTreeWidgetItem(group, [record["name"], record["installed"],
                                                record["candidate"], format_bytes(record["size"]), ""])
                item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable | Qt.ItemFlag.ItemIsSelectable)
                item.setCheckState(0, Qt.CheckState.Checked)
                item.setData(0, Qt.ItemDataRole.UserRole, record)
                package_font = item.font(0)
                package_font.setBold(True)
                item.setFont(0, package_font)
                for column in range(5):
                    item.setBackground(column, QBrush(QColor(pale)))
                    item.setForeground(column, QBrush(QColor("#263746")))
                item.setToolTip(0, record["description"])
                progress_container = QWidget(objectName="rowProgressContainer")
                progress_layout = QHBoxLayout(progress_container)
                progress_layout.setContentsMargins(9, 3, 9, 3)
                progress_layout.setSpacing(0)
                row_progress = QProgressBar(objectName="rowProgress")
                row_progress.setTextVisible(True)
                row_progress.setRange(0, 100)
                row_progress.setFormat("%p%")
                row_progress.setMinimumWidth(126)
                row_progress.setValue(1)
                row_progress.hide()
                progress_layout.addWidget(row_progress, 0, Qt.AlignmentFlag.AlignCenter)
                self.tree.setItemWidget(item, 4, progress_container)
                self.progress_widgets[(record["source"], record["name"])] = row_progress
                self.package_items.append(item)
                if first_package_item is None:
                    first_package_item = item
            group.setExpanded(True)
        self.tree.blockSignals(False)

        try:
            checked_epoch = int(state.get("checked_at", "0"))
            if checked_epoch <= 0:
                raise ValueError
            checked_text = format_last_check(checked_epoch)
        except (ValueError, OSError, OverflowError):
            checked_text = "—"
        self.last_checked.setText(self.t("last_check", time=checked_text))
        if restart_is_required(state):
            self.status_title.setText(self.t("restart_pending"))
        elif state.get("release_upgrade") == "1":
            self.status_title.setText(self.t("release_available"))
        elif (state.get("state") == "ok" or user_records) and self.records:
            self.status_title.setText(self.t("available"))
        elif state.get("state") == "ok":
            self.status_title.setText(self.t("current"))
        else:
            self.status_title.setText(self.t("empty"))
        self.select_all.blockSignals(True)
        self.select_all.setChecked(bool(self.package_items))
        self.select_all.blockSignals(False)
        self.select_all.setEnabled(bool(self.package_items))
        if first_package_item is not None:
            self.tree.setCurrentItem(first_package_item)
        else:
            self.description.setText(self.t("choose"))
        self.update_selection_summary()
        if update_panel:
            self.sync_panel_status()

    def sync_panel_status(self) -> None:
        # The open manager is already a visible status surface. The panel icon
        # returns from closeEvent() only when updates are still available.
        set_panel_status("hidden")

    def selected_records(self) -> list[dict]:
        selected = []
        for item in self.package_items:
            if item.checkState(0) == Qt.CheckState.Checked:
                record = item.data(0, Qt.ItemDataRole.UserRole)
                if isinstance(record, dict):
                    selected.append(record)
        return selected

    def selection_changed(self, _item=None, _column=0) -> None:
        self.update_selection_summary()

    def update_selection_summary(self) -> None:
        selected = self.selected_records()
        self.selection_label.setText(self.t("selected", count=len(selected),
                                            size=format_bytes(sum(r["size"] for r in selected))))
        self.install_button.setEnabled(bool(selected) and self.process is None)
        self.select_all.blockSignals(True)
        self.select_all.setChecked(bool(self.package_items) and len(selected) == len(self.package_items))
        self.select_all.blockSignals(False)

    def toggle_all(self, state: int) -> None:
        checked = Qt.CheckState.Checked if state == Qt.CheckState.Checked.value else Qt.CheckState.Unchecked
        self.tree.blockSignals(True)
        for item in self.package_items:
            item.setCheckState(0, checked)
        self.tree.blockSignals(False)
        self.update_selection_summary()

    def show_description(self, current, _previous) -> None:
        if current is None:
            return
        record = current.data(0, Qt.ItemDataRole.UserRole)
        if not isinstance(record, dict):
            return
        category = record["category"]
        color = CATEGORY_COLORS[category][0]
        source = self.t(f"source_{record['source']}")
        package_name = html.escape(record["name"])
        purpose = html.escape(record["description"])
        installed = html.escape(record["installed"])
        candidate = html.escape(record["candidate"])
        self.description.setText(
            f"<b style='font-size:13px'>{package_name}</b> &nbsp; "
            f"<span style='color:{color};font-weight:700'>● {self.t(category)}</span> &nbsp; · &nbsp; {source}<br>"
            f"<b>{self.t('purpose')}:</b> {purpose}<br>"
            f"<b>{self.t('fixes')}:</b> {self.t('fix_' + category)}<br>"
            f"<b>{self.t('danger')}:</b> <span style='color:{color}'>{self.t('risk_' + category)}</span><br>"
            f"<b>{self.t('recommendation')}:</b> {self.t('recommend_' + category)}<br>"
            f"<span style='color:#64748B'>{installed} → {candidate}</span>"
        )

    def showEvent(self, event) -> None:
        set_panel_status("hidden")
        super().showEvent(event)

    def closeEvent(self, event) -> None:
        if self.process is not None:
            QMessageBox.information(self, "EUS", self.t("installing"))
            event.ignore()
            return
        if self.records:
            set_panel_status("available", count=len(self.records))
        else:
            set_panel_status("hidden")
        super().closeEvent(event)

    def set_busy(self, busy: bool, text: str = "") -> None:
        for widget in (self.about_button, self.settings_button, self.history_button, self.check_button,
                       self.close_button, self.select_all):
            widget.setEnabled(not busy)
        self.install_button.setEnabled(not busy and bool(self.selected_records()))
        self.progress_detail.setVisible(busy)
        if busy:
            self.status_title.setText(text)
            self.progress_detail.setText(text)
        else:
            self.progress_detail.clear()

    @staticmethod
    def record_key(record: dict) -> tuple[str, str]:
        return str(record.get("source", "")), str(record.get("name", ""))

    def begin_row_progress(self, records: list[dict], indeterminate: bool) -> None:
        self.active_progress_keys = []
        for record in records:
            key = self.record_key(record)
            progress = self.progress_widgets.get(key)
            if progress is None:
                continue
            progress.setRange(0, 100)
            progress.setFormat("%p%")
            progress.setValue(1)
            progress.setToolTip(self.progress_detail.text() if indeterminate else self.t("progress"))
            progress.show()
            self.active_progress_keys.append(key)
        if self.active_progress_keys:
            self.progress_animation.start()

    def update_row_progress(self, value: int) -> None:
        value = max(1, min(100, value))
        for key in self.active_progress_keys:
            progress = self.progress_widgets.get(key)
            if progress is None:
                continue
            progress.setValue(max(progress.value(), value))
            progress.show()

    def advance_row_progress(self) -> None:
        """Keep slow APT/Flatpak operations visibly active between backend reports."""
        for key in self.active_progress_keys:
            progress = self.progress_widgets.get(key)
            if progress is not None and progress.value() < 95:
                progress.setValue(progress.value() + 1)

    def finish_row_progress(self, success: bool) -> None:
        self.progress_animation.stop()
        if success:
            self.update_row_progress(100)
            for key in self.active_progress_keys:
                progress = self.progress_widgets.get(key)
                if progress is not None:
                    progress.setFormat(self.t("complete_progress"))
        else:
            for key in self.active_progress_keys:
                progress = self.progress_widgets.get(key)
                if progress is not None:
                    progress.setFormat(self.t("failed_progress"))
        self.active_progress_keys = []

    def privileged_command(self, action: str, extra: list[str]) -> tuple[str, list[str]]:
        args = [action, self.lang, *extra]
        if os.geteuid() == 0:
            return ROOT_HELPER, args
        return "pkexec", [ROOT_HELPER, *args]

    def root_queue_item(self, action: str, extra: list[str] | None = None,
                        records: list[dict] | None = None) -> dict:
        program, args = self.privileged_command(action, extra or [])
        timeout_ms = 7_200_000 if action in {"upgrade-apt", "install-apt"} else (
            3_700_000 if action == "install-flatpak-system" else 600_000)
        return {"program": program, "args": args, "protocol": True, "root": True,
                "records": records or [], "timeout_ms": timeout_ms,
                "ignore_failure": False}

    def user_flatpak_queue_item(self, refs: list[str], records: list[dict]) -> dict:
        return {"program": "flatpak", "args": ["update", "--user", "--noninteractive", "-y", *refs],
                "protocol": False, "root": False, "ignore_failure": False,
                "records": records, "timeout_ms": 3_700_000}

    def user_flatpak_refresh_item(self) -> dict:
        return {"program": "flatpak", "args": ["update", "--user", "--appstream", "--noninteractive"],
                "protocol": False, "root": False, "ignore_failure": True,
                "records": [], "timeout_ms": 120_000}

    def start_queue(self, commands: list[dict], operation: str) -> None:
        if self.process is not None or not commands:
            return
        self.operation_kind = operation
        self.pending_commands = list(commands)
        if operation in {"check", "install"}:
            set_panel_status("hidden")
        self.run_next_command()

    def run_next_command(self) -> None:
        if not self.pending_commands:
            self.finish_operation()
            return
        self.current_command = self.pending_commands.pop(0)
        self.process_buffer = ""
        self.process_was_timed_out = False
        self.process = QProcess(self)
        self.process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        environment = QProcessEnvironment.systemEnvironment()
        environment.insert("LC_ALL", "C.UTF-8")
        environment.insert("LANG", "C.UTF-8")
        environment.insert("TERM", "dumb")
        self.process.setProcessEnvironment(environment)
        self.process.readyReadStandardOutput.connect(self.read_process_output)
        self.process.finished.connect(self.process_finished)
        self.process.errorOccurred.connect(self.process_error)
        text = self.t("checking") if self.operation_kind == "check" else (
            self.t("saving") if self.operation_kind == "settings" else self.t("installing"))
        self.set_busy(True, text)
        self.begin_row_progress(self.current_command.get("records", []),
                                indeterminate=not self.current_command["protocol"])
        timeout_ms = int(self.current_command.get("timeout_ms", 0))
        if timeout_ms > 0:
            self.process_timeout.start(timeout_ms)
        self.process.start(self.current_command["program"], self.current_command["args"])

    def process_error(self, error) -> None:
        if error != QProcess.ProcessError.FailedToStart or self.process is None:
            return
        QTimer.singleShot(0, lambda: self.process_finished(127, QProcess.ExitStatus.CrashExit))

    def read_process_output(self) -> None:
        if self.process is None:
            return
        output = bytes(self.process.readAllStandardOutput()).decode("utf-8", errors="replace")
        if not self.current_command:
            return
        self.process_buffer += output.replace("\r", "\n")
        while "\n" in self.process_buffer:
            line, self.process_buffer = self.process_buffer.split("\n", 1)
            self.handle_process_line(line)

    def handle_process_line(self, line: str) -> None:
        text = line.strip()
        if text.isdigit():
            value = max(0, min(100, int(text)))
            self.update_row_progress(value)
            set_panel_status("hidden")
        elif text.startswith("# "):
            self.progress_detail.setText(text[2:])
        else:
            percentages = re.findall(r"(?<!\d)(\d{1,3})%", text)
            if percentages:
                self.update_row_progress(int(percentages[-1]))

    def stop_stalled_process(self) -> None:
        process = self.process
        if process is None or process.state() == QProcess.ProcessState.NotRunning:
            return
        self.process_was_timed_out = True
        self.progress_detail.setText(self.t("timeout"))
        process.terminate()

        def force_stop() -> None:
            if process.state() != QProcess.ProcessState.NotRunning:
                process.kill()

        QTimer.singleShot(5000, force_stop)

    def process_finished(self, exit_code: int, _status) -> None:
        if self.process is None:
            return
        finished_process = self.process
        command = self.current_command or {}
        self.process_timeout.stop()
        self.read_process_output()
        if self.process_buffer.strip():
            self.handle_process_line(self.process_buffer)
        self.process_buffer = ""
        timed_out = self.process_was_timed_out
        command_succeeded = exit_code == 0 and not timed_out
        history_records = command.get("records", [])
        if self.operation_kind == "install" and history_records:
            append_update_history(history_records, command_succeeded)
        self.finish_row_progress(command_succeeded)
        self.process = None
        self.current_command = None
        finished_process.deleteLater()
        if exit_code != 0 or timed_out:
            if command.get("ignore_failure"):
                self.run_next_command()
                return
            self.pending_commands.clear()
            self.set_busy(False)
            detail = self.t("timeout") if timed_out else (
                self.t("auth") if command.get("root") and exit_code in {126, 127} else self.t("failed"))
            if command.get("root") and not timed_out:
                try:
                    server_error = ERROR_FILE.read_text(encoding="utf-8", errors="replace").strip()
                    if server_error:
                        detail = server_error
                except OSError:
                    pass
            QMessageBox.critical(self, "EUS", detail)
            self.load_updates()
            return
        self.run_next_command()

    def finish_operation(self) -> None:
        operation = self.operation_kind
        self.operation_kind = ""
        self.set_busy(False)
        if operation == "install":
            needs_restart = restart_is_required(self.read_state()) or self.install_had_kernel
            self.install_had_kernel = False
            set_panel_status("hidden")
            cache = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "eus" / "last-notified"
            try:
                cache.unlink(missing_ok=True)
            except OSError:
                pass
            self.load_updates()
            if needs_restart:
                self.show_restart_prompt()
            else:
                QMessageBox.information(self, "EUS", self.t("success"))
            return
        self.load_updates()

    def show_restart_prompt(self) -> None:
        dialog = QMessageBox(self)
        dialog.setIcon(QMessageBox.Icon.Warning)
        dialog.setWindowTitle(self.t("restart_title"))
        dialog.setText(self.t("success"))
        dialog.setInformativeText(self.t("restart_body"))
        restart_button = dialog.addButton(self.t("restart_now"), QMessageBox.ButtonRole.AcceptRole)
        dialog.addButton(self.t("restart_later"), QMessageBox.ButtonRole.RejectRole)
        dialog.exec()
        if dialog.clickedButton() is restart_button:
            program, args = self.privileged_command("reboot", [])
            QProcess.startDetached(program, args)
            self.close()

    def check_updates(self) -> None:
        self.check_button.setText(self.t("check_again"))
        commands = []
        if shutil.which("flatpak"):
            commands.append(self.user_flatpak_refresh_item())
        commands.append(self.root_queue_item("refresh"))
        self.start_queue(commands, "check")

    def install_updates(self) -> None:
        selected = self.selected_records()
        if not selected:
            return
        total_size = format_bytes(sum(r["size"] for r in selected))
        text = self.t("confirm", count=len(selected), size=total_size) + "\n\n" + self.t("partial_warning")
        will_need_restart = any(restart_sensitive_package(record) for record in selected)
        if will_need_restart:
            text += "\n\n" + self.t("restart_may_be_required")
        answer = QMessageBox.question(self, self.t("confirm_title"), text,
                                      QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                      QMessageBox.StandardButton.No)
        if answer != QMessageBox.StandardButton.Yes:
            return

        self.install_had_kernel = will_need_restart

        commands: list[dict] = []
        selected_apt = [r for r in selected if r["source"] == "apt"]
        all_apt = [r for r in self.records if r["source"] == "apt"]
        if selected_apt:
            if len(selected_apt) == len(all_apt):
                commands.append(self.root_queue_item("upgrade-apt", records=selected_apt))
            else:
                commands.append(self.root_queue_item(
                    "install-apt", [r["name"] for r in selected_apt], records=selected_apt))
        system_flatpak_records = [r for r in selected if r["source"] == "flatpak-system"]
        if system_flatpak_records:
            commands.append(self.root_queue_item(
                "install-flatpak-system", [r["name"] for r in system_flatpak_records],
                records=system_flatpak_records))
        user_flatpak_records = [r for r in selected if r["source"] == "flatpak-user"]
        if user_flatpak_records:
            commands.append(self.user_flatpak_queue_item(
                [r["name"] for r in user_flatpak_records], user_flatpak_records))
        # Always rebuild updates.tsv after installation. This prevents stale
        # package rows and an incorrect panel icon after updates complete.
        commands.append(self.root_queue_item("refresh"))
        self.start_queue(commands, "install")

    def notifier_enabled(self) -> bool:
        override = Path.home() / ".config/autostart/eduka-update-system-notifier.desktop"
        if not override.exists():
            return True
        try:
            return "Hidden=true" not in override.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return True

    def set_notifier_enabled(self, enabled: bool) -> None:
        override = Path.home() / ".config/autostart/eduka-update-system-notifier.desktop"
        try:
            if enabled:
                override.unlink(missing_ok=True)
            else:
                override.parent.mkdir(parents=True, exist_ok=True)
                override.write_text("[Desktop Entry]\nHidden=true\n", encoding="utf-8")
        except OSError as exc:
            QMessageBox.warning(self, "EUS", str(exc))

    def current_interval(self) -> int:
        try:
            value = int(INTERVAL_FILE.read_text(encoding="utf-8").strip())
            return value if value in {1, 3, 6, 12, 24} else 6
        except (OSError, ValueError):
            return 6

    def show_about(self) -> None:
        dialog = QMessageBox(self)
        dialog.setIconPixmap(QIcon(EUS_APP_ICON).pixmap(QSize(48, 48)))
        dialog.setWindowTitle(self.t("about_title"))
        dialog.setText("Eduka-Update-System")
        dialog.setInformativeText(
            f"{self.t('about_version')}: {self.version}\n\n{self.t('about_body')}"
        )
        dialog.setStandardButtons(QMessageBox.StandardButton.Close)
        dialog.exec()

    def show_settings(self) -> None:
        dialog = QDialog(self)
        dialog.setWindowTitle(self.t("settings_title"))
        dialog.setMinimumWidth(450)
        layout = QVBoxLayout(dialog)
        layout.addWidget(QLabel(self.t("interval")))
        interval = QComboBox()
        for hours in (1, 3, 6, 12, 24):
            interval.addItem(self.t("hours", hours=hours), hours)
        current = self.current_interval()
        interval.setCurrentIndex(interval.findData(current))
        layout.addWidget(interval)
        notify = QCheckBox(self.t("notifications"))
        notify.setChecked(self.notifier_enabled())
        layout.addWidget(notify)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        buttons.button(QDialogButtonBox.StandardButton.Save).setText(self.t("save"))
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText(self.t("cancel"))
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        layout.addWidget(buttons)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        self.set_notifier_enabled(notify.isChecked())
        new_interval = int(interval.currentData())
        if new_interval != current:
            self.start_queue([self.root_queue_item("set-interval", [str(new_interval)])], "settings")

    def show_history(self) -> None:
        dialog = QDialog(self)
        dialog.setWindowTitle(self.t("history_title"))
        dialog.resize(760, 520)
        layout = QVBoxLayout(dialog)
        viewer = QPlainTextEdit()
        viewer.setReadOnly(True)
        viewer.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)

        def render_history() -> str:
            try:
                lines = HISTORY_FILE.read_text(encoding="utf-8", errors="replace").splitlines()
            except OSError:
                return self.t("no_history")
            entries = []
            for line in lines[-2000:]:
                fields = line.split("\t", 5)
                if len(fields) != 6 or fields[1] not in {"success", "failed"}:
                    continue
                timestamp, result, _source, name, installed, candidate = fields
                try:
                    display_time = datetime.fromisoformat(timestamp).strftime("%A, %d %B %Y · %H:%M")
                except ValueError:
                    display_time = timestamp
                if result == "success":
                    marker, status = "✓", self.t("history_success")
                else:
                    marker, status = "✕", self.t("history_failed")
                entries.append(
                    f"[{display_time}]\n{marker} {name} — {status}\n"
                    f"  {installed} → {candidate}"
                )
            return "\n\n".join(entries) if entries else self.t("no_history")

        viewer.setPlainText(render_history())
        layout.addWidget(viewer)
        button_row = QHBoxLayout()
        clear_button = QPushButton(self.t("clear_history"), objectName="secondaryButton")
        close = QPushButton(self.t("close"))
        close.clicked.connect(dialog.accept)
        button_row.addWidget(clear_button)
        button_row.addStretch(1)
        button_row.addWidget(close)
        layout.addLayout(button_row)

        def request_clear_history() -> None:
            answer = QMessageBox.question(
                dialog,
                self.t("clear_history"),
                self.t("clear_history_confirm"),
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if answer != QMessageBox.StandardButton.Yes:
                return
            try:
                HISTORY_FILE.unlink(missing_ok=True)
                viewer.setPlainText(self.t("no_history"))
                QMessageBox.information(dialog, "EUS", self.t("history_cleared"))
            except OSError:
                QMessageBox.warning(dialog, "EUS", self.t("failed"))

        clear_button.clicked.connect(request_clear_history)
        dialog.exec()


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Eduka-Update-System")
    app.setOrganizationName("Edukasaun OS")
    app.setDesktopFileName("eduka-update-system")
    app.setWindowIcon(QIcon(EUS_APP_ICON))
    screenshot_mode = len(sys.argv) >= 3 and sys.argv[1] == "--screenshot"
    if not screenshot_mode and request_existing_window():
        return 0
    if not screenshot_mode and gui_pid_is_live():
        # A just-started primary instance may still be creating its local
        # socket. Avoid a second window while it finishes initialization.
        def retry_primary() -> None:
            request_existing_window()
            app.quit()

        QTimer.singleShot(250, retry_primary)
        return app.exec()

    server = None
    pid_file = None
    if not screenshot_mode:
        QLocalServer.removeServer(INSTANCE_NAME)
        server = QLocalServer(app)
        if not server.listen(INSTANCE_NAME):
            if request_existing_window():
                return 0
            print(f"EUS could not create its single-instance socket: {server.errorString()}",
                  file=sys.stderr)
            return 75

        runtime_dir = gui_runtime_dir()
        runtime_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        pid_file = runtime_dir / "gui.pid"
        temporary_pid = runtime_dir / f"gui.{os.getpid()}.tmp"
        temporary_pid.write_text(f"{os.getpid()}\n", encoding="ascii")
        temporary_pid.chmod(0o600)
        os.replace(temporary_pid, pid_file)

    window = UpdateWindow()
    window.show()

    if server is not None:
        def present_primary_window() -> None:
            while server.hasPendingConnections():
                connection = server.nextPendingConnection()
                if connection is not None:
                    connection.readAll()
                    connection.disconnectFromServer()
                    connection.deleteLater()
            if window.isMinimized() or window.isFullScreen():
                window.showNormal()
            else:
                window.show()
            window.raise_()
            window.activateWindow()

        server.newConnection.connect(present_primary_window)
        app._eus_instance_server = server

    if pid_file is not None:
        def remove_pid_file() -> None:
            try:
                if pid_file.read_text(encoding="ascii").strip() == str(os.getpid()):
                    pid_file.unlink(missing_ok=True)
            except OSError:
                pass

        app.aboutToQuit.connect(remove_pid_file)

    if screenshot_mode:
        destination = sys.argv[2]

        def save_preview() -> None:
            window.grab().save(destination)
            app.quit()

        QTimer.singleShot(700, save_preview)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
EUS_GUI

install -m 0755 /dev/stdin "$(target /usr/local/bin/eus-panel-status)" <<'EUS_PANEL_STATUS'
#!/usr/bin/python3
"""Write the current EUS panel state atomically for Eduka-Panel."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import time
from pathlib import Path


VALID_STATES = ("hidden", "idle", "available", "running", "finished")


def runtime_base() -> Path:
    configured = os.environ.get("XDG_RUNTIME_DIR")
    if configured:
        return Path(configured)
    normal = Path("/run/user") / str(os.getuid())
    if normal.is_dir():
        return normal
    return Path(tempfile.gettempdir()) / f"eus-runtime-{os.getuid()}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Set Eduka-Update-System panel status")
    parser.add_argument("state", choices=VALID_STATES)
    parser.add_argument("--count", type=int, default=0)
    parser.add_argument("--progress", type=int, default=-1)
    parser.add_argument("--message", default="")
    args = parser.parse_args()

    state_dir = runtime_base() / "eduka-update-system"
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    state_file = state_dir / "panel-status.json"
    payload = {
        "version": 1,
        "state": args.state,
        "count": max(0, args.count),
        "progress": min(100, max(-1, args.progress)),
        "message": args.message.strip(),
        "updated_at": int(time.time()),
    }
    temp_file = state_dir / f"panel-status.{os.getpid()}.tmp"
    temp_file.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
    temp_file.chmod(0o600)
    os.replace(temp_file, state_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EUS_PANEL_STATUS

install -m 0755 /dev/stdin "$(target /usr/lib/EUS-ICONS/eus_panel_indicator.py)" <<'EUS_PANEL_INDICATOR'
#!/usr/bin/python3
"""Embedded and standalone EUS status indicator for Eduka-Panel/LXQt."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

try:
    from PyQt6.QtCore import QProcess, QSize, Qt, QTimer
    from PyQt6.QtGui import QAction, QIcon, QPixmap
    from PyQt6.QtWidgets import QApplication, QLabel, QMenu, QSystemTrayIcon

    ALIGN_CENTER = Qt.AlignmentFlag.AlignCenter
    KEEP_ASPECT = Qt.AspectRatioMode.KeepAspectRatio
    SMOOTH = Qt.TransformationMode.SmoothTransformation
    LEFT_BUTTON = Qt.MouseButton.LeftButton
    POINTING_HAND = Qt.CursorShape.PointingHandCursor
    TRAY_TRIGGER = QSystemTrayIcon.ActivationReason.Trigger
    TRAY_DOUBLE_CLICK = QSystemTrayIcon.ActivationReason.DoubleClick
except ImportError:
    from PyQt5.QtCore import QProcess, QSize, Qt, QTimer
    from PyQt5.QtGui import QIcon, QPixmap
    from PyQt5.QtWidgets import QAction, QApplication, QLabel, QMenu, QSystemTrayIcon

    ALIGN_CENTER = Qt.AlignCenter
    KEEP_ASPECT = Qt.KeepAspectRatio
    SMOOTH = Qt.SmoothTransformation
    LEFT_BUTTON = Qt.LeftButton
    POINTING_HAND = Qt.PointingHandCursor
    TRAY_TRIGGER = QSystemTrayIcon.Trigger
    TRAY_DOUBLE_CLICK = QSystemTrayIcon.DoubleClick


ICON_DIR = Path("/usr/lib/EUS-ICONS")
I18N_FILE = ICON_DIR / "eus-i18n.json"
EUS_COMMAND = "/usr/local/bin/eduka-update-system"
APP_ICON = "/usr/share/icons/hicolor/48x48/apps/eduka-update-system.png"
_LAST_LAUNCH = 0.0
DEFAULT_MESSAGES = {
    "updates_available": "Updates available",
    "updates_available_count": "{count} updates available",
    "update_running": "Update in progress",
    "update_finished": "Update finished",
    "open_manager": "Open Update Manager",
}


def system_locale_candidates() -> list[str]:
    """Return normalized locale keys, with English as the final fallback."""
    candidates: list[str] = []
    for variable in ("LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"):
        raw_value = os.environ.get(variable, "")
        for value in raw_value.split(":"):
            normalized = value.strip().split(".", 1)[0].split("@", 1)[0].replace("-", "_").lower()
            if not normalized:
                continue
            for candidate in (normalized, normalized.split("_", 1)[0]):
                if candidate and candidate not in candidates:
                    candidates.append(candidate)
    if "en" not in candidates:
        candidates.append("en")
    return candidates


def load_messages() -> dict[str, str]:
    """Load the system language, falling back safely to built-in English."""
    messages = dict(DEFAULT_MESSAGES)
    try:
        payload = json.loads(I18N_FILE.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            return messages
        translations = payload.get("translations", {})
        if not isinstance(translations, dict):
            return messages
        selected = next(
            (translations[key] for key in system_locale_candidates() if isinstance(translations.get(key), dict)),
            translations.get("en", {}),
        )
        if isinstance(selected, dict):
            messages.update(
                {key: value for key, value in selected.items() if key in messages and isinstance(value, str)}
            )
    except (OSError, ValueError, json.JSONDecodeError):
        pass
    return messages


def state_file_path() -> Path:
    configured = os.environ.get("XDG_RUNTIME_DIR")
    if configured:
        base = Path(configured)
    else:
        normal = Path("/run/user") / str(os.getuid())
        base = normal if normal.is_dir() else Path(tempfile.gettempdir()) / f"eus-runtime-{os.getuid()}"
    return base / "eduka-update-system" / "panel-status.json"


def launch_eus() -> bool:
    """Launch EUS without blocking Eduka-Panel or the tray process."""
    global _LAST_LAUNCH
    now = time.monotonic()
    if now - _LAST_LAUNCH < 1.2:
        return True
    _LAST_LAUNCH = now
    result = QProcess.startDetached(EUS_COMMAND, ["--ui"])
    started = result[0] if isinstance(result, tuple) else bool(result)
    if started:
        return True
    try:
        subprocess.Popen(
            [EUS_COMMAND, "--ui"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return True
    except OSError:
        return False


class EUSPanelIndicator(QLabel):
    """Show an EUS icon only while one or more updates are available."""

    def __init__(self, panel_icon_size: int = 18, parent=None):
        super().__init__(parent)
        self._icon_size = 18
        self._state = "hidden"
        self._data: dict[str, object] = {}
        self._signature: tuple[int, int] | None = None
        self._messages = load_messages()
        self.setAlignment(ALIGN_CENTER)
        self.setCursor(POINTING_HAND)
        self.setAccessibleName("Eduka-Update-System")
        self.set_panel_icon_size(panel_icon_size)
        self.hide()

        self._poll = QTimer(self)
        self._poll.timeout.connect(self.check_status)
        self._poll.start(500)

        self.check_status()

    def set_panel_icon_size(self, size: int) -> None:
        self._icon_size = max(16, min(30, int(size)))
        self.setFixedSize(max(30, self._icon_size + 12), max(24, self._icon_size + 10))
        if self._data:
            self._apply_state(self._data, force=True)

    def check_status(self) -> None:
        path = state_file_path()
        try:
            stat = path.stat()
            signature = (stat.st_mtime_ns, stat.st_size)
            if signature == self._signature:
                return
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                raise ValueError("invalid EUS panel state")
        except (OSError, ValueError, json.JSONDecodeError):
            if self._state != "hidden":
                self._apply_state({"state": "hidden"})
            return
        self._signature = signature
        self._apply_state(data)

    def _clear_icon(self) -> None:
        self.clear()

    def _show_png(self, filename: str) -> None:
        self._clear_icon()
        pixmap = QPixmap(str(ICON_DIR / filename))
        if pixmap.isNull():
            self.hide()
            return
        self.setPixmap(pixmap.scaled(QSize(self._icon_size, self._icon_size), KEEP_ASPECT, SMOOTH))
        self.show()

    def _apply_state(self, data: dict[str, object], force: bool = False) -> None:
        state = str(data.get("state", "hidden")).lower()
        message = str(data.get("message", "")).strip()
        try:
            count = int(data.get("count", 0))
        except (TypeError, ValueError):
            count = 0

        self._data = data
        if state != "available" or count <= 0:
            self._state = "hidden"
            self._clear_icon()
            self.setToolTip("")
            self.hide()
            return

        self._state = "available"
        self._show_png("eus-update-available.png")
        tooltip = message or self._messages["updates_available_count"].format(count=count)
        self.setToolTip(tooltip)

    def mousePressEvent(self, event) -> None:
        if event.button() == LEFT_BUTTON:
            launch_eus()
            event.accept()
            return
        super().mousePressEvent(event)


class EUSTrayIndicator(QSystemTrayIcon):
    """Standalone StatusNotifierItem/XEmbed icon for LXQt and Eduka-Panel."""

    def __init__(self, parent=None):
        super().__init__(QIcon(APP_ICON), parent)
        self._messages = load_messages()
        self._signature: tuple[int, int] | None = None
        self._state = "hidden"

        menu = QMenu()
        open_action = QAction(self._messages["open_manager"], menu)
        open_action.triggered.connect(lambda _checked=False: launch_eus())
        menu.addAction(open_action)
        self._menu = menu
        self.setContextMenu(menu)
        self.activated.connect(self._activated)

        self._poll = QTimer(self)
        self._poll.timeout.connect(self.check_status)
        self._poll.start(750)
        self.check_status()

    def _activated(self, reason) -> None:
        if reason in (TRAY_TRIGGER, TRAY_DOUBLE_CLICK):
            launch_eus()

    def check_status(self) -> None:
        path = state_file_path()
        try:
            stat = path.stat()
            signature = (stat.st_mtime_ns, stat.st_size)
            if signature == self._signature:
                return
            data = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                raise ValueError("invalid EUS panel state")
        except (OSError, ValueError, json.JSONDecodeError):
            self._apply_state({"state": "hidden", "count": 0})
            return
        self._signature = signature
        self._apply_state(data)

    def _apply_state(self, data: dict[str, object]) -> None:
        state = str(data.get("state", "hidden")).lower()
        try:
            count = int(data.get("count", 0))
        except (TypeError, ValueError):
            count = 0
        if state != "available" or count <= 0:
            self._state = "hidden"
            self.hide()
            return
        self._state = "available"
        self.setIcon(QIcon(str(ICON_DIR / "eus-update-available.png")))
        message = str(data.get("message", "")).strip()
        self.setToolTip(message or self._messages["updates_available_count"].format(count=count))
        # Qt registers this as StatusNotifierItem on LXQt/Wayland and uses
        # the XEmbed tray fallback on X11.
        self.show()


def acquire_tray_lock():
    lock_path = state_file_path().parent / "tray-indicator.lock"
    lock_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    handle = lock_path.open("a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("Eduka-Update-System Indicator")
    app.setOrganizationName("Edukasaun OS")
    app.setQuitOnLastWindowClosed(False)
    lock_handle = acquire_tray_lock()
    if lock_handle is None:
        return 0
    app._eus_lock_handle = lock_handle
    app._eus_tray_indicator = EUSTrayIndicator(app)
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
EUS_PANEL_INDICATOR

install -m 0644 /dev/stdin "$(target /usr/lib/EUS-ICONS/eus-i18n.json)" <<'EUS_ICON_I18N'
{
  "version": "0.12",
  "default_language": "en",
  "translations": {
    "en": {
      "updates_available": "Updates available",
      "updates_available_count": "{count} updates available",
      "update_running": "Update in progress",
      "update_finished": "Update finished",
      "open_manager": "Open Update Manager"
    },
    "tet": {
      "updates_available": "Atualizasaun disponivel",
      "updates_available_count": "Atualizasaun {count} disponivel",
      "update_running": "Atualizasaun lao hela",
      "update_finished": "Atualizasaun remata ona",
      "open_manager": "Loke Jestór Atualizasaun"
    },
    "pt": {
      "updates_available": "Atualizações disponíveis",
      "updates_available_count": "{count} atualizações disponíveis",
      "update_running": "Atualização em andamento",
      "update_finished": "Atualização concluída",
      "open_manager": "Abrir Gestor de Atualizações"
    },
    "id": {
      "updates_available": "Pembaruan tersedia",
      "updates_available_count": "{count} pembaruan tersedia",
      "update_running": "Pembaruan sedang berjalan",
      "update_finished": "Pembaruan selesai",
      "open_manager": "Buka Pengelola Pembaruan"
    }
  }
}
EUS_ICON_I18N

install -m 0644 /dev/stdin "$(target /usr/lib/EUS-ICONS/eus-icons.json)" <<'EUS_ICON_MANIFEST'
{
  "version": "0.12",
  "size": 48,
  "default_language": "en",
  "translation_file": "eus-i18n.json",
  "idle": "eus-update-idle.png",
  "available": "eus-update-available.png",
  "running": "eus-update-running.gif",
  "running_fallback": "eus-update-running.png",
  "finished": "eus-update-finished.png"
}
EUS_ICON_MANIFEST

base64 -d >"$(target /usr/share/icons/hicolor/48x48/apps/eduka-update-system.png)" <<'EUS_APP_ICON_PNG'
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
VN3/AtHkA7BVN/d7AAAAAElFTkSuQmCC
EUS_APP_ICON_PNG
chmod 0644 "$(target /usr/share/icons/hicolor/48x48/apps/eduka-update-system.png)"

base64 -d >"$(target /usr/share/pixmaps/eduka-update-system.png)" <<'EUS_PIXMAP_PNG'
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
VN3/AtHkA7BVN/d7AAAAAElFTkSuQmCC
EUS_PIXMAP_PNG
chmod 0644 "$(target /usr/share/pixmaps/eduka-update-system.png)"

base64 -d >"$(target /usr/lib/EUS-ICONS/eus-update-idle.png)" <<'EUS_IDLE_PNG'
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
VN3/AtHkA7BVN/d7AAAAAElFTkSuQmCC
EUS_IDLE_PNG
chmod 0644 "$(target /usr/lib/EUS-ICONS/eus-update-idle.png)"

base64 -d >"$(target /usr/lib/EUS-ICONS/eus-update-available.png)" <<'EUS_AVAILABLE_PNG'
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
SS5FOQYAAAAASUVORK5CYII=
EUS_AVAILABLE_PNG
chmod 0644 "$(target /usr/lib/EUS-ICONS/eus-update-available.png)"

base64 -d >"$(target /usr/lib/EUS-ICONS/eus-update-running.gif)" <<'EUS_RUNNING_GIF'
R0lGODlhMAAwAIcAAP////r///P8//H6//D6//D5/+//++/5/+75/+74/+3/++z/++z/+uv/+uv9
+u34/+r9+ur9+en9+er8+en8+ej9+ej8+ej8+Oj7+Ob7+OX79+T79+L79+P69uL69t/59d/49N75
9d749N349Nz49O33/+z3/+r2/+n1/+j1/+f0/+b0/+bz/+D29tz38+Ty/+Py/9v389r389v28uTx
/uPx/OLx/+Hw/+Hw/uDw/uDv/d/v/t7v/t7u/t7u/d3u/t3t/dzt/tzt/drr+tn389n28tj28tf1
8db18dTz79fp+tTn+dHy7s7x7Mnv6sjq7sDr577r5r3q5brp5Mvi+Mng98ff9sXe9rvf7qHg25be
2JLf2Y/d1ord1r3S5qLL8r+/357I8ZLW2prG8ZvF7pfF83jXz3HTzG7Sy23QyG3NxmXOx1/NxVnJ
wVTHvz7NyAD//wD/fwD/AIe88He811LAt03FvEjBuU69tUPAtz+/v0G9sje8sii9swC/vwC/f7Wt
un6y5X217Xuz63mx6XKu6m22tmin5mil32Wd2FWq/1Wqqlu2o1+j5lye4Fqc3lSb4VOZ4E2V3Te3
rje0qzCyqS6vpzCroiOyqCStoyaroiCqoSKonyKnnEOV3iOinB+onx+nnR+lnR2imhmqoBalnBak
mhmjmxWimBGimRKhlxChlw+hlw6glwCqqg2jmBaflhKdlBCelQ+flROblQ2elQ2dlA6dkg6clAyd
lAqelQqdkwqclAqckgmdlAebkX9//0uR2EeP1kaIzUKL1EGK00GJ0D+J0j9/vz9/fzqO4TiI2DmF
zzqCzTaBzTZ/zTOE0DSB0DGB0DSAzTR/yTF/yjF9ywB//wB/fzF8yTR5xi18yyt5xyh6yyh4ySl4
xip3xCZ4ySV2xyZ1xSZ0wyVzxiR3yCR1xiN1xyR0xCN0xSN0xCF0xCNzxCBzxStsu1VVqiFyxCBx
xB9xxB9xwx5xwxhqvQMBAQEBAAAA/wEAAQMAAAIAAAEAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEA
AAAh+QQJBQD/ACwAAAAAMAAwAAAI/wD/CRxIsKDBgwgTKlwo0F07dOfOuZPGsCJDc+GcRSo0p0yY
MGMagbNIsqC5aYfCVIGRYMCBAyYAzKlXsmQ4aIOumECwYsePHTds7EAgiF5Ni90OWSmQogcPFQQO
qACiZIkJQTQHiupjqavXSpowharIbRmZByiA3Hhw4sqYQo6CESMWzFM2grvSgGjChEmTGVL4nKro
zdOVAjt6mKDxpdE0ce4W9kJjYMSHDxucTFJV8ZukJQ+CsPwCqZs5i5MbECERQ0MdXRXBebIaREUN
QtvClZzMgEiMGB6gVILFcNmVB0JSDHF0uubkCCE0fCgCYQqmhd3IFKg9JJLuo73SBP+AUqcJhyMK
uKRK2O6QiR0wajgSd1TgLzMzKP3CA0KEjAtu4IIQNFWg0EMChKBTn0CrtJFHLf/UkkYERmgQxSYH
tTPIdiZ8sc2CAnHSx2AClZLFBUc4kIaABU1zRQo40AAJOSD+IwqGA8mSBwgxbCAFKAW1Z0IPCHzx
TY0IqZIFBUYAyKJA44SBAA8nNKIOkgfZYkcGRTjAxSwEOVMFCypcMQ2WCIEChQfBcUJQJC/sQMAY
6aCZJRcMyCDCHgPJU0gCPRxQyDx2GrTLGg4YEQEbvggkzxwD7KCCI4UedEcHRShgxi4CqVPGATcA
EUylBk1ihAsMdGGLQOeEcYANShD/Q2pBlTAxQgNbgPlPq6/GOitBtd6aq0DtfHqDD6P+KpCpqKrq
KKSSUqrsP5dmagYvArHz5w+CGvXroYku2qhAkcCgw5x1/joLnnryOZCYK6hgxZm/ghJFB20SlI6r
PVTZzqy1bEndFrIQxI57PTzwhTezqqIFkwDm0uKLObwwI0HRUFOjjiC44COQQW74gwlYfCjQNspo
DKKJFhzBQBqrGgSNFSj8kIAgV7IDySH0LdiKGhMYsQEUmSBEziEl7GBDDYnUI4wOM/l8BwghyIBB
GwUjlN12KSiBSBUBDOJtTazskcR5DHBhykLGTfnCCTYQNTZJrNyRxAZHVGAdQ98I3EPFCjnk0AMB
RZWUSilqgMABEhk0wQdxDLmTyAk63BBo4RW9kkoeWUwQQt6Oc8aQN8EskcILLNggAOYJ6dKKKHZo
AYIFRsjAwBR8oFKRNYbpsIQSVb1ASDwEncIHJZZUMskda3ARRQYUuHDEBhRwgcnaDFGjjDHCHFPM
98UYo8xdA00mAV9HdODAApgKzQAUbZTy63MyjOBCEbV74MAFUqSRyXq/+sUZAFCBBjBAAREQARS2
4AZQvGJa/0DFG7qwhS10wQxs2AMnVvFACAqEFLmYxSxqUQvYeFBZAQEAIfkECQUA/wAsAAAAADAA
MACH////+f//8/z/8fr/8Pr/8Pn/7//87/n/7f/77P/77P/66//66/366/357vn/7vj/7fj/7Pj/
6v356vz56fz56P356Pz55vz45/v45fv35Pv34/v34/r24vr24vn14Pn13/j03fj07ff/7Pf/6/f/
6vb/6fX/6PX/6PT/5/T/5vT/5vP/3vf03Pfz4/L/2/fz2vfz2vfy4/H+4/H84vH/4fH+4fD/4fD+
4PD+4O/+3+/+3u/+3u7+3u793e7+3e393O3+3O392+z82fby2Pby2PXx1/Xx1vXx2O731+n61un6
0/Pv0fLuz/Hszerxwuznv+vnv+rlvOrlvOnksebhy+H3x+D3xt71xd72wtz0qeLcoOPdpNvel93X
vNDtsNHxrM/ypszwocrzocjtnsjymsbxmMXymcTukt7Yjd3Wj9vVh9vUeNbPcNDJadHJg73nYdLG
X83FWcjAUca+T8W+SMK5R8G4Qb+2AP//AP9/P7+/Pr21P79/N7uyLLuyAL+/AL9/lbDLf6rKe7Lp
drHqcazxba3gZ6bmZaXlY6DdVar/UK+vW5/iWZ3hVJvhVJjdTZbfNreuL7GoN66oLLKpI7ShKayj
ILCmIq2jH6yiIaqfHqqeI6mfIaifIKifIKeeH6igIqadH6aeH6OcGquiG6edF6eXFqadAKqqGqSc
FaOaFKSbE6KYEaOaEaGXEKWbDqOYDqKZDqGXEqCXEJ6VD6CXD5+WD56VDp+VDp2UDaCWDZ+VDZ6V
C5+VC56UCZ6WCp2TCpyTCZ2TcoT2SZHZR4/VQZDfQ4vTQYvVP3//P3+/P39/OYnYPIjKNobVNYTS
NoLNNoHMNYHNNoDLNn/NL4fUM4LOM4HONIDLMn/NL3/MAH//AH9/M33LMH3LLHzLKXvNKXnIJ3nL
KnjIJ3bGJnfHJHjLJHfKJXbIJHbII3bIJXXFJHXGJHXFInXHJHTGI3TFI3PFInPGIHTGIHPGIHPE
H3PFVVWqEWS3AgEBAAD/AwAAAgAAAQAAAAAAAAAACP8A/wkcSLCgwYMIEypcKHCePHjt2rGbR4+h
xYXmyklzVOiNGTFkzLwp9Eias4soBZ67hoiMFRkPBhyYeWAAhBVZjKW0KO7ZoCwjDqjI4UOHDRo0
bOgIsqLKtJ0LwR26UuAEDx4pCBxI8UOJkh8pIAT4Qg4qwm/MzkAw8cMGhBJXyhBqROzYMWKNCIUZ
tM6swXDEshTQwWOEjDCMsKWbZ5BeOmfYCI7yw0mVrl4Xw0FSEgGIiwdfHIk7t5MXGyZa1ripQ4lT
J1CdDo7bTALIiRmDvokzy0qLgQsJFGjw0MUPKITMsEQIYiJJI9J+P0HpMCQGjBZdKJVCKG5MASAp
kkD/gu430hEQMF5Y0PJq+8F1h0TocDGjETq/AoHR4QCiQosQHsxBC0LOWGECDw8Mwg5+AgXjRgBM
dNEBDBdIkclB8AxCQBAjfPENgwL5ssUTfbyiRQVGIOBGLgZdg8UJN8jgSFkgjiIHJbOoYscHL2Qw
hXsDxXPICDw4EEY5IAp0ySkDsbIFBUNgMMcuBK1DhgM8lMAIPEn+gwlBvMyBAREMqGELQdFUoUIK
WEjT5UGdTNcBFJ8Q5IgMORBQRjtvGkSLGg280MIeA9VTyAM8HECIPX0W5IsbDBAhQRzCCETPGwPo
kEIjjRpUBwdDIMCGLwLBY8YBNvxATKcFRTJECwqs/8GLQO2QcQANSRzDKkGSMBHCAmic+Q87Ytya
664D9fprsKWeakMPqyL7j6uwrkHlP/VgqgMKjEj7jx2gigqMpYf6oGhFuwYTR6STVirQI3geQAaf
u96ShgIwsEDoQNJYoYIKVkCDrCdQcNDBE7ENZOUBPJCASDwEPdMlL3RkMAQDaAw4EDyIkMADBGGE
MxBaXbrSBQVEWDBlQdlkYQIOKzQSDjnMHNJNkrPcwUILGkhxXEHxDFKADyN4IQ4kVYTBJYinaGGB
EQq0waJBz2BRgg4qhJFEAIPUA6IsbkxAhAZPfPkeIinUYMMILqCACKP4yWIHC+hRIMctCGljzhck
4P8wnxDR+hXLHktsALUaqyCUDTJj3KCDDjukYEVkgtuxhAZHVCDFJQhdY0wYK5hwAAElCPDFOGa1
skobLGxwxAVN9MHKQdJYMw00yDBCiBlfJPEGxCnF0sodWkwAghEVxD67RfOwEw40xtw80CeX1EKq
o7WIQkcXIFhABAwKTNGHKl3O0kYXcdgRiSSSRGJHHGlAgQEFLxiRAQVqLPnmLFoEQAEHRWACE4zA
AQYkgDpjU0AU5JC4Pn3iCR8wwqtCEIIWDOF7HWCABabghky8olN+oAIIJIAABSxgAQpAgARY8AQ0
zAEUsNjVJTyxhziwYQ1oQEMa2BCHO3TCFTH01j8QfuGLXdjiFrvoBWaEiKyAAAAh+QQJBQD/ACwA
AAAAMAAwAIf////2/v/y/v7x+v/w+v/w+f/v+f/t//vs//vs//ru+f/u+P/t+P/s+P/r//rr/frr
/fnq/fno/fnq/Pnp/Pno/Pnn/Pjm/Pjm+/fl+/fk+/fk+vfj+/fj+vbi+vbf+fXf+PTd+PTs9//r
9v/q9v/q9f/p9f/o9f/n9P/m9P/m8//e9/Pc9/Pb9/Pk8v7j8f3i8f/i8P/h8P/i8P3g8P7g7/7f
7/7f7/3e7/7e7v7e7v3d7v7d7f3c7f7c7f3c7PvM///a9/Pa9vLZ9vLY9vLY9fHX9fHW9fHT8+/Q
8u3Z6/vW6frJ7+vC7OjB7Oi/6uW+6+a76eTT5vnJ4ffI4PfG3/bF3vWr497B2/Sh4dub3di60vWv
0fCmy++eyfOfyPCaxvGWxfKbx+aR39mS3deS3NaN3NaI3NWA19By08t1yc5qyr1lzsdizcVezMRV
yMBWxb1OxbpIxLlHwbgA//8A/38A/wA/v/8/v79Bv7Y/v6UwvrUAv78Av3+Rt9yGu/B/tet2sep5
seRxrepqqelopuVjouFHu7RVqv9VqqpeoOJanuJZneE4ua80urE2t64vsagmsqkxr6gpraIkq6Eh
rqMfrKIdq6AqqqYiqJ4hp6AfqZ8fp54fpZ0eqaAdpZsaq54XppwAqqobpJsWpJsUpJsTpJsTo5kQ
pJoQopgOopkNopkWoJgSoJcRn5YPoZgPn5YPnpUOoZcNn5UOnpYOnpMNnZMMoZcMn5ULn5UJoJYK
npQLnZMJnZN3jehUmuFQmOBMlNtIk95IkdpGkNZFitFBitM/f78/f388i9k8iNI9h9A4hNA4gc01
hNE1gs4oj782gcw0gMwzgM00f9A0f8svf88Af/8Af38yfcotfc0xe8orfMwpe8wqesopeMknecwo
dscmd8gleMkjd8sldsokdsgjdskldcUkdcYkdcUldcQidcckdMcjdMUjc8Yic8YhdMYgc8Ygc8Qf
dMdVVaogcsQJXrIDAgICAQEAAP8DAAACAAABAAAAAAAAAAAI/wD/CRxIsKDBgwgTKlwoUB48d+nU
uYMnj6HFheTGRQM26E8YL17C/Bn0K9q4cxdT/iM3rRAYKi8WDDBA08CABS+mfCk0rZtKheOcBbIy
wkCKGjtsyIABQ4aNpCkUjLBCyNvPg90KWSlwIkcOFDRR8FiyhAdYAyhw+AgQaN5Vgt6SiWFggocM
BiSqgAm0aJgxY8MYDQJjxYSAKczeDvwmbKuNHCJcdFEkzVw8g+zMVVPEJQw6xf++AVvSoIeLBVx+
fSvH8Jw3YdkUhxO2hESPEy8EcQOn0lnBTqYuJrPSwIcJJYzIgR5IKc2cULIUfvtS4LYSYOKWC7QV
JwCIK2kelf/SZbBdIRE2XMxglF37v1hkKgS5kMBIljSQPhF0RsVEjgWCmOOeQJEw4QELLRBxQQda
PKKfQO8AUoAPInDBzYD/5OIGBUSE0MIFWUyiSigESWPFCTK88Ms6GLaShQAXfDDfFSQSJM95OTDQ
RTgY/tMIBk7AoUUEQ1QQBy4EofOFATmQoMg7GLoCBxuf9HJIBkQgYAYtBEUzRQooWDFNj5V4oopA
lDThQQdQdELQLzDUQAAY6pBJECxkQNACC40MJM8gC+RgQCD29FgQL2wkQEQEbvQi0Dx/DGADCosY
apAcGwxxQBq8COROGAbIoMMwlhbUiBAtJHDGLAKl44UBMCj/YUypBEGCRAgOjMHqP+q8GuustApk
K666CgQPqDTcEEywAj0yBAuq1tJQpDiYoAiz/8zRgaZp7CKQPYMwsEMBgVRE6y5sPLBoowMBEwMN
CnzB4kC+YRiLGQkEsUIeJVKBQgqICcRSYhhyAoUHHjShCUHqgMEkCYbYk00ghvA44CxxYDDEA2S4
QlA8hTCAg46FUFECMD2mMiQRFbyx60DabEFCDS6MEMCOUeaxAgsaQLEJQdqMswwXJNAAww4MDAIP
hqFcUYERCaRhy0DZDNMFCiTkQIMMKkihDIaysDHBEBo0UQlB2RgDCBc/EECCDQx88Zl7r8yxgowU
vBGLQfR4/zMMIFu4EIAh7riXSiNIcAB1GacodI42jABC8HKrzIGEBkdIAEUkF3UTG0GWqIQKKWys
wMERFyThSCuKcbIHKbcwtMopeVwxwQdGSJBEHqwrFssZV8jRCSzeFqTLK5zEoQUIFRARRAJRONI4
aJQwIUAGUJjRxhyPQALJI3OwYQYUGFDQghEZUFBGJKQsh6gARwzRwQMPdGBEEkkUMT8EHgxBhAYJ
eMIbgqMdUrzhCRZ4gAeCQIRnhSAELPBfEDzwAAtEgQ2WQAWGSuGJN5ChCSCIwAES4AAHJOAAEViB
E8rwBjOVahWq0EQe3ICGM4xhDGdIgxvyoIlXrAJbAskFLg1mEYtYzAIXuQAiswICACH5BAkFAP8A
LAAAAAAwADAAh/////v///f///T//vH6//D6//D5/+/5/+3/++z/+u75/+74/+34/+z4/+33/+z3
/+v/+uv9+uv9+er9+en9+er8+en8+ej8+ej8+Of8+Or2/+n1/+j1/+f1/+j0/+f0/+b7+OT79+P7
9+X69+P69uL69t/49N759d349Nz49OT1+973893389z389v389v28uPy/+Tx/ePx/uLx/+Lw/OHw
/+Hw/uDw/uDv/d/v/t/v/d7v/t7u/t3u/t3t/Nzt/tzt/cz//9r389r28tn28tj28tf28dj18df1
8db18dPy7trr/Njq+tHy7sXt6cHs577r5r/q5bvp5dXn+Mrh98jg98ff9cXe9sXe9Lng66bh25je
2LnS9K7P76XL8J/H75nP5pvG8ZfF8ZW/6I3kyY/c1ojc1YbZ0nfWznnSyGzPx2bOxmHOxnzF0WPI
wljJwFjGvFLGvk3FvErDu0nAtkXAtwD//wD/fwD/AEG/tj+/vz++oznCqwC/vwC/f5G28YW7736x
5Hex6niw4Xav52+t6mmn5Wam5Wid31Wq/1u2tlWqqmCi5Vyf4Vid4T+6szm5sDS5sDK0py+xqDmv
oyS0qimvpSytoSGtozensSenoyOooCGpoCClnR6qoR+onx6nnx6inBiqoBmnnRamnBalmxekmxGk
mg+kmhOjmg6jmACqqhSgmRGhmBChlg+hmA6imQ6hlhGelQ+elQ6elQ+dlQ2hmA2flQqflAyelQqe
lAydkwqdk1Oa4FCY339//1aT2kmT3UmR00eN0kGK0z+B5D9/vz9/fzuK2TqH0DmG0zqEzzl/zDaE
0jSCzjWBzDSBzDSAzDKGzQOZkDGA0DB/zgB//wB/fzJ+yi19zS57yit7zCl7zCl6yip5yih4yid5
yyZ3yCZ2xSV4zCV3ySR3yiN4yiR2yCR1xyR1xSV1xCJ1xiZ0xCR0xSN0xSRzxSJ0xyJzxSJyxSBz
xiByxB9yxVVVqgxgtAMCAQIBAQAA/wMAAAIAAAEAAAAAAAAAAAj/AP8JHEiwoMGDCBMqXChwHrx1
6dK5gzePocWF5sg981UIkJgwX8QAKtTrWThzF1P+KxftUJgqNBYQOEDzAIEFMqh8OQStnEqF4JoJ
wvLgwIcbPHLUmDGjRo4eOT4ceIBFUDNwPw1yM2TFAAcePD4oOODBBxMmPqQW+LCDB4cCVg5lyypw
G7IvDDb8qMFAg5UwghoFI0YsmCNCYq5oYFDjBwcCgKhl/RYMi4EcPB7E8MIo2rmKBeedi8bIi4wH
Px4QEvfzm68pqGEs6NLrG8qF5L716iKgi7ef3oJN0fCjAw1B27CmBLctkCN1P5FdeQBkAxNHt7Ny
w/az2xcDxZn4/wpHt3w7Qw5ywKDhiFx5hKFEnUrYrMoGHgsIoXuP0NKZPLAcFI8g4DXQxTb8HTSL
GgK8cEYlqBQEzRUc2CBDL6wlWFAkSpyAQgJNrFHKLgK9c8gDPDDgBXkaEtRKGRAIgQIRIgwQBRwC
pfPFATxowMg7LQ4kSx0mpIACCiYQEcUWawj0DBUffHAFNEEONIoUApjgQgsiPMHJLbwI1IsMOBQQ
RjtV/iMLHFKg8UgZFLQwBCQD0VPIAj0cIAg9aVZiySi0TOPGBEVY8EaY/9ADCAE5cNBImp1UQtAc
IxCBABok/hOPGAfcoEMwaRoEyQsuJHBGLgK1E8YBMywxTKgFSf+iBAoQlEGLQOis2uqrsA40yay1
3qqpGAbccAOovQoEyRClmpGpogTwsAEjBCnDXZVzkGApGroIVM+dPShASD3tZEMMMmnqskYERUzA
BqL/+IKDDQx8AQwgWBiSYZC1lJGAECs8IhA98Dz5QQ01wBDAFXOl+QkUJJTgpUCEeHFFDkzNYKEj
7KSZixwgEBFBGbMIZAgWAnyAcQ4HhMFila1sQUERGMRxi0DxaEPIFAbMAAMTyFYpSx4mtBACFJ8U
NA4yY+AQQCDphEqKFhcgkYAamRZUTi9jKBNqLGpUQEQIT2CSUDfZXBukK3WscIIQhtaS7EGqPKKE
CFaXkcpPo8z/RxcsdSgRAhIUQCGpSkOqUYrfF51SihoriJAECE1EwspPqWgxgBZ5nBLgQrCckocW
FZxAeBOPtPKTK2tgYMQFJmwhRyevdFuQLq58IscWJlxQhBAJSBHJ3j+JkgYCeLdAAQhQlMFGHZFM
MgkkdKxRBhQgWOACEiFUUEYlppQ3yhtPJBBCEUSQEEEEJBzRRBNHkACBBCUQUUQICUTxBikJooKJ
GlDAQARKIAT0teBILbCfC0oQgQxIQQ2YiFCLYPGJOJThCSuYAAISAAEIJAABE2DBE8oQh098Lk2q
aMUm8sAGNJihDGUwAxrY8AhOvOKEc8PFLW4xi1ncQhe2m9vcAgICACH5BAkFAP8ALAAAAAAwADAA
h/////f///L7//D6//D5/+/5/+3/++z/++z/+u37/e74/+34/+z4/+v/+uv9+uv9+er9+en9+ej9
+er8+en8+ej8+Ob79+T7+OT79+P79+P69uL79+L69uH59d759d/49N349Nz49Oz3/+z2/+r2/+n1
/+j1/+j0/+f1/+f0/+b0/+bz/t73893389z38+Py/+Px/eLx/+Lx/eHx/+Pw/OHw/+Dw/uDv/t/v
/t7v/t7u/t3u/t3t/Nzt/tzt/dv389r389v28tn389n28tj28tf28tj18df18dnr+9T079Ly7tDx
7cvw68Hr58Ds57/r5r3q5bzq5dbp+svi98jg98jf9cXe9cXd9Lvh66Xh25nf2LvP7KfM8aHJ8J/G
7Z3I85rL2JnF8JDd15Hc1pLa1I7d14jc1XvY0IDSzHXQyW7RynzG0mfNxl3MxGDFvVjIwFTHv1DF
vUzCukfAuELAtwD//wD/fwD/AD+/v0C/kgC/vwC/f5yzyYa67IS463uz6nqw5nut3nWw4W6s6W6p
5Gun4WWm5lWq/1OxsGCi5Fyf4mCc2Fmd4VWc4kG+tj28tDW8sj64sjO1rDSwqS24qyOyqTCwpSqt
pCGtpDOrpSqqqiWpoCGonyGknB+soB+onx+nnh2tohqonhynngC2kQCqqhmkmxalmxijmxWlnBSk
mhKkmhCkmg6jmROimBChmA+hmBGglw6imA6glw6flQ2imAyglQuflRCelQ6elg2dlAyelAqelQud
lAmck1KZ30+Y4VWZzFWU3X9//1KMzkqV20mS20iM0kWIzkKK0j9/4T9/vz9/fzqK2z6H0DeF0jqC
zjOCzyKMvzSBzjGBzTR/0DSAzDR/yjF/zgB//wB/fzV+yTB8yi18yit8zCt6ySl7zCl5yil4xyd5
zCZ4zCV4yiZ3yCV3yCR3yiN3yiR2xyV1ySV1xSN1yCN0xiR0xCNzxSJ1xiF0xiB0xyFzxiJxwlVV
qh5xxABVqgMCAQAA/wMAAAIAAAEAAAAAAAAAAAj/AP8JHEiwoMGDCBMqXCiQ3rx47NS5kzePocWF
6cpZ+zWoT5gvX8L0GfTLmrl0F1P+QzfN0BcqMhQMKECzwAAFMKh0MWQNnUqF4579uSKigIobOnDU
iBGjBo4dN1QUEGHlzzNyPw2CM1RlgAkdOlLMPMFDihQeJ2ymAGuCQBVD4LIKDNfMi4ISPWosIGEl
DCBGxpIlM8ZoUBgrJBbU6FFCgZdm336GK2aFAA4dDGB0SXRNnTyD8tRZS9QFBoOkBK4UM5dSHDAp
DHq8UMDlV7hyDMuF+8VFwYseIqQ06mZRXDEpJHqgoAHI2ziV47wBgpFiBwFC4iw2s8LARwkkjHzK
/0XHSEoAP1gZgvNCQDkSYLjlCmzHKIw3i+8MicDxggajc/IR1E0zFz1DRQk6KAAIgAFmBc8f7YnA
xX0NZjWNFSbYAEMj7FSYkCmngKafDgtwwZqHB70ihxy1FMTOFwXoQEIi9KBokCuQJNHBG6wQZA0V
KqRAxTQ2GlRJFBaAUEEaqwz0Sww2FPDFO0USJEoWEAjhQggOkCHKP/cMsoB1f9RY5T+yoNEAECCA
4EIHATTxDz19DJBDCYqc+c8paQTAQQgghMBBE1po8Y87YRBgww3FnAkKJWy0MQciRPzQABq+4HIo
jDP4YEyVoGDSCS+++HJJEiE0UEYsApkDYw1IJP9zzz30XPPMNVVKgqqquvzDzj19FGCDDosUBkgz
1pwZSRA/IGDGLv9wwcUUKyw1wwrnUVilHBgMYUAavfxTRQAvLBUDDgX0EV+VvbCBABEUtOHLP9iE
UcAMThUwoZ7/4CLGAz+08MhA4PgxQgwkXEEgv5w8wQEHToBC0DiFrICEMdnpqUscFgzhgBiaEpSO
Ioqow+8/sWgRAREVwJGLQd8Qxy8ujnzgAgZRfHJyQqlkUcERCKjR684GzcLGBENg0AQmF1Viioew
zMGCB0BQ8EbIC4mCxhy2NAjLI0pkADQZqljESp9LzNGKfLLMocQFR0gARSUWueKGA0VswAIbqTT2
mdIqqbDBgtgWLAGJKxaZQscSEhzhwQRZOLLK2gvVsoojWUzgQdxLPIL4Ra9AEgUCQBAhwQdayAHK
LLwYxAssoMShxQcSEAEEAlAc/hMqlZABAQZHuBCBBU+UwcYcklhiiSRzsFHGExZQ4MIRGEBARiUh
ypXKG00ggAERQ2hwgAMaGKGEEkZo0MADHAxBBAYIPPFGKhWygokaUFTgAAelD+FCmz9w3w844IAK
QEENmOgRimTxCTiMoQksgIABENCABiDAABBogRPGAIdPUK5KrXgFJxzRhjOYQQxiMMMZ2vAITsCi
RUT7hy1uoQta2JAXt4jhzgICACH5BAkFAP8ALAAAAAAwADAAh/////L8//D6//D5/+/5/+3/++z/
++z/+uv/+uv9+u75/+74/+34/+z4/+r9+en9+er8+en8+en8+Oj9+ej8+Ob8+Of7+OT7+OT79+T5
9uP79+P69uL69uH69uH49OD69t759eD49N349Nz49Oz3/+v3/+r2/+n1/+j1/+f1/+j0/uf0/+b0
/9/39N7389z38+Xy/uPy/9328+Px/eLx/+Lx/ePx/OHx/+Pw/OHw/+Dw/uDv/t/v/t7v/t7u/t7u
/d3u/t3t/Nzt/tzt/dv389r389n28tj28tj28dj18df18dvs/db18dPz7tLy7s/x7c7w7MHs58Hr
5r/r5tnq+tfp+9bo+c/k+Mng9sjf9L3q5bzq5cbf9rHm4abh28Xe9cTd9MzM4LTT8qfM8bLF55/I
757H7Z3I8pnd2JPc1pDe2I/c1ojc1Y7S2JvG8XnTzJfD73XExGzPyGzNxWvKw2DMxFjJwWTCu1XH
tVHFvQD//wD/f0nCukfAuEq/tEG/tj+/vzPMzAC/vwC/f4i664K16Hyz6nyx53iw53Ww13ut3WSy
1lWq/2OqwEa4uGmo5mWl5mGi5F6e31md4V2b2lOa4FCY4D69tDu9tDW8sje2rTCxqDOtpSi1ryOy
qCiwpiatoyCsoy2lvCOqoSOroCConyOnnB+nnSClnB6toR2qoBqqoBunnhqlnRWmnBOlmxmjmhOk
mhKkmRGkmg6jmQ2jmQCqqhqinRWhlxOimBGhmA+imA+hlw+flg6hmA6flQ6elgyhlwuflQ2elAqe
lQmclHWE90+X30uR2EiU4EiO00SN1kSJx0WHzz+D5j9/vz9/fzuI1TeH1zaF0jmCzjWBzDOD0DKB
zjKAzjN/zjR/yC5/0AB//wB/fzJ9yS99yi17xyt7yyl7zCt5xyl4ySp3xih5yid6zCZ4yyV4yyV4
ySR4yyV3ySR3yid1xyR1xiR0xiN1xiN0xCJ1xyF0xSFzxlVVqh9xxABVqgIBAAAA/wMAAAIAAAEA
AAAAAAAAAAj/AP8JHEiwoMGDCBMqXCiwXr14797Nc8iw4sJ27KpVekQIzpkzcAg9slRN3TqLKP+t
ywapDJYZCwQQmElAwIIaWM5AutYupUJ00wx9IUGAxQ4gPHLQoJGDB5AdLAiQAGNo2jmfBsU9yiIA
hY8eK2SqCFKlShAVNVf48IFiQJZH4rAKDCfNzIITQnIwMPHFDaJJyJYtQzYJkRsuJhjkEHJigRlp
4XySSwZmAA8fDWaMiYTtHT2D9d5lizRmRgMfPAZ8SWYOJTlLVhoIibFATCVz6RiyM1dJzIIYQhpY
sUSuYrlkVkwISWEDUbirKM+FQ4QjhRATVpKVYyiNS4MhJ6hM/+opt90kKieGNPgibaE5MwOWUzmm
Tu5AdceopFgiYExkhPI8sgAPMdgwCTv2EcTOJNWdUMg2CU2DxQk+LHDIPAkWNM8hKjyCTkLyGDLA
ECSI8V+GBE1zDHQIYQMGCjrAMMk7KBakDYQgQlKCDwyMUVyNKb3jBgE+lACJPECmVA0XK7CABTVJ
JoQKKgUdk4MOCpRBY5QGxeIJKAS98wgDQAhgyGdcEjRLJ1KsMYtA49yjCJEoTHJPmgPN0gcUFUgg
By//iAEHGCnQoAMlyizTTDXTVJMkLXW0oIERIGSQRy9LBMDCDUvF8AMMhEgDJZCrvCEBCESIQMQH
T2iCjBUw6P9gaAwkEIJNkqWE8oYHSIAggggjdBAAE+9EogINbNnwSG5A5noKKJtsgkcRImjQxRpd
/MOOISSUYMUkH+L5TzF/bGAEAnQUg4tA58CBBWviCjSMHAccEYEdvaQYTWvx/tNLGg4Q8QImBXnj
Tb8CkRIFBxxMcQrCBw2ThwVHGLAGMBAbpAsaERxhQR7DKLQKlVH28kcIRGCwBSsKxYLJKFy64gUF
SiQgB8YI0WJHBnMEk6Qvc0BwBAZThJJQqRloIEMfgKLISx8ugFDEvfki5AoaBzChgROY7JLhLpg0
oYESB6Qhy0KebDEBExc00Ycv9tHSRxMXKDGBFp4whEsmT1T3oLULc7jyJkqxuDKHCxowUcETmazL
UC6YPDGBEiBA4MUfs9TCUC2z/OEFBCDY/QQmuaCUSyZaHFDEERO0gEYep/BCjEHC8HJKHmiEMMER
RRywRSax+OSKJwBjoMQLEVgwxRp18KFJtJrwUccaU1jwwAtKYOBAGp7AYt8rdkhxAAZHGMHBAQhs
kIQTTiSxQQIGmDv0AVLY8QqKs4QihxYUJMABEeVLlQheYATecSABFNCCHEIxuBrRohR5WEMUXuCA
AqAPAQcogANcEIU05KEUtMBTLXZRikvU4Q1sUIMa2PCGOlyiFLrQHMSEQYxf2HAYxBBGxuIVEAAh
+QQJBQD/ACwAAAAAMAAwAIf////0/v/x+v/w+f/u//vv+f/u+f/u+P/t//vs//rs/frt+P/s+P/t
9//s9//r//rr/frr/fnq/fnp/fno/fnq/Pnp/Pno/Pjn/Pjr9//q9v/q9f/p9f/o9f/o9P/n9P/m
/Pjm+/fk+/jk+/fm+vfj+/fj+vbi+vbg+fXe+fXg+PTe+PXd+PTc+PTk9P3k8v/j8v/e9/Pc9/Pb
9/Pk8f3j8Pzi8f7h8f/h8P/g8P7f7/7e7/7e7v7d7v7d7f3c7f7c7f3M///a9/PZ9/LZ9vLY9vLY
9fHX9fHW9fHU8+/S8u7Q8e3a6/zZ6vnI7+rA6+a+6+a86+bX6frV6PnL4vfH3/XF3va86eS84uyp
4tyi4dzF3fS+2fSy0vDGzeeozfGhyvGex+2Z3tiT2tSR3deP3NWJ29Scx/GZxfCXw+581s50yr9v
z8drzsZkzsZnzMBmw8FZycFVx7xSx75PxLtKwrYA//8A/38A/wBHwLhBv71Av6s1v7UAv78Av3+E
uOx8sul8seR2sOR5rN5wreptttpVqv9ttrZVqqpItrBwpuBop+ZlpuZho+Vind1boN9ZneFUmuE8
u7Q0u7IxubAztKs1rqYis6ktr6UlraMmrKIrq6Ajq6EhqqEfqqIfqZ8kqJ8hqKAfp58fo54aq6Eb
qJ4cp50Xpp0Aqqocqo0apZsVpZwUpZwXpJsTo5kRpJoSo5kQpJoPo5kJpYEUopgSoZcQoZcPopkO
opkOoZcRn5YPn5UQnZQOnpQNopkLoJYLn5UKnZNXmeFPmOBLld9IlOBNkNVFkN1IiNBAjto5idk9
iNI9hs49hM82hNM4gtw3gs83gsw1gss/f78/f38zj8Izg9EygtI0gc0ygM0zf80zf8gvf84Af/8A
f38wfcoufcwsfc4se8spe8wqeMgpecopeMgoeMknecomd8kld8kjeMokd8ojd8omdsYkdscjdscj
dMUidskhdMchc8Y4ccZVVaofccQAVaoDAQEAAP8DAAACAAABAAAAAAAAAAAI/wD/CRxIsKDBgwgT
KlwocB69eBDhOWRIceG6dNEiEfqD5syZNH8IDZOmrl3Fk//YYWN0hgqNAwIKyCwg4ICNKmcYZWOH
UiE6Z4C2ODDwQUcPHThs2MChg0eODwUybAHkDF1Pg+MWVRnQgceODzE/+JAixYeHAkR58OgwoMqi
cVcFilMWZgGHHzgWaLCChhAkY8uWGYNE6EwVDQtw+OCwIIwyuCjLFdsyoCkDGmAaaXs3zyC9d9ga
faHhgIeOAVuKnTtpbtgUBj9gHOgS6Zw6hu3OReqyAMYPBlOGrWZIrtgUDT8+1AgkrhxKdOIA1ejw
Q8OUYuYYKrPCAEiHJpB4xv9dB6kJByAOrChbWC7MgORNht2OKzDdsCbUB4SBfNDdogU6wEADJPPR
J5A6kNQAgw4NLBIPQs5UwQEPBwACj4EFvSPIATxwUIU1B8UDSAE+ONBFOBgaFE4XDjAhwB8PFpTN
Fhw8BYk7KRbkTiQvLEADINzo2IgGPCzwxXA5EpQOGF0Qw98/y5BzTxoG9LAAI/QkWdA3xYBjFUFb
fDEIFR98YEU2WhrkzEGBBODACzpk0AUz4MgTZJoJgcNFBzrYcAMMTFiRxjHKQIPnQe88skFSOrwg
ABWCQIPNoQiZ84UDOhzQxB/WdEapQLaQQtA5xLywQRjHrPPpQLLM4QYtBJH/I0gj4q0qCyVlhKDC
JLAOdE2BlP7iCRtJRDDEBWK4smpBn3DihhMIoCAECy2QQIctywrUySWUmBFFEii0wIIQI2ShSrYD
mfKLKptkgYEQKFwQwBoHebJqKVeYcMITcGhxRUGxnMLHuYf2MocFRTxgRjC0aEIQK5NkIUYtlNKi
hQVEhEAHxQSVwoYKFqggiS547pKHCjOEcIUpBvWiBgFJXJDFKnieksUFRyDQRi/1PjECERW0kYuW
ubBRQREiQGHvQbzEYYEQKcSQB7Yp2nLyCkJYIMcuCbkyRgJHlKCEJLJgKIskSZRwhAJjKKvQJVBQ
cIQISuSBC3245JGECEdQ/xDFJQzRMskSICBRQgxtrPIKSq+s0kYMJSABwhK8UgSLJEvInUIFWeQB
iy8M3fKKJFlUkELfS0jituWTXJGAEEVcoIIYdIiySzAG/ZKLKHSIoQIFRQiRwBWTrF5RK5eMIcEI
R8xgQQhQlOFGHpVggkklebhRBhQhTCDDESNIMMYlrdDHShxPJDBCEUScEMEDJhihhBJGmAABBCYQ
UcQICTwRByspikUn2nAFDEDgBDNgnwxYwAIZ6E8IJ4DABaLABk7EQku4EMUcyvCEGEgAAQl4wAMS
gAAJxOAJZJjDJ+52KF/cIhSSiIMazEAGMphBDW6QRChsMTR0AQMYvdjFLgd68UN0LSsgACH5BAkF
AP8ALAAAAAAwADAAh/////f///H8//D5/+/5/+75/+74/+3/++z/++z/+uv/+uv9+u34/+z4/+r9
+ur9+en9+er8+ej9+ej8+ej8+Oj7+Ob8+Ob7+OX8+OT7+OT79+P79+P69uL69uL59eD49N759d74
9N349Nz49O33/+z3/+v3/+r2/+n2/+n1/+j1/+f1/+f0/+P2+ebz/9738+Xy/ePy/9z389v389r3
8+Px/eLx/+Lx/eHx/+Hw/+Dw/uDv/t/v/t7v/t7u/t3u/t3t/dzt/tzt/dvs+9P7+dn28tj28tf2
8dj18df18db18dTz79Hy7tbs9tbp+tXo+c3w68Hs57/r5r/q5r3q5brp5LTn4sng9sbf98be9MXe
9sTd9a/h4qPg25bf2ZPc1sbU77jV8rHS8aLK8Z7H75fO5ZzF7ZfF8pK/7I7c1orc1ovY0XjVzm3Q
yG3Ox3DIxYG93WHNxVjIwGbAvFPGvk7FvEbGuEfBuEe/uEC/tj+/vwD//wD/fwD/ADTErTi9tDa7
sgC/vwC/f5K45oC16nyy6Hew5ner3muq52Wm5mWf316h5FWq/1asrFqd4Vid4lWb4VKZ302W3TW5
sDm1qjavpy+xqCi2qiOzqSSwpy2qpCSroCKspR+soR+qoCCqnCejp0eV4iGooCCpoR+onyCnnhuu
nx2qnhqnnhqmnRSmmxylmxSlmxqkmxOkmhGjmRKjlhClmg+jmACqqhehmBOhmBKhmBCflg+imQ+h
lw+flQ6imQ6hlw6flQ2imAyglg2flQqflQ2dlAqelViO4UiOz0eO2UOJ0T+L1j9//z9/vz9/fzuL
2zmI1TyH0jiG0zWE0TeCzDWCzjZ/zDKEzTSBzTGBzTOAzDJ/zzJ/ywB//wB/fzJ9yi99zS97yCx9
zSp7zSl6yyh4yil4xil3xid6zCV4yyR4zCZ3yiV3yiN3yyZ2xyR2yCR2xyN2xyV1xyR0xlVVqiJ1
yCN1xSF0xiJzxg1htQMCAQMBAQIBAQAA/wMAAAIAAAEAAAAAAAAAAAj/AP8JHEiwoMGDCBMqXCiQ
Xj147ebBq0ePocWF6tJFi4QIzZkxY84QQhSpWjp1F1P+S1ctEZkrNQwMIECTwAADN66QSXTtnEqF
5qAVylKigAseP3jksGEjB9IdLgiY2FIIGrqfBsEhyjJAhQ8fLGiyAOLECZCwBFh8VTEgS6JwWAWG
a2bGQIogORic0HLGkCNjx44Ze2SIDJYTDHIAScHATLNvP8WF2jKAh48SNcYsysauYkF67a4tGgOj
hA8eA7aEgntRnKQnJYLEMCAGkjhzDNOJgyTGQIwgDZ5IEmdxXKgnJoKwqFEIXDmV5b4VqrEiyIkn
ocYxbLalgRAVQxyh/4yrzpGTFEIaaGG2UJyZAcqHREoXdyA6SU6qDyBDnGC1ge8kQoIOMcCwCDv1
EcSOIzXEwAMJiMxD0DPDvcONFij8YAAhCCaooCEG+JDCFc8QRI4ZYkhySAE/NBAGZB4W9I0YJQgx
QCH1DESPIgHkIEQMNsTwCDkxFrQOJDXkoIIW/w1UDRYq2MDDCS/iViRB64zBwGWJ5CjQPGgM0IMN
OOhA1THSXClQPYucIEQJZMBD0CMu6MCDDScEUAIazDDTZJHXYFFAAFhcQ1A3YQxgVBiEGNNNmmr+
A48ZVxAiCTQE1UOIE2hA0o08kRLETSjXgGpQKNGYGmpBmCJk6Kqwxv8q66yhkpIQJ7T+88smlxz0
Syl/rBLrL6nkwQYTbAhDECeAsBFFGspGOgoqk7RhhQcOHGBFKwSRIsUBDkhh65WiYHLJGhUEcIEI
NMzgwR0E6fIFBUlcUAcwkXpiiRtVzDACuwis0ctAwNBBgREQeGHLqrKkwoUFNIiggbjdUqGBDC/k
cUuotOARggggLCFDAHQMM5AwbSSQxARdqBIqKlxAcIQDc0zCxRe1LBuFBkVE4AYvavLixgNGYFDF
KrfUAkgm8cpBAQ0gvIAHLkXycscHIcxAAR0bCzRKQa58ofIGS/xBdYK45LFEB0kcsMYrC2EyhQRK
ZLDEHb7UJ8sdS2j/oAQEVTC9EC2AMGGBEhu84AYrcKf0CitufLCBEhZAMQktFr3yBxQSJAFCBF3k
4QrQC+HySh5dRABCEhJA8UfOF7kCSBUJ0GDEBB94UUcpuZhc0DC6lFKHFx9MYAQNCVQxiSs/sYLJ
FxFokMQMEVwgRRpx3DGJJZZMckccaUhxAQQyJKHBA19kwkp9rMgxRQIaGFFEBwsswAESTDCRBAf1
c1CEERpIgBTksD4PxaIT/LLAAjpguyLIQAQikMH/aEA/ClChDZyIhZp2QQo6pCEKL3jAARKgAAUk
4AAPCEEUvkAHUuwCVr7IhSjyEAc2qMELXlADG+KQB1HIIm+5+gUwDYChC10AIxjByNWsAgIAIfkE
CQUA/wAsAAAAADAAMACH////+///9/7/8Pr/8Pn/7/n/7vn/7vj/7fj/7Pj/7ff/7Pf/6/f/6vb/
6fX/6PX/5/T/5vT/5vP/5fP/4/L/4/H/4vD/4fD/4fD+4PD/4O/+3+/+3u7+3e7+3e3+3O3+7//8
7P/77P/67P776//66/366v356f356fz56Pz56Pz45/z55fb75PH94/H93O393Oz65vv35Pv34/v3
4/r34/r24vr34vr24fr24vn13/n14Pj03vf03fj03/fz3Pfz2/fz//8A2vfz2fby2Pby1/bx2PXx
1/Xx1vXx1+v40vLuzvDsxu7pweznv+vmverluOjj1Of50ub5yeH3x971xd71teHnp+LcnN/Zl9/Z
kt7Ywdv1ttXzvs/rpszwocnxnMvtmcXwmMLsiO7rjNzWjNrThNbQctXOcs3CbM7HYc3FXM3Fi77v
bMS/WcjAU8e/TsS7ScG4R8G4Sr+4Qr+2AP//AP9/AP8AP7+/P761QL6qP79/N7yzAL+/AL9/jKvP
fbPpe7LodLDscK3qdqvgbKzgZ6bmZKDaY5vUVar/VqysX6HaWZ3hVpvhVZreUpnfObavMbqxLbSq
MK+pKq+lK6ukI7SqIa6lIKykIaqhH6qiTZfgR5PfK6OvIaefH6ifH6eeH6OeHKyhHKqhFaqUG6ee
HaWcG6WbFKWbGKObFaSaE6OZEaOaEaKZD6SYD6KYDqKZDaKZAKqqFKGYEaGYD6CXD56VDqGXDZ+W
DZ6VC6GXC5+VDJ6UCp6VCZ6UC52UCZ2UZIjXSInNQozWQYfTP4/PP3//P3+/P39/OozeOojUPIfN
OYXSNYbJN4PSNILQNYHMNoDMNIHNNX/MLobAMoHPM3/MMn/MKX/NAH//AH9/MX3KL3zKLHzLLHvJ
KnrKKHnKJ3nMKXjJJnjJJ3fHJXjLJXfJJHfKI3fLJHbII3bIJXXGI3XIIXXHJHTGIXTHIXPFInLF
IHTGIHPFH3LGVVWqDV+yAwICAwEBAgEAAAD/AwAAAgAAAQAAAAAAAAAACP8A/wkcSLCgwYMIEypc
KHDeO3fr1rmDJ4+hxYXoxkF7NIhNmC9fwrAZ9CjaOHQXU/47J83QlykuDgwoQLPAgAMupoQxJO2c
SoXhnAGqsqBABA0dNlyoUOHChg4aIhhYUCWQs3E/DX4zRIXAAw4cINCE8CJJkhdiB0AA+4AAFUPf
sgr0piwMAgceLiBoQCWMIEachg3jxEhQGCoNEFzwkFiMMm8/wXHaQmADhwUtvBiylu6dwXfprDHy
0mIBhw0EtnCKm9AZQXGboiT4QOEAl0bg0jFEB64RlwMUPiSIsklcQmjJsIrjJIXBBwgtAHULpzJc
t0AuHnxgEIWT8YPixBT/grdtC4IXD2AwKid3JaMkDl4kqKIMIT02AQCJGdABAgxH5rQnkDmPJAHB
BwR8Ac5B8wxyQAMPZEABBIsEKOCAjLhAwQYKGLLOQY9UkMGIDBDi2YUDpRPIARw4MAUzBy0jRQQX
XDCBF8Owg+JA3XCxwAsDAOKOQd5wsVYFFAjQQiDP7PjPOo+4gMEDVUhjkDteALCABFFs4QUbnCQD
zY7keGHAZYbAUxA5g4QxSCPEcLMOPdc4+Y87jDTAgQFffEhQNM/EU5GdBklTBQQRTDEmoRe5E8YA
GlTwCKMX0SNIAR4sMMg8lFrECAQWBMAGPZ0yxEkFUVAhCDkHaVLqQMk0/zIMN9VMI5AnopwyCR2S
vCpQNQfNkoYTSvAAia8JAWOGAD3UIAeyCAGzhgpFlKDGL9AelAcPQohAhi3ZGuRJEzfU4MQnvu7C
iyieFGSLFiUMEQMcudhZSi+1nEKJHGqUsQYtBeHyhgpEnJAFwChmYkkkZmABxRI3pBBAFuAW9MkT
MvzgQx4IJ5xGDiDo0AMRNUCRikG5pCHCESlcgYqdukyChcg/4LBEJQdd0oQMQ5iQxi0wtxEDEETz
kMdBtriBghA6+BBHLTveMkcOOgBBQwwmuNHLQatosfIMSuTxyoWw5IGEDUWMUAYaApix9UGWPHEC
EjIoEQcs7cESBxIzHP9xAhSm/OKGGaogNEskS6zAtw9poMKKSqygksYONiCxwhKRFM6KJe0itAof
S5xwhA4mXEHHKrEw5MoqdFxhgg5+L8HHLARhotAqkUAhghBEpLADFnCAUsvbBOELChxY7JACEd1C
EckqP6lySRkoxHAEENU7QYYackAyySSQ8EuGEzGcAMQRMqBQxiWFy4XKG06IIAMRQ9wQQgk1HKGE
EkbUUAL+QyCCDETghDe87EKswEQanqCCEtyAd0P4QQ968IMACuEGJVDBE9KACVfYCRafeIMWmsAD
E4RABCQggQhCYAIeNEELb/gE3igVi1Z4Ig9qOAMZtKAFMpxBDXnwRCsSUgetXewCF7awBS564Ytw
lSogACH5BAkFAP8ALAAAAAAwADAAh/////r///L+/vH6//D5/+/5/+75/+74/+3/++z/++z/+uv/
+uz9+uv9+u34/+z4/+r9+ur9+er8+en8+ej9+ej8+ej7+Ob7+OX7+OT79+L79+P69uL69uD59d75
9d/49N749N349O33/+z3/+v3/+r2/+n1/+j1/+f0/+b0/+D299z38+Ty/uPy/9v389r389v28uPx
/uPx/OLx/+Hw/+Dw/uDv/d/v/9/v/t7v/t7u/t3u/t3t/dzt/tzt/drr+tn389n28tj28tf28df1
8dTz79Hy7c7x7Mvw69fp+9bo+dTn+cLs58Hr577r5sDq5r3q5bvp5Mvi98jg98ff9cLg8sTd9aXh
3Jre2JLe2JDe143c1cPS363Q8aDK8r+/v57I8JPV25rH8pvF7pfF84fm4HjXz3fWz2/Sy2zQyG/O
xGXOxlzLw07LwgD//wD/fwD/AIe88GzCt1XFvUzDu0fBuE++tkPAtz+/v0C+tUG9jTa8sii9swC/
vwC/f6uwyn+p1n217Huz63uy6HWw63Ct6nGzx2in5Wam5mah3FWq/1+k6Fint1ye4Vuc3lOa4E+V
2ji3rz2zqTOyqi+yqS6wqC6wpyOyqCOtpCKroiWqoh6qoiKooCConyKnnR+oni6jsUeT3x+lmxmq
nxilnBikmxGkmhejmhCjmhaimRGhlw+imA6imACqqg2imBKflg+flg+elQ6glg2elRKdlBKckw6c
lAuelAmflQudkwmdkQuckwqckwqckgeckn9/30qP2EeN1UKL1EGK00WLyD+J0j9/vz9/fzmL3juH
1DeE0DqCzTaBzDd/yjSD0jWBzTSAzTOAzTR/zjGAyyyA1QB//wB/fzR9yjV8yTF8yS17yip6yy14
xSl4yCh5ySZ4yyd2xSV5yyR3ySN3yiV2yCN2xyR1xSN1xiJ1yCR0xCN0xCB0xSVzxyNzxSRyxSJz
xiFyxCFxxCBzxyBxwx9xxB9xwx5xxFVVqhNluQMBAQAA/wMAAAIAAAEAAAAAAAAAAAj/AP8JHEiw
oMGDCBMqXChQ3rtz5sydeyePocWF474xe1QoDhkvXsjEKfSIGblxF1P+ExcNEZgpMQ4MKECzwIAD
MaaAQQRNnMqBzwyGUybIyggDKWzswEFjxgwaOJamMDDCyiBl334iy0Zw2yEqBE7o0IGCJgoeSZLw
KDsAxdgTBKgc2qayWKhu/7olG+PAxI4aDkpQEUOoETBhwoA1IiTGSgkHNHiYcDAmGV2LwaxAqpeZ
gA0dJFh0WQSN3DqD68pFW+QlxggdOAhYuWuxmA0piaQY6DHjQJdG3nwuJOftUZcDLXo8WPII78Jh
S06USJHjBItA2rKm9LZtkAwUPUgs/wkF7nkSFjdqsFDiSPjPlY1+nPDhwAoy8ylo1CiRqOL7geI8
8gN4BIzhjULQzaBDDjkFc85/A5HTiAwt4DDCIekkJAwLAthkQAA2PKINhAKdM8gBOpgwhTMJISNI
IDAGIkgchyATFInadDFCDwQI0g5C0cBTz5D1xGMPONewSGI6j8RAwwlW3Ejif+B44YAOIyDizpT/
qbNICTkUAEaGXL4HjRUopDAFM2W+l44YA+AQwyMEjeJLL75s0iZC9BBSgA4HFHLaP6e0gQYaaeyx
J0KNoIDDAHHMI9AuWgDQwASRLHoQMDzQUAAZP/4DSxYUvHBEJZoaJEwSMxTghTkCjf+6QAhGUJJq
QcIsYeGrAtmyhQIrCJHprQNBIoIBAIgBj0C8mIFAEBvUQexAocS4yIj/8MJGBEI0sEYv0/7jjD30
2EMNQXl88IICW8QSbkKcMMHBBk588i5Co0IQxAV0zHKvQbnMUYEQEGChyr8GdQJFBit8cActU2Li
CSx39mJxL7noeZAtaShARAVXkDIlJ3zMcUYahx6aBh8JYdJEBkJIoIYsU5JyBwwBQIDAAgJ0YElC
scxhwQsefFAHLFPKMgkTIAQBRAhH/JxQKlp4rEEReawyJS52YOBCCB0YIXVCl0RBAREZFFEHKxCy
YscRHbjwwgdiL5TKHkdcQIQGH6j/QQoqKplCihofaBAEBxhkEDVDdx9xtgcSXJGHKa4wtIopd1wR
AQhDQMCEHUjAMLZCd0ehwAtCVPABFnSIAsstBt2iSid0YPHBwC8wEAUlvEQCxSQXnXLJFhNkQMQK
E1zgxBZr1BEJJZREUscaWzhxwQQuDIFBBVtckso/r+wxOkOmzPGEAjBDm0ADGwhhhBHQNtAAB0EI
kQEDUMxhCkGkXPKTKZhIAxQqMD/UBWEFIQjBCur3Ag404AJRSEMmAFcQTvyHFZ+YQxaYFgEEKGAB
C1AAAjbHBC3M4RNsS5UrVsGJPLDBDFvIQha2YAY25KETqqjcvXAxi1nAAhazuAUuBRBGrIAAACH5
BAkFAP8ALAAAAAAwADAAh/////j+//H6//D6//D5/+///O/5/+75/+74/+3/++z/++z/+uv/+uz9
+uv9+u34/+r9+en9+ej9+en8+ej8+Of9+ef8+Ob79+T79+T69+P79+P69uL69uH69uH59eD49N75
9d349Nz48+33/+z3/+v3/+r2/+n1/+j1/+j0/+f0/+P1+ubz/97389z389v389r38+Py/+Px/ePx
/OLx/+Hw/+Dw/uDv/t/v/t7v/t7u/t7u/d3u/t3t/Nzt/tzt/dvs+9n28tj28tj18df28df18db1
8djt+Nfp+tPz79Hy7s/x7Mrr7s7k+cDs57/r5r3q5brp5Kbk3sjg98ff9sXe9cTd9LLg5aDf2Zrf
2ZLf2ZTZ08HQ67LT863P8aPL8qLI7p3H8ZzF7pfF8pXD8ZDd1ozd1onc1X/U6nrWz3TUzWvSzIS+
5GvIw4i58mTOxl/NxV+/v1rJwVTHv1DFvUnCuUbBuEm7tz+/vz++qAD//wD/fzy9tDa3rja2rjC6
sCe6rAC/vwC/f6qn13yy6Hmy6XSv5m+t6min5WOl5Vyg412Y2lWq/1id4VWqqlKZ4EuV30qR2UuO
1jawpS+yqSyupiOxpyOpoCCupB+roCCqnyCooCConR+onzCmoiGnniCnnh+mnUSO10KL1DSUxxuq
ohesoxunnRymnBamnBSlnBmjmxSimBOjmRCjmhGimRGhmACqqg6kmg6imA2imRKglhCflg+glg+e
lQ6hlg6elg2glg2elQqflhCelA2elAqelAiifgudlAmdlHWB3D9//z9/vzqJ1jmD0jaF1TWE0TWD
zzSC0jaCzTaBzDV/0zWAzTWAyzV/yTR/yjOBzDN/zC2B0AB//wB/fzJ+yjF8yS18yit7zCl6yyd6
yyl4yCh5ySZ5yyh3xyZ3xyR4yyR3yiR2ySV2xiN2ySR1xyN1xiR1xSF1xiZ0wyR0xSNzxiJ0xyJz
xyB0xyBzxh9zxSByxVVVqgBVqgMCAQIBAAAA/wMAAAIAAAEAAAAAAAAAAAj/AP8JHEiwoMGDCBMq
/Fdt4Tx46tKlUwdv3sKLBbMpM1gunLNHh9yM+RJmjJtDj5yFQ4dxYTRR2QaWo5YozBQZCAQY2GlA
AAIZU8IgglauJcJoYERtO6eskJUSBljc4IGjBg0aNXDwuMHiAIkqhJKFM1pwFAsw4RBZIXBChw4V
Bwyk2IEESQ8VO1Xk0IFiABVE3cgOVHSiRhcVJnjYeFAiaKFGkUaNitTI0JgqJx7U8IECgZhjgY3W
K2QARwkapll4SeRsnDyD8sxVUwRGBgkdOAhYgQTOqDsyA3DYqMGiS6NuRReSA/fIC4IYPh4ggfSt
5bcuJnLgIIGWG1lv3AjN/1Dho8R0cRidIRGgIkaM6e0E/yPXCMmJHw+sHMMIyU0XKkCkEEAT+8lX
ziNAkDeAGKEplEw630QTSSKFfIHINvL9Y04jM8SwHSLrkAXPiNkcQ02G6RCCgA4nULFRhjAKxE0X
JPxAQCHvxAjjOY3IYAMKVpyoY4bifPGADiQkEuJAofzxCSuwWDIkQu4kYoIOBoThDkGbRMGEFGpg
MiVC0FChAgtTQEMQHx54EEAWvox5kDthDHBDDI8MNAwcEBgxARzAyGkQPYYYoAMCh9QjkDBpJBDE
BnYIelAjKuAggBsW/cPLGQu4MEQfkhoUSQ81GDBGjv/gogUDIShBSahlIf9BgwFfLKkqq67CStAo
sma55C+cilCEH7oONGqpY2z5D6OOQlqsQJRaiqlAe0IghANvCFNsPYeMEN0hmf7DxwcwLFAGLsW6
80UALLCQ50CbOMEBB090UmwyhHTRhBVqDuRLGQ4EcQEdvOiazDgRQhLTQL/MYYEQE2QBy7MJdQIF
Bi98YEecFBv0yxoLFEGBFKl0fBAmT1wAcRu5ZAiKJaHo0ksvZOEyBwUwgNBCHbdkuIocWaxBhx+h
sLKLmAu1skXIGiTBxywZWsJEABsY4YQUafyBkSVRSGAEBknUAbVgvvChRAggcFBAEpdgxMofS1hg
hAYttKHKK2Sp4koWEsD9EIQFUrDSEit8LCFBESBMIAUfr4ytkCut2CFFBy68AIMCZxQ8+B9RLACD
EBJ8kAUdodwSaEHA2PIJHVh4UAEMIVhQbrZkpWLJFhBgUIQLEVzwhBlv2NEHJZT0UccbZThhwQQv
EGGBB1K4kEEdGaoihxMLYCDEow44sMEQSijxKAMOcLD9BQ1EQYcsW3jwaoauYLIGFBSU/3kQLoQQ
ggtBCPECBw6wQBTegAlbrIISWPiEjmSxiTkkrwUQSMACGMCABSQAAi1wQhnocArHocJJU6LFKzbB
Bzik4Qxa0MIZ0gAHPoDiFbQwSCZCISlgAGMXt8DFL2a2EHuZLEMBAQAh+QQJBQD/ACwAAAAAMAAw
AIf////1/v/y/f7x+v/w+v/w+f/v//zv+f/u+f/u+P/t//vs//rr//rr/frt+P/s+P/q/fnp/fno
/fnq/Pno/Pnn/Pjm/Pjm+/fk+/fl+vfj+/fj+vbi+vbj+fbf+fXg+PTd+PTs9//r9v/q9//q9v/p
9f/o9f/o9P/n9P/m9P/e9/Pc9/Pb9/Pk8v7j8v/j8f7i8f/j8P3h8P/g8P7g7/7f7/7f7/3e7/7e
7v7e7v3d7v7d7fzc7f7c7Pza9/Pa9vLZ9vLY9vLX9fHO+vjU8+/R8u7O8OzZ6/vX6frV6PnD7OjB
7Oe+6+a86eXL4vfI4PbF3vW+4e+q496m4Nue3tma3tiS3ti70/Wv0PCmy++eyfSeyPGexu2YzuWY
xfGWxPKQ3teO3NWJ3NZ+19B008x2x9GKve5qz8dpyMVjzsZizMRcy8NUyL9Qxb1TwbRLw7tHwbgA
//8A/38A/wA/v/8/v79Bv7c+vbQ/v38wvrUAzJkAv78Av3/VqqqMsOOAs+Z6suh1sOZxrelrquln
puVjod9Vqv9btrZVqqpho+VeoONdnt9ZneJWmt88uLI2t64yuK0vsKYxq6QlsqgprqEgraIqq6Ii
q6IiqaAiqJ4fqJ8hp6Egp50eqJ8ep58fppwkoKsZq6Ebp58Xpp0VpJoQpJoWo5oSo5kSopsPopkO
opkAqqoNopkToZgRoJYRn5YPoJYQn5UPnpQOoZYOn5UOnpYNoJYNnpQNnZQLoJYMnpQKnpUKnZQH
nJJviPFOl99KkdlHkdlCi9RDidU/f78/f388i9g5iNk9hs06hM42hNM3gtA1g840gc0zgM00f9A0
f8oygc0xf80tf9IAf/8Af38xfsovfMctfMore80qecspeMcoeMkmeMsnecckeMopd8cmd8gld8gl
dcUkdsgkdsMkdcckdcUjdsojdcYmdMcjdMcjc8UidMYhdMghc8cgc8cgc8Ufc8UhcsVVVaoOY7cD
AgEDAQECAQECAQAAAP8DAAACAAABAAAAAAAAAAAI/wD/CRxIUKA1awUTKlzIsOE/YcESvoPX7py5
dOzgOdy4UB6gLOf+mevm7JcgM1+0aPFiRlCjZt/QcZwJDgsKZNgSeXkSI8GAA0APDEjw4skWQjBn
OgTWYwSWKw4OoJih48YMGDBk1NBRIwWCEFAAKeumVCG7PwNwkCBxA4dXAiVsHDmSAwVQFDhwmCDw
hFC2sgWxXSExo7ADEk62AFIETJgwYIwEeYFCwoEMHiUScDmmDbBARi1qyIDRIkshZuLcSSTnTFGW
Fw9w1CgA5Rc3wOL+BAiRQocIQvI2fuPWCIsDFzxCJLFdFlqyRFySOAjgJNpMbdkAxTDBY8RycIDR
hf8TJihLCUDslH5jdKQEjwdQjnkWiI7br0TSyob7dYR7AS6dzSfQNsdAU5Y4jMTgQg0hEDLOQqHs
IqBD5gCSAA4lPKGMQq2wocYlqVQy4ULZYBGCDgWgl1AnSxigxBh5fDJiQuM00oIMJkDhTEG3sFGB
EAZIYcqMCnmThQM4NLgOQbFY0QAQGbzBC5EJsZMICTgcsMWDA2WiBAcbMMEJlQo1AwUKKTzRDEF3
qODDAmHIQmZC53hBwAwvNDIQL2pAEEQDaUw5J0HyCHIADgkIEo9AvIyhABAbwDFoQoycUMMAZmj0
zy1iLLCCEI9MWhAwO8hwwBfp/QOLFQyAUEQkohL/JAwSMBygRUiqsuoqrLEKNGuttwrEqadAhNrr
P6Sa6kWqu5DxaKTH/sMICpeaseg/vazhJ6CCilrooYnOM1CbLCwAhpyx1kkADXkSlMkSHHDAhCa9
OnNmmmsOFEsYT17Qxi2izqNICVluSZAtPgYxQRWtiKoNFgLw8Nu1A3XSBAYsfGBHLINCY4wZTgTw
hHUF4XLGAkJQIMUokzLTzTKCDLKNQpUsgYHCZ8wS6zvTLBQLGxT44IEKcMBS1ieTnDLiKWGgrAER
d6RSVidtOHKKLQJO0oQEQmBABByqKHXLGRlQoUYkqWBdVit5GGGBEBqocAYppczUiRIGRGCEFW1Y
7DKmUq3cYQTXHkwwhR2nSO1QthUEwUEEAZDhCmCn5NHEAj4EIcEHVbzxCSwSFpRLKpi4QYUHIKzg
wweSekbKJGFAgIEQK0RwARNhpAHHI5FE8sgbZ1hhcwQsFH+BkBOSwsYSC9wMaQMNbAAEEUT8kMEC
DXAQBBAWWBCEAmToMmIplZzRBAXZZw7ECiCAwAIQQbDAQQMqT/G2sTOqogkbViihAgQKWAADGLAA
BURgBbhrgyks0YEpNIxMrEhFJu6wBjKIwQpgEAMZ1nAHTaSCFv+oRRXO0ItY5WIXtEghLXSRi4Tw
LlobEYWMHBIQACH5BAkFAP8ALAAAAAAwADAAh/////j///T//vH6//D6//D5/+/5/+3/++z/+u36
/e74/+34/+z4/+z3/+v/+uv9+ur9+ur9+en9+ej9+er8+ej8+Of8+Or5/Or2/+n1/+j1/+f1/+j0
/+f0/+b79+T7+OT79+P79+P69uL69t/59d/49N749N349Nz49Ob0/9738+Py/93389z389v389v2
8uTx/ePx/uPw/OLx/+Lx/uLw/+Hx/+Hw/+Hw/uDw/uDv/t/v/t/v/d7v/t7u/t3u/t3t/Nzt/tzt
/cz//9r389r28tn28tj28tj18df18db18dPy7trr/Njq+dDx7cLs58Dr57/r5r7q5bzq5dbo+srh
98jg98ff9sXe9sXe9Lfk5qbh25rf2ZPd17jW8r7O96nN8aDJ8Z/G7JfT4J3I85vH8ZbE8JDe147c
1o3Y0ofb1HnXz3XRym3QyGnOxnnD0mXOxl7MxF7JwVfHv1PHv03EvEnCuUfAuEK/t0C+tQD//wD/
fwD/AD+/vz2/mgC/vwC/f7Cy3oe774K463yz6niw6Heu5HWw5m6s6muo5Gam5lWq/1u2tlWqqmCj
5Vuf4lmd4lib4UO7sju7sja6sTm0qjSsoi+0qy+xqCywpSqtoimqpCO1qyGtoyGroyGqoiKonx+o
nyGnoB+nnh2nniClnBqrohinnRemnRilmxWlnBSlmxOkmhCkmRajmhCjmg+imACqqg6imRWhlxKg
mBGglhCflg+elQ6glw6elg6elA2flg2elg2elA6dlAyflAqelAqdkgqckwmdk1SZ3FCX339//1iS
2kuU3UaP2EWI0EGK0T9/vz9/fzuK1jqG0jiE0TiCzDaBzTeAzTWC0TSBzCqGxDV/zzOA0DSAyzB/
zwB//wB/fzB9zC57yCt8zCp7yyh5yyh4yCd3xiZ3yCV3yiR3yyR2yCJ2yiR1xiR1wyN1xiR0xCN0
xSNzxSNzxCJ0xiJyxSBzxh9zxyByxR9yxFVVqg9itwMCAgIBAAAA/wMAAAIAAAEAAAAAAAAAAAj/
AP8JHEiwIL1EhegVXMiwoUOH36yAefdvHrx269jBkyfvoceP/9oVCoAlWjFEgsyQIWNGEKJi0siZ
A0lzoDMqHXZU0aGAQAEDQAcoiFEljKJqM2t6XGeGwI4YHW786JHDxowcPX7oSGGgQRZC0MopbUgu
kg4aM2bcWGAgQw4mTHhoANrBhw8NBa4kAjd2ITgzAVbsmIFDjCFHyJIlQ/aoUJkrGBbcCJJBgRhn
3/oOpPZsUBMFN1YQq7dQ3rlsjsLAYOBjR4EsyMRpHlgumRgYAQStc2guHDEwClYEYUClmOzZAsNF
8oLFm8dw3wrJ2BAEA5XYH029chium6JlIM1B/2qSQQgDLM48pmIDZ1Ur7s6ygSxXrAn1AmLCObw1
50CFLXeY8pB8IJEDiQyCLZCIOg118kQISQjABivIFZROIQv4kIEV0DDUSxsIJPGfKhUu9I0XDQhR
ACHuLBTKFCC0UAIetZRYEDuRwICDBllUU1AvdFRwhARc0GLjQuOAYYAPDSjSDkG2dPGAER7UwcuR
Bb3jCAY+GFBGOgSB8sQIIkQRCpYLVXNFBylYIQ1BeZRABAJo+ILmjWUQoEMNxQw0TBwRHPEAHMHc
SVA9hSy5ACKk/QPMGgcYIcIdhhYECQc7DCCIQv/0ogYCLSBBSaUEIQPEDQaY8eQ/t5zhwAlOYP9C
6kDLUDGDAWSAyaqrsMo66z+13pqrQLt8GuqovyZzaqot/iMMpJLa8es/kOSkKad/BuoAHMLMSs8h
SyqACKf/5MGCC3TeMis7eeqwQp8DgQLFCCOYOWs1WLBZxZsD3YLGlFVeaag7W3YZhq4C+UKHBUdA
UGSl44SRYZPNDvQiCC7MWCOa40QSw45Y+FiQLyCKuAWJaH4DRgNBrFgxQZ1AAcIRFLiBC5biEBKA
EBpw2BB/FRBBggp3wELTKA9hE8nKAyjCjkOsSJlECEtMYvRHo3DyXkPlgHOIIJk9xMkUEyTxwRJ3
yAJSJnOcsl1D4Wjz0SyUOGGBEiGo4IYqWzvn5MoUWuDR92y0TOJE2SRQsEUer1zNUC5rBFBCGpc4
rhkrlEyBABFHTFACF3WMYgswCw0jSQkoRLBEG5p8gpwqnHQRAQhJtCCBB1GgAYcdlFxyCSV1wJGG
CycIHUAaKCO3yhxQIDCzESM84IAIRSyxxAseQCABCid0/wIes9jYSidtTFHBAyNwbgTxJ7hgxBEt
hGDCnGrsgqYsodDRxRMqRHAAAg5wAAIOQIEiPAF6TrhEpWQBC1DkIQ5rUMMZzqAGNsRhEqCQggDc
oItpAeMXv8jFLkBIul5wAQqnmNZDhOGGOXSLJgEBACH5BAkFAP8ALAAAAAAwADAAh/////j///P/
/fH6//D5/+/5/+3/++z/+uv/+uz9+uv9+u75/+74/+34/+z4/+r9+en9+er8+en8+ej9+ej8+ej7
+Ob8+OT7+OT79+T69+P79+P69uL69uH69uD59d759d349Nz49O33/+z3/+z2/+r2/+n1/+j1/+f1
/+j0/+f0/+b0/9/3897389z38+Ty/+Px/uLx/+Lx/eHx/+Pw/eHw/+Hw/uDw/uDv/t/v/t7v/t7u
/t7u/N3u/t3t/Nzt/tzt/dv389r389v28tn38tn28tj28tf28tj18df18dnr+tT079Ly7tDx7cPs
57vx7cDr5r3q5dfp+tDl+Mng98fg9sff9sXe9sXd9MDj7afh3Jvf2LvP7L+//6fM8aPK8J/H7Z3I
8pzI9JjF8JDd14/d1pLa1Ivd1nvY0IDSzHbPyG7RyXnGzWrDwWbOx13MxFnJwVnHwE3Eu0jCuUfA
uEG/tgD//wD/fwD/AD+/vz+/kQC/vwC/f9Wqv5G96Ie67H+06Hqx5n6p3Haw6new326s6mqo5WWm
5lWq/1u2tlWqqmGj5F6h5F6h3Fqe4lmd4V2c40m8sz28szW7sj64sjS0qzevpii2piOyqSuxqCiu
pSGto0SgySqqoCOqniWlnyGnnx+qoSCnnh+knhusoh2ooBenngCqqhulnBekmxqjmhWlnBSkmRGk
mhKjmRGimA6imROglxChlxCflg+glw+flQ2hmA6glQ6flhCelQ2elQ2dlQuglgyelAqelAqdkwic
kp6E0XGNxlSX3k2V3EuJ0EiU4EiR2USL0kWGzECE4j9/vzuM3TmI1DmF0TeE0TmCzDaByjWBzTKE
1TKBzjOAzS+AvAB//wB/fzF+yjJ8yi58yyt8zCl7zCp6ySh5yil4yCd3xiZ4zCZ4yiV3xyR3ySN2
yiZ1xSR1xiR1xCJ1xiR0xCN0xSN0xCNzxSFzxSJzxB9zxSByxCFxw1VVqh5tvABVqgMCAQIBAQAA
/wIAAQQAAAIAAAEAAAAAAAAAAAj/AP8JHEiwIEFqVbyEM8iwocOHA7uNCfBF3jl07N7Fg8ix4z9x
fwq8oOJHjJgxfwoNk1bOnMeXA80ZIjGjxosCOAkMYCCDSphD1crB7OiN0YoYNWLMuFGjxg0dPXCs
KDACC6Bn4oY+3MZISYkcMWLsUALkhgkCC1Ts2HFigBVD3bQ6HGcMC4McNRohO0aM0aAwVUo0qPHD
BAMwzbwNTbWKobdmXgqseCRv4Dty0hZ9gTFiRw4CWIyBeymrTpxWDbn5CVCocsFy34Z5afDihwMp
w0ZzjDWpSQI1phqKAzTItUFx3ALRQPGjhBRjiiFiikLhiIA0mFIzy/bQ3CMlJoA4/7jSDCIrMweS
aGBCB5XDZ9EgjiOmhDkBMHEb5oojQciHFnTwAlE1HJHzCA0v5CCCIec0tIkTGBQRgRu3yMUQOoEw
sIMJVDzD0C5rpEeBFo1ZyBA3XowABAGAtGNQKFFg4AILdcxiIkPnDAODDSdgQSBBt8RBgREQbCHL
jQ2F80UDO4xwiDsEzUKGAkVYIIcuSDLEDiMl7FBAGOsQBAoUHGwQhShZNlSNFSqsQIU0BNXRghAH
lJFLmgytE8YAOMQwzEC/vPGAEQq48QueBskzSAE7NFDIPAL9goYBRWwwB6IMOZJCDgP84ZouZxzg
AhKVYGrQMTzUQMAY7whUCxkIgP/ARCamFoSMFDF8iY6rsMpKa60D3ZprGOkIBOoBQZAK7EDH+FBD
AWOwE+mklV667D+acvoHPAL5Iiihhi4bz6I7MFDIRgJJ4kIQdday7Dpj8AnDnwONyQEHUISybDVX
tPkmQa9SaeUutW7Z5QJh7DqQLkIaIYGRtSrJpJPSEgQjBkHQeCeiOe54whVwFqRLiEmMWCKeKI7w
A4suGvQgBkZMaAueGGrIoYcM7dfff3QcCRGaD6lzYIILhtnQeemtJwksP2/i0DaPSKHCymB8I10U
EyRxAXtMOyTKJCcXNM1qPYxA3m69WaBeC26s4kpDv7ihRtcGbQMIAc8txJErkjTLkfUHEWhRhyt0
DwTMGwGkERxD4hjyiFAeuTJJFAcIYcQELGwhhyiy9GI4HRwosAUmrDDUzTaLYWLGAxgkEYQEFkBB
hhtzTFKJJpGEIMQDUUzyCqKrxAHFATAXEfoBGQyxxBJGgAACERYsIUcqiLayyRpRWKAAB0EYUUQQ
IYQAPgghgMCBHKVjCkspcpABhQsQGHAAAvR34EIIFcQxM7CwvCKKJG9QwxkGmAYneOA3qLnWQHzR
i17oIhfA2EIAzBA2BRZkFluAAinkEhAAIfkECQUA/wAsAAAAADAAMACH////9f3/8f/98fr/8Pr/
8Pn/7/n/7vn/7vj/7f/77P/66//66/366v356vz57fj/7Pj/6P356fz56fz46Pz55vz45/v45Pv4
5Pv35fr24/v34/r24vr24fr24fj04Pr23vn14Pj03fj03Pj07ff/7Pf/6/f/6vb/6vX/6fX/6PX/
5/X/6PT/5vT/3/fz5fP/5fL+4/L/3vfz3fbz3Pfz4/H/4vH/4/H94vD94fD/4PD/4O/+3+/+3u7+
3u793e7+3e393O3+3O392/fz2vfz2fby2Pby1/bx2PXx1/Xx2+z82er51vXx1PPv0/Lu0PHtxu3p
weznv+vmvurm1un61ej51Of5yeD3x9/2xd71vOnlreXfn9/av9v1zMzmq9TqpcvwoMjvncjymsTt
kN7Xj9zWktrUh9nUedXNiMrecsnGbc/Has3Far+/YMzEWMnBU8e+WcG8S8O7R8C4RcC3RL+1AP//
AP9/AP8AP7+/P761O761Pb6aAL+/AL9/xq3Ih7nqgK3ZfLPqe7Hlca7qdbLXaqnmaqPdVar/W7a2
VaqqZaXmYaPkWp7iWZ3hWJvdPLmwM7uxNrSrMLGoMq+nKbKpI7GoIa6kKquhIqygQKG2UJjgKqag
IqqgIaifIaehH6mfIKieH6efIKWcHK2hHaifG6eeAKqqHKWcGqObFqSbGaKaFKWbE6OZE6KYEaSa
EKOZEqKZD6KYDqKZEqCWEKGXD6GXDqCWEZ6VD5+VD56VDp+WDp2VDaGXDJ6UDZ2UCp2TCZ2TBpuU
eIP4UZbeS5LaR5PfR47VRIrTRITMP4PhP3+/OInYOIXSOIPPNYTUNoHMNYDONX/ILIu+MoLNNIHN
M4DOM3/LMn/LMH/NAH//AH9/Mn3JMHvJLnzJK3zNKnrLLHnHKXjIKHnKJ3fHJnnMJnjKJHjKJnfK
JXfIJHfJJnbGJHbIJnXFJHXGJHTEI3TFI3TEI3PFIXPFIHLEVVWqH2/ADVmzAgEBAgEAAAD/AwAA
AgAAAQAAAAAAAAAACP8A/wkcSLCgwX/miinpEu6gw4cQHZZjRCXAGHvoImrcSLCcIBQvWnQZRIhY
NXTsOKosaK3ZGBI2dORYYeABDixiFlnLuFIlNmZXTPSwQbTHDx0sDJjIIqiZuZ4GVZUySM6YFRU6
bOxQQeBAix49VBTAYugbVIGqLHFBI8vgOkc3YsQ49EhQmKAPdABJgSAMM3A9W0XSoiDDm1gG0xki
4eOYvXnmoDECA6NEDx4FshgTp9LVnicRmGjIsCeVQXSAYCAjeG6coy8IYgSBUGUTZ42uIj2pIHrG
mkyiDmYDlMxguW+DbqwIcqLKZo2WpkRIcsHJnFkQn0lzeM7RkhRCIGT/YRaRlRkFSTQ42dMW4rXt
Ds1tWrK8QBjADnm9mUAEhAw6tWwEDUTpOIJDDDyQYMg7Dl0SBQZGOMCGLWcdpM4gCPSQwhXNHPTL
GuhRsAUrFTr0zRclBFGAIPAYBIoWGNDggh64lHhQO5vckIMKWVRTkC9wUGCEBFwEaONB5IDxQA8l
LNLiQLqUwUARFsjxy5EHwcPICT0YIIY7BHkSBQccSAEKlg5VkwULLVzh40B6yDCEAmXkguZB74hB
wA41bDJQMG40YAQDbABzp0H0EGJADwgQQo9AwKCRQBEbzHHoQY2wwMMAgDz6jy9nKDAEEpJcalAx
QORgwBhP5kLGAiI4/zGJqQUhQ4UNXjL4j6uwykorQbbi+qVAv4RKA6m/DlSMDzkUMMY8kEpKqaXJ
/pPppp0KBKigDLhh6K+JLvqAo3DKQASduiSb5542+DmQmBxsMMWZv1aDBZtXDAglGVNWuQutWnLp
ZTsEASlkBEXSmuSSTcpTEChTxDhjjYfiqCOPbxL0YYgjXnpiCUKsGM9BDmJQhIS33MkOhhpy6BAu
+/UnwxwUPhScRgUemKAhBDtkHnrqsffQKKNEJB99KoYxTkTRTVfddQ6NcglE6ngHnnjkRUSLbrxp
IAMbqiBWECZoTGXQNc4MgsNyzRnTEG6fTQeCA1vQ8Up7Ak3iARqwGLXkzSYsrKAEbbapJBhhRBhB
QQhcwOGJLb4IIwkSE7iB90DjGJICAZrdplJaZkiAwRFDSGBBFGSsUUccIIDgwhy0nAYIGH9VyMob
UihgshEcNKDABkSIMIQGT0QSe0HZmGUjLJmwoYUFDHAwhBFFiGB9ERREYQkqyc5SChxlTEGDBAto
MMIQIExgxiWhVPvPLLWIAskbbGzRwQcZrPGK+wbVIowZAniCHPbHP4OsYgtNgETfShQQACH5BAkF
AP8ALAAAAAAwADAAh/////b///L7//D5/+79/e/5/+75/+74/+3/++z/+uv/+uz9+uv9+u34/+z4
/+r9+en9+er8+en8+ej9+ej8+ej8+On7+Of8+Ob79+X79+T7+OT79+X69+P79+P69uL69uD49N/5
9d/49N759d349Nz49O33/+z3/+v3/+r2/+r1/+n1/+j1/+j0/+f0/+P1+uXz/t738+Ty/+Py/+Ty
/dz389v389r38+Tx/ePw/OLx/+Hw/+Dw/+Dv/t/v/t7u/t3u/t3t/Nzt/tzt/drs/NP7+dn28tj2
8tf28dj18df18db18dTz79Ly7tnq+tfp+9bo+c7x7MLs57/r577q5rvs57zp5Mrh98fg98ff9sbe
9MXe9cXd9bvg7ajh3J7g2rnW8czM67PS8arO8Z7N7J7H75vF7ZHe15Lb1ZLa1Ira1HbUzY7E5nHN
xmvOxmfLxGq/v2HOxljIwFXIv1XEv07Du0jBuEfAuD+/v0G/pAD//wD/fwD/ACW/qgC/vwC/f6+y
4IW67YGy4nyy6Xqw53er33Ky3XWu5m2q52en5mOk5VWq/1u2tlWqql+h4lqe4Vmd4VGb30C9szu9
tDW7sj2zrDa2rjG4rSOyqSG4riuxqCquoy2royaroSOqoSCsoh+poCOooCGnoCConyGknBupnxyq
lBunnxqmnBamnRWmnRmlnBOlmxijmhOkmhOjmhKjmRGjmgCqqhehmBOhmBKgmBGglhCelQ+imA+e
lQ6ilw6glQ6elg2flg2elAydlAqdkwqckwedklKZ4E6X3WeK6EuT20mT3kWS3UaK0UKN10CHzT9/
zz9/vziJ2j6IzDyG0TiE0DWD0TaByzZ/zjZ/yDSC0DSBzTGC0DOAzTN/zAB//wB/fzJ+yjB7yS58
yyt8zCt7yyl7zCl5yyp5xyp4xid5yyd4yyV4yyd3yCV3yCR3yiV2xyN2xyV0xSR1xiR0xCN1xiNz
xiNzxCF0xSFyxVVVqiVxxABVqgIBAQAA/wMAAAIAAAEAAAAAAAAAAAj/AP8JHEiwoMGC574J4gLt
oMOHEA+CE+cITIAx5SJq3Egw3LExKlicKFTPHMeT/3SVMvjtEI0TO3zIuGJGUbZ1KCHG+rSmDa2C
7hS18KFDhw8XBlBwGSQNXU6DrORMQSCCkq2C78oUIIrCBZAfKwpoSSTuqcBUmNI82MAEghdUBpE5
kSFDzJYGJngAWdHAjLNwOV1RopLgxpEJIND0gUswXiABRJZlSzQGxokfPgZwOTbuZK1JUSYoGRHB
iyRXoA5Ku7LF27944yCJOTBDiAMow8htnEUpyoUlHWK4UeXqYb1DZuoNPAduEA4XQlJAOZYxIiYq
ojU0uaNL4zRkrgmi/3vkhMWQE1ucRXyVZoGSDk0m4drYTb1BdMOcQB9QprPDW3JYcMMIMdwxH0fT
OKTOIznM4IMJicDj0CdSbGBEBG50Z5ZB7RByAFhYRHOQL24koAQFXqiyoUPgiHGCEAMMIo9BoFix
gQ0iSHLViga5MwwOO7CwxTUF/TLHBUc88EUtPDqUThkN/HBCIjMOlAsaDBiBQR2+NHmQPI6k8IMB
ZbxD0ChTfPDBFKN46VA2W7jgwhUJDiRJDTYkcEYubh4EjxkD9CDDMAMBE8cDRzAQRzB9GnRcAT8c
gIhy/wCzBgJGeGBHowdB4oIPAgRC6S9qJFBDEpZwapAxQexQgBlV5v9yhgIkNKGJqgUp84QOBZQp
kKy02oorQbry6us/vZR6aqrDCsSqq2bEI5ClmGrarECPDBUqPdMemmgcwDRLzyGQNoAItwJJIsIN
CajB57DwaNWDDoQOFIoUH3hARZvDXpOFnFgQOZAtZ2SZAZe4zqOImL26Q5Avc1RwBARL4prOGAb8
gIIi0hIEChUb1JDjjn36CCQLXGRjEIkmoqhioy2+GGOVBVFoIYYaevkOIVGugIU0/wU4YIEHGsTv
RupA0qAPDSTisEOuoGFiB0zId1AmpGx0DjHlwViGSRBdN8ESbNmRs0CrXOKJRutA4sQKQziQnka0
9PZbcG6kAkuharzYwahD44RDSA4sRDdddRHRAppoIzzgxR2u9PJPK1VE8clB2ZgzzGy13TZMOie9
QokVhR1BAQhf0FEKJ0wgsAYvBXWDTBkvYTbAFpzl1EpaEmSAhA0SSGCFFyGEwMQlLIHRABF8leEM
OBuyMocVC2RgxBEeXFDCDQqgATtB7BwjgwBjlcVjLKC4YQUGDHxwAwkk3OABHbcUlM4ggVhzTp+6
nFKHGlIIwQ1KcLo3pMIg2MCJqlghjDdUYAMc+AIlXnatgsziCwHwQh1cccAKGmQTVmjDKWLRp4AA
ACH5BAkFAP8ALAAAAAAwADAAh/////b///H6//D6//D5/+/5/+75/+74/+3/++z/++z/+uv/+uv9
+u34/+z4/+r9+en9+ej9+er8+ej8+Oj7+Ob8+Ob79+X8+OT7+OT79+P79+L69uL59uD59d759d34
9Nz49O33/+z3/+v3/+r2/+n1/+j1/+f1/+f0/+L2+N7389338+bz/uPy/9z389v389r38+Tx/ePx
/+Tx/OPw/OLx/+Lx/uHx/+Hw/+Dw/+Dv/t/v/t7u/t3u/t3t/Nzt/tzt/dvs+sz//9n28tj28tf2
8df18db18dTz79Hy7tTu89bp+tXo+cnv68Hs57/r5r3q5bvp5Mrh+Mff9sXe9sTe9sTd9LLl4Kjj
3Zre2JLe2MPY7LbU8rnN6qTK8J7J8p/G7ZbS35jF8pjC7I7c1ofb1IzX0HjVzW7RyXDKxYu97mXO
xmnFwFnJwVPHv1HFvUvDukfBuEfAuEPAtz+/v0G+tj++mgD//wD/TDq9tDW7si+9tAC/vwC/f8Kt
y4G26X6y5Xmx6Xew33er3W6r6Wam5mOj42Ob21Wq/1u2tlq0tFWqql2g4lqd4Vec4VOa4E6Y4Tq4
sTK2qy6yqTWspiuqmCO3qiOyqCGupCSrpB+roySooCGnoCConx+onx+nniCmnSOinB6lnByqpByn
nxqmnRenoBOlnBWkmhGkmxuimxSjmhCjmQCqqg6imRKklhOhlxGhmA+hlxCglhGflhCelQ+flQ+e
lQ6dlA2glwyelAihhAydlAqdkwmdk3GG8FGS2EqS20qL1UeV4keS3EOM00eHzz+K0j9//z9/vzqM
2zmI2TmG0TeDzzWE0jSBzjGBzTR/zyp/1DSAzDGAzDGAwgB//wB/fzN9yTF+yi98yS19zCt7yyl7
zC14xyl5yil4xyh4yiZ4yiV4zSd3yCV3yyV2xiR4yiR3yiR2yCR2wyV1xSR1xiR0xCN0xiNzxSJ1
xiBzxSFyxCByxFVVqhNeswMCAAMBAQIBAAAA/wMAAQMAAAIAAAEAAAAAAAAAAAj/AP8JHEiwoMGD
BNF9Y4YNocOHEBM+MzQmmLeIGAe6YuUJ1EF02xyNmRKAC7iMGF15cqMFSp6C2Yb94cJigAkcwcih
fJgKExooEyYEOMOrYLMlA3LssBFk0DNxOw+eauNEQQYiRhg0+VRQnhoDO2rsaGGgSqFuUQeiuqTl
QQYjLiBYeGJmj6qCjljUuEGiRo8SIcAs4xaVlR4oCmAQiaAiCxxQsjAZ1MaFRA4uMhz00EHACrFv
KGPlSRLBiAcJWOqwcuVQ3p8AVkJyOSDjhwMmkE5GhKUnSYUjGlSkObUqIrEGgdiB2/ZnBoofJJgM
0/3wEpTSGJDIYY1Rm5piA9Ex/wpiAogDKssgpiKjwIgGJHlYocSmrGH4R0GeEwADGmEtNxTA4IEK
ccgSlTIGpdPIDC3sEEIh7SCkyRMWECFBGgZGZV9B6ARyAA8lSOHMQbyg0d4EWJiS1kPccCECEAQE
8o5BnkSRwQsdzFHLig6t80gMOJhAxTMF5eJGBRZmEQuPD5HjRQM8iFBIPATZQgYDQ1jwRlFMIvQO
IyTwUMAX6xDUiRMbbPBEJ10+NA0VKKAgxTQE1bHCCwqQcUubDrUjxgA6yPDIQL608QARDKzRC58I
xRNIATwcQMg8AvVyBgJDbBAHow41gsIOAqghj0C6lKGAC0NEwilCwfiAQwFizP/4zy1aLPBBEpOs
elAxS9QwJjsC2VLrrbnqWhCvvn4B7D+lnmqEJMYW1OqrsVZ6aaabRjuQp6CKKpAvaxya6KLaOgqp
pJQKVIcKMOS5p7Z+AiooQZygqSZX2j4zRZxT0DlQLVpgaQEcukT7jiFhjlnmQEZOQAQESkbrJJQj
FOJOQZ5AkYELKtRBi67rOAKkCVYQWZAuJhqB4im6buNiDzFGaBAmTlx1YS4HiZJWOh6COMWIB9XS
RoADFmiQJVGhs2CDUsp8UCpatPeeagSJYolHGZEDSRAn/LBffw5ZV1oGSMDB3T+TmHEXRuc0EkQJ
5lWRHkS8+QZcB2iYAssta0jZAC1E4XATCA1djyAddQ/BkkcTEJj2ABZzlBJFAGhweVA54TzCRQMt
/CACbuGgtIoeUSjwwmIrXPFCBVeUYpAz6UzDiBcxOMDDDp0NA3ZGq2BiBgUXFPFBBSB8kGNB2gwz
EgkN4PBDCQcIRtiKp7wRxQMdwPABDA8QVdA0UhgABA8mDDDFWW2m4gkbSHwwxAsJJJFJQfG8JoII
VgTizDiM8uZCBgngwBXQsAedEQQSVvhCIZ6BjlXBAgsBeEIZInc2gkzjKQ3UlR7M8IZOVFBbBwEF
JlbxwVUFBAAh+QQJBQD/ACwAAAAAMAAwAIf////6///z/f/w+v/w+f/v+f/t//vs//rr//rs/vvr
/fru+f/u+P/t+P/s+P/q/fnp/fnq/Pno/fno/Pjo+/jn/Pjm+/fl+/fk+/fj+/fj+vfj+vbi+/fi
+vbi+fXg+PTe+fXd+PTc+PTs9//r9//q9v/p9f/o9f/o9P/n9P/n8/3m9P/m8//k8v7j8v/f9/Te
9/Tc9/Pb9/Pj8f7j8fzi8f/h8P/h8P7g8P7g7/7f7/7e7v7d7v7d7fzc7f7c7f3c7Pra9/PZ9vLY
9vLX9vLY9fDX9fHX9fDW9fHY7vfW6frT8+/Q8u3O8OzR6vTC7OjB7ei/6+a+6uW86eSz5+LS5vnJ
4ffI3/bF3vXD3var3+Cb39mT3tiS2tTD0u6z0/KpzfCgyfKexu2ZzeeaxvGZxfCVweuG8OeM3NaD
2tOF1c9x1cxvzcZrzsdjzsZfzcVbzMSBvuBhxLxVx79PwrpNxbxIwbhNwLhDwLdAvrUA//8A/38/
v78/vrU/v4oyvLIAv78Av3+4rs+Br918suh2set4sN9yredtrOprqeZnpuZkod5kmthWrPBVqqpf
oeNZnuFWm+FTmuBRmd83tq4wuK4us6wvrqUrqqMktKohsagjraMiq6Adq587ncYhqKAhp50gqJ4f
qJ8fpZ0eppsAqv8cqqoAqqoXqaAcpJ0ap5sYpJoTpZsRpJoWo5oUopkPopkOopgTpZYRoJcOoJYN
oJcSn5YPn5UMn5URnpUPnpUOnpUNnpQKnpQJnpUNnZQKnZMKnJMJnZRxg/FKjdNJkttGkdtCi9NB
idI/f8k/f785jNk5iNY7hdM2hdM3gsw1gs81f8o0gtEzgc0zgsw0gM00gMkwgM4qf8YAf/8Af38x
fckvfMgye8kte8kqfM8pesspeMknecood8cleMsldsckdsgjdsoldcYkdcUjdcgidcUldMUjc8Uj
csUic8UhdMchcsUgdMcgc8UgcsRVVaoAVaoDAgECAQECAQAAAP8DAAACAAABAAAAAAAAAAAI/wD/
CRxIsKDBgwgTKlwoEJcvVKEYSpz4LxasT33gpHGzaqE8eN6gQaN4MJaoOVyewJgQAEpHgtXAmfPW
TFIiM2aWkSzYalMbKRMUdAhCRASTSwW9IQrzpcoMBgESjds5kNWcKAcwDBGyQYGCDTDwFIxHBkCK
FThKEFJH9Z8rTV0eYDAiAoKFKGjc2KFUaRRBeohG7LCBA4UYad52vvoz5UCQIRJebKkzilavhJFY
1CCMY0AWY+EovurTRIIREBG05GkFiyEyJS1YkHDBw0GVSaEZLm5SAUkGGG1YtZrILYsAMIZUrPBB
ooqxqQs1TTGNYYmdWCTTgWmBjN4iICd+OP/Iwmxhqy4HjHBY0qc1SXpmCMX7p04SkOUExIBLmGsO
hSAgvHAdVdsYM81A5jzSggs6NJBIOghtEsUFQ0TABi1t/aMTQeYQwsAOJljhzEG/tJHeBFqwkuE/
1hj0zRcj/EAAIe0YJMoUGMjwAR65rHgQOpG0gMMJWBxIEC9zVFDhFrP4iNA4YDSwwwiKwEOQLlwo
IIQFdfDi5EHvPFLCDgWEgQ5Bn0DRQQdRiPIlQtNgcZYVzxDUBwxBHICGLm8exA4ZA+QwgyQDCfPG
A0Mo4AYwfRo0TyEF7MAAIvQI1MsaBnBlR6MHQZKCDgOYMY9AvKBxgAhHUMKpQcX0YEMBZdT/+A+W
CIRw1KoFHaNEDWVCOCsXtd6K60C68hqGr7iYGkMRqg4rUKuvxioQMJhq6qxAnoJqxnz/GIqoosE4
+2ikk1Yq0J157unsn4G2MAmaT3SwQZvOVnPFnCMNdEuWW9aBC67tiEkmGb6SOscEQ0DAJK5QSknl
OgWJIkWOO9rCKZAz3ECkkQSVeGKKBoGy4osxzihrQRJqZSF2BGWSoToegnjFiAfpcjCAH9zB8j+h
VEIKVeVAQgODVBZsECvoqYdEHhgC04YajJJkziRApODDAPpFNwUERmSwxB3BXOLBFreQRA4kSoTX
AHm6/cEbEh14IMcWAlDxEkPifEMIDVY30fecRLtBQAQIFXwAQhNILUSOOJJ8wYALPtiGm2h/UJGA
DDKIEIIHYiEEjznRPBLGDILpQAAWxeRGkSuddKGBDDEMMcEblw20zTLEQFJIGViU0IANPpzAgBjM
7EdVLWxYIEMHGgCARtQDQTJDCgUU8OkOJwxwhSLGU2ULHAE8AEMTVGwBx90CFctDDissMAIWhDhD
zoqZqJEGHHlgsgotrYhMEDdWCMAIZmCFMChiGvNbESc44Ype/Esh3iiEGRAxiWeI4xzXOsgzvjEP
K2XwWgEBACH5BAkFAP8ALAEAAQAuAC4Ah/////r///P8//H6//D6//D5/+//++/5/+75/+74/+3/
++z/++z/+uv/+uv9+u34/+r9+ur9+en9+er8+en8+ej9+ej8+ej8+Oj7+Ob7+OX79+T79+L79+P6
9uL69t/59d/49N759d749N349Nz49O33/+z3/+r2/+n1/+j1/+f0/+b0/+bz/+D29tz38+Ty/+Py
/9v389r389v28uTx/uPx/OLx/+Hw/+Hw/uDw/uDv/d/v/t7v/t7u/t7u/d3u/t3t/dzt/tzt/drr
+tn389n28tj28tf18db18dTz79fp+tTn+dHy7s7x7Mnv6sjq7sDr577r5r3q5brp5Mvi+Mng98ff
9sXe9rvf7qHg25be2JLf2Y/d1ord1r3S5qLL8r+/357I8ZLW2prG8ZvF7pfF83jXz3HTzG7Sy23Q
yG3NxmXOx1/NxVnJwVTHvz7NyAD//wD/fwD/AIe88He811LAt03FvEjBuU69tUPAtz+/v0G9sje8
sii9swC/vwC/f7Wtun6y5X217Xuz63mx6XKu6m22tmin5mil32Wd2FWq/1Wqqlu2o1+j5lye4Fqc
3lSb4VOZ4E2V3Te3rje0qzCyqS6vpzCroiOyqCStoyaroiCqoSKonyKnnEOV3iOinB+onx+nnR+l
nR2imhmqoBalnBakmhmjmxWimBGimRKhlxChlw+hlw6glwCqqg2jmBaflhKdlBCelQ+flROblQ2e
lQ2dlA6dkg6clAydlAqelQqdkwqclAqckgmdlAebkX9//0uR2EeP1kaIzUKL1EGK00GJ0D+J0j9/
vz9/fzqO4TiI2DmFzzqCzTaBzTZ/zTOE0DSB0DGB0DSAzTR/yTF/yjF9ywB//wB/fzF8yTR5xi18
yyt5xyh6yyh4ySl4xip3xCZ4ySV2xyZ1xSZ0wyVzxiR3yCR1xiN1xyR0xCN0xSN0xCF0xCNzxCBz
xStsu1VVqiFyxCBxxB9xxB9xwx5xwxhqvQMBAQEBAAAA/wEAAQMAAAIAAAEAAAAAAAAAAAj/AP8J
HEiwIEFdtWrNmpWLlMGHECMWfLWK0x42Zrps2dLlDSqJIEG+AuVmCxQRERQwaFABwJlfIWMWTJUp
jZQLDjzIMFLExQgZEdD0kkm0VBsoDDbw7LDAQYcjTJpIEEowmzJjxbIWOybMmDJqIE1h4kJhwxEX
FDJE4bLmzqRKlijxOUUwHqEXS5QoWaLjiidrIFHxmcJgpwUQWuyIaqULJD1BAmyweJFiSTBvIFXx
aVLhSIgJWfKkeiXz8YEeN3ScSOQOJKzNGZBwAKGmVCqi/x4T6JEjxwoqwr5JxDSl84Ykd1jhFvgY
gY0TL3gguLIsoikuDI5wSLJH+fLcgwJU/0GkJEWQAmS6PZTVBoOMECDutPousN4cHcLqJaphY0eJ
Q+QYlAkUSk2gxnz0/SPOIZCw8486giTwAwpWQFOQLWlkZ0EWpSQoEDXKbDPQNliY8EMBg7RDEChS
bOACCHnI4uE/1ERDEDmQvJBDCldMM1AublxgBAVaqDIjRN588UAPJhzi4D+ybAFBERnYUcuRD7XT
yAk9HBBGOgJxAoUHHUQBCpYQTWOFCitU4YxAe4ggAwNczILmQ+mMQYAOMETyjy9sRGCEA2vscqdB
9BRywA8JFMIOL2YoUEQHdxz6kCMq7DDAHPLY0gUDLhgxiaUGBePDDQeU0c4sWzQwAhOVkP9aEDFK
2ODlOay6CqusBNFqaxjneAqqqLwOFAwQqJahzi6RTlppsf9gqimngApKqKG8zqNoD43K80+cc3Jh
S7F5ErDDC37+I6YHHkBxJq/TXKECC24KNAsXDlBpx7ikqrOldGGMIxAuQQ6ZhZGkfvMFAkweoqJA
LG4QA4wyDrSJKDPiSAMOPPo4EC5pOHDEBRwOdEofnMy4zRcmnJdiQZtEoYEREaRxZS15tLGKh+gQ
kkAPKFRhYUEEXyCDCCDg8QslM5gBE33iOFIDDDs0+fBMXCigXRN1QBFAGkN9F04kQ6hwXnoRETfl
BxqEEFTYuJnjyBApCPEAdRLBUsmYMcTWQAQDVBEVzjaE1GC2CUt4Ag5IutShQQwkENFA4CGZ0w0k
XyQAQxAPLCGJcBKpMokTG3zwwQgGUA6RO+JM08gXNJjQww4F+IWZRKfwIcUMTTARFQhpYCtQNp4E
QwwxwThSyBhXnPDADUCg8AAZy3ADUiiYaAKXJdxz3wfGA9UjCOJKAKHCAQSowEMPKRRgxSHqWdrc
DjbcsMMPO6yAgAlXDAJNOLKyDwBMcIADDEBzVQjDIaZhjmKBoxFjCEMYyjCHQkTCGeFoILT+IQ13
nOMc6GhHa74TEAAh+QQJBQD/ACwAAAAAMAAwAIf////5///z/P/x+v/w+v/w+f/v//zv+f/t//vs
//vs//rr//rr/frr/fnu+f/u+P/t+P/s+P/q/fnq/Pnp/Pno/fno/Pnm/Pjn+/jl+/fk+/fj+/fj
+vbi+vbi+fXg+fXf+PTd+PTt9//s9//r9//q9v/p9f/o9f/o9P/n9P/m9P/m8//e9/Tc9/Pj8v/b
9/Pa9/Pa9/Lj8f7j8fzi8f/h8f7h8P/h8P7g8P7g7/7f7/7e7/7e7v7e7v3d7v7d7f3c7f7c7f3b
7PzZ9vLY9vLY9fHX9fHW9fHY7vfX6frW6frT8+/R8u7P8ezN6vHC7Oe/6+e/6uW86uW86eSx5uHL
4ffH4PfG3vXF3vbC3PSp4tyg492k296X3de80O2w0fGsz/KmzPChyvOhyO2eyPKaxvGYxfKZxO6S
3tiN3daP29WH29R41s9w0Mlp0cmDvedh0sZfzcVZyMBRxr5Pxb5IwrlHwbhBv7YA//8A/38/v78+
vbU/v383u7Isu7IAv78Av3+VsMt/qsp7sul2sepxrPFtreBnpuZlpeVjoN1Vqv9Qr69bn+JZneFU
m+FUmN1Nlt82t64vsag3rqgssqkjtKEprKMgsKYiraMfrKIhqp8eqp4jqZ8hqJ8gqJ8gp54fqKAi
pp0fpp4fo5waq6Ibp50Xp5cWpp0AqqoapJwVo5oUpJsTopgRo5oRoZcQpZsOo5gOopkOoZcSoJcQ
npUPoJcPn5YPnpUOn5UOnZQNoJYNn5UNnpULn5ULnpQJnpYKnZMKnJMJnZNyhPZJkdlHj9VBkN9D
i9NBi9U/f/8/f78/f385idg8iMo2htU1hNI2gs02gcw1gc02gMs2f80vh9Qzgs4zgc40gMsyf80v
f8wAf/8Af38zfcswfcssfMspe80pecgnecsqeMgndsYmd8ckeMskd8oldsgkdsgjdsgldcUkdcYk
dcUidcckdMYjdMUjc8Uic8YgdMYgc8Ygc8Qfc8VVVaoRZLcCAQEAAP8DAAACAAABAAAAAAAAAAAI
/wD/CRxIsKDBgwgTKlwosFevXbds7fL1i6HFhbBcdboTh00aNGjWsImzx9OliygFwgI1B80TFhIQ
KFiwQAECCSCo+Elp8VUmN1MsMOgAg8iQFiFCtBhi5MOTTzwXrpITRYEGox0SMOBghAmTIhwoBNAy
KyrCU5fUUMhg5AUFDFDSxLETSZKkSHbidGlT1mxBVX2mKChqAUQXOqJq+TLoq9YlqAO7GYMWjt28
i6z6NKlgBMQELXdaxeIZ702SL2YIMUIGbZo1aQczN7lwZAOLNqtamR33RUAJAgdMrAhj7BrCS1Iq
HNGwxM5ov9ispNihQ8eNMciyIVylRoGRDUv2PP/3S0yICx04SHwxpw3hLTkUYIBgYUeWX4H2EKFw
McJGjRSIrIMQJk9cNYEb9t33Tz2DBJBEGCroUAIWzxyUSxveWaDFKQoKBE8YVUAijhcj+FDAIPEY
BIoUGrTAwh19KdjNIcyQE04jK+BgQhbaEbTLHBYQQUEXrnQoEDPfDBROGBDwQAIi8BBECxoMDJEB
HbwY+U+FA8WDCAk8HECGgAN18kQHHEDhiZYHQWOFCipYAdtAe7AAgwJp3MKmQe2QcUAOMjwykDBx
SEAEA3EEs2dB9BBygA8PFEKPQMCwgcAQHNixqEGMoKDDAG/UI9AuayiwVCSbFkRMDzYcYEaU/9j/
gsYCITAhSaoEHZMEDQeIwY5AstJqK64D6corGe0IxEuppxIrEDE/tPqqQL5Yimkdzv7TSAqfvjHp
P4QayoAbi+Fqj6M8RCqqQHu08EIDatBCbDtlEACoIwR9AkUHHUDRCbHSYJGCClVEQ5AtajBABAZz
ZDkQJlrCw0gJPDgwpo9zYDAEBVuwMhBaWpYThgM8jHBIigSVMkUGL3xghyqzUCLHKEaS44gMN5yA
hXEF5eIGAkZUoMUrfTyxRbkKfvPFCEEQMAisBWUixQUwdNAFEwG4oaiC7AzyAA8mWOEMQrTM4YFS
FYDAAR3AKIhOIzOcJ8IhZBpUyitaWPCCfEeg/3rfOZAkkQIQBYwhDkKlUNJFCzDEMES/kJl1TiNJ
mBBEBFgwgxAofnThgQYKJHCBAVp4HJU43wwywwlAkKAEJOMc1AkonXBCSR1urKEFE2w4jNI54jjy
xQMuABHB6+Fc1IsuqnDiB80DYeNMOt8SNE862DAShgwj8KBDAVkQk7yR6wwSBiGNEHPMMcQ0QkgZ
V5QAgQ0/mADBGUiySc4XAUCQwg9KUMIPUnAAAqSABzw4QQGucAhwLGoaVVhBEHRgAxrQwAY68EEO
VHCAEWRhEM843KKMkYUVQGAAB0jhAQbwABlYgQyIuMY5cOUMaTyiEG8wAxnEYIY3FMIR0iiHORKy
JRB6zIMd7WgHPORxGSISKyAAIfkECQUA/wAsAAAAADAAMACH////9v7/8v7+8fr/8Pr/8Pn/7/n/
7f/77P/77P/67vn/7vj/7fj/7Pj/6//66/366/356v356P356vz56fz56Pz55/z45vz45vv35fv3
5Pv35Pr34/v34/r24vr23/n13/j03fj07Pf/6/b/6vb/6vX/6fX/6PX/5/T/5vT/5vP/3vfz3Pfz
2/fz5PL+4/H94vH/4vD/4fD/4vD94PD+4O/+3+/+3+/93u/+3u7+3u793e7+3e393O3+3O393Oz7
zP//2vfz2vby2fby2Pby2PXx1/Xx1vXx0/Pv0PLt2ev71un6ye/rwuzowezov+rlvuvmu+nk0+b5
yeH3yOD3xt/2xd71q+Pewdv0oeHbm93YutL1r9Hwpsvvnsnzn8jwmsbxlsXym8fmkd/Zkt3XktzW
jdzWiNzVgNfQctPLdcnOasq9Zc7HYs3FXszEVcjAVsW9TsW6SMS5R8G4AP//AP9/AP8AP7//P7+/
Qb+2P7+lML61AL+/AL9/kbfchrvwf7XrdrHqebHkca3qaqnpaKblY6LhR7u0Var/VaqqXqDiWp7i
WZ3hOLmvNLqxNreuL7GoJrKpMa+oKa2iJKuhIa6jH6yiHaugKqqmIqieIaegH6mfH6eeH6WdHqmg
HaWbGqueF6acAKqqG6SbFqSbFKSbE6SbE6OZEKSaEKKYDqKZDaKZFqCYEqCXEZ+WD6GYD5+WD56V
DqGXDZ+VDp6WDp6TDZ2TDKGXDJ+VC5+VCaCWCp6UC52TCZ2Td43oVJrhUJjgTJTbSJPeSJHaRpDW
RYrRQYrTP3+/P39/PIvZPIjSPYfQOITQOIHNNYTRNYLOKI+/NoHMNIDMM4DNNH/QNH/LL3/PAH//
AH9/Mn3KLX3NMXvKK3zMKXvMKnrKKXjJJ3nMKHbHJnfIJXjJI3fLJXbKJHbII3bJJXXFJHXGJHXF
JXXEInXHJHTHI3TFI3PGInPGIXTGIHPGIHPEH3THVVWqIHLECV6yAwICAgEBAAD/AwAAAgAAAQAA
AAAAAAAACP8A/wkcSLCgwYMIEypcKDAXrlmxYs3ClYuhxYWrXmnK4ybNmTFjzqBxk0eTqlUXU/5T
5elNGScrIhxI4MBBggMRQDQh88ZTKZUKUVliE8XCAw9BiAxhESIEiyFEgnh4YOHJG1JAD5p68ySB
BqUeIDzoUCRJEiMdHowdckQAG15ZCZKKVIZCBiMtKGCAYobNnEeQID2a08YMlAwCmFCKO/CUoygJ
klYAoSUOp1e6DO6C1UnOlTOxGP9rlSeJBCMfJlzJcwrlwluk9nBi3MpRkgtHOKxgQwqVSksFs3W7
GAmKhCMakMxxLfofM0CMtJ1TeKpMAiMckDRK1VygO0MBXGz/ATTMGz2Dsd5QCPJhxZxX3QWi+8LA
BgkCP7gAMpaNYKUmGgwxARuyxCeQMlKoIAMNOZCAQhfD9CeQLWlcV8EVoRj4DzyDMLADDDSQwMUy
42hD0CZQaMDCCnm4omE4XQQwggs1kLCFiQTN8kYFRESgBXcaAlMCFYV0wQAODBQSD0GukPHAEBjE
McuLhgSSjT2GkJCDAWCoQ5AmTXjgARSzacjMNOQIxMwUKaBAhTQE5bFCEAmYEZqGzhC0zhcK0BAD
MAP14kYERDzAxi4aGiRPIAXswMAg9gi0SxoHDNHBHIkepIgJOAzwhzwC1XJGAk89kqlBwdxAgwFh
wCPQLGM4/xACEpCcWpAxSsBggBde/gOrrLTaShCuunqRzqujtiBEI8IONIwOMrDqjkC8UDrEBnI0
K9AiKNjg6TwCCUpoAm81a08gBuSwwCCgCtQICy1AQAYs/iWqDhgE1ADDLwR1AkUHHjSx2EqeVJLo
NFagkMIU0RBEixkIEJHBIb18wgYcLhr4jiJaGvAFOgThEkcFQ/gIhxMYMPuikTmIUEi7A4VyxQXs
XSBAFq1ouM4vL8hwghVwxqzKJFlc0EIIRFDgRkUGcsOFCD4UAMg7A33yiBYdXEBECyx4wEQkGpoj
yAI5mEBFnlVDkkYWRiRAcwVk3NmdOIzM4IINLrdjkC6lPP+SxhUgBBCHLfGJA4wSJ/RQwBffKCRL
KHOkMXBz5DCihAk+NGBFMheZ0klBaF8EDjeCvJA4CUsIEw5j2QjjzXQLlfPNL1ws4EIPDSwBTOOM
oRMGF4pUYw47BsVjjjSKdOGCCDnYUIAVwvDO2JoCmGAFGIMwMowxxgyzSCBgVEECAzLwYAIDYiTj
TXPzBBKADzigYIABKPCwxBI8yE9/Djmc8Hwhw+mONwhhhREoIAU22IENZAADGMgggTVIgQFGYIVA
OGMcGurGNArxhSm8YAEDmN/8BrCAF1ABDIVAk63OMY5o/GIQfwiDF7wQhj8MAhjRGEeatCUQecDD
HepIhzsH4AEzHgorIAAh+QQJBQD/ACwAAAAAMAAwAIf////7///3///0//7x+v/w+v/w+f/v+f/t
//vs//ru+f/u+P/t+P/s+P/t9//s9//r//rr/frr/fnq/fnp/fnq/Pnp/Pno/Pno/Pjn/Pjq9v/p
9f/o9f/n9f/o9P/n9P/m+/jk+/fj+/fl+vfj+vbi+vbf+PTe+fXd+PTc+PTk9fve9/Pd9/Pc9/Pb
9/Pb9vLj8v/k8f3j8f7i8f/i8Pzh8P/h8P7g8P7g7/3f7/7f7/3e7/7e7v7d7v7d7fzc7f7c7f3M
///a9/Pa9vLZ9vLY9vLX9vHY9fHX9fHW9fHT8u7a6/zY6vrR8u7F7enB7Oe+6+a/6uW76eXV5/jK
4ffI4PfH3/XF3vbF3vS54Oum4duY3ti50vSuz++ly/Cfx++Zz+abxvGXxfGVv+iN5MmP3NaI3NWG
2dJ31s550shsz8dmzsZhzsZ8xdFjyMJYycBYxrxSxr5NxbxKw7tJwLZFwLcA//8A/38A/wBBv7Y/
v78/vqM5wqsAv78Av3+RtvGFu+9+seR3sep4sOF2r+dvreppp+VmpuVond9Vqv9btrZVqqpgouVc
n+FYneE/urM5ubA0ubAytKcvsag5r6MktKopr6UsraEhraM3p7Enp6MjqKAhqaAgpZ0eqqEfqJ8e
p58eopwYqqAZp50WppwWpZsXpJsRpJoPpJoTo5oOo5gAqqoUoJkRoZgQoZYPoZgOopkOoZYRnpUP
npUOnpUPnZUNoZgNn5UKn5QMnpUKnpQMnZMKnZNTmuBQmN9/f/9Wk9pJk91JkdNHjdJBitM/geQ/
f78/f387itk6h9A5htM6hM85f8w2hNI0gs41gcw0gcw0gMwyhs0DmZAxgNAwf84Af/8Af38yfsot
fc0ue8ore8wpe8wpesoqecooeMonecsmd8gmdsUleMwld8kkd8ojeMokdsgkdcckdcUldcQidcYm
dMQkdMUjdMUkc8UidMcic8UicsUgc8YgcsQfcsVVVaoMYLQDAgECAQEAAP8DAAACAAABAAAAAAAA
AAAI/wD/CRxIsKDBgwgTKlwoUJeuW7Nm3bqFi6HFhbBecXrEBo2ZMmXMoGGTZ1MrVRdT/oP1KU6Z
JywmIEgAAUICBBNWPCkT5xMslQpRYVIjJUOEEi6KEGmBAkULIkWElIiAAYoaTKiAGiT1JkqCEEpL
SIBA4kiTJkdIRIhAAmqIBE/ejNIq0FSlMhVCIHFhAQSUMmvoQJo0KVIdNmWggKDQAokIBGlEaU0V
SUoCIUUumNgi55MrXQZ1veokZ4uJC0YwrHEFtNWjJhSQnKigJc+pnxhP5dEyQEsqoKwiNQGRRMQK
NaVOqTxVSk0dWUArQYkdQkkd3FpPzVWZqkwCx0oeof+kS7fWGwtCTqyow5r8QWzZuiXE9CQEkQpq
YrlHqGxMr3IH7aLGdxdoQcp+B6UTSAA4jIHMOAV9AkUILZiQB3QIFhQMEzDMYMAUhGgTj0C3xIFB
ERRs0UqGBYUTxgE5zJDDBwJgYYhAs5QRAREgyJELiwOx44gMNsxgZA5XeEGIQJw8UQIJUHwC5EDZ
XBEADDXU8AEVz8BDj0CPrCBEAmXUMuU/4hiCBSDAfMGADTj4MhAvbExQRARrgDYlMsRk0049hCjQ
wwKF1NMQGggQQcIcZ2KjDEGMbMADAYB8+c8uZiTgwhCQnGlQMDfcYIAYI/5DSxkQoKDEJJ4WNMwS
Mxz/EAY6Ap2aqhKStErQq7GG0Y5AuZyh6Qud6ipQMDrccACpAu2CKBEjMDpQJZ2c2QgHOVBqKS/n
FTGBG9PQMoollZxJjyAHDFqIpf9AMkQLFJTxCBpSwIEhkO2EUQAOMvQiEC+3NClCCy6YIIAU200J
zRUfbPmMQGtsEQURJjSVggnPnfkOIxrwcMAX6QgERxQDiEAECkJAUMaKZ4bjBQM8PHDIO82WskYT
CaBwghKReCpOL0RycAU0BaFSyRkvCKDGLJ5u00UDPxggSKkFwZLHGZZ4ig4hC/CwQRXNJHSKKKGc
SY4jNMCQgwOG/GqsQeH4wkQHUX8hn0rYcEOeOY4w/rEBEA9cgQxQ6jgSyDbgqATONoLQQLcGUwTj
DVDedCFAF718Qw5D5nzTSxcLwPDDA1P48g1Q4hDywOgyeMFINOfMY9A850TDiBcxPMBDDgZgEczp
QFEDCAEc/FADAxpcIQYhjgRDDDHBNCJIGFZowEANP2zAwBfIbENeNodYUQAHPOzwQQEHfOADE0z4
4MEBCnzAAw8cGGCFIXrvB04zgmDxQPo56EEOamCkGuSABzf4wAEegAVBNCNxLCoHNA7xBSrIYAEE
OIAGD0CABdCgCmE4RDQA5ClzhOMZvSgEIMTwhTCIARCF8MUzyGGOtw1kHvBwRzrSsQ54yM6GbwsI
ACH5BAkFAP8ALAAAAAAwADAAh/////f///L7//D6//D5/+/5/+3/++z/++z/+u37/e74/+34/+z4
/+v/+uv9+uv9+er9+en9+ej9+er8+en8+ej8+Ob79+T7+OT79+P79+P69uL79+L69uH59d759d/4
9N349Nz49Oz3/+z2/+r2/+n1/+j1/+j0/+f1/+f0/+b0/+bz/t73893389z38+Py/+Px/eLx/+Lx
/eHx/+Pw/OHw/+Dw/uDv/t/v/t7v/t7u/t3u/t3t/Nzt/tzt/dv389r389v28tn389n28tj28tf2
8tj18df18dnr+9T079Ly7tDx7cvw68Hr58Ds57/r5r3q5bzq5dbp+svi98jg98jf9cXe9cXd9Lvh
66Xh25nf2LvP7KfM8aHJ8J/G7Z3I85rL2JnF8JDd15Hc1pLa1I7d14jc1XvY0IDSzHXQyW7RynzG
0mfNxl3MxGDFvVjIwFTHv1DFvUzCukfAuELAtwD//wD/fwD/AD+/v0C/kgC/vwC/f5yzyYa67IS4
63uz6nqw5nut3nWw4W6s6W6p5Gun4WWm5lWq/1OxsGCi5Fyf4mCc2Fmd4VWc4kG+tj28tDW8sj64
sjO1rDSwqS24qyOyqTCwpSqtpCGtpDOrpSqqqiWpoCGonyGknB+soB+onx+nnh2tohqonhynngC2
kQCqqhmkmxalmxijmxWlnBSkmhKkmhCkmg6jmROimBChmA+hmBGglw6imA6glw6flQ2imAyglQuf
lRCelQ6elg2dlAyelAqelQudlAmck1KZ30+Y4VWZzFWU3X9//1KMzkqV20mS20iM0kWIzkKK0j9/
4T9/vz9/fzqK2z6H0DeF0jqCzjOCzyKMvzSBzjGBzTR/0DSAzDR/yjF/zgB//wB/fzV+yTB8yi18
yit8zCt6ySl7zCl5yil4xyd5zCZ4zCV4yiZ3yCV3yCR3yiN3yiR2xyV1ySV1xSN1yCN0xiR0xCNz
xSJ1xiF0xiB0xyFzxiJxwlVVqh5xxABVqgMCAQAA/wMAAAIAAAEAAAAAAAAAAAj/AP8JHEiwoMGD
CBMqXCjwFi9aEHXdssWw4sJasDg9anPGjBgxZs60ccTpVSuLKP+1+gRnjJMWEAwgaNAAgQEILJqM
gfNJVkqFrDCpgVLBAYcfRIb8AAHCxRAiQDg4qABFDSZWPw2mevMEAYakHB400GBEiRIjGhwc0PAU
A4Imb1JlFXiqEhkIGI64oGDhSRk2cyRZsiRpDpsyTyxEcHEEAwQylVD9dAUJCgIgRCR80BIHFCxe
BnnNAiVHywcJUBFEgfQKpatHSyQc8TAhi6NVtRi2WuUoywQPRyQsoWOqIuUlFo5kYMEm1aqUq1Kx
YbGhiAM3ripWgiL7gpI5Pue2/5qzJEAarAxVkUGgXMkjWHMH2pqDRlRFXG8oAPHAYg78+AOZUolF
mDSBwRATsDELgHPpogZ7FWQhF4NZfRIFBi584AguFCbUzTcG5QJHBUREoEUsHSKkjiKKpFMQLmI4
MIQFceiSokHiGIPECoWMQxAoTnDAwROc3GhQM1eQEMMIfoAz0CMt/PCAGBwaOZA3XBSAQw0zFBAG
Nv/40gYFRCDARi9WClROH1rGEEMNLwRQxT+9pGHAEBjIkeY/3vgRwAozvLnCFFxw8c8uZiDwQxCR
pGlNM4AMwsgiOthQQB/3sPOPLmU0EEISklh5zTPX0HPPPckgUUMBX5gjUCydfv96iS++8NIJJqBY
aYwPXX7hzj+4+IJGA0ghMkcbbFCSq5XF3GADAWH8qoUWTXAQAgghcGDeKXsqUkIOA/RBzz9NBNCB
C0wB0QAa4VlJzx8E7LDAIPf8IwoZDoTgghAQZGHfnu98UYANMfwy0CppVACCBVEMuOc/01CRggpU
WEMQK290kAQk2e1JTyIk6MCqpgTVIoccrT1sDhcL6CCCIfIYdEpxD7PTCAw2mGDFNA8rhKUIPRDw
Bzw9I3QOIAroUAIVz1jUTDcdnsMIDS/g8PI7FXkTBiPtMFgOMEigELQXTjJEjp9SMIJOfOgwgkQJ
PjBgRTMViUNIvCnAAIg3PqLyNI43gNAgNglSFCNORd00IgXQLyjAxS/hlMNQOeH8woUCL/TAgBTA
HG6ROcVcQQAOOjAAQxeJWKNOzAXJo841iXQBAwM64ECAFcWE89M3zXihQAk91LAACVaEIakxySRj
DCOAhGEFCQvU0EMJCnjRjO5zgWNIFQSYoIMOKQxQwAk8SCEFDycUMEAK35swQBWGlA0gOc/8YYUI
Bahwww5bulkD6TdQQQFEcIU/PKNvHUKHNQzRBSrAQAHiK4AEB6AAGVDhC4aYxtrSlA5zWOMXg+hD
GL7whTD0YRC/sEY5XFQ0gcxDHu5QBzviMY9xtbBoAQEAIfkECQUA/wAsAAAAADAAMACH////8vz/
8Pr/8Pn/7/n/7f/77P/77P/66//66/367vn/7vj/7fj/7Pj/6v356f356vz56fz56fz46P356Pz4
5vz45/v45Pv45Pv35Pn24/v34/r24vr24fr24fj04Pr23vn14Pj03fj03Pj07Pf/6/f/6vb/6fX/
6PX/5/X/6PT+5/T/5vT/3/f03vfz3Pfz5fL+4/L/3fbz4/H94vH/4vH94/H84fH/4/D84fD/4PD+
4O/+3+/+3u/+3u7+3u793e7+3e383O3+3O392/fz2vfz2fby2Pby2Pbx2PXx1/Xx2+z91vXx0/Pu
0vLuz/HtzvDsweznwevmv+vm2er61+n71uj5z+T4yeD2yN/0verlvOrlxt/2sebhpuHbxd71xN30
zMzgtNPyp8zxssXnn8jvnsftncjymd3Yk9zWkN7Yj9zWiNzVjtLYm8bxedPMl8PvdcTEbM/IbM3F
a8rDYMzEWMnBZMK7Vce1UcW9AP//AP9/ScK6R8C4Sr+0Qb+2P7+/M8zMAL+/AL9/iLrrgrXofLPq
fLHneLDndbDXe63dZLLWVar/Y6rARri4aajmZaXmYaLkXp7fWZ3hXZvaU5rgUJjgPr20O720Nbyy
N7atMLGoM62lKLWvI7KoKLCmJq2jIKyjLaW8I6qhI6ugIKifI6ecH6edIKWcHq2hHaqgGqqgG6ee
GqWdFaacE6WbGaOaE6SaEqSZEaSaDqOZDaOZAKqqGqKdFaGXE6KYEaGYD6KYD6GXD5+WDqGYDp+V
Dp6WDKGXC5+VDZ6UCp6VCZyUdYT3T5ffS5HYSJTgSI7TRI3WRInHRYfPP4PmP3+/P39/O4jVN4fX
NoXSOYLONYHMM4PQMoHOMoDOM3/ONH/ILn/QAH//AH9/Mn3JL33KLXvHK3vLKXvMK3nHKXjJKnfG
KHnKJ3rMJnjLJXjLJXjJJHjLJXfJJHfKJ3XHJHXGJHTGI3XGI3TEInXHIXTFIXPGVVWqH3HEAFWq
AgEAAAD/AwAAAgAAAQAAAAAAAAAACP8A/wkcSLCgwYMIEypcKFAYsWG/IhITxrDiwlq6Sl2q84aN
GjVs3tS5VGpXLYso/9EqlSdNFBcOChxAgOBAAQcvoqzJU4pWSoWzQsnRQiEBhyJHjLwQIYKIkSNE
OCSgoEVOqFk/Db6yI+UAhqQbDCTYkMSJkyQbanJ4iuGAFDuvsgqE5SmNAwxKXjywMGVNHT6aNm3S
xKfOmikWIrxQgsFBGk+ufsbKtOUA0gkh0OQ5xYtiQWK8TuVB02LCkSIHtGTKhTIXpicTlICA4OXP
rJMXZ/3xAgGEkglPMLFmiCvTkwpMNLiY4ypWylmu5rjQwKTCk0y4GHrSEvtCkz4+5fr/6tPkApMJ
WzwtlJXmgBINTTDtkjtwFyYn1A+giYywl50IRYDgQh+80EcQL33IoEEGb6ySUChTfAXBHL4YWFAw
c2RgR3gHASNHAkpQ4AV/FhI0CibOJcTKFhgQEcIfvZRYECoOJjRMHhYcEQEausj4EzBrGHCEBXkM
42NKp0zBAQdRkHJkQt54UxAmLxDhWIxPGmRONNMQ5F8ERxwgh5FZEmROMljAcY5AuBRDBwJGbPBH
MWUOhM4kVpRAgiHs/NPFGl1oIEIReAgGyimhlHJkOo/YgIIPNKgQyTtMBNDBCEyBgIQHbyR6JDaE
kBCDDjToAIMVyGjyxAdENAWCBA0e/0mNNITA8EMMNNBwAwsBLNFLHhmAYIQGLdTBYYnVTFNNM8so
QwmpKYABhxj/8CKHBBVA0QdWdf5zzySPEqDIPeMINMsaUnTCbbf0GCIAEAw88g5BoHiSYrf/vFOG
AjrkcMyMqOA7EDVYsLACF9UIjJA8kJTgAwFuzKuwQeSMwYAPJUAij0LbaJPlO5PAoAMKYGCj0DnH
dPlkOGKQMMQAhmyMEDqPqHDIPEfOc8gCPpyAhcoHbVPICSngMEmfJbIziQ0x8LDAIzIfFM4YAiyR
AhXHqGOhOsdQkYIQA5hhzkLSfNHAECdQMUk79LUzCRUnDNEAF9IwVE4yVpggRNGIhPazJkrnhIOI
DV+bYEUy5VREjiVWNCBEDAuIUYk5SCuUjjmViLFADEI0YIUl5KB05hcD8OBDAzOMEUk279RjED3v
YBPJGDM04AMPA4CRTOgphSONGQucIEQODJjAhRuITILMMssgMwkibnxhAgM5CHHCAmZIEw594jyS
xQCP+rCCAASoEEQVVQShAgECrNCDDygIkMUj4pR4zjSGgEECASzsAAQPOchVDngAhB2wgAAk+IIh
poGOI7XjGpA4AxZqsADyEeCCAljADLBQBkhkYx11Woc6qmGJRxACDmc4AxwI8YhKVIMdbJtYPeox
j3e8Ix4znJjAAgIAIfkECQUA/wAsAAAAADAAMACH////9P7/8fr/8Pn/7v/77/n/7vn/7vj/7f/7
7P/67P367fj/7Pj/7ff/7Pf/6//66/366/356v356f356P356vz56fz56Pz45/z46/f/6vb/6vX/
6fX/6PX/6PT/5/T/5vz45vv35Pv45Pv35vr34/v34/r24vr24Pn13vn14Pj03vj13fj03Pj05PT9
5PL/4/L/3vfz3Pfz2/fz5PH94/D84vH+4fH/4fD/4PD+3+/+3u/+3u7+3e7+3e393O3+3O39zP//
2vfz2ffy2fby2Pby2PXx1/Xx1vXx1PPv0vLu0PHt2uv82er5yO/qwOvmvuvmvOvm1+n61ej5y+L3
x9/1xd72vOnkvOLsqeLcouHcxd30vtn0stLwxs3nqM3xocrxnsftmd7Yk9rUkd3Xj9zVidvUnMfx
mcXwl8PufNbOdMq/b8/Ha87GZM7GZ8zAZsPBWcnBVce8Use+T8S7SsK2AP//AP9/AP8AR8C4Qb+9
QL+rNb+1AL+/AL9/hLjsfLLpfLHkdrDkeazecK3qbbbaVar/bba2VaqqSLawcKbgaKfmZabmYaPl
Yp3dW6DfWZ3hVJrhPLu0NLuyMbmwM7SrNa6mIrOpLa+lJa2jJqyiK6ugI6uhIaqhH6qiH6mfJKif
IaigH6efH6OeGquhG6ieHKedF6adAKqqHKqNGqWbFaWcFKWcF6SbE6OZEaSaEqOZEKSaD6OZCaWB
FKKYEqGXEKGXD6KZDqKZDqGXEZ+WD5+VEJ2UDp6UDaKZC6CWC5+VCp2TV5nhT5jgS5XfSJTgTZDV
RZDdSIjQQI7aOYnZPYjSPYbOPYTPNoTTOILcN4LPN4LMNYLLP3+/P39/M4/CM4PRMoLSNIHNMoDN
M3/NM3/IL3/OAH//AH9/MH3KLn3MLH3OLHvLKXvMKnjIKXnKKXjIKHjJJ3nKJnfJJXfJI3jKJHfK
I3fKJnbGJHbHI3bHI3TFInbJIXTHIXPGOHHGVVWqH3HEAFWqAwEBAAD/AwAAAgAAAQAAAAAAAAAA
CP8A/wkcSLCgwYMIEypcKBAYsF67dvVyyLDiwly2Qklyo8YMGTJm1MSRFOqWL4so/+H6NIfMkxgS
ECR48CABAgkxnpSZIwpXSoWxOLGJcgHCCSFFiMhgwUIGkSIzTkDAcKVNp1g/DbKK8yTBiKQmIEAw
YUSJEiMmHkQ48XREgidxWGUV2OrSGAkjjsiYEAJKGTd5KmHCVCmPmzJQQliYcWSEhDGXWv10NelK
AqQUVIihIyrXL4PBdomiI0bFhSJCElyZBAulK0lLKBxJUSGLpFe3GPqClSdLhRRHKCyR1JohrUlL
QCApEaPNqlcpX61qE6MEEhBLJtFieCmKbBFJ8vj/nIsrjxIRwaFcWuhqjIIjJZJIkjV3oCxJSkoc
STDGVcJdclggxAoq5GFLfQTZkkcMKQhhQRy8IOQJFCIUUQEbuSBYUC5tVEDECE94clAvbSBwxAVZ
nKKhQatkcUESBKjRi0GmXBHCDAXusmJBukiiggUqsFFKQbXQEQIRFmix3Y5EipHFJHINpAktwZjx
QBEWzDEjkwSpwscpWBF0hRZwPHGCCVcMyWVBIhq0RgAXoCAEBllsosovpqypkCpZjCAECy2gkEQU
ZlBySSd6HmQLHSS0wIIQKCDghBucfJIoQq6IccEQESTBhiefXSqQOtcQdJwKIZRBCX2iCsROI4KQ
/2OqG3Ow2uo6x4SxwQvEnEMQKQe2Oo81fzRxgA4OfGFOqwVhA40gVAjwgg424LDBI+8wKxA0yhyT
hhVMwHCDDTp0wAU42g7EjTzgMNNFBjq84EAAgRzkTKvZWPHBB1QM8sUWBaEDTjHfXEoPIwv0YEAa
95CzDEHjENMFGOlces4XC/CgQSPuFMQNIDQs8EIkHa/pDiQf5MDBFtkYFM8fAjDhQBfh6BlOFw74
UAAg8RxkTRUc8HCAINkyCQ8gB/DAQRX3HhTPIg3oAEMNkKizozqQ0ACDDgssUvJB44QxwA8dNDFM
xQiqM0wTH/wwQBjlLKSMFQ4AwUETkKxTHzuQNP/RARAMWKEMQ+YUM4UGZNcAiDjopFSOOIHU0LYG
UxQjK0PnDDMFAz/AsEAXkZzTDkPqnBNJFwfA8AMDUwyzrEXnFLPFADrw4AANXzSCzTv0GDTPO9o0
AgYNDPCgwwBbFBN3SuMoE8YCHPiAwwIaVHEGIZAYs8wyxkBCCBpWaLAADj9wsEAYyohT3ziLVDFA
Bzzw8IEBBXjggxRS+PBBAQJ8sAMPHRhAFRYxjhWhwxmA2EIGCpAy4+HABtXSQQ90MD8HbAEQzmgc
k9iRDUacoQo2OIAACkBC/h2ABlQ4AyOwwY5LtUMd0hgGIf6QhjOcAQ1/IEQkopEOvaWLHvOARzwH
hgjEdDErIAAh+QQJBQD/ACwAAAAAMAAwAIf////3///x/P/w+f/v+f/u+f/u+P/t//vs//vs//rr
//rr/frt+P/s+P/q/frq/fnp/fnq/Pno/fno/Pno/Pjo+/jm/Pjm+/jl/Pjk+/jk+/fj+/fj+vbi
+vbi+fXg+PTe+fXe+PTd+PTc+PTt9//s9//r9//q9v/p9v/p9f/o9f/n9f/n9P/j9vnm8//e9/Pl
8v3j8v/c9/Pb9/Pa9/Pj8f3i8f/i8f3h8f/h8P/g8P7g7/7f7/7e7/7e7v7d7v7d7f3c7f7c7f3b
7PvT+/nZ9vLY9vLX9vHY9fHX9fHW9fHU8+/R8u7W7PbW6frV6PnN8OvB7Oe/6+a/6ua96uW66eS0
5+LJ4PbG3/fG3vTF3vbE3fWv4eKj4NuW39mT3NbG1O+41fKx0vGiyvGex++XzuWcxe2XxfKSv+yO
3NaK3NaL2NF41c5t0MhtzsdwyMWBvd1hzcVYyMBmwLxTxr5OxbxGxrhHwbhHv7hAv7Y/v78A//8A
/38A/wA0xK04vbQ2u7IAv78Av3+SuOaAtep8suh3sOZ3q95rqudlpuZln99eoeRVqv9WrKxaneFY
neJVm+FSmd9Nlt01ubA5tao2r6cvsagotqojs6kksKctqqQkq6AirKUfrKEfqqAgqpwno6dHleIh
qKAgqaEfqJ8gp54brp8dqp4ap54app0UppscpZsUpZsapJsTpJoRo5kSo5YQpZoPo5gAqqoXoZgT
oZgSoZgQn5YPopkPoZcPn5UOopkOoZcOn5UNopgMoJYNn5UKn5UNnZQKnpVYjuFIjs9HjtlDidE/
i9Y/f/8/f78/f387i9s5iNU8h9I4htM1hNE3gsw1gs42f8wyhM00gc0xgc0zgMwyf88yf8sAf/8A
f38yfcovfc0ve8gsfc0qe80pessoeMopeMYpd8YneswleMskeMwmd8old8ojd8smdsckdsgkdscj
dscldcckdMZVVaoidcgjdcUhdMYic8YNYbUDAgEDAQECAQEAAP8DAAACAAABAAAAAAAAAAAI/wD/
CRxIsKDBgwgTKlwoMFgwYLp0AQP2i6HFhb5kicoTh40aL17UsImTR1QuXxdT/ttFis6XKCEeHEig
QEGCAw9eRElDh9QulQpjcWpDhcKCDjSMFJEhQoSMIkZodFhgoYqbTrGAGmQlR0oCDUo5LFjAIQkT
JkjEHoWqIcEUOay0CmSV6csDDUlkQLggJU2cO5MsWZp0J04aKRcizEiiIcIXTHFVuppUJUHSCR+8
1Cmla5jBYblK1fHyYULUBFUAuUpZ6w8UCUlAROiS5xUuhrxc5ekSAUQSCVD+vLJIaxIUC0o2fHDD
anjKV6zcvNigxAITQLQYZqoCQYmGJXdkyf/95+vOkgxKJEzBtPDVmgNJOizJc3v8P1x/lmxIkuDL
aoKjDHQLHRTMEMIHd/Bi30C44PECCDRQIIcuBGUCSC23rFIFBkY84IaCCw7EixsRFKFBFJwQVMsX
XEwyhwNHQMAFKiEWpEoXE/DXhjADDUNHADIsAYIIIeCRXY0C5vGCDBpQQQpBpEihgQg0WMBFKuIh
OZAtXkBgBAV0ADNQL2sgQIMII8xglSWeaPkPMHVckAQFX1A40B0ezHDmBQFUsMYlmIiiZZQOHCDF
kwO1YsUBDnhgRRuToBKgm8KkEQUbgKQ4kDBsMMFGHqlU5OZAq/xRiqgFXbIJqqMSpOlBiLb/Kuus
tNbq5jUJQWPrP/JEE8pB8lwTCjezytMNJGg4QUg9BEEjCSFXmAHPqNJ0YwwhYbhQwABhdEPQNVgE
UAAWuCJZDTPMoFFCACfYwIMOLjxCEDxklCDECYswq6U0xxSyhQ442NDDAGjMM1A9iZTgAwNjrNOq
Od+EcQIPNqiARTUEVaOFCjnUAInDbpLzSAw2xCBEDgEoQs/BhQwgRAlifDNqxA38UMAhkohhBjkE
PXNFCj4YYAg7WrJDiAE/oKAFN++II8kzBM2DCAk8xFCDI0SHyM4iMMSgAwmJvDMQxgSJQ8YAQazg
hCToLJhOJEOwEMQAZoizEDNaNCBECk44/6LOeOo4MoQKQjSwRTMMjRPKEyekXUMh35SjUjngFFKD
3CY8Eco4Fjn9RANBxGCAGJCIkw5D5ogDiRgGxBBECU9IYvdF4YSyxQA8+FACDGMsck07KxdEDzvZ
LDJGDQrzMMAWocye0jfNmMFACkDkwMAJWJBhyCPGHHOMMY4YcoYWJzCQQxApGGBGM+GMF04iWQyg
gg8+sEAAASwA4YQTQNiPP/0qGEAWEAGOEKEDGv4yAQFcsIMf8CAHNrBBDnjgQG2VIAuFgIY5tHSO
aySCDFe4gQEGcL/7DcAANbgCGRJRjdO1Sh3pqEYkEEGIM4xhDGdAAyIiEY10/G1X9KgHPAzm0Q54
1CN4u5pVQAAAIfkECQUA/wAsAAAAADAAMACH////+///9/7/8Pr/8Pn/7/n/7vn/7vj/7fj/7Pj/
7ff/7Pf/6/f/6vb/6fX/6PX/5/T/5vT/5vP/5fP/4/L/4/H/4vD/4fD/4fD+4PD/4O/+3+/+3u7+
3e7+3e3+3O3+7//87P/77P/67P776//66/366v356f356fz56Pz56Pz45/z55fb75PH94/H93O39
3Oz65vv35Pv34/v34/r34/r24vr34vr24fr24vn13/n14Pj03vf03fj03/fz3Pfz2/fz//8A2vfz
2fby2Pby1/bx2PXx1/Xx1vXx1+v40vLuzvDsxu7pweznv+vmverluOjj1Of50ub5yeH3x971xd71
teHnp+LcnN/Zl9/Zkt7Ywdv1ttXzvs/rpszwocnxnMvtmcXwmMLsiO7rjNzWjNrThNbQctXOcs3C
bM7HYc3FXM3Fi77vbMS/WcjAU8e/TsS7ScG4R8G4Sr+4Qr+2AP//AP9/AP8AP7+/P761QL6qP79/
N7yzAL+/AL9/jKvPfbPpe7LodLDscK3qdqvgbKzgZ6bmZKDaY5vUVar/VqysX6HaWZ3hVpvhVZre
UpnfObavMbqxLbSqMK+pKq+lK6ukI7SqIa6lIKykIaqhH6qiTZfgR5PfK6OvIaefH6ifH6eeH6Oe
HKyhHKqhFaqUG6eeHaWcG6WbFKWbGKObFaSaE6OZEaOaEaKZD6SYD6KYDqKZDaKZAKqqFKGYEaGY
D6CXD56VDqGXDZ+WDZ6VC6GXC5+VDJ6UCp6VCZ6UC52UCZ2UZIjXSInNQozWQYfTP4/PP3//P3+/
P39/OozeOojUPIfNOYXSNYbJN4PSNILQNYHMNoDMNIHNNX/MLobAMoHPM3/MMn/MKX/NAH//AH9/
MX3KL3zKLHzLLHvJKnrKKHnKJ3nMKXjJJnjJJ3fHJXjLJXfJJHfKI3fLJHbII3bIJXXGI3XIIXXH
JHTGIXTHIXPFInLFIHTGIHPFH3LGVVWqDV+yAwICAwEBAgEAAAD/AwAAAgAAAQAAAAAAAAAACP8A
/wkcSLCgwYMIEypcKNBXL1y2bOHatYuhxYWxWnnKo+YMGS1ayJxRk8dTq1gXU/6D9emNliY8TIQQ
QYKEiBAmeDTR8uYTLJUKXWFK80RFiRtCiAz50aPHjyFEhNwooeJJGkysgBpE9caJCBlKa5QoUcOI
EiVHxIa4AVWGCCdvUGkVqOpSGRQyjgA5EcMJGTVyIE2aBEmOGjJOYqAAckRxmUuqgK6KBEVE0hQ7
sMABVauXwV61QMHBsiNFVBFQIq1SiIngLD5LThzRYeIKnVWuGMZaReeKCR1HTizhsxqhJ0tZVUVa
sgKJjR1pUGVNyQpVGh8zkKxYEmkWQlVm3Pz/MgVFdvY4P+fCiqNEBpITTywh7GVGAJoyI4rYQJIn
/dx/r+ShxAxHiKBFcQX14oYJMdAAhA45zHHLfwTVEocPOgiBghu2HJQHD0CEGEMbulBY0C1pmDCE
DE1cclAlS+DAlA5YTFKiiQOhckUKBaaRi0GpQFEDET3oAEIOaWSCo0C05OHDDzI88YlBtmQRQAo3
LAEFFmZEYomSONKSxQlEqPAGLgXRskYZgFFySmelLClQLnDEMEQJWnRIkCei8FKRnAd94kQNNzTh
CaAq2UKGZTzkgWhKv6hRQhEqrAHMoxfJUUMPAphxKaYMQcKDEk6k4Z1B1YBKkCR0THKKKIf+/zNN
NdwM00gyqg6kyUHkCEJFFBVwkqtC9LARgAUQMDJsQvMMsoAHBQhCz7IIPVKBBgOE4Q61B0EzRQQQ
VCHNsPLE80w0Ba3zhQEcNMDItnJeQ8863BDTyCBhDEJOQfAYsgAHBnixL47QJMMJG15sEYUECwDg
BbwESVPFAxi48Mg6cj4TSAsCUFABBxBw4Y1B7gAywAsLcNENoOwM48UEF1wQgRTLHMTMFA5wcEAg
6QD6DiEMZCB0BY8ctI4hCmxAgQuMmLOkOYtAQEEGDzRwwCDzHATOFwR8AEESjzhNoTmOwABBBwOI
AUgAbEx7kDJVJPCCA0kwcs5/5TACwwMvIP+wxTbwFCKGOAiJw0kUDHzwgAuBdBOOSuF0A0gLEHzA
gBScED5OMtAkJM4mUSTwAQUHcNEIOOgwlA44jXBxAAUfJBDFJoQP5IxC33CyBQEbcLBAC14wYk06
7xj0TjrWGOJFC/9uQMAWnIADlDfKiIFAAx5ccD0VYQjCCCfDDMMJI4KEQUUDCFzggQMIhKHMyHN9
YwgVBDzAAcgDFADBC0kk8QIEBdDf/R5AACoY4hs4GoczAlGFBRggAhrowAYuUIEKXGADHdBABAqw
gCoAwhmPk9M5pGGIMEzBBQfIXwALMIADuGAKXzCENO6GKXSMIxqPGAQbwvCFL4SBDYN4BDQUxpE6
askDHu5Yxzrc8Y6scUtVAQEAIfkECQUA/wAsAAAAADAAMACH////+v//8v7+8fr/8Pn/7/n/7vn/
7vj/7f/77P/77P/66//67P366/367fj/7Pj/6v366v356vz56fz56P356Pz56Pv45vv45fv45Pv3
4vv34/r24vr24Pn13vn13/j03vj03fj07ff/7Pf/6/f/6vb/6fX/6PX/5/T/5vT/4Pb33Pfz5PL+
4/L/2/fz2vfz2/by4/H+4/H84vH/4fD/4PD+4O/93+//3+/+3u/+3u7+3e7+3e393O3+3O392uv6
2ffz2fby2Pby1/bx1/Xx1PPv0fLtzvHsy/Dr1+n71uj51Of5wuznwevnvuvmwOrmverlu+nky+L3
yOD3x9/1wuDyxN31peHcmt7Ykt7YkN7XjdzVw9LfrdDxoMryv7+/nsjwk9Xbmsfym8Xul8Xzh+bg
eNfPd9bPb9LLbNDIb87EZc7GXMvDTsvCAP//AP9/AP8Ah7zwbMK3VcW9TMO7R8G4T762Q8C3P7+/
QL61Qb2NNryyKL2zAL+/AL9/q7DKf6nWfbXse7Pre7LodbDrcK3qcbPHaKflZqbmZqHcVar/X6To
WKe3XJ7hW5zeU5rgT5XaOLevPbOpM7KqL7KpLrCoLrCnI7KoI62kIquiJaqiHqqiIqigIKifIqed
H6ieLqOxR5PfH6WbGaqfGKWcGKSbEaSaF6OaEKOaFqKZEaGXD6KYDqKYAKqqDaKYEp+WD5+WD56V
DqCWDZ6VEp2UEpyTDpyUC56UCZ+VC52TCZ2RC5yTCpyTCpySB5ySf3/fSo/YR43VQovUQYrTRYvI
P4nSP3+/P39/OYveO4fUN4TQOoLNNoHMN3/KNIPSNYHNNIDNM4DNNH/OMYDLLIDVAH//AH9/NH3K
NXzJMXzJLXvKKnrLLXjFKXjIKHnJJnjLJ3bFJXnLJHfJI3fKJXbII3bHJHXFI3XGInXIJHTEI3TE
IHTFJXPHI3PFJHLFInPGIXLEIXHEIHPHIHHDH3HEH3HDHnHEVVWqE2W5AwEBAAD/AwAAAgAAAQAA
AAAAAAAACP8A/wkcSLCgwYMIEypcKBDXrVmwYM2ahYuhxYWuVHXKw8bMlixZtphhk4fTKlcXU/5j
9WmOFiYgIiBQsGCBAgQRQDDJMucTK5UDORlElSlNlAsNOLwQEmRFiBArggh5waFBBShpMJkCeokU
QVNzoDDIwLRqgw1BjBgRsqFBArRCMih4MmdrSkt7Xv1LdWlLBQxDXEy44GTLmjqRKFGKVGfNFicX
JqwgkmHClkunLk6CEokXpSgMllb4gIVOJ1W3DN6CJYoOlg8VpiqIsieVRUswkNhhAmFIzCt3TK1i
6MpUnisSPBChcKQ2Q0tHMmDgEETDBzWk7F5ERUrNBw1ELjT/t63QkpEPL1x0OGLnJ1CBrOoUybA8
yqWF5juEcIHBTsX3A62SRxHgKaAFeQhBFwIQQeg0iSwADgRLHR948IIFc8SSkCUdCLAAAhAEAMMd
XkX4jyxqSBBXE5gkxEcaaMSIRhpnzMGHUCaSckUFRCiQhi0IbZJLL0QS6QssnrRoIi13fLBCBlB0
YqKJqmABgRAVzJHLlADOQscFQUCQBSxcAviJExtwwASOZaoUyxYKvPBBHgRRYw899jjTJkK9rNGA
EBGwwYtA2iwSyKGh7IlQHWghYMag/8AjBgAGiACJogdFIsQKCmwB5D/meDECDksIg6lBlBgRwgJj
ChRqATMk/2HqqQRVcsQLFLT6TztkFEADD8DQSlAkEzQAgBa7CDRPHAPggEIjwg60B4xotJHZP+sU
coAOBRBCT7T/bOJLL76MQtAjMeAwgBjpgJsQM1OkgIIV0LiLUDpgFJBDCYuoY69B7iAygg4OeAHO
vwY9Y8UJNMTwSLsmOnMNOPbEU8/F9cATDULtCEJADyN0oc2UzyBzSByCHHqoIMgk5MwUJuhwwCDn
TKnNIzYEYMAABQjAwqwHpXPIqC3I0Ag5U54TzBQx5KDDDEsMo5A3Y3yMwg+PiDOlPImUUAMNKSQh
tULIWOGADyf80IjWAIrjiBIs1HADC2IvBE4oS5DQAwoyDP+yjTcqfaNNICyckEMKJZwQNUPdPLLE
Az20cEAXj3iD9ELieNNIFwfM0IMBUiQihQ3FWNRNKFYQgIMOI8TgxSLRlLOOQeuQA80iXbBAgg42
EGBFMPVA8vtF2yQzhgMm8ECDAyVYIQYhjQAjjDDANEKIGFSU4EANO5jgwBjJdPPP6aWntM0hVBBw
gg46oMAzCjwkkQQPKBRQAArsn0AAFYdsQ1A2LQucMgZhhREYIAU42AEOaDCDGdAggTZIgQFGYAVB
KCMcCWsbNBABBqYdgGf2K8AADhCDKYABEdFgG6bGQQ5mPKIQcSCDF7xAhjgU4hHM+MY4/iWPd5zD
HOY4xzsG5IEwYQUEACH5BAkFAP8ALAAAAAAwADAAh/////j+//H6//D6//D5/+///O/5/+75/+74
/+3/++z/++z/+uv/+uz9+uv9+u34/+r9+en9+ej9+en8+ej8+Of9+ef8+Ob79+T79+T69+P79+P6
9uL69uH69uH59eD49N759d349Nz48+33/+z3/+v3/+r2/+n1/+j1/+j0/+f0/+P1+ubz/97389z3
89v389r38+Py/+Px/ePx/OLx/+Hw/+Dw/uDv/t/v/t7v/t7u/t7u/d3u/t3t/Nzt/tzt/dvs+9n2
8tj28tj18df28df18db18djt+Nfp+tPz79Hy7s/x7Mrr7s7k+cDs57/r5r3q5brp5Kbk3sjg98ff
9sXe9cTd9LLg5aDf2Zrf2ZLf2ZTZ08HQ67LT863P8aPL8qLI7p3H8ZzF7pfF8pXD8ZDd1ozd1onc
1X/U6nrWz3TUzWvSzIS+5GvIw4i58mTOxl/NxV+/v1rJwVTHv1DFvUnCuUbBuEm7tz+/vz++qAD/
/wD/fzy9tDa3rja2rjC6sCe6rAC/vwC/f6qn13yy6Hmy6XSv5m+t6min5WOl5Vyg412Y2lWq/1id
4VWqqlKZ4EuV30qR2UuO1jawpS+yqSyupiOxpyOpoCCupB+roCCqnyCooCConR+onzCmoiGnniCn
nh+mnUSO10KL1DSUxxuqohesoxunnRymnBamnBSlnBmjmxSimBOjmRCjmhGimRGhmACqqg6kmg6i
mA2imRKglhCflg+glg+elQ6hlg6elg2glg2elQqflhCelA2elAqelAiifgudlAmdlHWB3D9//z9/
vzqJ1jmD0jaF1TWE0TWDzzSC0jaCzTaBzDV/0zWAzTWAyzV/yTR/yjOBzDN/zC2B0AB//wB/fzJ+
yjF8yS18yit7zCl6yyd6yyl4yCh5ySZ5yyh3xyZ3xyR4yyR3yiR2ySV2xiN2ySR1xyN1xiR1xSF1
xiZ0wyR0xSNzxiJ0xyJzxyB0xyBzxh9zxSByxVVVqgBVqgMCAQIBAAAA/wMAAAIAAAEAAAAAAAAA
AAj/AP8JHEiwoMGDCBMq/NdpYa9ev3Dd2gUM2MKLBUNlMkjrFSg+cNKc0aLlTBo4fDa9ooVx4ac/
qAbOOkWnjJMWEBIsYMBgQQIILZyUmbNJVkuEn7BQWmUL05soFhxweCEkiIsQIVwEEQKDgwMKUNZg
cnW0ICUPW2TRidLgwlavDDYEUaJkyAYHDuQKwbDAiRxVZQfWyeBCigcLRF5MsCD0TZ0+lCj1sfPG
zJMLEVwUwQBhi6VUZYW9WQDDQggYFTxgofPJlsWCwG6FopPlgwSuC6L8YXWU1xkFMF646CDFTiuy
C2e94iNlAogiEpbw4Y2RlRQLQWBIyOIK8NFXqtq0/9BgxMKS3RgvJSnAAUQIJXx8Bf43q04SDEYk
RLGE8U8aKU4YsUEATPA33yx8JKFBEQts0cpFmOzCSih+0LFGFnKsMt8/t9TRAggwUDAHLmU9pEso
loCyYS5tTCDEBU9gsuGMA6UiBQUMrvELjTP6YscHL2AARUM8bghLFi5aMMeOA2UDSTTfjJNMkQjx
QodbDpQh30DQWNFEF4RMSeVBnTzBAQdObELQIyywEMAX7ox5EC5lkPYBHwPNc8gDPoxwSD1yGiSa
A0JAAMcwAs3jhgA4qNBIoAfZIVcCaQgjkDtjGFBDD5FAapAfRYiwwBlMrhOGATQgMYqnZikRAgNa
kP/4zzpfoKoqqwRR4iqssr6T6aad4ipQH0O4MCoviS7a6KPC/iNpEJRa+k89hyCggwGG0CMsMHBM
YIShiAr0SAw3DBBGnLj6kkUAHniAJ5dTsKACFdAIi4kaUjARhZoDuXOqDiYkgq6nlsDCykuhELRO
IiTo8MAX4jSbEDVWoGCDDI2cI/FB7xRCwA8kdMHNxgcpQ8UJOiBASDobUnNMNvDEXNY6iJCAQwwz
NGLOhtsg8kUhiUQCZTpiKtSNGAP4oAIQj5Sz4TFNBJACEFR04QYkGB1jxQM/nIBEI+TM1w4kSMQQ
gwoCIOEMRuKQXYLSMxDCjTdlcRMOGDbnYEIX37T99A3ZfMaAgBePgBP2QuV000gXLNRgAw4DkDHw
ReBAYgUBOOhAggxgKFKNOfIYJM84ziTiBQsl4EBD6gYUAuhR3RwjBgIo+FDDAydUMYYhjUQyyiiR
NFJIGFOU8IANPJigQhc1nKDIht0gQsUAKOiQgwoGGKBCD0ggsUMKBhyggg46nECAFYjczcKqG4aT
DCFVkHAACzfwgEMNNNBQAw483MCCASWwQiGUcY5tiAIM0eBROaCBCOLJAAECyF72BIAAGUwhDImg
htMEkg1RJLBI6AiHMx5xCDeMIQxfGIMbDvEIZ4RjgwRRRjYgNQ94qCMd6VAHPOaxkGqQbEYBAQAh
+QQJBQD/ACwAAAAAMAAwAIf////1/v/y/f7x+v/w+v/w+f/v//zv+f/u+f/u+P/t//vs//rr//rr
/frt+P/s+P/q/fnp/fno/fnq/Pno/Pnn/Pjm/Pjm+/fk+/fl+vfj+/fj+vbi+vbj+fbf+fXg+PTd
+PTs9//r9v/q9//q9v/p9f/o9f/o9P/n9P/m9P/e9/Pc9/Pb9/Pk8v7j8v/j8f7i8f/j8P3h8P/g
8P7g7/7f7/7f7/3e7/7e7v7e7v3d7v7d7fzc7f7c7Pza9/Pa9vLZ9vLY9vLX9fHO+vjU8+/R8u7O
8OzZ6/vX6frV6PnD7OjB7Oe+6+a86eXL4vfI4PbF3vW+4e+q496m4Nue3tma3tiS3ti70/Wv0PCm
y++eyfSeyPGexu2YzuWYxfGWxPKQ3teO3NWJ3NZ+19B008x2x9GKve5qz8dpyMVjzsZizMRcy8NU
yL9Qxb1TwbRLw7tHwbgA//8A/38A/wA/v/8/v79Bv7c+vbQ/v38wvrUAzJkAv78Av3/VqqqMsOOA
s+Z6suh1sOZxrelrqulnpuVjod9Vqv9btrZVqqpho+VeoONdnt9ZneJWmt88uLI2t64yuK0vsKYx
q6QlsqgprqEgraIqq6Iiq6IiqaAiqJ4fqJ8hp6Egp50eqJ8ep58fppwkoKsZq6Ebp58Xpp0VpJoQ
pJoWo5oSo5kSopsPopkOopkAqqoNopkToZgRoJYRn5YPoJYQn5UPnpQOoZYOn5UOnpYNoJYNnpQN
nZQLoJYMnpQKnpUKnZQHnJJviPFOl99KkdlHkdlCi9RDidU/f78/f388i9g5iNk9hs06hM42hNM3
gtA1g840gc0zgM00f9A0f8oygc0xf80tf9IAf/8Af38xfsovfMctfMore80qecspeMcoeMkmeMsn
ecckeMopd8cmd8gld8gldcUkdsgkdsMkdcckdcUjdsojdcYmdMcjdMcjc8UidMYhdMghc8cgc8cg
c8Ufc8UhcsVVVaoOY7cDAgEDAQECAQECAQAAAP8DAAACAAABAAAAAAAAAAAI/wD/CRxIUOAnUQUT
KlzIsOG/SI8S5tJFqyKtXbkcalzY60yVWv9opdJ0Zw0ZMWCsiCGz5k6mVKw2ymw1pYMlU23CMFkR
QcECBgwWKICgQokVNppUyXT4SIiFKVIoNODAIggQFiBArAASxAeHBhSanKlUaqlCXWQUBLFggevX
BRl+ECECZEODBhu4YliwhA0pswVNSbnAonAEDEusnHnzKBJEOGl0XoiwQggGCGEm/QX8D84HHytA
eKDiBlOqjAV3wfr0psoHCV0XNMlzCrArMgEicAhSYU0vjalO2ZkywYMQCUbutDLLyVIbK0YiGFDS
SWYpUmdUaHBqJM9ys7ZSRf9SQyXDmVtLVcEhguF4k0mcBdo65ahN9aWp7hDZviBM7fgCnTLJJ2bB
AocKHvhAARuxLDTNOwA6NMsZEwSBWCUKbTOIIMt0w0yEC40SlRALnIFLQtE8EYATZhgDDYgJxWLH
Byxg0MR9A8VDiAg8CICFNjAq1EoVFVbAhi0EjbPFATiUoMg8QSZ0SxsXANFAGA0O1MwTKaAAhTNR
KqQJExxwsEQmBDXyAg0EeHFOmAnJAsYCLKhwx0DzCJIADgcIIg+cBfGSRgNBQOCbQPGYMUANKDAC
aEJw5KUAGbsIxI4XB8iwAzCPFvQIECssIAZ6/5yjxQEwICFMpwRFUgQIDFj/AYtApqKqKqsDuQqr
rJZ+kemmuArUVKijCgSPojWc4GiwkQKhwBi8IKonn37iKiihEKgRrUBqztDmm6zKEsYCPthJ0JZd
QtEMrpwwsQEHSqA5kJJMkpAIO53y8kYGVlqRpUDrEBICDg5k4U2nghkghJGkDuQMFCbI0EIj4wD6
SR5jKGHAEjgOxA4gBegQAhbZPFpJKpeowcZ3BSnzRAk4JACIOazuEspC4whcgwsxMCKOWdAcsw2I
2nBRAA8mHPFLOGZJk8gv3KAD4DFQPMBDCUcw8s1SH5eQhSDChCO1WeD8ksQISMcASDZAbhSNEwE4
kAQXiSTz4lLcmB0CDy4454BFI9xs7ZA8O+qQQggB/PGzWXlDUUANODzwQhaKOEMOhAW5Iw4zhWTR
Agwy1NDCsoBpcwwXCZTAgwwOkACFF4IwAowwwgCjCCBbOEGCAzP0TsIV2ESYDSFPEGACDjigcMAB
KORwxBE2lEAAAingcAMJJOAwwB/4RtiNMoBAEQL1NehQgwwwwDDDDTrMoLwDV2AxQg+cBvlNM4Rs
8cQLCQyw/PIDSEAMnuCFRGADGSjAAjjghI77NUIQZvCCFrTwBTMI4hfO6AbNzpEFQPypU/BgRzrM
cY52wANzBAnGqoKlEWtYQyMBAQAh+QQJBQD/ACwAAAAAMAAwAIf////4///0//7x+v/w+v/w+f/v
+f/t//vs//rt+v3u+P/t+P/s+P/s9//r//rr/frq/frq/fnp/fno/fnq/Pno/Pjn/Pjq+fzq9v/p
9f/o9f/n9f/o9P/n9P/m+/fk+/jk+/fj+/fj+vbi+vbf+fXf+PTe+PTd+PTc+PTm9P/e9/Pj8v/d
9/Pc9/Pb9/Pb9vLk8f3j8f7j8Pzi8f/i8f7i8P/h8f/h8P/h8P7g8P7g7/7f7/7f7/3e7/7e7v7d
7v7d7fzc7f7c7f3M///a9/Pa9vLZ9vLY9vLY9fHX9fHW9fHT8u7a6/zY6vnQ8e3C7OfA6+e/6+a+
6uW86uXW6PrK4ffI4PfH3/bF3vbF3vS35Oam4dua39mT3de41vK+zvepzfGgyfGfxuyX0+CdyPOb
x/GWxPCQ3teO3NaN2NKH29R518910cpt0MhpzsZ5w9JlzsZezMReycFXx79Tx79NxLxJwrlHwLhC
v7dAvrUA//8A/38A/wA/v789v5oAv78Av3+wst6Hu++CuOt8s+p4sOh3ruR1sOZurOprqORmpuZV
qv9btrZVqqpgo+Vbn+JZneJYm+FDu7I7u7I2urE5tKo0rKIvtKsvsagssKUqraIpqqQjtashraMh
q6MhqqIiqJ8fqJ8hp6Afp54dp54gpZwaq6IYp50Xpp0YpZsVpZwUpZsTpJoQpJkWo5oQo5oPopgA
qqoOopkVoZcSoJgRoJYQn5YPnpUOoJcOnpYOnpQNn5YNnpYNnpQOnZQMn5QKnpQKnZIKnJMJnZNU
mdxQl99/f/9YktpLlN1Gj9hFiNBBitE/f78/f387itY6htI4hNE4gsw2gc03gM01gtE0gcwqhsQ1
f88zgNA0gMswf88Af/8Af38wfcwue8grfMwqe8soecsoeMgnd8Ymd8gld8okd8skdsgidsokdcYk
dcMjdcYkdMQjdMUjc8Ujc8QidMYicsUgc8Yfc8cgcsUfcsRVVaoPYrcDAgICAQAAAP8DAAACAAAB
AAAAAAAAAAAI/wD/CRxIsKCwOW6EFVzIsKFDh6egcOn1D9ivX7tyXQT2sKPHf7rcCJACalIcNmrO
nFGzJk4eULBkfZw58JKTEUaeFKFwAIEDBwgORFDxpAudUDJpdtylBgEREyFaHDHi4sQJF0aOEBnx
oMKUNp1aKW04C88LqydQSIDg4cWSJUVEOHiA8wgIBFDmrBq7UFWaACSIXE0Dpw6lS5co2YGDJooH
CS2SgIjQhZMqvgM/aWqzJAKKEpKGLQRma1QdLiUmaEUwhRIrzANhXUpTIsCaXA5hvcqzhQKJJBOc
TKIFe2ArPFqmuOrYSpUbFSGUWHBCaZZHbeEcvjo1J9NHWXeWfP8APoVTx2+CDoEr57AVp1EfYU1a
EiLJgy6vG7JTNKABmEjYPARffHeoEFgFc9zSEDRWaCBEAISIU1xBuLhBgV1QdMKQO4QUEIR/30zY
1xYVJIFAG74sVA0WGuAQQyTjiFhQLXiU4AIIU4RSkDuKNODDAmHEKGNBtHABwREW0JHiQOmEYYAP
GDjizpAF8VKHB0Y8gIaCA0lTRQodYFENlQuFEsUII0ABCkHFrKADAWWwQ2ZBt6CBgAss5DEQPYgo
4IMBh9AzJ0HCwOHAERHEIdo/9AgywA4dQDJoQXaIYMQBayj0jztmGHADEMlMShAlSLSAgBq7CJQO
GQbMQMUyog7/hIkTJzhwBpertvpqrALNWuutArXT6afI8PoPqaaqQRGjju7AgaS83mEpphz9Uw8i
C/xZSD2xBgPHA4gqOlAxNbwZZ6y+2ElECXp2aQWYV4wpqpkijPDEmkyW8WSU70xqJZb32UJQOz3+
CYaQcxYpwREV0LHsQNVk0SIMkchJJo0ltICjjjt2KEQDXoRIpiokmtjGwwQxmMGPhaRDJStsCJBE
CE9oyJA6iSywwwoyQELOTNk8ZModJB6QoEPhiOHhBk0Uw55H2TiTXUOtrAIHG6l05AwWDAiRQROQ
mPPRMop0MzVDr5jikTjIUIFBEBvIUMg3ZzfkDRZeRFI3ZuIU5EMFA0GsoAAYxIQjdkPrCBIADGIk
8zRsbGdRwA4+MABDGI5kc448C9VDzAo3KNDEIM9QU9w3zoihQAZB3LAABleUUcgjyCSTDDKOGCIG
DjPsHIAZ4IgITiJXFKCBDz50YIABGvDABBM5ZGDAAjfMMAMNOkTys4jlQENIFg0YkIIOP/SQwww2
5NDDDzd0EMMOBJixDpnmVKNIGFXEoMAAyxtQAAEK0EEVIEUFZ0zKHOSQRjEQIQgzkIEMZhAEIooR
DSwEoBDtMJY85AEPdqyjHfCYxz/eAQYriMxYDaFHIRIhqJkEBAAh+QQJBQD/ACwAAAAAMAAwAIf/
///4///z//3x+v/w+f/v+f/t//vs//rr//rs/frr/fru+f/u+P/t+P/s+P/q/fnp/fnq/Pnp/Pno
/fno/Pno+/jm/Pjk+/jk+/fk+vfj+/fj+vbi+vbh+vbg+fXe+fXd+PTc+PTt9//s9//s9v/q9v/p
9f/o9f/n9f/o9P/n9P/m9P/f9/Pe9/Pc9/Pk8v/j8f7i8f/i8f3h8f/j8P3h8P/h8P7g8P7g7/7f
7/7e7/7e7v7e7vzd7v7d7fzc7f7c7f3b9/Pa9/Pb9vLZ9/LZ9vLY9vLX9vLY9fHX9fHZ6/rU9O/S
8u7Q8e3D7Oe78e3A6+a96uXX6frQ5fjJ4PfH4PbH3/bF3vbF3fTA4+2n4dyb39i7z+y/v/+nzPGj
yvCfx+2dyPKcyPSYxfCQ3deP3daS2tSL3dZ72NCA0sx2z8hu0cl5xs1qw8FmzsddzMRZycFZx8BN
xLtIwrlHwLhBv7YA//8A/38A/wA/v78/v5EAv78Av3/Vqr+RveiHuux/tOh6seZ+qdx2sOp3sN9u
rOpqqOVlpuZVqv9btrZVqqpho+ReoeReodxanuJZneFdnONJvLM9vLM1u7I+uLI0tKs3r6YotqYj
sqkrsagorqUhraNEoMkqqqAjqp4lpZ8hp58fqqEgp54fpJ4brKIdqKAXp54AqqobpZwXpJsao5oV
pZwUpJkRpJoSo5kRopgOopkToJcQoZcQn5YPoJcPn5UNoZgOoJUOn5YQnpUNnpUNnZULoJYMnpQK
npQKnZMInJKehNFxjcZUl95NldxLidBIlOBIkdlEi9JFhsxAhOI/f787jN05iNQ5hdE3hNE5gsw2
gco1gc0yhNUygc4zgM0vgLwAf/8Af38xfsoyfMoufMsrfMwpe8wqeskoecopeMgnd8YmeMwmeMol
d8ckd8kjdsomdcUkdcYkdcQidcYkdMQjdMUjdMQjc8Uhc8Uic8Qfc8UgcsQhccNVVaoebbwAVaoD
AgECAQEAAP8CAAEEAAACAAABAAAAAAAAAAAI/wD/CRxIsCBBUlC2zDLIsKHDhwNXmQmwBVguXb16
+YLIseO/VmoSeHCS5oxJNW8kiXoFy6PLgbbiVAjhogOCmwcMQHABhYycUi1fcmQlhwOIEEeDhAgR
pIiRIBwUWIiyZlMroQ9TyVligQgIEEaWLBmS4YACDk4xHIASZxVWh68mRXkgJEQkTZUmzXFDBooF
CUGSYHhgBlMqodu6MWSFactZOsAG9pIlSs4WFhOMCDkQZZIrl+UeGRLX0FSaAG8iF4Tlqo6WCB+S
TGgi6TPHcMakEAC0rSEsNW5+NXS1yk0LDUksNJkUi2OzKyN6BPAzreGqSaIewqLD5ILsKJggfv8D
Q+CHCimPejfclF27JCbID5hh5XCdIRE5XtB4pA5i+4ey0NHCB0JIEEcuDT1DhQk7MBAIOm8xZIsb
ERiBgRObMNQOIOWN4AU3EVqnBQVJHLCGLgZJc8UJNsAwzDkhMpRLHSwEgUEUoRTEziEj7NDAF+HE
2JAsW0hgBAVxoDgQOmEssEMJjLAjJEO7yGFBEQqQUQtB0lCxggpXVDNlQ6FAwQEHUIBC0DAw4DDA
GOuMyVAtZRwQhAuSDBRPIQzsUMAg8chp0C9uKGDEA29s9A88fwyQQwqOCMrQHBsUYQAawv3DzhgF
1ODDMZIaVAkSQRxwhpLphFFADFIgE2pBmTD/AQICWgrE5KqtvkpQrLPW+s87YxBQAw+g6irQqC6Y
qqQ8jT4aqbH/UGoppgLNU0gDfg4ij7GEGopopv8ME4ObYcSpay51CtFCHVx6qYIVYuoqShQboKnm
QOuo+mSUr+piJZZkLDSQOzz6COSrREJwZBy3FFQNFiy6CKOgs9Dowo05FrQhAUB4CKKgq4xY4hq7
MKQggw5COOYtFBZxYYYMnXNffvuRw1G8DvEiIIEGIthQN+T9gIISxIwDUTTPOIQKd/HNB9FzDgBh
ghKPmPNQNsx8bBAmaQhwBAXgceRNbiUITUMg3JDGkDyDAKK2QaaEtFxzHIEzjBQO/PBCA14MzfNN
OQbJU8h0WhfUShx1yOISOMZgQUAOO4wAwxeLSEPOOwPJ88gKBXjRjDcMrXLYS940AwYDJvxQQwMl
VBHGIIwQcwwyjdSQAwNYGGO0nN0YYsUAJ+ywgwoLEGDCDUAosUMMMeRQghKMqDemOM8AgsUIBayA
Qw863FBDDTfMEEMNMazACOiSllPNIWFQIQMDAxBQwPwv1DADCYZYras55UgzTCF/GIMYxOAHKryg
AH94G7T+EY93sAMd55DHFwIwBsUssCHh8EIVqPGWgAAAIfkECQUA/wAsAAAAADAAMACH////9f3/
8f/98fr/8Pr/8Pn/7/n/7vn/7vj/7f/77P/66//66/366v356vz57fj/7Pj/6P356fz56fz46Pz5
5vz45/v45Pv45Pv35fr24/v34/r24vr24fr24fj04Pr23vn14Pj03fj03Pj07ff/7Pf/6/f/6vb/
6vX/6fX/6PX/5/X/6PT/5vT/3/fz5fP/5fL+4/L/3vfz3fbz3Pfz4/H/4vH/4/H94vD94fD/4PD/
4O/+3+/+3u7+3u793e7+3e393O3+3O392/fz2vfz2fby2Pby1/bx2PXx1/Xx2+z82er51vXx1PPv
0/Lu0PHtxu3pweznv+vmvurm1un61ej51Of5yeD3x9/2xd71vOnlreXfn9/av9v1zMzmq9Tqpcvw
oMjvncjymsTtkN7Xj9zWktrUh9nUedXNiMrecsnGbc/Has3Far+/YMzEWMnBU8e+WcG8S8O7R8C4
RcC3RL+1AP//AP9/AP8AP7+/P761O761Pb6aAL+/AL9/xq3Ih7nqgK3ZfLPqe7Hlca7qdbLXaqnm
aqPdVar/W7a2VaqqZaXmYaPkWp7iWZ3hWJvdPLmwM7uxNrSrMLGoMq+nKbKpI7GoIa6kKquhIqyg
QKG2UJjgKqagIqqgIaifIaehH6mfIKieH6efIKWcHK2hHaifG6eeAKqqHKWcGqObFqSbGaKaFKWb
E6OZE6KYEaSaEKOZEqKZD6KYDqKZEqCWEKGXD6GXDqCWEZ6VD5+VD56VDp+WDp2VDaGXDJ6UDZ2U
Cp2TCZ2TBpuUeIP4UZbeS5LaR5PfR47VRIrTRITMP4PhP3+/OInYOIXSOIPPNYTUNoHMNYDONX/I
LIu+MoLNNIHNM4DOM3/LMn/LMH/NAH//AH9/Mn3JMHvJLnzJK3zNKnrLLHnHKXjIKHnKJ3fHJnnM
JnjKJHjKJnfKJXfIJHfJJnbGJHbIJnXFJHXGJHTEI3TFI3TEI3PFIXPFIHLEVVWqH2/ADVmzAgEB
AgEAAAD/AwAAAgAAAQAAAAAAAAAACP8A/wkcSLCgwX+wIDXZsuqgw4cQHb6S80SAGWG1ImrcSPDV
mgwfOmxh8waSqFqzOKosGOqSmQkghozQsEACjSll4JRKuVIlKktRKBQRQbSIkSEcGFjQwiYTrJ4G
v2UzSCvSEw1DRBDZoKABByNFMCiQ8oYVVIHgmIEBhI7qHBcgQMSps4ZMFAsShhzBIMGMJVU9xRnL
QiCFoXEGZbmZgESSMF+2PMHhEoKCESIKtERqpVLcpioQlKxgscmbQVhoPEwiKOsVnS0OQCSJ8GSP
q43hjFU5EWQFjkHOrh0shQaTwViq2MjQwKTCk0i0NDLLAkFIiiWO1EG8NMrhrDlOLsz/nmIp4rgw
BXov2WQu4qjuDmXtcaIhiQIzZh22M0SCRwwcjqSzkSgQ2TKHDCAQMcEbuDjUzBUp9IDAIOycddAt
bDgQVhSXHBSPIAUIUcIX31joECtbUGDfGr8YVE0WKuRwwybtmHgQLnq4QAMGU4BSkDyLlNDDA2CQ
Y6NDtXARgREUwOELQe2IYUAPJzACz5EH7SKHBUUwQIYuBEFzRQssYFENlg6BMsUGHEThCUGb2LAD
AWK8g+ZBupShABEy6DEQPYQ80IMBhNBzp0HAuMGAEQ24EYxA9AAyAA8sNHLoQXNsUEQCaAAj0Dxj
FJCDD8VcapAkSNCgwBkt/uOOlDZQ/4GMqQVN4oQIC5CRi0DvwCorrQTZiquuAsEzhgE5AFEqsAKh
OsSqT/4T6aSVMitQppt2CikhCAxaKLPAsLFoo48KtEkNc9bJbC56DtEnQdWMyUIWZwILihQctPnm
QK9OWeWVpv6yZZdlgDkQPEEOWSStSUrApJMFvRjjjDUeiqOOGGjhY0HwgBjEiCUeiqKKCrB40IMR
TqgdmrZkaAQGHDr0Dn/+ASjgQ9BsVAsdCCr4Bi8PgYOeeuw9JI1wEMlHn334RTRdddc5co5D0jwD
0XfhjVdeRILt1tsNg3xTjkHJADKVQaJkssYMzDkXyW0aeQZaEDEg8IUj40w9EDIwsLRlUCp7ZMAc
bbZ1NlgBPPRQAgxgMAKNOfPYc4wPJBhyM0GxvJFBZpv1lFYYCKQAhA4PmHBFGII8ckgMMdzgyDqJ
ocHFXxZ+YwgWBajQQw8tHECACjvYoIMKVhhjZEGlAGajOc0IkoUJBrCgww892GB9D6Yzgw2z6Fiz
iBhY4PCAASvkoIMNJIzRjDXW/sMOOtUQQ8ggXbTwAgqCjN1+QejYM0YAVGCE/vZXkHB0QQnFaI+J
AgIAIfkECQUA/wAsAAAAADAAMACH////9v//8vv/8Pn/7v397/n/7vn/7vj/7f/77P/66//67P36
6/367fj/7Pj/6v356f356vz56fz56P356Pz56Pz46fv45/z45vv35fv35Pv45Pv35fr34/v34/r2
4vr24Pj03/n13/j03vn13fj03Pj07ff/7Pf/6/f/6vb/6vX/6fX/6PX/6PT/5/T/4/X65fP+3vfz
5PL/4/L/5PL93Pfz2/fz2vfz5PH94/D84vH/4fD/4PD/4O/+3+/+3u7+3e7+3e383O3+3O392uz8
0/v52fby2Pby1/bx2PXx1/Xx1vXx1PPv0vLu2er61+n71uj5zvHswuznv+vnvurmu+znvOnkyuH3
x+D3x9/2xt70xd71xd31u+DtqOHcnuDaudbxzMzrs9Lxqs7xns3snsfvm8Xtkd7XktvVktrUitrU
dtTNjsTmcc3Ga87GZ8vEar+/Yc7GWMjAVci/VcS/TsO7SMG4R8C4P7+/Qb+kAP//AP9/AP8AJb+q
AL+/AL9/r7LghbrtgbLifLLperDnd6vfcrLdda7mbarnZ6fmY6TlVar/W7a2VaqqX6HiWp7hWZ3h
UZvfQL2zO720NbuyPbOsNrauMbitI7KpIbiuK7GoKq6jLaujJquhI6qhIKyiH6mgI6igIaegIKif
IaScG6mfHKqUG6efGqacFqadFaadGaWcE6WbGKOaE6SaE6OaEqOZEaOaAKqqF6GYE6GYEqCYEaCW
EJ6VD6KYD56VDqKXDqCVDp6WDZ+WDZ6UDJ2UCp2TCpyTB52SUpngTpfdZ4roS5PbSZPeRZLdRorR
Qo3XQIfNP3/PP3+/OInaPojMPIbROITQNYPRNoHLNn/ONn/INILQNIHNMYLQM4DNM3/MAH//AH9/
Mn7KMHvJLnzLK3zMK3vLKXvMKXnLKnnHKnjGJ3nLJ3jLJXjLJ3fIJXfIJHfKJXbHI3bHJXTFJHXG
JHTEI3XGI3PGI3PEIXTFIXLFVVWqJXHEAFWqAgEBAAD/AwAAAgAAAQAAAAAAAAAACP8A/wkcSLCg
wYKxTrWxsumgw4cQD6ZyVcdLgC+zImrcSFAVpS8cNlR4I4wVx5P/1mEzmOoNCAolboSQoqbOKV0o
IZ6zFmhQuoK36Hi4QYLEjQ8MMFhxAypWToPiEmkRIOMYu4K80Ci4UeKChyNGMiywMsfk03/gnJVp
sIJIAzDfDF5iEiKEFysSJNhAkkFCGkytco47tmWAjx8naJRB1g3rGgRMOJWi8+XlkRsJrFB6dTLd
MCgOhMw4IGaYuWwHP0WpEriXqzteHoxQMiHKJFobyx2DkkIIixyEwo17GOyNGmADYaVyE6PDkgtR
KOGO6GyLgyErnEBap9HTpVUFddn/YbJhyQQqmCKaKzPAtxNi5zaSynQQ1yQmHZQkQOPqobtEDfgw
Qw6QqHPSKA7hckcMI9xggRy3OCQNFiv80AAh75x1kC5uRGDEBlJ8cpA8g7R3ghjgaOiQKl5QoJ8b
vhiUDRcs7IDDMO6oeJAtkohQwwZUgFJQPIqg8IMBY/yk40G1fAHBERXMEeNA7pRRwA8pKDLPkgf5
UkcGRjBwhi0EXYOFCy5kcQ2XDo1ChQcfSBEKQcPo0EMBZcDD5kG5qJHADSJIMhA9iDTwQwGH0LOn
QcDEwcARD8SB3D/0BCKADy08suhBdnhgBAJrTBqPGQXsEIQxmxpkSRI1JKBGLwK9/2OlDk8ok2pB
mjRBggJn5BLrrLXeSlCuu/YqkDykmoqqsAKt2qoavwhUj6U+uAAJswJ1+mmo0iJywKGH1MNsMI5C
KulAw8jQwwBm6ClsLmckYEMNgg40zRVoboGasKNM8cEHUyA4kKwGYOmIPLd6iUGYaPg6kDyJnGBh
GUpu2uQDR1wwR7RlblHjjTkuyqMINmxghZAFkWgiipuy6GICMB4UDYU/HEBIO3ty6CGIIh4ETyIm
CJjDIwYeNM1JCjLoIIQPjcOeEC44MQw6BznTmEb2NZHfAmlwBlF1JwzBghOPUE2QN8gcHZEudzSh
AW3oaaQbb1DjMAg48UlrRrgPuc6iCnPOQUdJRhqR81loo4kByTjx/OPNFldIcxAorkjiRQSz1TZJ
LScNxoVhiMEwRiLZLEOEAIE0ThAqfaABwgSXJUAFJf2hFI4zZrAFBA8mNLCFGDLI4AQyBqHiBQTk
PfBXKhpGpUUBFQLhAgo6+IBnhgTZQokICEwhh1kqoiPNIFygYIALPuhQfQuKhDwQLW2s8YlTbK6T
jSJmXCGDDzskdkhcBSkFTlJljnoU4gQsUMEYjhEObB2kHGMIABgcIY4UOdAg0OCCIL6RNy4FBAAh
+QQJBQD/ACwAAAAAMAAwAIf////2///x+v/w+v/w+f/v+f/u+f/u+P/t//vs//vs//rr//rr/frt
+P/s+P/q/fnp/fno/fnq/Pno/Pjo+/jm/Pjm+/fl/Pjk+/jk+/fj+/fi+vbi+fbg+fXe+fXd+PTc
+PTt9//s9//r9//q9v/p9f/o9f/n9f/n9P/i9vje9/Pd9/Pm8/7j8v/c9/Pb9/Pa9/Pk8f3j8f/k
8fzj8Pzi8f/i8f7h8f/h8P/g8P/g7/7f7/7e7v7d7v7d7fzc7f7c7f3b7PrM///Z9vLY9vLX9vHX
9fHW9fHU8+/R8u7U7vPW6frV6PnJ7+vB7Oe/6+a96uW76eTK4fjH3/bF3vbE3vbE3fSy5eCo492a
3tiS3tjD2Oy21PK5zeqkyvCeyfKfxu2W0t+YxfKYwuyO3NaH29SM19B41c1u0clwysWLve5lzsZp
xcBZycFTx79Rxb1Lw7pHwbhHwLhDwLc/v79BvrY/vpoA//8A/0w6vbQ1u7IvvbQAv78Av3/CrcuB
tul+suV5sel3sN93q91uq+lmpuZjo+Njm9tVqv9btrZatLRVqqpdoOJaneFXnOFTmuBOmOE6uLEy
tqsusqk1rKYrqpgjt6ojsqghrqQkq6Qfq6MkqKAhp6AgqJ8fqJ8fp54gpp0jopwepZwcqqQcp58a
pp0Xp6ATpZwVpJoRpJsbopsUo5oQo5kAqqoOopkSpJYToZcRoZgPoZcQoJYRn5YQnpUPn5UPnpUO
nZQNoJcMnpQIoYQMnZQKnZMJnZNxhvBRkthKkttKi9VHleJHktxDjNNHh88/itI/f/8/f786jNs5
iNk5htE3g881hNI0gc4xgc00f88qf9Q0gMwxgMwxgMIAf/8Af38zfckxfsovfMktfcwre8spe8wt
eMcpecopeMcoeMomeMoleM0nd8gld8sldsYkeMokd8okdsgkdsMldcUkdcYkdMQjdMYjc8UidcYg
c8UhcsQgcsRVVaoTXrMDAgADAQECAQAAAP8DAAEDAAACAAABAAAAAAAAAAAI/wD/CRxIsKDBgwRd
rcIECqHDhxATdnpjRk/EiwTRiXs27aCrUnPKPAmABRbGi+ieFfpiBVJBUXvQXOGQIIMLPSZPOhzn
LJAVESIC/IlXMFOSBC+GfEDCxlMqnQe7FZoywAQPIAakdCTI68wDGB9gdHgQ5c0pqAO5LQNzoMQP
HA1ITBkzTFvBOR0+gKjwocgFCmYwrYL6bZgVAjt4OIjhhdG0dM4MlrpS4cWVFRGIvFAQRc9gjOEg
MRHxo0UDLo/ClXPIC02AKCCxPPBgBEKTPDkhghvGZMSPEzQCcQsXUZKENbdgmULTQcORCklwRlxW
xQGQEkEancOoysykga7gIP/JYCQClEsQv4Eh8DsIJHInQVkSRZBVHSQajCjQ8hRhu0Ii7NDCDI2g
A5UlBskShwoewEBBG7Ug5MwUJfBwQCDpoEWfQbmkIQERGTiByUHtBEJADyJwsQ1aD52CxQT6oaGL
Qc9YYQIOMTiyDosO0VKHCi5kAIUnBblTyAg8NOAFfDw6FEsWEBAxgRu5ELTOFwXwQIIh7zTpkC5w
WDAEA1pEONA0U6CAwhTPePnQJ09ssIETnBD0iAw6DCBGO246dAsZCsCgQh0DzUPIATwUEAhRfR7U
yxoMEPHAGr4IJI8aAuyAQiONOhTHBkMgcEYvAr0jRgE4+BBMpwhJYoQLCpT/MeM/7GBZwxLFsHrQ
JEl8sIAWtghUawG35qprQbz6qsUtpZ6a6qrHEhTJELDKaimmmnIa7UCfhjqqQIYiqiij0T4a6QNt
VCrQnXnuue0/fyrwwgqEnimFmlRsFW0ncc7ZiZVYaslIl8fy8oaYDJAR7EDxAJjkktE++WEFVBb0
DBU3xvDIjqzWgtcLGURBZEHvmAhEitzoasqLMfJykDNSVHihgQZhg5YsHhJhwROa+FdICAISmGFB
ykClIIMOumHmQeqxh0IQj9AsEDbK2IwRK3ngpx8Z/Tm0DBXWmRAEI1IXo4ZdF7kiBxIYlHdeRLsx
QcIPKMzwxzbgsBNIA8RE1LTKKWmo4Bx00sEtmgM/yHAAF45sY4VQ8jjkin1YSEBbBEnkEctJ3xBz
mA49OCADFzmQwAXaBGEiCyhwZKFCZjAoAIUerEClFhghlNBDDSTcUAMLjhSkyh5mPGEBBC4YkcED
WlyCCo9SVWFACzvUsIMBakRO0CdNMGAEiAo40cZZXm40SBA27JDDAEs0U1BXAUwwARRoYNK1l+QE
g4MJA7DAxR/DyEZB8gAFLbjBE65gFTi4EIC5NE5qBAGFJ1iRQFZ5IxhjMMQzIPiumjHjGxxkVUAA
ACH5BAkFAP8ALAAAAAAwADAAh/////r///P9//D6//D5/+/5/+3/++z/+uv/+uz+++v9+u75/+74
/+34/+z4/+r9+en9+er8+ej9+ej8+Oj7+Of8+Ob79+X79+T79+P79+P69+P69uL79+L69uL59eD4
9N759d349Nz49Oz3/+v3/+r2/+n1/+j1/+j0/+f0/+fz/eb0/+bz/+Ty/uPy/9/39N739Nz389v3
8+Px/uPx/OLx/+Hw/+Hw/uDw/uDv/t/v/t7u/t3u/t3t/Nzt/tzt/dzs+tr389n28tj28tf28tj1
8Nf18df18Nb18dju99bp+tPz79Dy7c7w7NHq9MLs6MHt6L/r5r7q5bzp5LPn4tLm+cnh98jf9sXe
9cPe9qvf4Jvf2ZPe2JLa1MPS7rPT8qnN8KDJ8p7G7ZnN55rG8ZnF8JXB64bw54zc1oPa04XVz3HV
zG/NxmvOx2POxl/NxVvMxIG+4GHEvFXHv0/Cuk3FvEjBuE3AuEPAt0C+tQD//wD/fz+/vz++tT+/
ijK8sgC/vwC/f7iuz4Gv3Xyy6Hax63iw33Kt522s6mup5mem5mSh3mSa2Fas8FWqql+h41me4Vab
4VOa4FGZ3ze2rjC4ri6zrC+upSuqoyS0qiGxqCOtoyKroB2rnzudxiGooCGnnSConh+onx+lnR6m
mwCq/xyqqgCqqhepoByknRqnmxikmhOlmxGkmhajmhSimQ+imQ6imBOllhGglw6glg2glxKflg+f
lQyflRGelQ+elQ6elQ2elAqelAmelQ2dlAqdkwqckwmdlHGD8UqN00mS20aR20KL00GJ0j9/yT9/
vzmM2TmI1juF0zaF0zeCzDWCzzV/yjSC0TOBzTOCzDSAzTSAyTCAzip/xgB//wB/fzF9yS98yDJ7
yS17ySp8zyl6yyl4ySd5yih3xyV4yyV2xyR2yCN2yiV1xiR1xSN1yCJ1xSV0xSNzxSNyxSJzxSF0
xyFyxSB0xyBzxSByxFVVqgBVqgMCAQIBAQIBAAAA/wMAAAIAAAEAAAAAAAAAAAj/AP8JHEiwoMGD
CBMqXCgQ3rxvzxhKnPjvnLhnkxCZKeRtIa5erjhxoniQ3DRFYazMGBHACreCoFrRWoUpD5w0ajKR
LEjOGSEsIxasyMGjhpJjBVfB2UKlCYwHAeDY2jkQnKIrA07s0JGiQIEUMyAVBIYGgIYOMiywqUX1
HzhmYhic8GGjQQksZQpBIrZsG8FebyYMiSFDQ5dOrnaGK4aFgI4dI2aEeRTNHLyEeDyEECFDRgIq
f15RDDepigMfLhh8kSSOHMNLTUB8qACCCIQmoSWOM1aFhI8UNAh9EzdxFRUBW+R46ICkAm7RC5ll
afDjhBJIrine2uLhUrA7SzIY/4EwRdNCcGIG/AYyydxOYGraAPtHKw8SDkYOdGGVMJ2iETq4QAMk
5VBFSiWhDBTLHR+AEMQEc+iCkDNXmLADA4So09Y/OhEUCxsRDIFBFJsc1A4hBPwwwhffbPgPKAax
osUE+bXxi0HTYHHCDTNEgo6LB9mCxwcyYCCFKAWt898ODYAxDpAIzbIFBENAyAtB6ZBRwA4lPNIO
lAfhUocFQijAxS0EQWPFCilcUQ2YCIkSxQYdPPEJQZO0kMMAZLAD50G6oHFAEDD0MRA9iDCwQwGF
zPOnQcG4ocAQD7whjEDxmDEAV2I9apAdGwhhwBrz/dNOGQXY0EMxnhpESRExHP+ABi4CpRNGAUYh
1SpBlzARAgJcSPiPrbgetSuvvgIr7KmprnrsQJQcIYKsV/4zj6acPisQqKKu0YtAiCrKqKPHAiMp
pZYOJMkMe/b5bKCDFkrQM2umgMU0z8rZQQdQ3DkQOrdy+cg7u/IyZpnBEgTPkk0+2aqUIVYwR7UD
5XgCDi346GkuQxY5BZIFnZjiii0WZI2LMtJ4gI0HOWOFhRi6R9AyG9IC4hAXkIhQOok0EGALj8j8
zzTG+LVTLHa84CAFc+SSEHoE+LACEJJoGA8hZtCzEyx9LIGffq1El4UD1QGxCD3ItABGOiQhvQQG
RkhQHkO79Sa1CoaAIUAWL0nV1AorbcCQQXPPSUSaaTy4QAILLSiBDEOwtJKHFhGAEHcTfUBnuDFZ
DIADDjbUwEIkCfVCyyh1bPGCBEMEccAUuZHkjTRioAA6ZIhoPdAolVBihxtoRGEBBCIYgcEDXWiS
GFXqEFICDmwCQEY8BeEBwwYKKBCqiAdEMQd/bY2TSAAMzFDFF2Eg0hGyIhARRAcKTCBFG5uEveEy
ZpiRiCTNeGMOOG8iyCqgEIAJwOAJXJiDKGIBJGhAwxvwkMdCVuGGNMChD5+ABQO1ZZBQoMIXtOKg
tgICADs=
EUS_RUNNING_GIF
chmod 0644 "$(target /usr/lib/EUS-ICONS/eus-update-running.gif)"

base64 -d >"$(target /usr/lib/EUS-ICONS/eus-update-running.png)" <<'EUS_RUNNING_PNG'
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
VN3/AtHkA7BVN/d7AAAAAElFTkSuQmCC
EUS_RUNNING_PNG
chmod 0644 "$(target /usr/lib/EUS-ICONS/eus-update-running.png)"

base64 -d >"$(target /usr/lib/EUS-ICONS/eus-update-finished.png)" <<'EUS_FINISHED_PNG'
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
EUS_FINISHED_PNG
chmod 0644 "$(target /usr/lib/EUS-ICONS/eus-update-finished.png)"

install -m 0644 /dev/stdin "$(target /usr/share/applications/eduka-update-system.desktop)" <<'EUS_DESKTOP'
[Desktop Entry]
Type=Application
Name=Eduka-Update-System
Name[tet]=Eduka-Update-System
Name[pt]=Eduka-Update-System
Name[id]=Eduka-Update-System
GenericName=Update Manager
GenericName[tet]=Jestór Atualizasaun
GenericName[pt]=Gestor de Atualizacoes
GenericName[id]=Manajer Pembaruan
Comment=Review and install categorized Edukasaun OS and Flatpak updates
Comment[tet]=Haree no instala atualizasaun Edukasaun OS no Flatpak tuir kategoria
Comment[pt]=Rever e instalar atualizacoes categorizadas do Edukasaun OS e Flatpak
Comment[id]=Periksa dan pasang pembaruan Edukasaun OS dan Flatpak berdasarkan kategori
Exec=/usr/local/bin/eduka-update-system --ui
TryExec=/usr/local/bin/eduka-update-system
Icon=eduka-update-system
Terminal=false
DBusActivatable=false
Categories=System;Settings;
Keywords=update;upgrade;security;APT;Flatpak;EUS;Edukasaun;
StartupNotify=true
StartupWMClass=Eduka-Update-System
X-LXQt-Need-Tray=false
EUS_DESKTOP

install -m 0644 /dev/stdin "$(target /etc/xdg/autostart/eduka-update-system-notifier.desktop)" <<'EUS_AUTOSTART'
[Desktop Entry]
Type=Application
Name=EUS Update Notifier
Name[tet]=Notifikasaun Atualizasaun EUS
Name[pt]=Notificador de Atualizacoes EUS
Name[id]=Notifikasi Pembaruan EUS
Comment=Notify when categorized Edukasaun OS or Flatpak updates are available
Exec=/usr/local/bin/eduka-update-system --watch
TryExec=/usr/local/bin/eduka-update-system
Icon=eduka-update-system
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-LXQt-Need-Tray=false
EUS_AUTOSTART

install -m 0644 /dev/stdin "$(target /etc/xdg/autostart/eduka-update-system-indicator.desktop)" <<'EUS_INDICATOR_AUTOSTART'
[Desktop Entry]
Type=Application
Name=Eduka-Update-System Indicator
Name[tet]=Indikadór Eduka-Update-System
Name[pt]=Indicador do Eduka-Update-System
Name[id]=Indikator Eduka-Update-System
Comment=Show the EUS icon only when updates are available
Comment[tet]=Hatudu ikone EUS bainhira deit atualizasaun disponivel
Comment[pt]=Mostrar o icone do EUS somente quando houver atualizacoes
Comment[id]=Tampilkan ikon EUS hanya ketika pembaruan tersedia
Exec=/usr/bin/python3 /usr/lib/EUS-ICONS/eus_panel_indicator.py
TryExec=/usr/bin/python3
Icon=eduka-update-system
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-LXQt-Need-Tray=true
EUS_INDICATOR_AUTOSTART

install -m 0644 /dev/stdin "$(target /usr/share/polkit-1/actions/tl.edukasaun.eus.policy)" <<'EUS_POLICY'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
  "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <vendor>Edukasaun OS</vendor>
  <vendor_url>https://www.edukasaunos.tl/</vendor_url>
  <action id="tl.edukasaun.eus.manage">
    <description>Manage updates or restart Edukasaun OS</description>
    <description xml:lang="tet">Jere atualizasaun ka hahu fali Edukasaun OS</description>
    <description xml:lang="pt">Gerir atualizacoes ou reiniciar o Edukasaun OS</description>
    <description xml:lang="id">Kelola pembaruan atau mulai ulang Edukasaun OS</description>
    <message>Authentication is required to update or restart Edukasaun OS</message>
    <message xml:lang="tet">Presiza autorizasaun atu atualiza ka hahu fali Edukasaun OS</message>
    <message xml:lang="pt">E necessaria autenticacao para atualizar ou reiniciar o Edukasaun OS</message>
    <message xml:lang="id">Autentikasi diperlukan untuk memperbarui atau memulai ulang Edukasaun OS</message>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/libexec/eduka-update-system-root</annotate>
  </action>
</policyconfig>
EUS_POLICY

install -m 0644 /dev/stdin "$(target /etc/systemd/system/eus-refresh.service)" <<'EUS_SERVICE'
[Unit]
Description=Refresh and categorize Eduka-Update-System metadata
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/eduka-update-system-root refresh en
Nice=10
IOSchedulingClass=idle
EUS_SERVICE

install -m 0644 /dev/stdin "$(target /etc/systemd/system/eus-refresh.timer)" <<'EUS_TIMER'
[Unit]
Description=Check regularly for Edukasaun OS and Flatpak updates

[Timer]
OnBootSec=90s
OnUnitActiveSec=6h
AccuracySec=1min
RandomizedDelaySec=30s
Persistent=true
Unit=eus-refresh.service

[Install]
WantedBy=timers.target
EUS_TIMER

legacy="$(target /usr/local/bin/eduka-upgrade-action.sh)"
if [[ -f "$legacy" && ! -L "$legacy" ]]; then
    cp -a "$legacy" "${legacy}.backup-${STAMP}"
fi
ln -sfn eduka-update-system "$legacy"

if [[ -z "$INSTALL_ROOT" ]]; then
    while IFS= read -r -d '' desktop_file; do
        [[ "$desktop_file" == '/usr/share/applications/eduka-update-system.desktop' ]] && continue
        cp -a "$desktop_file" "${desktop_file}.backup-${STAMP}"
        if grep -q '^NoDisplay=' "$desktop_file"; then
            sed -i 's/^NoDisplay=.*/NoDisplay=true/' "$desktop_file"
        else
            printf '\nNoDisplay=true\n' >>"$desktop_file"
        fi
    done < <(grep -rlZ --include='*.desktop' '/usr/local/bin/eduka-upgrade-action.sh' \
        /usr/share/applications /etc/xdg/autostart 2>/dev/null || true)
fi

install -d -m 0755 "$(target /etc/systemd/system/timers.target.wants)"
ln -sfn ../eus-refresh.timer "$(target /etc/systemd/system/timers.target.wants/eus-refresh.timer)"

if ! /usr/bin/python3 -m py_compile \
    "$(target /usr/local/libexec/eduka-update-system-gui)" \
    "$(target /usr/local/bin/eus-panel-status)" \
    "$(target /usr/lib/EUS-ICONS/eus_panel_indicator.py)"; then
    echo 'ERROR: EUS Python component validation failed.' >&2
    exit 70
fi

if [[ -z "$INSTALL_ROOT" ]]; then
    if [[ -d /run/systemd/system ]]; then
        systemctl daemon-reload
        systemctl enable --now eus-refresh.timer
    else
        systemctl enable eus-refresh.timer >/dev/null 2>&1 || true
    fi
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

echo
echo "Eduka-Update-System ${EUS_VERSION} installed successfully."
echo "GUI          : eduka-update-system --ui"
echo "Terminal     : eduka-update-system --terminal"
echo "Old path     : /usr/local/bin/eduka-upgrade-action.sh (compatibility link)"
echo "Update data  : /var/lib/eus/updates.tsv"
echo "Log          : /var/log/eus/eus.log"
echo "Restart flag : /var/lib/eus/restart-required"
echo "Panel status : /usr/local/bin/eus-panel-status"
echo "EUS icons    : /usr/lib/EUS-ICONS"
echo "Auto-check   : about 2 minutes after boot, then every 6 hours."
