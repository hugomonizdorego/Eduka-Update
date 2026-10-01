#!/bin/bash
# User-facing launcher, terminal fallback, and session update notifier.

set -u
export PATH='/usr/local/bin:/usr/bin:/bin'

APP_NAME='Eduka-Update-System'
VERSION='0.13'
GUI='/usr/local/libexec/eduka-update-system-gui'
PYTHON='/usr/bin/python3'
ROOT_HELPER='/usr/local/libexec/eduka-update-system-root'
STATE_FILE='/var/lib/eus/status'
RESTART_FILE='/var/lib/eus/restart-required'
TSV_FILE='/var/lib/eus/updates.tsv'
PAUSE_FILE='/etc/eus/pause'
TOOL='/usr/local/libexec/eduka-update-system-tool'
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
            OLD_KERNEL_BODY='Kernel foun la'"'"'o hela. Kernel tuan %s bele hasai ho seguru iha EUS → Kernel.'
            OPEN_KERNEL='Jere Kernel'
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
            OLD_KERNEL_BODY='O kernel novo esta em uso. %s kernel(s) antigo(s) pode(m) ser removido(s) com seguranca em EUS → Kernel.'
            OPEN_KERNEL='Gerir Kernels'
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
            OLD_KERNEL_BODY='Kernel baru sudah dipakai. %s kernel lama dapat dihapus dengan aman di EUS → Kernel.'
            OPEN_KERNEL='Kelola Kernel'
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
            OLD_KERNEL_BODY='The new kernel is in use. %s old kernel(s) can be removed safely in EUS → Kernel.'
            OPEN_KERNEL='Manage Kernels'
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
    # Optional arguments are passed to the GUI, e.g. --open kernel.
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
            "$PYTHON" "$GUI" "$@" >"$attempt_log" 2>&1
    else
        QT_AUTO_SCREEN_SCALE_FACTOR=1 "$PYTHON" "$GUI" "$@" >"$attempt_log" 2>&1
    fi
    rc=$?
    cat "$attempt_log" >>"$log_file"
    if [[ "$rc" -ne 0 && -n "${DISPLAY:-}" && "$preferred_platform" != xcb ]] && \
       grep -Eqi 'qt\.qpa|platform plugin|could not connect to display' "$attempt_log"; then
        printf '[%s] Retrying with Qt XCB platform.\n' "$(date --iso-8601=seconds)" >>"$log_file"
        : >"$attempt_log"
        QT_AUTO_SCREEN_SCALE_FACTOR=1 QT_QPA_PLATFORM=xcb "$PYTHON" "$GUI" "$@" >"$attempt_log" 2>&1
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

