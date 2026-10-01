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
