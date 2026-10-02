#!/bin/bash
# Privileged helper for Eduka-Update-System 0.15. Do not launch directly.
# It is the only program PolicyKit allows EUS to run as root.

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
APT_UPDATE_LOG="$STATE_DIR/apt-update.log"
SCHEDULE_FILE='/etc/eus/schedule'
PAUSE_FILE='/etc/eus/pause'
TIMER_OVERRIDE='/etc/systemd/system/eus-refresh.timer.d/override.conf'
TOOL='/usr/local/libexec/eduka-update-system-tool'
PYTHON='/usr/bin/python3'
IGNORE_FILE='/etc/eus/ignored-updates'
# Defaults; /etc/eus/eus.conf overrides them.
AUTO_CLEAN=1
TIMESHIFT_SNAPSHOT=0
AUTO_UPGRADE='off'
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
        P_KEYS="Hadi'a xave GPG no keyring..."
        P_DUPLICATES="Hadi'a repositoriu duplikadu..."
        P_ADD_KEY="Aumenta xave GPG..."
        P_KERNEL_INSTALL="Instala kernel..."
        P_KERNEL_REMOVE="Hasai kernel..."
        P_PAUSE="Rai pauza atualizasaun..."
        P_PAUSED="Verifikasaun automatiku pauza hela."
        P_KEY_HINT="Iha problema xave GPG ka repositoriu. Loke menu Key Fix atu hadi'a."
        P_NETWORK="Repositoriu balun la bele asesu; lista atualizasaun bele la kompletu."
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
        P_KEYS="Reparando chaves GPG e keyrings..."
        P_DUPLICATES="Corrigindo repositorios duplicados..."
        P_ADD_KEY="Adicionando a chave GPG..."
        P_KERNEL_INSTALL="Instalando o kernel..."
        P_KERNEL_REMOVE="Removendo o kernel..."
        P_PAUSE="Salvando a pausa das atualizacoes..."
        P_PAUSED="As verificacoes automaticas estao em pausa."
        P_KEY_HINT="Ha problemas de chaves GPG ou de repositorios. Abra o menu Key Fix para corrigi-los."
        P_NETWORK="Alguns repositorios nao responderam; a lista de atualizacoes pode estar incompleta."
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
        P_KEYS="Memperbaiki kunci GPG dan keyring..."
        P_DUPLICATES="Memperbaiki repositori duplikat..."
        P_ADD_KEY="Menambahkan kunci GPG..."
        P_KERNEL_INSTALL="Memasang kernel..."
        P_KERNEL_REMOVE="Menghapus kernel..."
        P_PAUSE="Menyimpan jeda pembaruan..."
        P_PAUSED="Pemeriksaan otomatis sedang dijeda."
        P_KEY_HINT="Ada masalah kunci GPG atau repositori. Buka menu Key Fix untuk memperbaikinya."
        P_NETWORK="Beberapa repositori tidak dapat dihubungi; daftar pembaruan mungkin belum lengkap."
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
        P_KEYS="Repairing GPG keys and keyrings..."
        P_DUPLICATES="Fixing duplicate repositories..."
        P_ADD_KEY="Adding the GPG key..."
        P_KERNEL_INSTALL="Installing the kernel..."
        P_KERNEL_REMOVE="Removing the kernel..."
        P_PAUSE="Saving the update pause..."
        P_PAUSED="Automatic update checks are paused."
        P_KEY_HINT="Repository or GPG key problems were found. Open the Key Fix menu to repair them."
        P_NETWORK="Some repositories could not be reached; the update list may be incomplete."
        ;;
esac

# Strings added in 0.14 (English).
P_ADD_REPO='Adding the repository and looking for its signing key...'
P_OS_CHECK='Checking for a new Edukasaun OS base release...'
P_OS_PREPARE='Bringing the current release fully up to date...'
P_OS_SWITCH='Switching repositories to the new release...'
P_OS_UPGRADE='Upgrading the operating system (this can take a long time)...'
P_SNAPSHOT='Creating a Timeshift snapshot before installing...'
P_CLEAN='Cleaning up: unneeded packages, leftover configuration and package cache...'
P_AUTO='Installing updates automatically...'
P_OS_SPACE='Not enough free disk space for the OS upgrade (at least 5 GB is needed in / and /var).'

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

is_kernel_package() {
    # is_kernel_package BINARY SOURCE SECTION
    case "$1" in linux-libc-dev) return 1 ;; esac
    case "$2" in linux|linux-signed*|linux-meta*|linux-latest|linux-hwe*) return 0 ;; esac
    [[ "$3" == kernel ]] && [[ "$1" == linux-* ]]
}