updates_paused() {
    local key value until=0
    [[ -r "$PAUSE_FILE" ]] || return 1
    while IFS='=' read -r key value; do
        [[ "$key" == PAUSED_UNTIL && "$value" =~ ^[0-9]+$ ]] && until="$value"
    done <"$PAUSE_FILE"
    (( until > $(date +%s) ))
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

invoke_root_terminal() {
    # Render the backend progress protocol ("NN" / "# text") for a terminal.
    local rc
    invoke_root "$@" | awk '
        /^[0-9]+$/ { pct = $0; next }
        /^# / { printf "[%3d%%] %s\n", pct, substr($0, 3); fflush(); next }
        NF { print; fflush() }'
    rc="${PIPESTATUS[0]}"
    if ((rc != 0)) && [[ -r /var/lib/eus/last-error ]]; then
        printf 'ERROR: %s\n' "$(</var/lib/eus/last-error)" >&2
    fi
    return "$rc"
}

terminal_add_key() {
    # --add-key NAME FILE|HTTPS-URL|KEY-ID [REPO-URI SUITE [COMPONENT...]]
    local name="${1:-}" source="${2:-}" uri="${3:-}" suite="${4:-}"
    local -a args=()
    if [[ -z "$name" || -z "$source" ]]; then
        usage >&2
        return 64
    fi
    shift 2
    args=(--name "$name")
    if [[ -f "$source" ]]; then
        args+=(--file "$(realpath -- "$source")")
    elif [[ "$source" == https://* ]]; then
        args+=(--url "$source")
    elif [[ "$source" =~ ^(0x)?[0-9A-Fa-f]{8,40}$ ]]; then
        args+=(--keyserver "$source")
    else
        printf 'The key source must be a file, an https:// URL, or a key ID.\n' >&2
        return 64
    fi
    if [[ -n "$uri" ]]; then
        [[ -n "$suite" ]] || { printf 'A repository also needs a suite, e.g. stable.\n' >&2; return 64; }
        shift 2
        args+=(--repo-uri "$uri" --suite "$suite")
        (($#)) && args+=(--components "$*")
    fi
    invoke_root_terminal add-key "${args[@]}"
}

terminal_remove_old_kernels() {
    local answer
    local -a releases=()
    mapfile -t releases < <("$PYTHON" -I "$TOOL" kernels --format old | sed '/^$/d')
    if ((${#releases[@]} == 0)); then
        printf 'No old kernel is installed.\n'
        return 0
    fi
    printf 'Running kernel: %s\nOld kernels: %s\n' "$(uname -r)" "${releases[*]}"
    read -r -p 'Remove them? [y/N] ' answer
    case "${answer,,}" in y|yes|s|sim|sin|i|iya|ya) ;; *) return 0 ;; esac
    invoke_root_terminal kernel-remove "${releases[@]}"
}

usage() {
    cat <<'USAGE'
Usage: eduka-update-system [OPTION]

Graphical interface:
  --ui                         open the update manager (default)
  --open kernel|key-fix|add-key|settings
                               open the manager directly on one dialog

Terminal:
  --terminal                   check and install updates in this terminal
  --fix-keys                   repair missing/expired GPG keys and keyrings
  --fix-duplicates             disable duplicate APT repository entries
  --add-key NAME SOURCE [URI SUITE [COMPONENT...]]
                               add a GPG key (file, https URL or key ID) and
                               optionally a repository signed by it
  --list-kernels               show installed and installable kernels
  --install-kernel PACKAGE [--headers]
  --remove-kernel RELEASE...   remove kernels (never the running one)
  --remove-old-kernels         remove every kernel older than the running one
  --pause DAYS                 pause automatic checks and notifications
  --resume                     resume automatic checks
  --schedule interval HOURS | daily HH:MM
  --check-notify | --watch | --restart | --version
USAGE
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
    if updates_paused; then
        # Paused by the user: no indicator and no desktop notification.
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

send_old_kernel_notification() {
    # Once per boot: after restarting into a new kernel, point to the old ones.
    command -v notify-send >/dev/null 2>&1 || return 0
    local cache_dir stamp_file boot count action
    cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/eus"
    stamp_file="$cache_dir/old-kernel-notified"
    boot="$(current_boot_id)"
    [[ -r "$stamp_file" && "$(<"$stamp_file")" == "$boot" ]] && return 0
    mkdir -p "$cache_dir"
    printf '%s\n' "$boot" >"$stamp_file"
    count="$("$PYTHON" -I "$TOOL" kernels --format old 2>/dev/null | grep -c . || true)"
    [[ "$count" =~ ^[0-9]+$ ]] && ((count > 0)) || return 0
    if notify-send --help 2>&1 | grep -q -- '--action'; then
        (
            action="$(notify-send --app-name="$APP_NAME" --icon=eduka-update-system \
                --urgency=low --expire-time=30000 --action="default=$OPEN_KERNEL" \
                "$APP_NAME" "$(printf "$OLD_KERNEL_BODY" "$count")" 2>/dev/null || true)"
            [[ "$action" == 'default' ]] && /usr/local/bin/eduka-update-system --open kernel >/dev/null 2>&1
        ) &
    else
        notify-send --app-name="$APP_NAME" --icon=eduka-update-system --urgency=low \
            "$APP_NAME" "$(printf "$OLD_KERNEL_BODY" "$count")" || true
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
    send_old_kernel_notification
    while true; do
        send_update_notification
        send_restart_notification
        sleep "$CHECK_INTERVAL_SECONDS"
    done
}

detect_language
load_messages

command_name="${1:---ui}"
(($#)) && shift
case "$command_name" in
    --ui) launch_gui "$@" ;;
    --open)
        case "${1:-}" in
            kernel|key-fix|add-key|settings) launch_gui --open "$1" ;;
            *) usage >&2; exit 64 ;;
        esac
        ;;
    --terminal|--run) terminal_update ;;
    --check-notify) send_update_notification; send_restart_notification ;;
    --watch) watch_updates ;;
    --restart) invoke_root reboot ;;
    --fix-keys) invoke_root_terminal fix-keys ;;
    --fix-duplicates) invoke_root_terminal fix-duplicates ;;
    --add-key) terminal_add_key "$@" ;;
    --list-kernels) "$PYTHON" -I "$TOOL" kernels --format text ;;
    --install-kernel)
        (($#)) || { usage >&2; exit 64; }
        invoke_root_terminal kernel-install "$@"
        ;;
    --remove-kernel)
        (($#)) || { usage >&2; exit 64; }
        invoke_root_terminal kernel-remove "$@"
        ;;
    --remove-old-kernels) terminal_remove_old_kernels ;;
    --pause)
        [[ "${1:-}" =~ ^[0-9]+$ ]] || { usage >&2; exit 64; }
        invoke_root_terminal pause "$1"
        ;;
    --resume) invoke_root_terminal pause 0 ;;
    --schedule)
        (($# == 2)) || { usage >&2; exit 64; }
        invoke_root_terminal set-schedule "$1" "$2"
        ;;
    --version) printf 'Eduka-Update-System %s\n' "$VERSION" ;;
    -h|--help) usage ;;
    *) usage >&2; exit 64 ;;
esac