is_ignored() {
    # is_ignored NAME VERSION: entries in /etc/eus/ignored-updates are
    # "name" (all versions) or "name=version"; shell globs are allowed.
    local name="$1" version="$2" pattern pattern_name pattern_version
    [[ -r "$IGNORE_FILE" ]] || return 1
    while IFS= read -r pattern; do
        pattern="${pattern%%#*}"
        pattern="${pattern//[[:space:]]/}"
        [[ -n "$pattern" ]] || continue
        pattern_name="${pattern%%=*}"
        pattern_version=''
        [[ "$pattern" == *=* ]] && pattern_version="${pattern#*=}"
        # shellcheck disable=SC2053
        if [[ "$name" == $pattern_name ]] && [[ -z "$pattern_version" || "$pattern_version" == "$version" ]]; then
            return 0
        fi
    done <"$IGNORE_FILE"
    return 1
}

ignored_installed_packages() {
    # Binary packages with a pending update that the ignore list excludes.
    local line package source candidate key
    local inst_re='^Inst ([^ ]+)( \[([^]]*)\])? \(([^ ]+) '
    local -a held=()
    [[ -s "$IGNORE_FILE" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ $inst_re ]] || continue
        package="${BASH_REMATCH[1]}"
        candidate="${BASH_REMATCH[4]}"
        key="${package%%:*}"
        source="$(dpkg-query -W -f='${source:Package}' "$key" 2>/dev/null || true)"
        if is_ignored "${source:-$key}" "$candidate" || is_ignored "$key" "$candidate"; then
            held+=("$package")
        fi
    done < <(LC_ALL=C apt-get -s -o Debug::NoLocking=1 full-upgrade 2>/dev/null)
    printf '%s\n' "${held[@]}"
}

timeshift_snapshot() {
    [[ "${TIMESHIFT_SNAPSHOT:-0}" == 1 ]] && command -v timeshift >/dev/null 2>&1 || return 0
    progress 4 "$P_SNAPSHOT"
    log_header 'Timeshift snapshot before installing updates'
    timeout 3600 timeshift --create --scripted --tags O \
        --comments 'Before Eduka-Update-System updates' >>"$LOG_FILE" 2>&1 || \
        log_header 'Timeshift snapshot failed; continuing (see the lines above)'
}

post_clean() {
    # After installing or removing packages, leave the system clean:
    # unneeded dependencies, leftover configuration and downloaded .debs.
    [[ "${AUTO_CLEAN:-1}" == 1 && -x "$PYTHON" && -r "$TOOL" ]] || return 0
    progress 95 "$P_CLEAN"
    log_header 'Automatic clean-up after the operation'
    "$PYTHON" -I "$TOOL" clean-system autoremove configs apt-cache >>"$LOG_FILE" 2>&1 || true
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
    local simulation metadata_file tsv_tmp count fingerprint release_upgrade download_bytes
    local line package installed candidate archives size description category priority section key
    local installed_release candidate_release
    local -a packages=()
    declare -A meta_size=() meta_priority=() meta_section=() meta_description=() meta_source=()
    local source kind
    local inst_re='^Inst ([^ ]+)( \[([^]]*)\])? \(([^ ]+) (.*)\)'

    simulation="$(mktemp)"
    metadata_file="$(mktemp)"
    tsv_tmp="$(mktemp "$STATE_DIR/updates.XXXXXX")"

    if ! LC_ALL=C apt-get -s -o Debug::NoLocking=1 full-upgrade >"$simulation" 2>>"$LOG_FILE"; then
        rm -f "$simulation" "$metadata_file" "$tsv_tmp"
        write_state error 0 none 0 0
        fail 'APT could not calculate the available updates. See /var/log/eus/eus.log.'
    fi

    # One batched apt-cache call instead of several per package: with a
    # hundred pending updates the old per-package loop took minutes.
    mapfile -t packages < <(awk '/^Inst / {print $2}' "$simulation" | sort -u)
    if ((${#packages[@]})); then
        LC_ALL=C apt-cache show --no-all-versions "${packages[@]}" 2>/dev/null | awk '
            function flush() {
                if (pkg != "" && !(pkg in seen)) {
                    seen[pkg] = 1
                    gsub(/\t/, " ", desc)
                    printf "%s\t%s\t%s\t%s\t%s\t%s\n", pkg, size + 0, prio, sect, src, desc
                }
                pkg = size = prio = sect = desc = src = ""
            }
            /^Package: / { flush(); pkg = substr($0, 10) }
            /^Source: / { src = substr($0, 9); sub(/ .*/, "", src) }
            /^Size: / { size = substr($0, 7) }
            /^Priority: / { prio = substr($0, 11) }
            /^Section: / { sect = substr($0, 10) }
            /^Description(-[A-Za-z_@.-]+)?: / { if (desc == "") { sub(/^[^:]*: /, ""); desc = $0 } }
            END { flush() }' >"$metadata_file"
        while IFS=$'\t' read -r key size priority section source description; do
            meta_source["$key"]="${source:-$key}"
            meta_size["$key"]="$size"
            meta_priority["$key"]="$priority"
            meta_section["$key"]="$section"
            meta_description["$key"]="$description"
        done <"$metadata_file"
    fi

    declare -A done_packages=()
    while IFS= read -r line; do
        [[ "$line" =~ $inst_re ]] || continue
        package="${BASH_REMATCH[1]}"
        installed="${BASH_REMATCH[3]:--}"
        candidate="${BASH_REMATCH[4]:--}"
        archives="${BASH_REMATCH[5]}"
        [[ -z "${done_packages[$package]:-}" ]] || continue
        done_packages[$package]=1
        key="${package%%:*}"
        size="${meta_size[$key]:-0}"
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        priority="${meta_priority[$key]:-}"
        section="${meta_section[$key]:-}"
        description="${meta_description[$key]:-System package update}"
        source="${meta_source[$key]:-$key}"
        if is_ignored "$source" "$candidate" || is_ignored "$key" "$candidate"; then
            continue
        fi
        kind='package'
        is_kernel_package "$key" "$source" "$section" && kind='kernel'

        # APT lists every archive that carries the candidate version, so a
        # security fix also published in -updates is still recognised.
        # Browsers and mail clients are treated as security updates (as Linux
        # Mint does): nearly every release of them fixes vulnerabilities.
        if [[ "$key" == "$OS_RELEASE_PACKAGE" || "${archives,,}" == *security* ]] || \
           [[ "$source" =~ ^(firefox|firefox-esr|thunderbird|chromium)$ ]]; then
            category='critical'
            [[ "$kind" == kernel ]] || kind='security'
        elif [[ "$kind" == kernel ]]; then
            category='kernel'
        elif is_medium_package "$key" || [[ "$priority" == 'required' || "$priority" == 'important' ]]; then
            category='medium'
        else
            category='normal'
        fi

        installed="$(sanitize_field "$installed")"
        candidate="$(sanitize_field "$candidate")"
        description="$(sanitize_field "$description")"
        source="$(sanitize_field "$source")"
        printf '%s\tapt\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$category" "$package" "$installed" "$candidate" "$size" "$description" "$source" "$kind" >>"$tsv_tmp"
    done <"$simulation"
    rm -f "$metadata_file"

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
    # Keep the last `apt-get update` output separately: Key Fix reads it to
    # find missing/expired signing keys and duplicate repositories.
    local rc tmp
    tmp="$(mktemp "$STATE_DIR/apt-update.XXXXXX")"
    # fd 4 keeps the caller's stdout (the progress protocol); without it the
    # progress stream inherited apt's redirection and never reached the GUI.
    { apt-get -o Acquire::Retries=3 -o DPkg::Lock::Timeout=120 -o APT::Status-Fd=3 update \
        >"$tmp" 2>&1 3> >(apt_progress_stream 8 55 63 1 >&4); } 4>&1
    rc=$?
    cat "$tmp" >>"$LOG_FILE"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$APT_UPDATE_LOG"
    return "$rc"
}

apt_has_key_problems() {
    [[ -r "$APT_UPDATE_LOG" && -x "$PYTHON" && -r "$TOOL" ]] || return 1
    "$PYTHON" -I "$TOOL" apt-problems --check >/dev/null 2>&1
}

apt_update_or_fail() {
    # One unreachable or broken repository must not hide every other update:
    # APT keeps the last good lists, so continue with them and warn instead.
    apt_update_command && return 0
    log_header 'apt-get update reported errors; continuing with the available package lists'
    if apt_has_key_problems; then
        progress 62 "$P_KEY_HINT"
    else
        progress 62 "$P_NETWORK"
    fi
    return 0
}

os_check() {
    # Network check for a new Debian stable base; never fails the caller.
    [[ -x "$PYTHON" && -r "$TOOL" ]] || return 0
    timeout 90 "$PYTHON" -I "$TOOL" os-check >/dev/null 2>>"$LOG_FILE" || true
}

refresh_lists() {
    progress 8 "$P_REFRESH"
    log_header 'APT and Flatpak metadata refresh with category scan'
    apt_update_or_fail
    progress 68 "$P_CALCULATE"
    calculate_updates
    progress 96 "$P_OS_CHECK"
    os_check
    progress 100 "$P_DONE"
}

apt_upgrade_command() {
    # UPGRADE_RANGE lets long multi-step operations map APT progress to a slice.
    local -a range=(${UPGRADE_RANGE:-26 40 66 26})
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Acquire::Retries=3 \
        -o DPkg::Lock::Timeout=300 \
        -o APT::Status-Fd=3 \
        -o Dpkg::Options::='--force-confdef' \
        -o Dpkg::Options::='--force-confold' \
        "$@" 4>&1 >>"$LOG_FILE" 2>&1 3> >(apt_progress_stream "${range[@]}" >&4)
}

upgrade_all_apt() {
    progress 5 "$P_REFRESH"
    log_header 'Full APT upgrade selected in EUS'
    apt_update_or_fail
    timeshift_snapshot
    progress 26 "$P_UPGRADE"
    full_upgrade_respecting_ignores || \
        fail 'The system upgrade did not finish successfully. See /var/log/eus/eus.log.'
    progress 90 "$P_CALCULATE"
    calculate_updates
    post_clean
    progress 100 "$P_DONE"
}

full_upgrade_respecting_ignores() {
    # Ignored updates are held only for the duration of this upgrade.
    local rc package
    local -a hold=()
    mapfile -t hold < <(ignored_installed_packages | sed '/^$/d')
    local -a newly_held=()
    for package in "${hold[@]}"; do
        if ! apt-mark showhold 2>/dev/null | grep -qx "$package"; then
            apt-mark hold "$package" >>"$LOG_FILE" 2>&1 && newly_held+=("$package")
        fi
    done
    apt_upgrade_command full-upgrade -y
    rc=$?
    ((${#newly_held[@]})) && apt-mark unhold "${newly_held[@]}" >>"$LOG_FILE" 2>&1
    return "$rc"
}

install_selected_apt() {
    local package
    local -a selected=()
    declare -A seen=()

    ((${#EXTRA_ARGS[@]} > 0)) || fail 'No APT update package was selected.'
    ((${#EXTRA_ARGS[@]} <= 500)) || fail 'Too many package arguments.'
    progress 5 "$P_REFRESH"
    log_header "Selected APT upgrade (${#EXTRA_ARGS[@]} requested)"
    apt_update_or_fail
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

    timeshift_snapshot
    progress 34 "$P_SELECTED"
    # --only-upgrade keeps APT's automatic/manual marks unchanged, so
    # dependencies upgraded here can still be autoremoved later.
    apt_upgrade_command install --only-upgrade -y "${selected[@]}" || \
        fail 'One or more selected updates could not be installed. See /var/log/eus/eus.log.'
    progress 90 "$P_CALCULATE"
    calculate_updates
    post_clean
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

reload_timer() {
    if [[ -d /run/systemd/system ]]; then
        systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
        systemctl restart eus-refresh.timer >>"$LOG_FILE" 2>&1 || true
    fi
}

write_schedule() {
    local mode="$1" hours="$2" daily="$3"
    install -d -m 0755 "${TIMER_OVERRIDE%/*}"
    if [[ "$mode" == daily ]]; then
        {
            printf '[Timer]\n'
            printf 'OnUnitActiveSec=\n'
            printf 'OnCalendar=\n'
            printf 'OnCalendar=*-*-* %s:00\n' "$daily"
        } >"$TIMER_OVERRIDE"
    else
        {
            printf '[Timer]\n'
            printf 'OnCalendar=\n'
            printf 'OnUnitActiveSec=\n'
            printf 'OnUnitActiveSec=%sh\n' "$hours"
        } >"$TIMER_OVERRIDE"
        printf '%s\n' "$hours" >"$INTERVAL_FILE"
        chmod 0644 "$INTERVAL_FILE"
    fi
    {
        printf "SCHEDULE_MODE='%s'\n" "$mode"
        printf "INTERVAL_HOURS='%s'\n" "$hours"
        printf "DAILY_TIME='%s'\n" "$daily"
    } >"$SCHEDULE_FILE"
    chmod 0644 "$SCHEDULE_FILE" "$TIMER_OVERRIDE"
    reload_timer
}

current_schedule() {
    SCHEDULE_MODE='interval'; INTERVAL_HOURS=6; DAILY_TIME='09:00'
    [[ -r "$INTERVAL_FILE" ]] && INTERVAL_HOURS="$(tr -dc '0-9' <"$INTERVAL_FILE")"
    if [[ -r "$SCHEDULE_FILE" ]]; then
        local key value
        while IFS='=' read -r key value; do
            value="${value//\'/}"
            case "$key" in
                SCHEDULE_MODE) [[ "$value" == interval || "$value" == daily ]] && SCHEDULE_MODE="$value" ;;
                INTERVAL_HOURS) [[ "$value" =~ ^[0-9]+$ ]] && INTERVAL_HOURS="$value" ;;
                DAILY_TIME) [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && DAILY_TIME="$value" ;;
            esac
        done <"$SCHEDULE_FILE"
    fi
    [[ "$INTERVAL_HOURS" =~ ^(1|3|6|12|24|48|168)$ ]] || INTERVAL_HOURS=6
}

set_interval() {
    local hours="${EXTRA_ARGS[0]:-}"
    case "$hours" in 1|3|6|12|24|48|168) ;; *) fail 'Invalid update-check interval.' ;; esac
    progress 25 "$P_SETTINGS"
    current_schedule
    write_schedule interval "$hours" "$DAILY_TIME"
    progress 100 "$P_DONE"
}

set_schedule() {
    local mode="${EXTRA_ARGS[0]:-}" value="${EXTRA_ARGS[1]:-}"
    progress 25 "$P_SETTINGS"
    current_schedule
    case "$mode" in
        interval)
            [[ "$value" =~ ^(1|3|6|12|24|48|168)$ ]] || fail 'Invalid update-check interval.'
            write_schedule interval "$value" "$DAILY_TIME"
            ;;
        daily)
            [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || fail 'Invalid daily check time.'
            write_schedule daily "$INTERVAL_HOURS" "$value"
            ;;
        *) fail 'Invalid update schedule.' ;;
    esac
    progress 100 "$P_DONE"
}

pause_updates() {
    local days="${EXTRA_ARGS[0]:-}" now until
    [[ "$days" =~ ^[0-9]{1,3}$ ]] && ((days <= 365)) || fail 'Invalid pause duration.'
    progress 30 "$P_PAUSE"
    if ((days == 0)); then
        rm -f -- "$PAUSE_FILE"
        log_header 'Automatic update checks resumed'
    else
        now="$(date +%s)"
        until=$((now + days * 86400))
        {
            printf 'PAUSED_AT=%s\n' "$now"
            printf 'PAUSED_UNTIL=%s\n' "$until"
            printf 'PAUSE_DAYS=%s\n' "$days"
        } >"$PAUSE_FILE"
        chmod 0644 "$PAUSE_FILE"
        log_header "Automatic update checks paused for $days days"
    fi
    progress 100 "$P_DONE"
}

updates_paused() {
    local key value until=0
    [[ -r "$PAUSE_FILE" ]] || return 1
    while IFS='=' read -r key value; do
        [[ "$key" == PAUSED_UNTIL && "$value" =~ ^[0-9]+$ ]] && until="$value"
    done <"$PAUSE_FILE"
    if ((until > $(date +%s))); then
        return 0
    fi
    rm -f -- "$PAUSE_FILE"
    log_header 'Update pause expired; automatic checks resumed'
    return 1
}

auto_refresh() {
    if updates_paused; then
        log_header 'Scheduled check skipped because updates are paused'
        progress 100 "$P_PAUSED"
        return 0
    fi
    refresh_lists
    automatic_upgrade
}

on_battery_power() {
    # True when the computer runs on battery (no AC adapter online).
    local supply online=0 battery=0
    for supply in /sys/class/power_supply/*; do
        [[ -r "$supply/type" ]] || continue
        case "$(<"$supply/type")" in
            Mains|USB) [[ "$(<"$supply/online" 2>/dev/null)" == 1 ]] && online=1 ;;
            Battery) battery=1 ;;
        esac
    done
    ((battery == 1 && online == 0))
}

automatic_upgrade() {
    # AUTO_UPGRADE=security|all installs updates after the scheduled check,
    # only on AC power and while shutdown is inhibited (like mintupdate).
    local -a packages=()
    local inhibitor=''
    case "${AUTO_UPGRADE:-off}" in security|all) ;; *) return 0 ;; esac
    if on_battery_power; then
        log_header 'Automatic upgrade skipped: running on battery'
        return 0
    fi
    if [[ "$AUTO_UPGRADE" == security ]]; then
        mapfile -t packages < <(awk -F '\t' '$2=="apt" && $1=="critical" {print $3}' "$TSV_FILE")
    else
        mapfile -t packages < <(awk -F '\t' '$2=="apt" {print $3}' "$TSV_FILE")
    fi
    ((${#packages[@]})) || return 0
    log_header "Automatic upgrade ($AUTO_UPGRADE): ${#packages[@]} packages"
    if command -v systemd-inhibit >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemd-inhibit --what=shutdown:sleep --mode=block --who='Eduka-Update-System' \
            --why='Installing updates' sleep infinity &
        inhibitor=$!
    fi
    progress 70 "$P_AUTO"
    timeshift_snapshot
    apt_upgrade_command install --only-upgrade -y "${packages[@]}" || \
        log_header 'Automatic upgrade failed; see the lines above'
    [[ -n "$inhibitor" ]] && kill "$inhibitor" 2>/dev/null
    calculate_updates
    post_clean
}

set_conf_value() {
    # set_conf_value KEY VALUE: update /etc/eus/eus.conf, keeping other lines.
    local key="$1" value="$2" tmp
    install -d -m 0755 "${CONFIG_FILE%/*}"
    touch "$CONFIG_FILE"
    tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
    grep -v "^${key}=" "$CONFIG_FILE" >"$tmp" || true
    printf "%s='%s'\n" "$key" "$value" >>"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

set_option() {
    local key="${EXTRA_ARGS[0]:-}" value="${EXTRA_ARGS[1]:-}"
    case "$key:$value" in
        AUTO_CLEAN:0|AUTO_CLEAN:1|TIMESHIFT_SNAPSHOT:0|TIMESHIFT_SNAPSHOT:1) ;;
        AUTO_UPGRADE:off|AUTO_UPGRADE:security|AUTO_UPGRADE:all) ;;
        *) fail 'Invalid EUS option.' ;;
    esac
    progress 30 "$P_SETTINGS"
    set_conf_value "$key" "$value"
    log_header "Option $key set to $value"
    progress 100 "$P_DONE"
}

ignore_update() {
    # ignore add|remove PATTERN (name, name=version; globs allowed)
    local mode="${EXTRA_ARGS[0]:-}" pattern="${EXTRA_ARGS[1]:-}" tmp
    [[ "$pattern" =~ ^[A-Za-z0-9*?.+:~_-]+(=[A-Za-z0-9.+:~_-]+)?$ ]] || fail 'Invalid ignore pattern.'
    install -d -m 0755 "${IGNORE_FILE%/*}"
    touch "$IGNORE_FILE"
    tmp="$(mktemp "${IGNORE_FILE}.XXXXXX")"
    grep -vxF -- "$pattern" "$IGNORE_FILE" >"$tmp" || true
    case "$mode" in
        add) printf '%s\n' "$pattern" >>"$tmp" ;;
        remove) ;;
        *) rm -f -- "$tmp"; fail 'Invalid ignore mode.' ;;
    esac
    chmod 0644 "$tmp"
    mv -f "$tmp" "$IGNORE_FILE"
    log_header "Ignore list: $mode $pattern"
    progress 50 "$P_CALCULATE"
    calculate_updates
    progress 100 "$P_DONE"
}

clean_system() {
    local item
    ((${#EXTRA_ARGS[@]} > 0)) || fail 'Nothing was selected to clean.'
    for item in "${EXTRA_ARGS[@]}"; do
        case "$item" in
            apt-cache|autoremove|configs|old-kernels|logs|crash|journal|flatpak) ;;
            *) fail "Invalid clean-up item: $item" ;;
        esac
    done
    log_header "System clean-up: ${EXTRA_ARGS[*]}"
    run_tool clean-system "${EXTRA_ARGS[@]}"
    calculate_updates
}

run_tool() {
    # Run the Python maintenance helper; its stdout is the progress protocol.
    local errors rc message
    [[ -x "$PYTHON" && -r "$TOOL" ]] || fail 'The EUS maintenance helper is missing.'
    errors="$(mktemp)"
    "$PYTHON" -I "$TOOL" --lang "$LOCALE_CODE" "$@" 2>"$errors" | tee -a "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
    if ((rc != 0)); then
        message="$(tail -n 3 "$errors" | tr '\n' ' ')"
        cat "$errors" >>"$LOG_FILE"
        rm -f -- "$errors"
        fail "${message:-The maintenance helper failed. See /var/log/eus/eus.log.}"
    fi
    cat "$errors" >>"$LOG_FILE"
    rm -f -- "$errors"
}

refresh_after_repair() {
    # Repository changes alter the update set; rebuild it, but a remaining
    # repository error must not hide the successful repair itself.
    apt_update_command || true
    calculate_updates
}

fix_keys() {
    log_header 'GPG key and keyring repair requested'
    progress 2 "$P_KEYS"
    run_tool fix-keys
    calculate_updates
}

fix_duplicates() {
    log_header 'Duplicate repository repair requested'
    progress 5 "$P_DUPLICATES"
    run_tool fix-duplicates
    progress 70 "$P_REFRESH"
    refresh_after_repair
    progress 100 "$P_DONE"
}

add_key() {
    local -a args=()
    local index flag value
    ((${#EXTRA_ARGS[@]} % 2 == 0 && ${#EXTRA_ARGS[@]} <= 20)) || fail 'Invalid Add Key arguments.'
    for ((index = 0; index < ${#EXTRA_ARGS[@]}; index += 2)); do
        flag="${EXTRA_ARGS[index]}"
        value="${EXTRA_ARGS[index + 1]}"
        case "$flag" in
            --name|--file|--url|--keyserver|--repo-uri|--suite|--components|--arch) ;;
            --with-source) [[ "$value" == yes ]] || fail 'Invalid Add Key arguments.'; args+=(--with-source); continue ;;
            *) fail "Invalid Add Key option: $flag" ;;
        esac
        [[ "$value" != -* && "$value" != *$'\n'* && ${#value} -le 1024 ]] || fail 'Invalid Add Key value.'
        args+=("$flag" "$value")
    done
    log_header 'Manual GPG key installation requested'
    progress 3 "$P_ADD_KEY"
    run_tool add-key "${args[@]}"
    progress 70 "$P_REFRESH"
    refresh_after_repair
    progress 100 "$P_DONE"
}

add_repo() {
    local -a args=()
    local index flag value
    ((${#EXTRA_ARGS[@]} <= 24)) || fail 'Invalid Add Repository arguments.'
    for ((index = 0; index < ${#EXTRA_ARGS[@]}; index++)); do
        flag="${EXTRA_ARGS[index]}"
        case "$flag" in
            --auto-key|--with-source) args+=("$flag"); continue ;;
            --name|--line|--repo-uri|--suite|--components|--arch) ;;
            *) fail "Invalid Add Repository option: $flag" ;;
        esac
        value="${EXTRA_ARGS[index + 1]:-}"
        index=$((index + 1))
        [[ -n "$value" && "$value" != -* && "$value" != *$'\n'* && ${#value} -le 1024 ]] || \
            fail 'Invalid Add Repository value.'
        args+=("$flag" "$value")
    done
    log_header 'Manual repository installation requested'
    progress 2 "$P_ADD_REPO"
    run_tool add-repo "${args[@]}"
    progress 80 "$P_REFRESH"
    refresh_after_repair
    progress 100 "$P_DONE"
}

disk_free_kb() {
    df -Pk "$1" 2>/dev/null | awk 'NR == 2 {print $4 + 0}'
}

os_upgrade() {
    local target="${EXTRA_ARGS[0]:-}" backup errors plan
    [[ "$target" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || fail 'Invalid release codename.'
    # Keep going if the GUI that started the upgrade disappears.
    trap '' HUP PIPE
    log_header "OS upgrade to $target requested"
    progress 1 "$P_OS_CHECK"
    if (( $(disk_free_kb /) < 5242880 || $(disk_free_kb /var) < 5242880 )); then
        fail "$P_OS_SPACE"
    fi

    # Validate the repository plan before changing anything on the system.
    errors="$(mktemp)"
    plan="$("$PYTHON" -I "$TOOL" os-plan --target "$target" --format text 2>"$errors")" || {
        local message; message="$(tr '\n' ' ' <"$errors")$(grep -i blocked <<<"$plan")"; rm -f -- "$errors"
        fail "${message:-The OS upgrade plan could not be prepared.}"
    }
    rm -f -- "$errors"
    printf '%s\n' "$plan" >>"$LOG_FILE"
    grep -q '^  switch ' <<<"$plan" || fail 'No repository offers the new release yet.'

    timeshift_snapshot
    progress 3 "$P_OS_PREPARE"
    apt_update_or_fail
    UPGRADE_RANGE='5 10 15 10' apt_upgrade_command full-upgrade -y || \
        fail 'The current release could not be brought up to date. See /var/log/eus/eus.log.'

    progress 26 "$P_OS_SWITCH"
    errors="$(mktemp)"
    backup="$("$PYTHON" -I "$TOOL" os-switch "$target" 2>"$errors")" || {
        local message; message="$(tr '\n' ' ' <"$errors")"; rm -f -- "$errors"
        fail "${message:-The repositories could not be switched.}"
    }
    rm -f -- "$errors"
    log_header "Repositories switched to $target; backup in $backup"
    if ! apt_update_command || "$PYTHON" -I "$TOOL" apt-problems --check --keys-only; then
        # Never continue on half-working lists: restore the previous sources.
        "$PYTHON" -I "$TOOL" os-restore "$backup" >>"$LOG_FILE" 2>&1 || true
        apt_update_command || true
        fail "The new release repositories could not be loaded; the previous repositories were restored. See /var/log/eus/eus.log."
    fi

    progress 35 "$P_OS_UPGRADE"
    UPGRADE_RANGE='35 15 50 10' apt_upgrade_command upgrade --without-new-pkgs -y || \
        fail 'The minimal upgrade step failed. Fix the problem shown in /var/log/eus/eus.log and run Upgrade OS again.'
    UPGRADE_RANGE='60 15 75 15' apt_upgrade_command full-upgrade -y || \
        fail 'The full upgrade step failed. Fix the problem shown in /var/log/eus/eus.log and run Upgrade OS again.'
    progress 90 "$P_CALCULATE"
    calculate_updates
    post_clean
    os_check
    log_header "OS upgrade to $target finished"
    progress 100 "$P_DONE"
}

kernel_install() {
    local plan errors
    local -a tool_args=() packages=()
    for value in "${EXTRA_ARGS[@]}"; do
        if [[ "$value" == --headers ]]; then
            tool_args+=(--headers)
        else
            [[ "$value" =~ ^linux-image-[a-z0-9][a-z0-9.+~-]*$ ]] || fail "Invalid kernel package: $value"
            tool_args+=("$value")
        fi
    done
    log_header "Kernel installation requested: ${EXTRA_ARGS[*]}"
    progress 4 "$P_REFRESH"
    apt_update_or_fail
    progress 20 "$P_KERNEL_INSTALL"
    errors="$(mktemp)"
    plan="$("$PYTHON" -I "$TOOL" kernel-plan install "${tool_args[@]}" 2>"$errors")" || {
        local message; message="$(tr '\n' ' ' <"$errors")"; rm -f -- "$errors"
        fail "${message:-The kernel request was refused.}"
    }
    rm -f -- "$errors"
    mapfile -t packages <<<"$plan"
    timeshift_snapshot
    apt_upgrade_command install -y "${packages[@]}" || \
        fail 'The kernel could not be installed. See /var/log/eus/eus.log.'
    progress 90 "$P_CALCULATE"
    calculate_updates
    post_clean
    progress 100 "$P_DONE"
}

kernel_remove() {
    local plan errors value
    local -a packages=()
    ((${#EXTRA_ARGS[@]} > 0 && ${#EXTRA_ARGS[@]} <= 40)) || fail 'No kernel was selected.'
    for value in "${EXTRA_ARGS[@]}"; do
        [[ "$value" =~ ^[0-9][a-z0-9.+~-]*$ ]] || fail "Invalid kernel release: $value"
        [[ "$value" != "$(uname -r)" ]] || fail 'The running kernel cannot be removed.'
    done
    log_header "Kernel removal requested: ${EXTRA_ARGS[*]}"
    progress 10 "$P_KERNEL_REMOVE"
    errors="$(mktemp)"
    plan="$("$PYTHON" -I "$TOOL" kernel-plan remove "${EXTRA_ARGS[@]}" 2>"$errors")" || {
        local message; message="$(tr '\n' ' ' <"$errors")"; rm -f -- "$errors"
        fail "${message:-The kernel removal was refused.}"
    }
    rm -f -- "$errors"
    mapfile -t packages <<<"$plan"
    apt_upgrade_command purge -y "${packages[@]}" || \
        fail 'The kernel could not be removed. See /var/log/eus/eus.log.'
    progress 90 "$P_CALCULATE"
    calculate_updates
    post_clean
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
    refresh|auto-refresh|sources-refresh|upgrade-apt|install-apt|install-flatpak-system) ;;
    set-interval|set-schedule|pause|clear-history|reboot) ;;
    fix-keys|fix-duplicates|add-key|add-repo|kernel-install|kernel-remove) ;;
    os-check|os-upgrade|clean|ignore|set-option) ;;
    *) echo 'Invalid EUS privileged action.' >&2; exit 64 ;;
esac

[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
install -d -m 0755 "$STATE_DIR" "$LOG_DIR" /run/lock
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE"
exec 9>"$LOCK_FILE"
case "$ACTION" in
    # Background refreshes wait for an interactive operation to finish.
    auto-refresh|sources-refresh) flock -w 1800 9 || { log_header "$P_LOCK"; exit 0; } ;;
    *) flock -n 9 || fail "$P_LOCK" ;;
esac

case "$ACTION" in
    refresh|sources-refresh) refresh_lists ;;
    auto-refresh) auto_refresh ;;
    set-schedule) set_schedule ;;
    pause) pause_updates ;;
    fix-keys) fix_keys ;;
    fix-duplicates) fix_duplicates ;;
    add-key) add_key ;;
    add-repo) add_repo ;;
    os-check) progress 10 "$P_OS_CHECK"; os_check; progress 100 "$P_DONE" ;;
    os-upgrade) os_upgrade ;;
    clean) clean_system ;;
    ignore) ignore_update ;;
    set-option) set_option ;;
    kernel-install) kernel_install ;;
    kernel-remove) kernel_remove ;;
    upgrade-apt) upgrade_all_apt ;;
    install-apt) install_selected_apt ;;
    install-flatpak-system) install_system_flatpaks ;;
    set-interval) set_interval ;;
    clear-history) clear_history ;;
    reboot) perform_reboot ;;
esac
