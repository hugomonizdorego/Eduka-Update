#!/usr/bin/python3
"""Qt 6 interface for Eduka-Update-System 0.15."""

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
TOOL = os.environ.get("EUS_TOOL", "/usr/local/libexec/eduka-update-system-tool")
PAUSE_FILE = Path(os.environ.get("EUS_PAUSE_FILE", "/etc/eus/pause"))
SCHEDULE_FILE = Path(os.environ.get("EUS_SCHEDULE_FILE", "/etc/eus/schedule"))
APT_UPDATE_LOG = Path(os.environ.get("EUS_APT_UPDATE_LOG", "/var/lib/eus/apt-update.log"))
REPORT_FILE = Path(os.environ.get("EUS_REPORT_FILE", "/var/lib/eus/repair-report.json"))
CONFIG_FILE = Path(os.environ.get("EUS_CONFIG_FILE", "/etc/eus/eus.conf"))
IGNORE_FILE = Path(os.environ.get("EUS_IGNORE_FILE", "/etc/eus/ignored-updates"))
OS_UPGRADE_FILE = Path(os.environ.get("EUS_OS_UPGRADE_FILE", "/var/lib/eus/os-upgrade"))
REPOSITORIES_FIXTURE = os.environ.get("EUS_REPOSITORIES_FIXTURE", "")
OS_PLAN_FIXTURE = os.environ.get("EUS_OS_PLAN_FIXTURE", "")
PANEL_STATUS = "/usr/local/bin/eus-panel-status"
EUS_VERSION = "0.15"
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
        fields = line.split("\t")
        if len(fields) < 7:
            continue
        category, source, name, installed, candidate, size, description = fields[:7]
        srcpkg = fields[7] if len(fields) > 7 and fields[7] else name
        if category not in {"critical", "kernel", "medium", "normal", "flatpak"}:
            continue
        if source not in {"apt", "flatpak-system", "flatpak-user"}:
            continue
        try:
            size_bytes = max(0, int(size))
        except ValueError:
            size_bytes = parse_size(size)
        records.append({"category": category, "source": source, "name": name,
                        "installed": installed, "candidate": candidate,
                        "size": size_bytes, "description": description, "srcpkg": srcpkg})
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
    for category in ("critical", "kernel", "medium", "normal", "flatpak"):
        result[category] = sum(x["category"] == category for x in updates)
    result["groups"] = len({(x["source"], x["srcpkg"]) for x in updates})
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0)


try:
    from PyQt6.QtCore import (QFileSystemWatcher, QPoint, QProcess, QProcessEnvironment, QSize, Qt,
                              QTime, QTimer, pyqtSignal)
    from PyQt6.QtGui import QAction, QBrush, QColor, QFont, QIcon, QKeySequence, QShortcut
    from PyQt6.QtNetwork import QLocalServer, QLocalSocket
    from PyQt6.QtWidgets import (
        QAbstractItemView, QApplication, QButtonGroup, QCheckBox, QComboBox, QDialog,
        QDialogButtonBox, QFileDialog, QFormLayout, QFrame, QGridLayout, QGroupBox, QHBoxLayout,
        QHeaderView, QLabel, QLineEdit, QMainWindow, QMenu, QMessageBox, QPlainTextEdit, QProgressBar,
        QPushButton, QRadioButton, QSizePolicy, QSpinBox, QSplitter, QTabWidget, QTimeEdit,
        QToolButton, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget,
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

# Strings added in EUS 0.13 and 0.14. Missing translations fall back to English.
EXTRA_MESSAGES = {
    "en": {
        "menu_updates": "&Updates", "menu_kernel": "&Kernel", "menu_keyfix": "Key &Fix",
        "menu_addkey": "&Add Key", "menu_settings": "&Settings", "menu_help": "&Help",
        "action_quit": "Quit", "action_log": "View Log", "action_select_all": "Select All Updates",
        "banner_paused": "Automatic update checks are paused until {date}.",
        "resume": "Resume Updates",
        "banner_repo": "Repository problems: {details}", "open_keyfix": "Open Key Fix",
        "banner_kernel": "{count} old kernel(s) can be removed safely.", "open_kernel": "Manage Kernels",
        "chip_critical": "Critical", "chip_medium": "Important", "chip_normal": "Regular",
        "chip_flatpak": "Flatpak",
        "repo_unreachable": "{count} unreachable repository(ies)", "kf_unreachable": "Repository cannot be reached (network or address problem)",
        "repo_missing": "{count} missing key(s)", "repo_expired": "{count} expired key(s)",
        "repo_duplicates": "{count} duplicate repository entr(ies)",
        "repo_unsigned": "{count} unsigned repository(ies)", "repo_legacy": "legacy keyring in use",
        "repo_conflict": "conflicting Signed-By values",
        "working": "Working…", "busy": "Another EUS operation is still running. Wait for it to finish.",
        "next_check": "Schedule: {schedule}", "schedule_interval": "every {hours} hours",
        "schedule_daily": "daily at {time}", "schedule_week": "every week",
        "kernel_title": "Kernel Manager", "kernel_running": "Running kernel: {release}",
        "kernel_intro": "The kernel in use can never be removed. After a new kernel is installed and the computer restarts, the previous kernel is marked “Old kernel” and can be removed safely.",
        "k_col_release": "Kernel", "k_col_status": "Status", "k_col_version": "Package version",
        "k_col_size": "Size",
        "k_state_running": "In use (running)", "k_state_old": "Old kernel — safe to remove",
        "k_state_newer": "New — restart to use", "k_state_residual": "Leftover configuration",
        "k_installed": "Installed kernels", "k_available": "Install a new kernel",
        "k_headers": "Also install matching kernel headers (needed by drivers such as NVIDIA or VirtualBox)",
        "k_install": "Install Kernel", "k_remove": "Remove Selected", "k_remove_old": "Remove All Old Kernels",
        "k_refresh": "Refresh", "k_loading": "Reading kernel information…",
        "k_none_available": "No other kernel is available from the configured repositories.",
        "k_meta": "{package} — always the latest kernel of this series (recommended)",
        "k_confirm_install": "Install {package}?\n\nRestart the computer afterward to start using the new kernel.",
        "k_confirm_remove": "Remove these kernels?\n\n{items}\n\nThe running kernel is not affected.",
        "k_installed_ok": "The kernel was installed. Restart the computer to start using it; the current kernel will then be marked as an old kernel.",
        "k_removed_ok": "The selected kernels were removed.", "k_no_old": "There is no old kernel to remove.",
        "k_select": "Select at least one removable kernel.",
        "kf_title": "Key Fix — Repository and GPG Key Repair",
        "kf_tab_keys": "GPG keys", "kf_tab_repos": "Duplicate repositories",
        "kf_col_item": "Item",
        "kf_ok_keys": "No GPG key problem was found.", "kf_ok_repos": "No duplicate repository was found.",
        "kf_fix_keys": "Repair GPG Keys", "kf_fix_dups": "Fix Duplicates", "kf_rescan": "Scan Again",
        "kf_scanning": "Scanning repositories and keyrings…",
        "kf_missing": "Missing signing key", "kf_expired": "Expired or revoked signing key",
        "kf_unsigned": "Repository is not signed", "kf_conflict": "Conflicting Signed-By values",
        "kf_missing_file": "Signed-By keyring file is missing", "kf_legacy": "Keys are stored in the deprecated trusted.gpg keyring",
        "kf_multiple": "Repository configured multiple times",
        "kf_dup_complete": "Duplicate of {first} — will be disabled",
        "kf_dup_partial": "Partly duplicates {first} — repeated components will be removed",
        "kf_done": "Repair finished.", "kf_remaining": "Some problems remain:",
        "kf_backup": "Backups: {path}", "kf_last_update": "Based on the last repository refresh: {time}",
        "kf_no_refresh": "Run Check for Updates once so EUS can detect missing keys.",
        "ak_title": "Add Key — Install a GPG Key or Repository",
        "ak_intro": "Add the signing key of a repository you trust. Without a repository the key is trusted for all repositories (for repositories added in a terminal); with a repository, EUS adds it safely with Signed-By and never creates a duplicate entry.",
        "ak_name": "Name", "ak_name_hint": "e.g. vendor-tools", "ak_source": "Key source",
        "ak_file": "Key file", "ak_browse": "Browse…", "ak_url": "Key URL (https)",
        "ak_keyserver": "Key ID / fingerprint", "ak_repo": "Also add the repository that uses this key",
        "ak_repo_uri": "Repository URI", "ak_suite": "Suite", "ak_components": "Components",
        "ak_arch": "Architectures", "ak_optional": "optional", "ak_source_pkgs": "Also enable source packages (deb-src)",
        "ak_preview": "Result", "ak_add": "Add Key",
        "ak_added": "The key was added and the package lists were refreshed.",
        "ak_invalid_name": "Enter a name using lowercase letters, digits, dots, dashes or underscores.",
        "ak_missing_source": "Choose a key file, an https URL, or a key ID.",
        "ak_invalid_repo": "Enter the repository URI, the suite and the components.",
        "ak_select_file": "Select a GPG key file", "ak_key_info": "Key: {uid} ({keyid})",
        "ak_preview_key": "The key will be trusted for every repository:\n/etc/apt/trusted.gpg.d/{name}.gpg",
        "ak_preview_repo": "/etc/apt/keyrings/{name}.gpg\n/etc/apt/sources.list.d/{name}.sources:\n\n{stanza}",
        "st_schedule": "Update check schedule", "st_every": "Check every", "st_daily": "Check once a day at",
        "st_pause": "Pause updates", "st_pause_for": "Pause for", "st_days": "days",
        "st_pause_button": "Pause", "st_resume_button": "Resume Now",
        "st_not_paused": "Automatic checks are active.", "st_paused_until": "Paused until {date}.",
        "st_pause_note": "While paused, EUS does not check automatically and shows no update notifications. You can still check and install manually.",
        "st_week": "Every week", "st_general": "Notifications",
        "log_title": "EUS Log",
        "kf_col_problem": "Details",
        "kf_intro": "Key Fix first works out where each repository's key belongs: package keyrings in /usr/share/keyrings are never edited (their package is reinstalled), repository keyrings in /etc/apt/keyrings are used through Signed-By, and /etc/apt/trusted.gpg.d is only for keys trusted by every repository. Missing or expired keys are then found on the internet and installed into exactly that place; duplicate repositories are disabled. Backups are kept in /var/backups/eus.",
        "kf_tab_overview": "Repositories", "kf_target": "will be installed into {path} — {where}",
        "kf_keyring_info": "{role}{package} · used by {count} repository(ies)",
        "kf_keyring_global": "{role}{package} · trusted for every repository without Signed-By",
        "rp_col_repo": "Repository", "rp_col_suite": "Suite", "rp_col_type": "Type",
        "rp_col_keyring": "Signing keyring", "rp_col_status": "Status",
        "rp_role_debian": "Debian", "rp_role_debian-security": "Debian security",
        "rp_role_edukasaun": "Edukasaun OS", "rp_role_ubuntu": "Ubuntu", "rp_role_third-party": "Third-party",
        "rp_status_ok": "OK", "rp_status_disabled": "Disabled", "rp_status_unreachable": "Unreachable",
        "rp_status_missing-key": "Missing GPG key", "rp_status_expired-key": "Expired GPG key",
        "rp_status_unsigned": "Not signed", "rp_status_duplicate": "Duplicate",
        "kr_package": "package keyring", "kr_scoped": "repository keyring", "kr_global": "global keyring",
        "kr_legacy": "legacy trusted.gpg", "kr_embedded": "embedded key", "kr_none": "global keyrings",
        "menu_addrepo": "Add &Repo", "menu_upgrade": "Upgrade &OS",
        "banner_os": "Upgrade OS: {os} can move to the new Debian {version} \"{codename}\" base.",
        "open_upgrade": "Upgrade OS",
        "ar_title": "Add Repo — Add a Repository",
        "ar_intro": "Paste the repository line from the vendor's instructions or fill in the fields. EUS adds it, refreshes it on its own, and when the repository asks for a GPG key that is not installed, EUS searches the vendor's site and the keyservers for exactly that key, installs it into /etc/apt/keyrings/<name>.gpg and sets Signed-By, so the repository can be used right away.",
        "ar_line": "Repository line", "ar_fields": "Fields", "ar_mode": "Enter the repository as",
        "ar_auto_key": "Find and install the signing key automatically",
        "ar_add": "Add Repository", "ar_added": "The repository was added and is ready to use.",
        "ar_key_found": "Signing key found at {source}:", "ar_invalid_line": "Enter a line such as: deb https://repo.example.org/debian stable main",
        "os_title": "Upgrade OS", "os_from_to": "{os}: Debian {current} → Debian {target}",
        "os_intro": "A new Debian stable release is available as the base of Edukasaun OS. EUS first brings the current release up to date, then switches every repository that offers the new release to its new codename. Third-party repositories that do not offer it yet stay on their current suite, so nothing conflicts. All repository files are backed up and restored automatically if the new repositories cannot be loaded.",
        "os_col_repo": "Repository", "os_col_current": "Current suite", "os_col_new": "New suite",
        "os_col_action": "Action", "os_action_switch": "Switch", "os_action_keep": "Keep (no new release)",
        "os_action_unchanged": "Unchanged", "os_action_missing": "Not ready",
        "os_checking": "Checking every repository for the new release…",
        "os_blocked": "The upgrade cannot start yet: a distribution repository does not offer the new release.",
        "os_warning": "Save your work and keep the computer connected to power and network. The upgrade can take a long time; a restart is required at the end.",
        "os_start": "Upgrade OS", "os_confirm": "Upgrade to Debian {target} now?\n\nThis can take a long time. Do not turn the computer off.",
        "os_done": "The operating system was upgraded. Restart the computer to finish.",
        "os_none": "No new Debian base release is available.",
    },
    "id": {
        "menu_updates": "&Pembaruan", "menu_kernel": "&Kernel", "menu_keyfix": "Key &Fix",
        "menu_addkey": "&Add Key", "menu_settings": "Pe&ngaturan", "menu_help": "&Bantuan",
        "action_quit": "Keluar", "action_log": "Lihat Log", "action_select_all": "Pilih Semua Pembaruan",
        "banner_paused": "Pemeriksaan pembaruan otomatis dijeda sampai {date}.",
        "resume": "Lanjutkan Pembaruan",
        "banner_repo": "Masalah repositori: {details}", "open_keyfix": "Buka Key Fix",
        "banner_kernel": "{count} kernel lama dapat dihapus dengan aman.", "open_kernel": "Kelola Kernel",
        "chip_critical": "Kritis", "chip_medium": "Penting", "chip_normal": "Biasa", "chip_flatpak": "Flatpak",
        "repo_unreachable": "{count} repositori tidak dapat dihubungi", "kf_unreachable": "Repositori tidak dapat dihubungi (masalah jaringan atau alamat)",
        "repo_missing": "{count} kunci hilang", "repo_expired": "{count} kunci kedaluwarsa",
        "repo_duplicates": "{count} entri repositori duplikat",
        "repo_unsigned": "{count} repositori tidak ditandatangani", "repo_legacy": "keyring lama masih dipakai",
        "repo_conflict": "nilai Signed-By bertentangan",
        "working": "Sedang bekerja…", "busy": "Operasi EUS lain masih berjalan. Tunggu hingga selesai.",
        "next_check": "Jadwal: {schedule}", "schedule_interval": "setiap {hours} jam",
        "schedule_daily": "setiap hari pukul {time}", "schedule_week": "setiap minggu",
        "kernel_title": "Pengelola Kernel", "kernel_running": "Kernel yang berjalan: {release}",
        "kernel_intro": "Kernel yang sedang dipakai tidak pernah dapat dihapus. Setelah kernel baru dipasang dan komputer dimulai ulang, kernel sebelumnya ditandai “Kernel lama” dan dapat dihapus dengan aman.",
        "k_col_release": "Kernel", "k_col_status": "Status", "k_col_version": "Versi paket", "k_col_size": "Ukuran",
        "k_state_running": "Sedang dipakai (berjalan)", "k_state_old": "Kernel lama — aman dihapus",
        "k_state_newer": "Baru — mulai ulang untuk memakai", "k_state_residual": "Sisa konfigurasi",
        "k_installed": "Kernel terpasang", "k_available": "Pasang kernel baru",
        "k_headers": "Pasang juga header kernel yang sesuai (diperlukan driver seperti NVIDIA atau VirtualBox)",
        "k_install": "Pasang Kernel", "k_remove": "Hapus yang Dipilih", "k_remove_old": "Hapus Semua Kernel Lama",
        "k_refresh": "Muat Ulang", "k_loading": "Membaca informasi kernel…",
        "k_none_available": "Tidak ada kernel lain yang tersedia dari repositori yang dikonfigurasi.",
        "k_meta": "{package} — selalu kernel terbaru dari seri ini (disarankan)",
        "k_confirm_install": "Pasang {package}?\n\nMulai ulang komputer setelahnya untuk mulai memakai kernel baru.",
        "k_confirm_remove": "Hapus kernel berikut?\n\n{items}\n\nKernel yang sedang berjalan tidak terpengaruh.",
        "k_installed_ok": "Kernel berhasil dipasang. Mulai ulang komputer untuk memakainya; kernel saat ini akan ditandai sebagai kernel lama.",
        "k_removed_ok": "Kernel yang dipilih telah dihapus.", "k_no_old": "Tidak ada kernel lama untuk dihapus.",
        "k_select": "Pilih minimal satu kernel yang dapat dihapus.",
        "kf_title": "Key Fix — Perbaikan Repositori dan Kunci GPG",
        "kf_intro": "Key Fix memeriksa kunci penandatangan APT dan daftar repositori, mengunduh kunci yang hilang atau kedaluwarsa, memperbaiki keyring yang rusak, dan menghapus entri repositori duplikat. Cadangan disimpan di /var/backups/eus.",
        "kf_tab_keys": "Kunci GPG", "kf_tab_repos": "Repositori duplikat",
        "kf_col_item": "Item", "kf_col_problem": "Masalah",
        "kf_ok_keys": "Tidak ditemukan masalah kunci GPG.", "kf_ok_repos": "Tidak ditemukan repositori duplikat.",
        "kf_fix_keys": "Perbaiki Kunci GPG", "kf_fix_dups": "Perbaiki Duplikat", "kf_rescan": "Pindai Lagi",
        "kf_scanning": "Memindai repositori dan keyring…",
        "kf_missing": "Kunci penandatangan hilang", "kf_expired": "Kunci penandatangan kedaluwarsa atau dicabut",
        "kf_unsigned": "Repositori tidak ditandatangani", "kf_conflict": "Nilai Signed-By bertentangan",
        "kf_missing_file": "Berkas keyring Signed-By tidak ada", "kf_legacy": "Kunci tersimpan di keyring lama trusted.gpg",
        "kf_multiple": "Repositori dikonfigurasi lebih dari sekali",
        "kf_dup_complete": "Duplikat dari {first} — akan dinonaktifkan",
        "kf_dup_partial": "Sebagian menduplikasi {first} — komponen ganda akan dihapus",
        "kf_done": "Perbaikan selesai.", "kf_remaining": "Masih ada masalah:",
        "kf_backup": "Cadangan: {path}", "kf_last_update": "Berdasarkan pembaruan repositori terakhir: {time}",
        "kf_no_refresh": "Jalankan Periksa Pembaruan sekali agar EUS dapat mendeteksi kunci yang hilang.",
        "ak_title": "Add Key — Pasang Kunci GPG atau Repositori",
        "ak_intro": "Tambahkan kunci penandatangan dari repositori yang Anda percayai. Tanpa repositori, kunci dipercaya untuk semua repositori (untuk repositori yang ditambahkan lewat terminal); dengan repositori, EUS menambahkannya dengan aman memakai Signed-By dan tidak pernah membuat entri duplikat.",
        "ak_name": "Nama", "ak_name_hint": "mis. vendor-tools", "ak_source": "Sumber kunci",
        "ak_file": "Berkas kunci", "ak_browse": "Telusuri…", "ak_url": "URL kunci (https)",
        "ak_keyserver": "ID / sidik jari kunci", "ak_repo": "Tambahkan juga repositori yang memakai kunci ini",
        "ak_repo_uri": "URI repositori", "ak_suite": "Suite", "ak_components": "Komponen",
        "ak_arch": "Arsitektur", "ak_optional": "opsional", "ak_source_pkgs": "Aktifkan juga paket sumber (deb-src)",
        "ak_preview": "Hasil", "ak_add": "Tambah Kunci",
        "ak_added": "Kunci berhasil ditambahkan dan daftar paket telah diperbarui.",
        "ak_invalid_name": "Masukkan nama dengan huruf kecil, angka, titik, tanda hubung, atau garis bawah.",
        "ak_missing_source": "Pilih berkas kunci, URL https, atau ID kunci.",
        "ak_invalid_repo": "Masukkan URI repositori, suite, dan komponen.",
        "ak_select_file": "Pilih berkas kunci GPG", "ak_key_info": "Kunci: {uid} ({keyid})",
        "ak_preview_key": "Kunci akan dipercaya untuk semua repositori:\n/etc/apt/trusted.gpg.d/{name}.gpg",
        "st_schedule": "Jadwal pemeriksaan pembaruan", "st_every": "Periksa setiap",
        "st_daily": "Periksa sekali sehari pukul", "st_pause": "Jeda pembaruan", "st_pause_for": "Jeda selama",
        "st_days": "hari", "st_pause_button": "Jeda", "st_resume_button": "Lanjutkan Sekarang",
        "st_not_paused": "Pemeriksaan otomatis aktif.", "st_paused_until": "Dijeda sampai {date}.",
        "st_pause_note": "Selama dijeda, EUS tidak memeriksa secara otomatis dan tidak menampilkan notifikasi pembaruan. Anda tetap dapat memeriksa dan memasang secara manual.",
        "st_week": "Setiap minggu", "st_general": "Notifikasi", "log_title": "Log EUS",
    },
    "pt": {
        "menu_updates": "&Atualizacoes", "menu_kernel": "&Kernel", "menu_keyfix": "Key &Fix",
        "menu_addkey": "&Add Key", "menu_settings": "&Configuracoes", "menu_help": "A&juda",
        "action_quit": "Sair", "action_log": "Ver Registo", "action_select_all": "Selecionar Todas",
        "banner_paused": "As verificacoes automaticas estao em pausa ate {date}.",
        "resume": "Retomar Atualizacoes",
        "banner_repo": "Problemas nos repositorios: {details}", "open_keyfix": "Abrir Key Fix",
        "banner_kernel": "{count} kernel(s) antigo(s) pode(m) ser removido(s) com seguranca.",
        "open_kernel": "Gerir Kernels",
        "chip_critical": "Criticas", "chip_medium": "Importantes", "chip_normal": "Regulares", "chip_flatpak": "Flatpak",
        "repo_unreachable": "{count} repositorio(s) inacessivel(is)", "kf_unreachable": "Repositorio inacessivel (problema de rede ou endereco)",
        "repo_missing": "{count} chave(s) em falta", "repo_expired": "{count} chave(s) expirada(s)",
        "repo_duplicates": "{count} entrada(s) de repositorio duplicada(s)",
        "repo_unsigned": "{count} repositorio(s) sem assinatura", "repo_legacy": "keyring antigo em uso",
        "repo_conflict": "valores Signed-By em conflito",
        "working": "Processando…", "busy": "Outra operacao do EUS ainda esta em curso. Aguarde.",
        "next_check": "Agenda: {schedule}", "schedule_interval": "a cada {hours} horas",
        "schedule_daily": "diariamente as {time}", "schedule_week": "semanalmente",
        "kernel_title": "Gestor de Kernels", "kernel_running": "Kernel em execucao: {release}",
        "kernel_intro": "O kernel em uso nunca pode ser removido. Depois de instalar um kernel novo e reiniciar, o kernel anterior e marcado como “Kernel antigo” e pode ser removido com seguranca.",
        "k_col_release": "Kernel", "k_col_status": "Estado", "k_col_version": "Versao do pacote", "k_col_size": "Tamanho",
        "k_state_running": "Em uso (em execucao)", "k_state_old": "Kernel antigo — pode ser removido",
        "k_state_newer": "Novo — reinicie para usar", "k_state_residual": "Configuracao residual",
        "k_installed": "Kernels instalados", "k_available": "Instalar um kernel novo",
        "k_headers": "Instalar tambem os headers do kernel (necessarios para drivers como NVIDIA ou VirtualBox)",
        "k_install": "Instalar Kernel", "k_remove": "Remover Selecionados", "k_remove_old": "Remover Kernels Antigos",
        "k_refresh": "Atualizar", "k_loading": "Lendo informacoes dos kernels…",
        "k_none_available": "Nenhum outro kernel esta disponivel nos repositorios configurados.",
        "k_meta": "{package} — sempre o kernel mais recente desta serie (recomendado)",
        "k_confirm_install": "Instalar {package}?\n\nReinicie o computador depois para usar o kernel novo.",
        "k_confirm_remove": "Remover estes kernels?\n\n{items}\n\nO kernel em execucao nao e afetado.",
        "k_installed_ok": "O kernel foi instalado. Reinicie o computador para usa-lo; o kernel atual sera marcado como antigo.",
        "k_removed_ok": "Os kernels selecionados foram removidos.", "k_no_old": "Nao ha kernels antigos para remover.",
        "k_select": "Selecione pelo menos um kernel removivel.",
        "kf_title": "Key Fix — Reparacao de Repositorios e Chaves GPG",
        "kf_intro": "O Key Fix verifica as chaves de assinatura do APT e as listas de repositorios, transfere chaves em falta ou expiradas, repara keyrings danificados e remove entradas duplicadas. As copias de seguranca ficam em /var/backups/eus.",
        "kf_tab_keys": "Chaves GPG", "kf_tab_repos": "Repositorios duplicados",
        "kf_col_item": "Item", "kf_col_problem": "Problema",
        "kf_ok_keys": "Nenhum problema de chaves GPG encontrado.", "kf_ok_repos": "Nenhum repositorio duplicado encontrado.",
        "kf_fix_keys": "Reparar Chaves GPG", "kf_fix_dups": "Corrigir Duplicados", "kf_rescan": "Verificar Novamente",
        "kf_scanning": "Verificando repositorios e keyrings…",
        "kf_missing": "Chave de assinatura em falta", "kf_expired": "Chave expirada ou revogada",
        "kf_unsigned": "Repositorio sem assinatura", "kf_conflict": "Valores Signed-By em conflito",
        "kf_missing_file": "Ficheiro de keyring Signed-By em falta", "kf_legacy": "Chaves no keyring obsoleto trusted.gpg",
        "kf_multiple": "Repositorio configurado varias vezes",
        "kf_dup_complete": "Duplicado de {first} — sera desativado",
        "kf_dup_partial": "Duplica parcialmente {first} — componentes repetidos serao removidos",
        "kf_done": "Reparacao concluida.", "kf_remaining": "Ainda existem problemas:",
        "kf_backup": "Copias de seguranca: {path}", "kf_last_update": "Com base na ultima atualizacao: {time}",
        "kf_no_refresh": "Execute Verificar atualizacoes uma vez para o EUS detetar chaves em falta.",
        "ak_title": "Add Key — Instalar Chave GPG ou Repositorio",
        "ak_intro": "Adicione a chave de assinatura de um repositorio confiavel. Sem repositorio, a chave e confiavel para todos os repositorios; com repositorio, o EUS adiciona-o com Signed-By e nunca cria entradas duplicadas.",
        "ak_name": "Nome", "ak_name_hint": "ex. vendor-tools", "ak_source": "Origem da chave",
        "ak_file": "Ficheiro da chave", "ak_browse": "Procurar…", "ak_url": "URL da chave (https)",
        "ak_keyserver": "ID / impressao digital", "ak_repo": "Adicionar tambem o repositorio que usa esta chave",
        "ak_repo_uri": "URI do repositorio", "ak_suite": "Suite", "ak_components": "Componentes",
        "ak_arch": "Arquiteturas", "ak_optional": "opcional", "ak_source_pkgs": "Ativar tambem pacotes fonte (deb-src)",
        "ak_preview": "Resultado", "ak_add": "Adicionar Chave",
        "ak_added": "A chave foi adicionada e as listas de pacotes foram atualizadas.",
        "ak_invalid_name": "Use letras minusculas, digitos, pontos, hifens ou sublinhados no nome.",
        "ak_missing_source": "Escolha um ficheiro, um URL https ou um ID de chave.",
        "ak_invalid_repo": "Indique o URI, a suite e os componentes do repositorio.",
        "ak_select_file": "Selecionar ficheiro de chave GPG", "ak_key_info": "Chave: {uid} ({keyid})",
        "ak_preview_key": "A chave sera confiavel para todos os repositorios:\n/etc/apt/trusted.gpg.d/{name}.gpg",
        "st_schedule": "Agenda de verificacao", "st_every": "Verificar a cada", "st_daily": "Verificar diariamente as",
        "st_pause": "Pausar atualizacoes", "st_pause_for": "Pausar durante", "st_days": "dias",
        "st_pause_button": "Pausar", "st_resume_button": "Retomar Agora",
        "st_not_paused": "As verificacoes automaticas estao ativas.", "st_paused_until": "Em pausa ate {date}.",
        "st_pause_note": "Em pausa, o EUS nao verifica automaticamente nem mostra notificacoes. Pode verificar e instalar manualmente.",
        "st_week": "Semanalmente", "st_general": "Notificacoes", "log_title": "Registo do EUS",
    },
    "tet": {
        "menu_updates": "&Atualizasaun", "menu_kernel": "&Kernel", "menu_keyfix": "Key &Fix",
        "menu_addkey": "&Add Key", "menu_settings": "&Konfigurasaun", "menu_help": "A&judu",
        "action_quit": "Sai", "action_log": "Haree Log", "action_select_all": "Hili Atualizasaun Hotu",
        "banner_paused": "Verifikasaun automatiku pauza to'o {date}.", "resume": "Kontinua Atualizasaun",
        "banner_repo": "Problema repositoriu: {details}", "open_keyfix": "Loke Key Fix",
        "banner_kernel": "Kernel tuan {count} bele hasai ho seguru.", "open_kernel": "Jere Kernel",
        "chip_critical": "Kritiku", "chip_medium": "Importante", "chip_normal": "Regular", "chip_flatpak": "Flatpak",
        "repo_unreachable": "repositoriu {count} la bele asesu", "kf_unreachable": "Repositoriu la bele asesu (problema rede ka enderesu)",
        "repo_missing": "xave {count} lakon", "repo_expired": "xave {count} expiradu",
        "repo_duplicates": "repositoriu duplikadu {count}", "repo_unsigned": "repositoriu {count} la iha asinatura",
        "repo_legacy": "uza hela keyring tuan", "repo_conflict": "valor Signed-By konflitu",
        "working": "Servisu hela…", "busy": "Operasaun EUS seluk sei la'o hela. Hein to'o remata.",
        "next_check": "Oráriu: {schedule}", "schedule_interval": "kada oras {hours}",
        "schedule_daily": "loron-loron oras {time}", "schedule_week": "kada semana",
        "kernel_title": "Jestór Kernel", "kernel_running": "Kernel nebe la'o hela: {release}",
        "kernel_intro": "Kernel nebe uza hela labele hasai. Depois instala kernel foun no hahu fali komputadór, kernel uluk sei hetan marka “Kernel tuan” no bele hasai ho seguru.",
        "k_col_release": "Kernel", "k_col_status": "Estadu", "k_col_version": "Versaun pakote", "k_col_size": "Tamañu",
        "k_state_running": "Uza hela (la'o hela)", "k_state_old": "Kernel tuan — bele hasai",
        "k_state_newer": "Foun — hahu fali atu uza", "k_state_residual": "Konfigurasaun restu",
        "k_installed": "Kernel nebe instaladu", "k_available": "Instala kernel foun",
        "k_headers": "Instala mos header kernel (presiza ba driver hanesan NVIDIA ka VirtualBox)",
        "k_install": "Instala Kernel", "k_remove": "Hasai Nebe Hili", "k_remove_old": "Hasai Kernel Tuan Hotu",
        "k_refresh": "Atualiza", "k_loading": "Lee informasaun kernel…",
        "k_none_available": "Kernel seluk la disponivel husi repositoriu sira.",
        "k_meta": "{package} — kernel foun liu husi seri ida-ne'e (rekomenda)",
        "k_confirm_install": "Instala {package}?\n\nHahu fali komputadór depois atu uza kernel foun.",
        "k_confirm_remove": "Hasai kernel sira-ne'e?\n\n{items}\n\nKernel nebe la'o hela la afeta.",
        "k_installed_ok": "Kernel instala ona. Hahu fali komputadór atu uza; kernel agora sei hetan marka kernel tuan.",
        "k_removed_ok": "Kernel nebe hili hasai ona.", "k_no_old": "Kernel tuan la iha atu hasai.",
        "k_select": "Hili kernel ida ne'ebé bele hasai.",
        "kf_title": "Key Fix — Hadi'a Repositoriu no Xave GPG",
        "kf_tab_keys": "Xave GPG", "kf_tab_repos": "Repositoriu duplikadu",
        "kf_col_problem": "Problema", "kf_ok_keys": "Problema xave GPG la iha.",
        "kf_ok_repos": "Repositoriu duplikadu la iha.", "kf_fix_keys": "Hadi'a Xave GPG",
        "kf_fix_dups": "Hadi'a Duplikadu", "kf_rescan": "Verifika Fali", "kf_done": "Hadi'a remata.",
        "ak_title": "Add Key — Instala Xave GPG ka Repositoriu", "ak_name": "Naran",
        "ak_source": "Fonte xave", "ak_file": "Arkivu xave", "ak_browse": "Buka…",
        "ak_add": "Aumenta Xave", "ak_added": "Xave aumenta ona no lista pakote atualiza ona.",
        "st_schedule": "Oráriu verifikasaun", "st_every": "Verifika kada", "st_daily": "Verifika loron-loron oras",
        "st_pause": "Pauza atualizasaun", "st_pause_for": "Pauza durante", "st_days": "loron",
        "st_pause_button": "Pauza", "st_resume_button": "Kontinua Agora",
        "st_not_paused": "Verifikasaun automatiku ativu.", "st_paused_until": "Pauza to'o {date}.",
        "st_week": "Kada semana", "st_general": "Notifikasaun",
    },
}
for _lang, _values in EXTRA_MESSAGES.items():
    MESSAGES[_lang].update(_values)

# 0.15: compact Mint-style interface and System Cleaner (English; other
# languages fall back to these texts where they have no translation).
MESSAGES_015 = {
        "tb_refresh": "Refresh", "tb_menu": "Menu", "install": "Install Updates",
        "mm_select_all": "Select all", "mm_clear": "Clear selection",
        "mm_select_security": "Select security and kernel updates only",
        "mm_cleaner": "System Cleaner…", "mm_kernels": "Kernel Manager…", "mm_upgrade": "Upgrade OS…",
        "mm_sources": "Software sources", "mm_keyfix": "Key Fix…", "mm_addrepo": "Add repository…",
        "mm_addkey": "Add GPG key…", "history": "History", "settings": "Settings", "about": "About",
        "col_type": "Type", "col_update": "Update",
        "type_critical": "Security", "type_kernel": "Kernel", "type_medium": "Important",
        "type_normal": "Regular", "type_flatpak": "Flatpak",
        "tab_description": "Description", "tab_packages": "Packages", "tab_changelog": "Changelog",
        "st_updates": "{count} updates available: {parts}",
        "selected": "{count} selected · {size}",
        "current": "Your system is up to date",
        "empty": "No update information yet. Select Refresh.",
        "choose": "Select an update to see its description.",
        "sb_self_update": "A new version of the Update Manager is available. Install it before the other updates.",
        "sb_install_first": "Install it now",
        "banner_os": "Upgrade OS: {os} can move to Debian {version} \"{codename}\".",
        "banner_repo": "Repository problem: {details}.", "banner_kernel": "{count} old kernel(s) can be removed.",
        "banner_paused": "Automatic checks are paused until {date}.", "resume": "Resume",
        "open_keyfix": "Fix it", "open_kernel": "Review", "open_upgrade": "Upgrade OS",
        "restart_pending": "Restart required to finish installing updates", "restart_now": "Restart now",
        "cm_ignore_version": "Ignore this version ({version})", "cm_ignore_all": "Ignore all future updates",
        "cm_select_type": "Select only {type} updates",
        "cg_loading": "Downloading the changelog…", "cg_none": "No changelog is available for this update.",
        "cg_flatpak": "Flatpak applications do not publish a Debian changelog.",
        "kernel": "Kernel updates",
        "fix_kernel": "Updates the Linux kernel: hardware support, drivers and fixes.",
        "risk_kernel": "The current kernel stays installed and can still be chosen in the boot menu.",
        "recommend_kernel": "Restart after installing; remove old kernels later in Kernel Manager.",
        "fix_critical": "Fixes published security vulnerabilities.",
        "risk_critical": "Delaying leaves the computer exposed to known attacks.",
        "recommend_critical": "Install as soon as possible.",
        "fix_medium": "Updates an important system component.",
        "risk_medium": "Delaying can keep crashes or hardware problems.",
        "recommend_medium": "Install after saving your work.",
        "fix_normal": "Bug fixes and improvements.", "risk_normal": "Low risk if postponed briefly.",
        "recommend_normal": "Install during routine maintenance.",
        "fix_flatpak": "Updates a sandboxed application or runtime.",
        "risk_flatpak": "Close the application before updating.",
        "recommend_flatpak": "Reopen the application afterwards.",
        "cl_title": "System Cleaner",
        "cl_intro": "Frees disk space safely: downloaded package files, packages that are no longer needed, leftover configuration of removed packages, old kernels (never the running one), old logs, crash reports and application caches. EUS also runs the package clean-up automatically after installing updates or removing kernels.",
        "cl_col_item": "Item", "cl_col_detail": "Details", "cl_scan": "Scan again", "cl_clean": "Clean",
        "cl_scanning": "Scanning…", "cl_nothing": "Nothing to clean: the system is already clean.",
        "cl_total": "{count} item(s) selected · {size} will be freed",
        "cl_confirm": "Clean the selected items and free about {size}?",
        "cl_done": "Clean-up finished.", "cl_scope_system": "System (administrator)",
        "cl_scope_user": "Your personal files",
        "st_automation": "Automation", "st_auto_upgrade": "Install updates automatically",
        "st_auto_off": "Never (notify only)", "st_auto_security": "Security updates only",
        "st_auto_all": "All updates",
        "st_auto_note": "Automatic updates run after the scheduled check, only on AC power, and block shutdown while installing.",
        "st_auto_clean": "Clean up after installing updates or removing kernels",
        "st_auto_clean_tip": "Removes packages that are no longer needed, leftover configuration of removed packages and downloaded package files.",
        "st_timeshift": "Create a Timeshift snapshot before installing updates",
        "st_timeshift_missing": "Create a Timeshift snapshot first (Timeshift is not installed)",
        "st_ignored": "Ignored updates", "st_ignored_none": "No update is ignored.", "st_unignore": "Stop ignoring",
}
for _lang in MESSAGES:
    for _key, _value in MESSAGES_015.items():
        if _lang == "en" or _key not in EXTRA_MESSAGES.get(_lang, {}) and _key not in MESSAGES[_lang]:
            MESSAGES[_lang][_key] = _value

CATEGORY_COLORS = {
    "critical": ("#D92D20", "#FFF1F0", "#7A271A"),
    "kernel": ("#7C3AED", "#F5F3FF", "#4C1D95"),
    "medium": ("#B7791F", "#FFF8E1", "#7A4D00"),
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


CATEGORY_ORDER = ("critical", "medium", "normal", "flatpak")
INTERVAL_CHOICES = (1, 3, 6, 12, 24, 48, 168)
NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,62}$")


def translate(lang: str, key: str, **values) -> str:
    text = MESSAGES.get(lang, MESSAGES["en"]).get(key) or MESSAGES["en"].get(key, key)
    return text.format(**values) if values else text


def format_date(epoch: int) -> str:
    try:
        return datetime.fromtimestamp(epoch).strftime("%A, %d %B %Y · %H:%M")
    except (OverflowError, OSError, ValueError):
        return "—"


def paused_until() -> int:
    """Epoch until which automatic checks are paused, or 0 when they are active."""
    try:
        until = int(read_key_values(PAUSE_FILE).get("PAUSED_UNTIL", "0"))
    except ValueError:
        return 0
    return until if until > datetime.now().timestamp() else 0


def read_schedule() -> dict:
    data = read_key_values(SCHEDULE_FILE)
    try:
        hours = int(data.get("INTERVAL_HOURS") or INTERVAL_FILE.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        hours = 6
    if hours not in INTERVAL_CHOICES:
        hours = 6
    daily = data.get("DAILY_TIME", "09:00")
    if not re.fullmatch(r"([01]\d|2[0-3]):[0-5]\d", daily):
        daily = "09:00"
    mode = data.get("SCHEDULE_MODE", "interval")
    return {"mode": mode if mode in {"interval", "daily"} else "interval", "hours": hours, "daily": daily}


def tool_command(*args: str) -> list[str]:
    return [sys.executable or "/usr/bin/python3", "-I", TOOL, *args]


def run_tool_json(*args: str, timeout: int = 20) -> dict | list | None:
    try:
        result = subprocess.run(tool_command(*args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, timeout=timeout, check=False)
        return json.loads(result.stdout) if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


def repo_problem_text(lang: str, scan: dict | None) -> str:
    if not scan:
        return ""
    apt = scan.get("apt", {})
    parts = []
    for key, items in (("repo_unreachable", apt.get("unreachable", [])),
                       ("repo_missing", apt.get("missing_keys", [])),
                       ("repo_expired", apt.get("expired_keys", [])),
                       ("repo_unsigned", apt.get("unsigned", []))):
        if items:
            parts.append(translate(lang, key, count=len(items)))
    duplicates = len(scan.get("duplicates", [])) or len(apt.get("configured_multiple_times", []))
    if duplicates:
        parts.append(translate(lang, "repo_duplicates", count=duplicates))
    if apt.get("signed_by_conflicts"):
        parts.append(translate(lang, "repo_conflict"))
    if apt.get("legacy_warning"):
        parts.append(translate(lang, "repo_legacy"))
    return ", ".join(parts)


def stop_background(process: "QProcess | None") -> None:
    """Silence and stop a helper process whose dialog is going away."""
    if process is None:
        return
    try:
        process.blockSignals(True)
        if process.state() != QProcess.ProcessState.NotRunning:
            process.kill()
            process.waitForFinished(1000)
    except RuntimeError:
        pass


class BackgroundDialog(QDialog):
    """Dialog that stops its helper processes when it closes."""

    background_attributes = ("loader", "scanner", "user_cleaner")

    def done(self, result: int) -> None:
        for name in self.background_attributes:
            stop_background(getattr(self, name, None))
            if hasattr(self, name):
                setattr(self, name, None)
        super().done(result)


def style_button_box(box: QDialogButtonBox) -> None:
    """Give standard dialog buttons the EUS look (primary for accept roles)."""
    for button in box.buttons():
        role = box.buttonRole(button)
        primary = role in {QDialogButtonBox.ButtonRole.AcceptRole, QDialogButtonBox.ButtonRole.YesRole}
        button.setObjectName("primaryButton" if primary else "secondaryButton")


def mono_font() -> QFont:
    font = QFont("monospace")
    font.setStyleHint(QFont.StyleHint.Monospace)
    return font


INSTANCE_NAME = f"eduka-update-system-{os.getuid()}"


def request_existing_window(page: str = "") -> bool:
    socket = QLocalSocket()
    socket.connectToServer(INSTANCE_NAME)
    if not socket.waitForConnected(350):
        return False
    socket.write(f"open:{page}\n".encode() if page else b"show\n")
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


class PrivilegedTask(QWidget):
    """Runs one root-backend action with a progress bar; used by the dialogs."""

    finished = pyqtSignal(bool, str)

    def __init__(self, owner: "UpdateWindow", parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.owner = owner
        self.process: QProcess | None = None
        self.buffer = ""
        self.started_at = 0.0
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(3)
        self.label = QLabel(objectName="taskLabel")
        self.label.setWordWrap(True)
        self.bar = QProgressBar(objectName="taskProgress")
        self.bar.setRange(0, 100)
        self.bar.setTextVisible(True)
        layout.addWidget(self.label)
        layout.addWidget(self.bar)
        self.hide()

    def running(self) -> bool:
        return self.process is not None

    def start(self, action: str, extra: list[str], text: str) -> bool:
        if self.process is not None or self.owner.is_busy():
            QMessageBox.information(self.window(), "EUS", self.owner.t("busy"))
            return False
        program, args = self.owner.privileged_command(action, extra)
        self.process = QProcess(self)
        self.process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        environment = QProcessEnvironment.systemEnvironment()
        environment.insert("LC_ALL", "C.UTF-8")
        environment.insert("LANG", "C.UTF-8")
        self.process.setProcessEnvironment(environment)
        self.process.readyReadStandardOutput.connect(self.read_output)
        self.process.finished.connect(self.process_finished)
        self.process.errorOccurred.connect(self.process_error)
        self.buffer = ""
        self.started_at = datetime.now().timestamp()
        self.bar.setValue(1)
        self.label.setText(text)
        self.show()
        self.owner.external_busy = True
        self.owner.set_busy(True, text)
        self.process.start(program, args)
        return True

    def read_output(self) -> None:
        if self.process is None:
            return
        self.buffer += bytes(self.process.readAllStandardOutput()).decode("utf-8", "replace").replace("\r", "\n")
        while "\n" in self.buffer:
            line, self.buffer = self.buffer.split("\n", 1)
            text = line.strip()
            if text.isdigit():
                self.bar.setValue(max(self.bar.value(), min(100, int(text))))
            elif text.startswith("# "):
                self.label.setText(text[2:])

    def process_error(self, error) -> None:
        if error == QProcess.ProcessError.FailedToStart and self.process is not None:
            QTimer.singleShot(0, lambda: self.process_finished(127, QProcess.ExitStatus.CrashExit))

    def process_finished(self, exit_code: int, _status=None) -> None:
        if self.process is None:
            return
        self.read_output()
        process, self.process = self.process, None
        process.deleteLater()
        self.owner.external_busy = False
        self.owner.set_busy(False)
        if exit_code == 0:
            self.bar.setValue(100)
            self.finished.emit(True, "")
            return
        self.finished.emit(False, self.owner.failure_detail(exit_code, self.started_at))


class KernelDialog(BackgroundDialog):
    """Install a new kernel or safely remove old ones."""

    def __init__(self, owner: "UpdateWindow") -> None:
        super().__init__(owner)
        self.owner = owner
        self.t = owner.t
        self.data: dict = {}
        self.changed = False
        self.loader: QProcess | None = None
        self.setWindowTitle(self.t("kernel_title"))
        self.resize(820, 600)
        layout = QVBoxLayout(self)
        layout.setSpacing(10)

        title = QLabel(self.t("kernel_title"), objectName="dialogTitle")
        intro = QLabel(self.t("kernel_intro"), objectName="muted")
        intro.setWordWrap(True)
        self.running_label = QLabel(objectName="runningKernel")
        layout.addWidget(title)
        layout.addWidget(intro)
        layout.addWidget(self.running_label)

        installed_box = QGroupBox(self.t("k_installed"))
        installed_layout = QVBoxLayout(installed_box)
        self.tree = QTreeWidget(objectName="kernelTree")
        self.tree.setColumnCount(4)
        self.tree.setHeaderLabels([self.t("k_col_release"), self.t("k_col_status"),
                                   self.t("k_col_version"), self.t("k_col_size")])
        self.tree.setRootIsDecorated(False)
        self.tree.setUniformRowHeights(True)
        header = self.tree.header()
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        for column in (1, 2, 3):
            header.setSectionResizeMode(column, QHeaderView.ResizeMode.ResizeToContents)
        self.tree.itemChanged.connect(lambda *_: self.update_buttons())
        installed_layout.addWidget(self.tree)
        remove_row = QHBoxLayout()
        self.refresh_button = QPushButton(self.t("k_refresh"), objectName="secondaryButton")
        self.remove_old_button = QPushButton(self.t("k_remove_old"), objectName="secondaryButton")
        self.remove_button = QPushButton(self.t("k_remove"), objectName="dangerButton")
        self.refresh_button.clicked.connect(self.load)
        self.remove_old_button.clicked.connect(self.remove_old)
        self.remove_button.clicked.connect(self.remove_selected)
        remove_row.addWidget(self.refresh_button)
        remove_row.addStretch(1)
        remove_row.addWidget(self.remove_old_button)
        remove_row.addWidget(self.remove_button)
        installed_layout.addLayout(remove_row)
        layout.addWidget(installed_box, 1)

        install_box = QGroupBox(self.t("k_available"))
        install_layout = QVBoxLayout(install_box)
        self.available = QComboBox()
        self.available.setMinimumWidth(420)
        self.headers = QCheckBox(self.t("k_headers"))
        self.install_button = QPushButton(self.t("k_install"), objectName="primaryButton")
        self.install_button.clicked.connect(self.install_kernel)
        self.available_note = QLabel(objectName="muted")
        self.available_note.setWordWrap(True)
        row = QHBoxLayout()
        row.addWidget(self.available, 1)
        row.addWidget(self.install_button)
        install_layout.addLayout(row)
        install_layout.addWidget(self.headers)
        install_layout.addWidget(self.available_note)
        layout.addWidget(install_box)

        self.task = PrivilegedTask(owner, self)
        self.task.finished.connect(self.task_finished)
        layout.addWidget(self.task)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        buttons.button(QDialogButtonBox.StandardButton.Close).setText(self.t("close"))
        buttons.rejected.connect(self.reject)
        style_button_box(buttons)
        layout.addWidget(buttons)
        self.pending = ""
        self.load()

    def reject(self) -> None:
        if self.task.running():
            return
        super().reject()

    def load(self) -> None:
        fixture = os.environ.get("EUS_KERNEL_FIXTURE")
        if fixture:
            try:
                self.populate(json.loads(Path(fixture).read_text(encoding="utf-8")))
            except (OSError, ValueError):
                self.populate({})
            return
        if self.loader is not None:
            return
        self.running_label.setText(self.t("k_loading"))
        self.tree.clear()
        self.available.clear()
        self.update_buttons()
        self.loader = QProcess(self)
        self.loader.finished.connect(self.loaded)
        self.loader.errorOccurred.connect(lambda _e: self.loaded(1))
        command = tool_command("kernels")
        self.loader.start(command[0], command[1:])

    def loaded(self, exit_code: int, _status=None) -> None:
        if self.loader is None:
            return
        loader, self.loader = self.loader, None
        try:
            data = json.loads(bytes(loader.readAllStandardOutput()).decode("utf-8", "replace")) \
                if exit_code == 0 else {}
        except ValueError:
            data = {}
        loader.deleteLater()
        self.populate(data)

    def populate(self, data: dict) -> None:
        self.data = data
        running = data.get("running") or os.uname().release
        self.running_label.setText("● " + self.t("kernel_running", release=running))
        self.tree.blockSignals(True)
        self.tree.clear()
        styles = {
            "running": ("#0F7B4F", "#E9F7EF"), "old": ("#9A5B00", "#FFF6E0"),
            "newer": ("#1260A8", "#EAF3FD"), "residual": ("#6B7280", "#F3F4F6"),
        }
        for kernel in data.get("installed", []):
            state = kernel.get("state", "")
            item = QTreeWidgetItem([kernel["release"], self.t(f"k_state_{state}"),
                                    kernel.get("version", ""), format_bytes(int(kernel.get("size_kb", 0)) * 1024)])
            item.setData(0, Qt.ItemDataRole.UserRole, kernel)
            color, background = styles.get(state, ("#202020", "#FFFFFF"))
            for column in range(4):
                item.setBackground(column, QBrush(QColor(background)))
            item.setForeground(1, QBrush(QColor(color)))
            bold = item.font(1)
            bold.setBold(True)
            item.setFont(1, bold)
            if state == "running":
                item.setFont(0, bold)
                item.setFlags(Qt.ItemFlag.ItemIsEnabled)
            else:
                item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
                item.setCheckState(0, Qt.CheckState.Checked if state in {"old", "residual"}
                                   else Qt.CheckState.Unchecked)
            self.tree.addTopLevelItem(item)
        self.tree.blockSignals(False)

        self.available.clear()
        for kernel in data.get("available", []):
            if kernel.get("meta"):
                label = self.t("k_meta", package=kernel["package"])
            else:
                label = f"{kernel['package']}   ({kernel.get('version', '')}, {format_bytes(kernel.get('size', 0))})"
            self.available.addItem(label, kernel)
        self.headers.setChecked(bool(data.get("headers_installed")))
        self.available_note.setText("" if self.available.count() else self.t("k_none_available"))
        self.update_buttons()

    def removable_items(self, only_checked: bool) -> list[dict]:
        result = []
        for index in range(self.tree.topLevelItemCount()):
            item = self.tree.topLevelItem(index)
            kernel = item.data(0, Qt.ItemDataRole.UserRole)
            if not isinstance(kernel, dict) or kernel.get("state") == "running":
                continue
            if only_checked and item.checkState(0) != Qt.CheckState.Checked:
                continue
            if not only_checked and kernel.get("state") not in {"old", "residual"}:
                continue
            result.append(kernel)
        return result

    def update_buttons(self) -> None:
        busy = self.task.running() or self.loader is not None
        self.remove_button.setEnabled(not busy and bool(self.removable_items(True)))
        self.remove_old_button.setEnabled(not busy and bool(self.removable_items(False)))
        self.install_button.setEnabled(not busy and self.available.count() > 0)
        self.refresh_button.setEnabled(not busy)

    def confirm_remove(self, kernels: list[dict]) -> None:
        if not kernels:
            QMessageBox.information(self, self.t("kernel_title"), self.t("k_no_old"))
            return
        items = "\n".join(f"• {k['release']} — {self.t('k_state_' + k['state'])}" for k in kernels)
        answer = QMessageBox.question(self, self.t("kernel_title"), self.t("k_confirm_remove", items=items),
                                      QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                      QMessageBox.StandardButton.No)
        if answer != QMessageBox.StandardButton.Yes:
            return
        self.pending = "remove"
        self.pending_kernels = kernels
        if self.task.start("kernel-remove", [k["release"] for k in kernels], self.t("working")):
            self.update_buttons()

    def remove_selected(self) -> None:
        kernels = self.removable_items(True)
        if not kernels:
            QMessageBox.information(self, self.t("kernel_title"), self.t("k_select"))
            return
        self.confirm_remove(kernels)

    def remove_old(self) -> None:
        self.confirm_remove(self.removable_items(False))

    def install_kernel(self) -> None:
        kernel = self.available.currentData()
        if not isinstance(kernel, dict):
            return
        answer = QMessageBox.question(self, self.t("kernel_title"),
                                      self.t("k_confirm_install", package=kernel["package"]),
                                      QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                      QMessageBox.StandardButton.No)
        if answer != QMessageBox.StandardButton.Yes:
            return
        extra = [kernel["package"]] + (["--headers"] if self.headers.isChecked() else [])
        self.pending = "install"
        self.pending_kernels = [kernel]
        if self.task.start("kernel-install", extra, self.t("working")):
            self.update_buttons()

    def task_finished(self, success: bool, detail: str) -> None:
        self.changed = True
        kernels = getattr(self, "pending_kernels", [])
        if self.pending == "install":
            append_update_history([{"source": "kernel", "name": k["package"], "installed": "—",
                                    "candidate": k.get("version", "")} for k in kernels], success)
        else:
            append_update_history([{"source": "kernel", "name": f"linux-image-{k['release']}",
                                    "installed": k.get("version", ""), "candidate": "removed"}
                                   for k in kernels], success)
        if not success:
            QMessageBox.critical(self, self.t("kernel_title"), detail)
        elif self.pending == "install":
            dialog = QMessageBox(self)
            dialog.setIcon(QMessageBox.Icon.Information)
            dialog.setWindowTitle(self.t("kernel_title"))
            dialog.setText(self.t("k_installed_ok"))
            restart = dialog.addButton(self.t("restart_now"), QMessageBox.ButtonRole.AcceptRole)
            dialog.addButton(self.t("restart_later"), QMessageBox.ButtonRole.RejectRole)
            dialog.exec()
            if dialog.clickedButton() is restart:
                self.owner.request_reboot()
        else:
            QMessageBox.information(self, self.t("kernel_title"), self.t("k_removed_ok"))
        self.pending = ""
        self.load()


class KeyFixDialog(BackgroundDialog):
    """Diagnose and repair APT signing keys, keyrings and duplicate repositories."""

    def __init__(self, owner: "UpdateWindow") -> None:
        super().__init__(owner)
        self.owner = owner
        self.t = owner.t
        self.changed = False
        self.scanner: QProcess | None = None
        self.setWindowTitle(self.t("kf_title"))
        self.resize(980, 640)
        layout = QVBoxLayout(self)
        layout.setSpacing(10)
        layout.addWidget(QLabel(self.t("kf_title"), objectName="dialogTitle"))
        intro = QLabel(self.t("kf_intro"), objectName="muted")
        intro.setWordWrap(True)
        layout.addWidget(intro)

        self.tabs = QTabWidget()
        self.overview = QTreeWidget(objectName="keyTree")
        self.overview.setColumnCount(5)
        self.overview.setHeaderLabels([self.t("rp_col_status"), self.t("rp_col_repo"), self.t("rp_col_suite"),
                                       self.t("rp_col_type"), self.t("rp_col_keyring")])
        self.overview.setRootIsDecorated(False)
        self.overview.setTextElideMode(Qt.TextElideMode.ElideMiddle)
        header = self.overview.header()
        for column in (0, 2, 3):
            header.setSectionResizeMode(column, QHeaderView.ResizeMode.ResizeToContents)
        header.setSectionResizeMode(1, QHeaderView.ResizeMode.Interactive)
        header.setStretchLastSection(True)
        self.overview.setColumnWidth(1, 300)
        self.tabs.addTab(self.overview, self.t("kf_tab_overview"))
        keys_page = QWidget()
        keys_layout = QVBoxLayout(keys_page)
        self.keys_tree = self.make_tree()
        self.keys_note = QLabel(objectName="muted")
        self.keys_note.setWordWrap(True)
        keys_buttons = QHBoxLayout()
        self.fix_keys_button = QPushButton(self.t("kf_fix_keys"), objectName="primaryButton")
        self.fix_keys_button.clicked.connect(self.fix_keys)
        keys_buttons.addWidget(self.keys_note, 1)
        keys_buttons.addWidget(self.fix_keys_button)
        keys_layout.addWidget(self.keys_tree, 1)
        keys_layout.addLayout(keys_buttons)
        self.tabs.addTab(keys_page, self.t("kf_tab_keys"))

        repos_page = QWidget()
        repos_layout = QVBoxLayout(repos_page)
        self.repos_tree = self.make_tree()
        self.repos_note = QLabel(objectName="muted")
        self.repos_note.setWordWrap(True)
        repo_buttons = QHBoxLayout()
        self.fix_dups_button = QPushButton(self.t("kf_fix_dups"), objectName="primaryButton")
        self.fix_dups_button.clicked.connect(self.fix_duplicates)
        repo_buttons.addWidget(self.repos_note, 1)
        repo_buttons.addWidget(self.fix_dups_button)
        repos_layout.addWidget(self.repos_tree, 1)
        repos_layout.addLayout(repo_buttons)
        self.repos_page = repos_page
        self.tabs.addTab(repos_page, self.t("kf_tab_repos"))
        layout.addWidget(self.tabs, 1)

        self.task = PrivilegedTask(owner, self)
        self.task.finished.connect(self.task_finished)
        layout.addWidget(self.task)
        bottom = QHBoxLayout()
        self.rescan_button = QPushButton(self.t("kf_rescan"), objectName="secondaryButton")
        self.rescan_button.clicked.connect(self.scan)
        close = QPushButton(self.t("close"), objectName="secondaryButton")
        close.clicked.connect(self.reject)
        bottom.addWidget(self.rescan_button)
        bottom.addStretch(1)
        bottom.addWidget(close)
        layout.addLayout(bottom)
        self.pending = ""
        self.scan()
        # Used when documenting the dialog: EUS_KEYFIX_TAB=1 opens the GPG keys tab.
        self.tabs.setCurrentIndex(int(os.environ.get("EUS_KEYFIX_TAB", "0") or 0))

    def reject(self) -> None:
        if not self.task.running():
            super().reject()

    def make_tree(self) -> QTreeWidget:
        tree = QTreeWidget(objectName="keyTree")
        tree.setColumnCount(2)
        tree.setHeaderLabels([self.t("kf_col_item"), self.t("kf_col_problem")])
        tree.setRootIsDecorated(False)
        tree.setWordWrap(True)
        tree.header().setSectionResizeMode(0, QHeaderView.ResizeMode.Interactive)
        tree.header().setStretchLastSection(True)
        tree.setColumnWidth(0, 380)
        return tree

    @staticmethod
    def add_row(tree: QTreeWidget, item: str, problem: str, severe: bool = True) -> None:
        row = QTreeWidgetItem([item, problem])
        row.setToolTip(0, item)
        row.setToolTip(1, problem)
        row.setForeground(1, QBrush(QColor("#B42318" if severe else "#9A5B00")))
        tree.addTopLevelItem(row)

    @staticmethod
    def add_ok_row(tree: QTreeWidget, text: str) -> None:
        row = QTreeWidgetItem([text])
        row.setForeground(0, QBrush(QColor("#0F7B4F")))
        font = row.font(0)
        font.setBold(True)
        row.setFont(0, font)
        tree.addTopLevelItem(row)
        row.setFirstColumnSpanned(True)

    def scan(self) -> None:
        if self.scanner is not None:
            return
        self.keys_tree.clear()
        self.repos_tree.clear()
        self.keys_note.setText(self.t("kf_scanning"))
        self.repos_note.setText(self.t("kf_scanning"))
        self.set_buttons(False)
        repos = run_tool_json("scan-repos") or {}
        self.populate_repos(repos)
        self.populate_overview()
        self.scanner = QProcess(self)
        self.scanner.finished.connect(self.keys_scanned)
        self.scanner.errorOccurred.connect(lambda _e: self.keys_scanned(1))
        command = tool_command("scan-keys")
        self.scanner.start(command[0], command[1:])

    def set_buttons(self, enabled: bool) -> None:
        for button in (self.fix_keys_button, self.fix_dups_button, self.rescan_button):
            button.setEnabled(enabled)

    def keys_scanned(self, exit_code: int, _status=None) -> None:
        if self.scanner is None:
            return
        scanner, self.scanner = self.scanner, None
        try:
            data = json.loads(bytes(scanner.readAllStandardOutput()).decode("utf-8", "replace")) \
                if exit_code == 0 else {}
        except ValueError:
            data = {}
        scanner.deleteLater()
        self.populate_keys(data)
        self.set_buttons(not self.task.running())

    def populate_overview(self) -> None:
        self.overview.clear()
        if REPOSITORIES_FIXTURE:
            try:
                repositories = json.loads(Path(REPOSITORIES_FIXTURE).read_text(encoding="utf-8"))
            except (OSError, ValueError):
                repositories = []
        else:
            repositories = run_tool_json("repositories", timeout=30) or []
        colors = {"ok": "#0F7B4F", "disabled": "#6B7280", "duplicate": "#9A5B00"}
        for repo in repositories:
            keyring = repo.get("signed_by") or ""
            if keyring == "(embedded key)" or not keyring.startswith("/"):
                keyring_text = self.t("kr_" + repo.get("keyring_role", "none"))
            else:
                keyring_text = f"{keyring}  ({self.t('kr_' + repo.get('keyring_role', 'scoped'))})"
            row = QTreeWidgetItem([
                self.t("rp_status_" + repo.get("status", "ok")),
                f"{repo.get('uri', '')}  {' '.join(repo.get('components', []))}",
                " ".join(repo.get("suites", [])),
                self.t("rp_role_" + repo.get("role", "third-party")),
                keyring_text,
            ])
            tip = f"{repo.get('file', '')}:{repo.get('line', '')}"
            if repo.get("origin"):
                tip += f"\nOrigin: {repo['origin']}  Codename: {repo.get('codename', '')}"
            for column in range(5):
                row.setToolTip(column, tip)
            row.setForeground(0, QBrush(QColor(colors.get(repo.get("status"), "#B42318"))))
            font = row.font(0)
            font.setBold(True)
            row.setFont(0, font)
            self.overview.addTopLevelItem(row)

    def populate_keys(self, data: dict) -> None:
        self.keys_tree.clear()
        apt = data.get("apt", {})
        for item in apt.get("unreachable", []):
            self.add_row(self.keys_tree, item.get("url", ""),
                         f"{self.t('kf_unreachable')}: {item.get('reason', '')}", severe=False)
        for key, items in (("kf_missing", apt.get("missing_keys", [])),
                           ("kf_expired", apt.get("expired_keys", []))):
            for item in items:
                text = self.t(key)
                target = run_tool_json("key-target", item.get("url") or "-", item["keyid"]) or {}
                if target.get("path"):
                    where = self.t("kr_" + target.get("role", "scoped"))
                    text += " — " + self.t("kf_target", path=target["path"], where=where)
                self.add_row(self.keys_tree, f"{item['keyid']}  {item.get('url', '')}", text)
        for url in apt.get("unsigned", []):
            self.add_row(self.keys_tree, url, self.t("kf_unsigned"))
        for source in apt.get("signed_by_conflicts", []):
            self.add_row(self.keys_tree, source, self.t("kf_conflict"))
        if apt.get("legacy_warning"):
            self.add_row(self.keys_tree, "/etc/apt/trusted.gpg", self.t("kf_legacy"), severe=False)
        for path in data.get("missing_signed_by", []):
            self.add_row(self.keys_tree, path, self.t("kf_missing_file"))
        for keyring in data.get("files", []):
            if keyring.get("problems"):
                self.add_row(self.keys_tree, keyring["path"], "; ".join(keyring["problems"]),
                             severe="expired" not in " ".join(keyring["problems"]))
        try:
            when = format_date(int(APT_UPDATE_LOG.stat().st_mtime))
            note = self.t("kf_last_update", time=when)
        except OSError:
            note = self.t("kf_no_refresh")
        if self.keys_tree.topLevelItemCount() == 0:
            self.add_ok_row(self.keys_tree, self.t("kf_ok_keys"))
        # Then every keyring EUS knows about, with its location role.
        for keyring in data.get("files", []):
            if keyring.get("problems"):
                continue
            package = f" ({keyring['package']})" if keyring.get("package") else ""
            role = keyring.get("role", "scoped")
            info = self.t("kf_keyring_global" if role in {"global", "legacy"} else "kf_keyring_info",
                          role=self.t("kr_" + role), package=package, count=len(keyring.get("used_by", [])))
            row = QTreeWidgetItem([keyring["path"], info])
            row.setToolTip(1, keyring.get("role_text", ""))
            row.setForeground(1, QBrush(QColor("#4B5563")))
            self.keys_tree.addTopLevelItem(row)
        self.keys_note.setText(note)

    def populate_repos(self, data: dict) -> None:
        self.repos_tree.clear()
        for duplicate in data.get("duplicates", []):
            first = f"{duplicate['first_file']}:{duplicate['first_line']}"
            text = self.t("kf_dup_complete" if duplicate.get("complete") else "kf_dup_partial", first=first)
            if duplicate.get("signed_by_conflict"):
                text += " · " + self.t("kf_conflict")
            item = f"{duplicate['file']}:{duplicate['line']}  {duplicate.get('uri', '')} {duplicate.get('suite', '')}"
            self.add_row(self.repos_tree, item, text, severe=False)
        for target in data.get("apt", {}).get("configured_multiple_times", []):
            if not data.get("duplicates"):
                self.add_row(self.repos_tree, target, self.t("kf_multiple"), severe=False)
        count = len(data.get("duplicates", []))
        if self.repos_tree.topLevelItemCount() == 0:
            self.add_ok_row(self.repos_tree, self.t("kf_ok_repos"))
        self.repos_note.setText(", ".join(data.get("files", [])))
        self.tabs.setTabText(self.tabs.indexOf(self.repos_page), self.t("kf_tab_repos") + (f" ({count})" if count else ""))

    def fix_keys(self) -> None:
        self.pending = "keys"
        if self.task.start("fix-keys", [], self.t("working")):
            self.set_buttons(False)

    def fix_duplicates(self) -> None:
        self.pending = "duplicates"
        if self.task.start("fix-duplicates", [], self.t("working")):
            self.set_buttons(False)

    def task_finished(self, success: bool, detail: str) -> None:
        self.changed = True
        if not success:
            QMessageBox.critical(self, self.t("kf_title"), detail)
        else:
            lines = [self.t("kf_done")]
            try:
                report = json.loads(REPORT_FILE.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                report = {}
            lines += [f"• {action}" for action in report.get("actions", [])]
            lines += [f"• {fixed['file']}:{fixed['line']}" for fixed in report.get("fixed", [])]
            remaining = repo_problem_text(self.owner.lang, {"apt": report.get("remaining", {})})
            problems = report.get("errors", []) + ([remaining] if remaining else [])
            if problems:
                lines += ["", self.t("kf_remaining")] + [f"• {problem}" for problem in problems]
            if report.get("backup"):
                lines += ["", self.t("kf_backup", path=report["backup"])]
            QMessageBox.information(self, self.t("kf_title"), "\n".join(lines))
        self.pending = ""
        self.set_buttons(True)
        self.scan()


class AddKeyDialog(QDialog):
    """Install a GPG key manually, optionally together with its repository."""

    def __init__(self, owner: "UpdateWindow") -> None:
        super().__init__(owner)
        self.owner = owner
        self.t = owner.t
        self.changed = False
        self.setWindowTitle(self.t("ak_title"))
        self.resize(720, 640)
        layout = QVBoxLayout(self)
        layout.setSpacing(10)
        layout.addWidget(QLabel(self.t("ak_title"), objectName="dialogTitle"))
        intro = QLabel(self.t("ak_intro"), objectName="muted")
        intro.setWordWrap(True)
        layout.addWidget(intro)

        form = QFormLayout()
        self.name = QLineEdit()
        self.name.setPlaceholderText(self.t("ak_name_hint"))
        form.addRow(self.t("ak_name"), self.name)
        layout.addLayout(form)

        source_box = QGroupBox(self.t("ak_source"))
        grid = QGridLayout(source_box)
        self.source_group = QButtonGroup(self)
        self.file_radio = QRadioButton(self.t("ak_file"))
        self.url_radio = QRadioButton(self.t("ak_url"))
        self.keyserver_radio = QRadioButton(self.t("ak_keyserver"))
        self.file_edit = QLineEdit()
        self.file_edit.setPlaceholderText("/home/…/vendor.asc")
        browse = QPushButton(self.t("ak_browse"), objectName="secondaryButton")
        browse.clicked.connect(self.browse)
        self.url_edit = QLineEdit()
        self.url_edit.setPlaceholderText("https://example.org/key.asc")
        self.keyserver_edit = QLineEdit()
        self.keyserver_edit.setPlaceholderText("0x0123456789ABCDEF")
        for row, (radio, edit) in enumerate(((self.file_radio, self.file_edit),
                                             (self.url_radio, self.url_edit),
                                             (self.keyserver_radio, self.keyserver_edit))):
            self.source_group.addButton(radio, row)
            grid.addWidget(radio, row, 0)
            grid.addWidget(edit, row, 1)
            edit.textChanged.connect(lambda _text, r=radio: r.setChecked(True))
        grid.addWidget(browse, 0, 2)
        self.file_radio.setChecked(True)
        self.key_info = QLabel(objectName="muted")
        self.key_info.setWordWrap(True)
        grid.addWidget(self.key_info, 3, 0, 1, 3)
        layout.addWidget(source_box)

        self.repo_box = QGroupBox(self.t("ak_repo"))
        self.repo_box.setCheckable(True)
        self.repo_box.setChecked(False)
        repo_form = QFormLayout(self.repo_box)
        self.repo_uri = QLineEdit()
        self.repo_uri.setPlaceholderText("https://repo.example.org/debian")
        self.suite = QLineEdit()
        self.suite.setPlaceholderText("stable / trixie")
        self.components = QLineEdit("main")
        self.arch = QLineEdit()
        self.arch.setPlaceholderText(f"amd64 ({self.t('ak_optional')})")
        self.deb_src = QCheckBox(self.t("ak_source_pkgs"))
        repo_form.addRow(self.t("ak_repo_uri"), self.repo_uri)
        repo_form.addRow(self.t("ak_suite"), self.suite)
        repo_form.addRow(self.t("ak_components"), self.components)
        repo_form.addRow(self.t("ak_arch"), self.arch)
        repo_form.addRow("", self.deb_src)
        layout.addWidget(self.repo_box)

        layout.addWidget(QLabel(self.t("ak_preview"), objectName="detailsTitle"))
        self.preview = QPlainTextEdit(objectName="preview")
        self.preview.setReadOnly(True)
        self.preview.setFont(mono_font())
        self.preview.setMaximumHeight(120)
        layout.addWidget(self.preview)

        self.task = PrivilegedTask(owner, self)
        self.task.finished.connect(self.task_finished)
        layout.addWidget(self.task)
        buttons = QHBoxLayout()
        self.add_button = QPushButton(self.t("ak_add"), objectName="primaryButton")
        self.add_button.clicked.connect(self.submit)
        close = QPushButton(self.t("close"), objectName="secondaryButton")
        close.clicked.connect(self.reject)
        buttons.addStretch(1)
        buttons.addWidget(close)
        buttons.addWidget(self.add_button)
        layout.addLayout(buttons)

        for widget in (self.name, self.repo_uri, self.suite, self.components, self.arch):
            widget.textChanged.connect(self.update_preview)
        self.repo_box.toggled.connect(self.update_preview)
        self.deb_src.toggled.connect(self.update_preview)
        self.file_edit.editingFinished.connect(self.inspect_file)
        self.update_preview()

    def reject(self) -> None:
        if not self.task.running():
            super().reject()

    def clean_name(self) -> str:
        name = self.name.text().strip().lower()
        return name[:-4] if name.endswith((".gpg", ".asc")) else name

    def browse(self) -> None:
        path, _filter = QFileDialog.getOpenFileName(
            self, self.t("ak_select_file"), str(Path.home()),
            "OpenPGP keys (*.asc *.gpg *.pgp *.key *.pub);;All files (*)")
        if path:
            self.file_edit.setText(path)
            self.file_radio.setChecked(True)
            if not self.name.text().strip():
                guess = re.sub(r"[^a-z0-9._-]+", "-", Path(path).stem.lower()).strip("-.")
                guess = re.sub(r"[-.](archive-)?(keyring|key|pub|public|signing)$", "", guess) or guess
                self.name.setText(guess[:60])
            self.inspect_file()

    def inspect_file(self) -> None:
        path = self.file_edit.text().strip()
        if not path:
            self.key_info.clear()
            return
        keys = run_tool_json("show-key", path)
        if isinstance(keys, list) and keys:
            self.key_info.setText("\n".join(self.t("ak_key_info", uid=k.get("uid") or "?",
                                                   keyid=k.get("keyid", "")) for k in keys))
        else:
            self.key_info.setText("⚠ " + translate("en", "ak_missing_source")
                                  if not Path(path).is_file() else "⚠ OpenPGP?")

    def stanza(self) -> str:
        lines = ["Types: deb" + (" deb-src" if self.deb_src.isChecked() else ""),
                 f"URIs: {self.repo_uri.text().strip()}", f"Suites: {self.suite.text().strip()}"]
        if self.components.text().strip():
            lines.append(f"Components: {' '.join(self.components.text().split())}")
        if self.arch.text().strip():
            lines.append(f"Architectures: {' '.join(self.arch.text().split())}")
        lines.append(f"Signed-By: /etc/apt/keyrings/{self.clean_name() or '<name>'}.gpg")
        return "\n".join(lines)

    def update_preview(self) -> None:
        name = self.clean_name() or "<name>"
        if self.repo_box.isChecked():
            self.preview.setPlainText(self.t("ak_preview_repo", name=name, stanza=self.stanza()))
        else:
            self.preview.setPlainText(self.t("ak_preview_key", name=name))

    def submit(self) -> None:
        name = self.clean_name()
        if not NAME_PATTERN.match(name):
            QMessageBox.warning(self, self.t("ak_title"), self.t("ak_invalid_name"))
            return
        args = ["--name", name]
        if self.file_radio.isChecked() and self.file_edit.text().strip():
            args += ["--file", str(Path(self.file_edit.text().strip()).expanduser().absolute())]
        elif self.url_radio.isChecked() and self.url_edit.text().strip().startswith("https://"):
            args += ["--url", self.url_edit.text().strip()]
        elif self.keyserver_radio.isChecked() and re.fullmatch(
                r"(0x)?([0-9A-Fa-f]{8}|[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})", self.keyserver_edit.text().strip()):
            args += ["--keyserver", self.keyserver_edit.text().strip()]
        else:
            QMessageBox.warning(self, self.t("ak_title"), self.t("ak_missing_source"))
            return
        if self.repo_box.isChecked():
            uri, suite = self.repo_uri.text().strip(), self.suite.text().strip()
            components = " ".join(self.components.text().split())
            if not re.match(r"^(https?|ftp|file)://\S+$", uri) or not suite or \
                    (not components and not suite.endswith("/")):
                QMessageBox.warning(self, self.t("ak_title"), self.t("ak_invalid_repo"))
                return
            args += ["--repo-uri", uri, "--suite", suite]
            if components:
                args += ["--components", components]
            if self.arch.text().strip():
                args += ["--arch", " ".join(self.arch.text().split())]
            if self.deb_src.isChecked():
                args += ["--with-source", "yes"]
        if self.task.start("add-key", args, self.t("working")):
            self.add_button.setEnabled(False)

    def task_finished(self, success: bool, detail: str) -> None:
        self.add_button.setEnabled(True)
        if not success:
            QMessageBox.critical(self, self.t("ak_title"), detail)
            return
        self.changed = True
        try:
            report = json.loads(REPORT_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            report = {}
        lines = [self.t("ak_added"), ""]
        lines += [f"• {k.get('uid', '')} ({k.get('keyid', '')})" for k in report.get("keys", [])]
        lines += [f"• {action}" for action in report.get("actions", [])]
        lines += [f"⚠ {warning}" for warning in report.get("warnings", [])]
        QMessageBox.information(self, self.t("ak_title"), "\n".join(lines))
        self.accept()


class SettingsDialog(QDialog):
    """Schedule, pause and notification settings."""

    def __init__(self, owner: "UpdateWindow") -> None:
        super().__init__(owner)
        self.owner = owner
        self.t = owner.t
        self.changed = False
        self.schedule = read_schedule()
        self.setWindowTitle(self.t("settings_title"))
        self.setMinimumWidth(600)
        layout = QVBoxLayout(self)
        layout.setSpacing(10)
        layout.addWidget(QLabel(self.t("settings_title"), objectName="dialogTitle"))

        schedule_box = QGroupBox(self.t("st_schedule"))
        grid = QGridLayout(schedule_box)
        self.interval_radio = QRadioButton(self.t("st_every"))
        self.daily_radio = QRadioButton(self.t("st_daily"))
        self.interval = QComboBox()
        for hours in INTERVAL_CHOICES:
            self.interval.addItem(self.t("st_week") if hours == 168 else self.t("hours", hours=hours), hours)
        self.interval.setCurrentIndex(max(0, self.interval.findData(self.schedule["hours"])))
        self.daily_time = QTimeEdit()
        self.daily_time.setDisplayFormat("HH:mm")
        self.daily_time.setTime(QTime.fromString(self.schedule["daily"], "HH:mm"))
        grid.addWidget(self.interval_radio, 0, 0)
        grid.addWidget(self.interval, 0, 1)
        grid.addWidget(self.daily_radio, 1, 0)
        grid.addWidget(self.daily_time, 1, 1)
        grid.setColumnStretch(2, 1)
        (self.daily_radio if self.schedule["mode"] == "daily" else self.interval_radio).setChecked(True)
        self.interval.activated.connect(lambda _i: self.interval_radio.setChecked(True))
        self.daily_time.timeChanged.connect(lambda _t: self.daily_radio.setChecked(True))
        self.tabs = QTabWidget()
        schedule_page = QWidget()
        schedule_layout = QVBoxLayout(schedule_page)
        schedule_layout.addWidget(schedule_box)

        pause_box = QGroupBox(self.t("st_pause"))
        pause_layout = QVBoxLayout(pause_box)
        self.pause_status = QLabel(objectName="pauseStatus")
        pause_row = QHBoxLayout()
        self.pause_days = QSpinBox()
        self.pause_days.setRange(1, 365)
        self.pause_days.setValue(7)
        self.pause_days.setSuffix(" " + self.t("st_days"))
        self.pause_button = QPushButton(self.t("st_pause_button"), objectName="secondaryButton")
        self.resume_button = QPushButton(self.t("st_resume_button"), objectName="secondaryButton")
        self.pause_button.clicked.connect(lambda: self.set_pause(self.pause_days.value()))
        self.resume_button.clicked.connect(lambda: self.set_pause(0))
        pause_row.addWidget(QLabel(self.t("st_pause_for")))
        pause_row.addWidget(self.pause_days)
        for days in (1, 3, 7, 14, 30):
            quick = QPushButton(str(days), objectName="chipButton")
            quick.setFixedWidth(38)
            quick.clicked.connect(lambda _c=False, d=days: self.pause_days.setValue(d))
            pause_row.addWidget(quick)
        pause_row.addStretch(1)
        action_row = QHBoxLayout()
        action_row.addStretch(1)
        action_row.addWidget(self.resume_button)
        action_row.addWidget(self.pause_button)
        note = QLabel(self.t("st_pause_note"), objectName="muted")
        note.setWordWrap(True)
        pause_layout.addWidget(self.pause_status)
        pause_layout.addLayout(pause_row)
        pause_layout.addWidget(note)
        pause_layout.addLayout(action_row)
        schedule_layout.addWidget(pause_box)
        schedule_layout.addStretch(1)
        self.tabs.addTab(schedule_page, self.t("st_schedule"))

        notify_box = QGroupBox(self.t("st_general"))
        notify_layout = QVBoxLayout(notify_box)
        self.notify = QCheckBox(self.t("notifications"))
        self.notify.setChecked(owner.notifier_enabled())
        notify_layout.addWidget(self.notify)

        config = read_key_values(CONFIG_FILE)
        self.options = {"AUTO_UPGRADE": config.get("AUTO_UPGRADE", "off"),
                        "AUTO_CLEAN": config.get("AUTO_CLEAN", "1"),
                        "TIMESHIFT_SNAPSHOT": config.get("TIMESHIFT_SNAPSHOT", "0")}
        automation_page = QWidget()
        automation_layout = QVBoxLayout(automation_page)
        automation_box = QGroupBox(self.t("st_automation"))
        auto_layout = QVBoxLayout(automation_box)
        auto_layout.setSpacing(8)
        auto_row = QHBoxLayout()
        auto_row.addWidget(QLabel(self.t("st_auto_upgrade")))
        self.auto_upgrade = QComboBox()
        for value in ("off", "security", "all"):
            self.auto_upgrade.addItem(self.t("st_auto_" + value), value)
        self.auto_upgrade.setCurrentIndex(max(0, self.auto_upgrade.findData(self.options["AUTO_UPGRADE"])))
        auto_row.addWidget(self.auto_upgrade, 1)
        auto_layout.addLayout(auto_row)
        auto_note = QLabel(self.t("st_auto_note"), objectName="muted")
        auto_note.setWordWrap(True)
        auto_note.setMinimumHeight(auto_note.fontMetrics().lineSpacing() * 2 + 4)
        auto_layout.addWidget(auto_note)
        self.auto_clean = QCheckBox(self.t("st_auto_clean"))
        self.auto_clean.setChecked(self.options["AUTO_CLEAN"] == "1")
        self.auto_clean.setToolTip(self.t("st_auto_clean_tip"))
        has_timeshift = bool(shutil.which("timeshift"))
        self.timeshift = QCheckBox(self.t("st_timeshift" if has_timeshift else "st_timeshift_missing"))
        self.timeshift.setChecked(self.options["TIMESHIFT_SNAPSHOT"] == "1")
        self.timeshift.setEnabled(has_timeshift)
        for widget in (self.auto_clean, self.timeshift):
            widget.setStyleSheet("QCheckBox { font-weight: normal; }")
            auto_layout.addWidget(widget)
        automation_layout.addWidget(automation_box)
        automation_layout.addWidget(notify_box)
        automation_layout.addStretch(1)
        self.tabs.addTab(automation_page, self.t("st_automation"))

        ignored_page = QWidget()
        ignored_layout = QVBoxLayout(ignored_page)
        self.ignored = QTreeWidget()
        self.ignored.setHeaderHidden(True)
        self.ignored.setRootIsDecorated(False)
        ignored_layout.addWidget(self.ignored, 1)
        unignore_row = QHBoxLayout()
        unignore_row.addStretch(1)
        self.unignore_button = QPushButton(self.t("st_unignore"), objectName="secondaryButton")
        self.unignore_button.clicked.connect(self.unignore)
        unignore_row.addWidget(self.unignore_button)
        ignored_layout.addLayout(unignore_row)
        self.tabs.addTab(ignored_page, self.t("st_ignored"))
        layout.addWidget(self.tabs, 1)
        self.load_ignored()
        # Used when documenting the dialog (EUS_SETTINGS_TAB=1 opens Automation).
        self.tabs.setCurrentIndex(int(os.environ.get("EUS_SETTINGS_TAB", "0") or 0))

        self.task = PrivilegedTask(owner, self)
        self.task.finished.connect(self.task_finished)
        layout.addWidget(self.task)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        buttons.button(QDialogButtonBox.StandardButton.Save).setText(self.t("save"))
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText(self.t("cancel"))
        buttons.accepted.connect(self.save)
        buttons.rejected.connect(self.reject)
        self.buttons = buttons
        style_button_box(buttons)
        layout.addWidget(buttons)
        self.after_task = ""
        self.queue: list[tuple[str, list[str]]] = []
        self.update_pause_status()

    def reject(self) -> None:
        if not self.task.running():
            super().reject()

    def update_pause_status(self) -> None:
        until = paused_until()
        if until:
            self.pause_status.setText(self.t("st_paused_until", date=format_date(until)))
            self.pause_status.setProperty("paused", True)
        else:
            self.pause_status.setText(self.t("st_not_paused"))
            self.pause_status.setProperty("paused", False)
        self.pause_status.style().unpolish(self.pause_status)
        self.pause_status.style().polish(self.pause_status)
        self.resume_button.setEnabled(bool(until) and not self.task.running())
        self.pause_button.setEnabled(not self.task.running())

    def set_pause(self, days: int) -> None:
        self.after_task = "pause"
        if self.task.start("pause", [str(days)], self.t("working")):
            self.update_pause_status()

    def load_ignored(self) -> None:
        self.ignored.clear()
        try:
            patterns = [line.split("#", 1)[0].strip()
                        for line in IGNORE_FILE.read_text(encoding="utf-8").splitlines()]
        except OSError:
            patterns = []
        for pattern in filter(None, patterns):
            self.ignored.addTopLevelItem(QTreeWidgetItem([pattern]))
        if not self.ignored.topLevelItemCount():
            empty = QTreeWidgetItem([self.t("st_ignored_none")])
            empty.setFlags(Qt.ItemFlag.NoItemFlags)
            self.ignored.addTopLevelItem(empty)
        self.unignore_button.setEnabled(bool(patterns))

    def unignore(self) -> None:
        item = self.ignored.currentItem()
        if item is None or not item.flags() & Qt.ItemFlag.ItemIsEnabled:
            return
        self.after_task = "ignore"
        self.task.start("ignore", ["remove", item.text(0)], self.t("working"))

    def save(self) -> None:
        self.owner.set_notifier_enabled(self.notify.isChecked())
        self.queue = []
        if self.daily_radio.isChecked():
            new = ("daily", self.daily_time.time().toString("HH:mm"))
            old = ("daily", self.schedule["daily"]) if self.schedule["mode"] == "daily" else None
        else:
            new = ("interval", str(self.interval.currentData()))
            old = ("interval", str(self.schedule["hours"])) if self.schedule["mode"] == "interval" else None
        if new != old:
            self.queue.append(("set-schedule", list(new)))
        wanted = {"AUTO_UPGRADE": str(self.auto_upgrade.currentData()),
                  "AUTO_CLEAN": "1" if self.auto_clean.isChecked() else "0",
                  "TIMESHIFT_SNAPSHOT": "1" if self.timeshift.isChecked() else "0"}
        for key, value in wanted.items():
            if value != self.options[key]:
                self.queue.append(("set-option", [key, value]))
        self.run_queue()

    def run_queue(self) -> None:
        if not self.queue:
            self.accept()
            return
        action, args = self.queue.pop(0)
        self.after_task = "save"
        if self.task.start(action, args, self.owner.t("saving")):
            self.buttons.setEnabled(False)

    def task_finished(self, success: bool, detail: str) -> None:
        self.changed = True
        self.buttons.setEnabled(True)
        self.update_pause_status()
        if not success:
            QMessageBox.critical(self, self.t("settings_title"), detail)
            return
        if self.after_task == "ignore":
            self.load_ignored()
        elif self.after_task == "save":
            self.run_queue()


def read_os_upgrade() -> dict[str, str]:
    data = read_key_values(OS_UPGRADE_FILE)
    return data if data.get("available") == "1" and data.get("target_codename") else {}


class AddRepoDialog(QDialog):
    """Add a repository; its signing key is found and installed automatically."""

    def __init__(self, owner: "UpdateWindow") -> None:
        super().__init__(owner)
        self.owner = owner
        self.t = owner.t
        self.changed = False
        self.setWindowTitle(self.t("ar_title"))
        self.resize(760, 600)
        layout = QVBoxLayout(self)
        layout.setSpacing(10)
        layout.addWidget(QLabel(self.t("ar_title"), objectName="dialogTitle"))
        intro = QLabel(self.t("ar_intro"), objectName="muted")
        intro.setWordWrap(True)
        layout.addWidget(intro)

        form = QFormLayout()
        self.name = QLineEdit()
        self.name.setPlaceholderText(self.t("ak_name_hint"))
        form.addRow(self.t("ak_name"), self.name)
        layout.addLayout(form)

        mode_box = QGroupBox(self.t("ar_mode"))
        grid = QGridLayout(mode_box)
        self.line_radio = QRadioButton(self.t("ar_line"))
        self.fields_radio = QRadioButton(self.t("ar_fields"))
        self.line = QLineEdit()
        self.line.setFont(mono_font())
        self.line.setPlaceholderText("deb [arch=amd64] https://repo.example.org/debian stable main")
        grid.addWidget(self.line_radio, 0, 0)
        grid.addWidget(self.line, 0, 1)
        grid.addWidget(self.fields_radio, 1, 0, Qt.AlignmentFlag.AlignTop)
        fields = QWidget()
        fields_form = QFormLayout(fields)
        fields_form.setContentsMargins(0, 0, 0, 0)
        self.repo_uri = QLineEdit()
        self.repo_uri.setPlaceholderText("https://repo.example.org/debian")
        self.suite = QLineEdit()
        self.suite.setPlaceholderText("stable / trixie")
        self.components = QLineEdit("main")
        self.arch = QLineEdit()
        self.arch.setPlaceholderText(f"amd64 ({self.t('ak_optional')})")
        fields_form.addRow(self.t("ak_repo_uri"), self.repo_uri)
        fields_form.addRow(self.t("ak_suite"), self.suite)
        fields_form.addRow(self.t("ak_components"), self.components)
        fields_form.addRow(self.t("ak_arch"), self.arch)
        grid.addWidget(fields, 1, 1)
        self.line_radio.setChecked(True)
        self.line.textChanged.connect(lambda _t: self.line_radio.setChecked(True))
        for widget in (self.repo_uri, self.suite, self.arch):
            widget.textEdited.connect(lambda _t: self.fields_radio.setChecked(True))
        layout.addWidget(mode_box)

        self.deb_src = QCheckBox(self.t("ak_source_pkgs"))
        self.auto_key = QCheckBox(self.t("ar_auto_key"))
        self.auto_key.setChecked(True)
        layout.addWidget(self.deb_src)
        layout.addWidget(self.auto_key)
        layout.addStretch(1)

        self.task = PrivilegedTask(owner, self)
        self.task.finished.connect(self.task_finished)
        layout.addWidget(self.task)
        buttons = QHBoxLayout()
        self.add_button = QPushButton(self.t("ar_add"), objectName="primaryButton")
        self.add_button.clicked.connect(self.submit)
        close = QPushButton(self.t("close"), objectName="secondaryButton")
        close.clicked.connect(self.reject)
        buttons.addStretch(1)
        buttons.addWidget(close)
        buttons.addWidget(self.add_button)
        layout.addLayout(buttons)
        self.line.textChanged.connect(self.guess_name)

    def reject(self) -> None:
        if not self.task.running():
            super().reject()

    def guess_name(self) -> None:
        if self.name.isModified() and self.name.text():
            return
        match = re.search(r"(?:https?|ftp)://([^/\s]+)(/\S*)?", self.line.text())
        if match:
            host = match.group(1).lower()
            host = re.sub(r"^(www|deb|apt|repo|download|packages|ppa)\.", "", host)
            self.name.setText(re.sub(r"[^a-z0-9]+", "-", host.rsplit(".", 1)[0]).strip("-")[:40])

    def submit(self) -> None:
        name = self.name.text().strip().lower()
        if not NAME_PATTERN.match(name):
            QMessageBox.warning(self, self.t("ar_title"), self.t("ak_invalid_name"))
            return
        args = ["--name", name]
        if self.line_radio.isChecked():
            line = " ".join(self.line.text().split())
            if not re.match(r"^(deb|deb-src)\s+(\[[^\]]*\]\s+)?(https?|ftp|file)://\S+\s+\S+", line):
                QMessageBox.warning(self, self.t("ar_title"), self.t("ar_invalid_line"))
                return
            args += ["--line", line]
        else:
            uri, suite = self.repo_uri.text().strip(), self.suite.text().strip()
            components = " ".join(self.components.text().split())
            if not re.match(r"^(https?|ftp|file)://\S+$", uri) or not suite or \
                    (not components and not suite.endswith("/")):
                QMessageBox.warning(self, self.t("ar_title"), self.t("ak_invalid_repo"))
                return
            args += ["--repo-uri", uri, "--suite", suite]
            if components:
                args += ["--components", components]
            if self.arch.text().strip():
                args += ["--arch", " ".join(self.arch.text().split())]
        if self.deb_src.isChecked():
            args.append("--with-source")
        if self.auto_key.isChecked():
            args.append("--auto-key")
        if self.task.start("add-repo", args, self.t("working")):
            self.add_button.setEnabled(False)

    def task_finished(self, success: bool, detail: str) -> None:
        self.add_button.setEnabled(True)
        if not success:
            QMessageBox.critical(self, self.t("ar_title"), detail)
            return
        self.changed = True
        try:
            report = json.loads(REPORT_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            report = {}
        lines = [self.t("ar_added"), ""]
        if report.get("keys"):
            lines.append(self.t("ar_key_found", source=report.get("key_source", "")))
            lines += [f"  {k.get('uid', '')}\n  {k.get('fingerprint', '')}" for k in report["keys"]]
            lines.append("")
        lines += [f"• {action}" for action in report.get("actions", [])]
        QMessageBox.information(self, self.t("ar_title"), "\n".join(lines))
        self.accept()


class UpgradeOSDialog(BackgroundDialog):
    """Move Edukasaun OS to a new Debian stable base release."""

    def __init__(self, owner: "UpdateWindow") -> None:
        super().__init__(owner)
        self.owner = owner
        self.t = owner.t
        self.changed = False
        self.state = read_os_upgrade()
        self.plan: dict = {}
        self.loader: QProcess | None = None
        self.setWindowTitle(self.t("os_title"))
        self.resize(900, 620)
        layout = QVBoxLayout(self)
        layout.setSpacing(10)
        layout.addWidget(QLabel(self.t("os_title"), objectName="dialogTitle"))
        self.headline = QLabel(objectName="runningKernel")
        layout.addWidget(self.headline)
        intro = QLabel(self.t("os_intro"), objectName="muted")
        intro.setWordWrap(True)
        layout.addWidget(intro)

        self.tree = QTreeWidget(objectName="kernelTree")
        self.tree.setColumnCount(4)
        self.tree.setHeaderLabels([self.t("os_col_repo"), self.t("os_col_current"), self.t("os_col_new"),
                                   self.t("os_col_action")])
        self.tree.setRootIsDecorated(False)
        self.tree.header().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        for column in (1, 2, 3):
            self.tree.header().setSectionResizeMode(column, QHeaderView.ResizeMode.ResizeToContents)
        layout.addWidget(self.tree, 1)
        self.note = QLabel(objectName="bannerText")
        self.note.setWordWrap(True)
        layout.addWidget(self.note)
        warning = QLabel(self.t("os_warning"), objectName="muted")
        warning.setWordWrap(True)
        layout.addWidget(warning)

        self.task = PrivilegedTask(owner, self)
        self.task.finished.connect(self.task_finished)
        layout.addWidget(self.task)
        buttons = QHBoxLayout()
        self.start_button = QPushButton(self.t("os_start"), objectName="primaryButton")
        self.start_button.setEnabled(False)
        self.start_button.clicked.connect(self.start_upgrade)
        close = QPushButton(self.t("close"), objectName="secondaryButton")
        close.clicked.connect(self.reject)
        buttons.addStretch(1)
        buttons.addWidget(close)
        buttons.addWidget(self.start_button)
        layout.addLayout(buttons)
        self.load()

    def reject(self) -> None:
        if not self.task.running():
            super().reject()

    def load(self) -> None:
        if not self.state:
            self.headline.setText(self.t("os_none"))
            return
        self.headline.setText(self.t(
            "os_from_to", os=self.state.get("os_name", "Edukasaun OS"),
            current=f"{self.state.get('current_version', '').split('.')[0]} \"{self.state.get('current_codename', '')}\"",
            target=f"{self.state.get('target_version', '').split('.')[0]} \"{self.state['target_codename']}\""))
        self.note.setText(self.t("os_checking"))
        if OS_PLAN_FIXTURE:
            try:
                self.populate(json.loads(Path(OS_PLAN_FIXTURE).read_text(encoding="utf-8")))
            except (OSError, ValueError):
                self.populate({})
            return
        self.loader = QProcess(self)
        self.loader.finished.connect(self.loaded)
        self.loader.errorOccurred.connect(lambda _e: self.loaded(1))
        command = tool_command("os-plan", "--target", self.state["target_codename"])
        self.loader.start(command[0], command[1:])

    def loaded(self, exit_code: int, _status=None) -> None:
        if self.loader is None:
            return
        loader, self.loader = self.loader, None
        try:
            data = json.loads(bytes(loader.readAllStandardOutput()).decode("utf-8", "replace")) \
                if exit_code == 0 else {}
        except ValueError:
            data = {}
        loader.deleteLater()
        self.populate(data)

    def populate(self, plan: dict) -> None:
        self.plan = plan
        self.tree.clear()
        colors = {"switch": "#0F7B4F", "keep": "#9A5B00", "unchanged": "#6B7280", "missing": "#B42318"}
        for row in plan.get("entries", []):
            item = QTreeWidgetItem([row["uri"], row["suite"], row.get("new_suite") or row["suite"],
                                    self.t("os_action_" + row["action"])])
            tip = f"{row['file']}:{row['line']}" + (f"\n{row['note']}" if row.get("note") else "")
            for column in range(4):
                item.setToolTip(column, tip)
            item.setForeground(3, QBrush(QColor(colors.get(row["action"], "#202020"))))
            font = item.font(3)
            font.setBold(True)
            item.setFont(3, font)
            self.tree.addTopLevelItem(item)
        if not plan:
            self.note.setText(self.t("failed"))
        elif plan.get("blocking"):
            self.note.setText(self.t("os_blocked"))
        else:
            self.note.setText("")
        self.start_button.setEnabled(bool(plan.get("entries")) and not plan.get("blocking"))

    def start_upgrade(self) -> None:
        target = self.state.get("target_codename", "")
        answer = QMessageBox.question(self, self.t("os_title"),
                                      self.t("os_confirm", target=f"{self.state.get('target_version', '').split('.')[0]} \"{target}\""),
                                      QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                      QMessageBox.StandardButton.No)
        if answer == QMessageBox.StandardButton.Yes and self.task.start("os-upgrade", [target], self.t("working")):
            self.start_button.setEnabled(False)

    def task_finished(self, success: bool, detail: str) -> None:
        self.changed = True
        if not success:
            QMessageBox.critical(self, self.t("os_title"), detail)
            self.start_button.setEnabled(True)
            return
        dialog = QMessageBox(self)
        dialog.setIcon(QMessageBox.Icon.Information)
        dialog.setWindowTitle(self.t("os_title"))
        dialog.setText(self.t("os_done"))
        restart = dialog.addButton(self.t("restart_now"), QMessageBox.ButtonRole.AcceptRole)
        dialog.addButton(self.t("restart_later"), QMessageBox.ButtonRole.RejectRole)
        dialog.exec()
        if dialog.clickedButton() is restart:
            self.owner.request_reboot()
        self.accept()


CATEGORY_LABELS = {"critical": "Security", "kernel": "Kernel", "medium": "Important",
                   "normal": "Regular", "flatpak": "Flatpak"}
CATEGORY_RANK = {"critical": 0, "kernel": 1, "medium": 2, "normal": 3, "flatpak": 4}
SELF_PACKAGE = "eduka-update-system"


def group_updates(records: list[dict]) -> list[dict]:
    """Group binary packages by source package, like mintupdate does: one row
    for e.g. all WebKitGTK libraries built from webkit2gtk."""
    groups: dict[tuple[str, str], dict] = {}
    for record in records:
        if record["source"] == "apt":
            key = ("apt", record.get("srcpkg") or record["name"])
        else:
            key = (record["source"], record["name"])
        group = groups.get(key)
        if group is None:
            group = {"key": key, "name": key[1], "source": record["source"], "packages": [],
                     "category": record["category"], "size": 0, "main": record}
            groups[key] = group
        group["packages"].append(record)
        group["size"] += record["size"]
        if CATEGORY_RANK.get(record["category"], 9) < CATEGORY_RANK.get(group["category"], 9):
            group["category"] = record["category"]
        if record["name"] == key[1]:
            group["main"] = record
    for group in groups.values():
        main = group["main"]
        if len(group["packages"]) == 1:
            group["name"] = main["name"]
        group["installed"] = main["installed"]
        group["candidate"] = main["candidate"]
        group["description"] = main["description"]
        group["self_update"] = any(p["name"] == SELF_PACKAGE for p in group["packages"])
        if group["category"] == "kernel" and len(group["packages"]) > 1:
            group["name"] = f"Linux kernel {group['candidate']}"
    return sorted(groups.values(), key=lambda g: (not g["self_update"], CATEGORY_RANK.get(g["category"], 9),
                                                   g["name"]))


class CleanerDialog(BackgroundDialog):
    """System Cleaner: APT cache, unneeded packages, leftover configuration,
    old kernels, logs, crash reports and per-user caches."""

    def __init__(self, owner: "UpdateWindow") -> None:
        super().__init__(owner)
        self.owner = owner
        self.t = owner.t
        self.changed = False
        self.items: list[dict] = []
        self.scanner: QProcess | None = None
        self.user_cleaner: QProcess | None = None
        self.setWindowTitle(self.t("cl_title"))
        self.resize(720, 520)
        layout = QVBoxLayout(self)
        layout.setSpacing(8)
        layout.addWidget(QLabel(self.t("cl_title"), objectName="dialogTitle"))
        intro = QLabel(self.t("cl_intro"), objectName="muted")
        intro.setWordWrap(True)
        layout.addWidget(intro)
        self.tree = QTreeWidget(objectName="kernelTree")
        self.tree.setColumnCount(3)
        self.tree.setHeaderLabels([self.t("cl_col_item"), self.t("size"), self.t("cl_col_detail")])
        self.tree.setRootIsDecorated(True)
        self.tree.header().setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        self.tree.header().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.tree.header().setStretchLastSection(True)
        self.tree.setTextElideMode(Qt.TextElideMode.ElideRight)
        self.tree.itemChanged.connect(lambda *_: self.update_total())
        layout.addWidget(self.tree, 1)
        self.total = QLabel(objectName="bannerText")
        layout.addWidget(self.total)
        self.task = PrivilegedTask(owner, self)
        self.task.finished.connect(self.system_cleaned)
        layout.addWidget(self.task)
        buttons = QHBoxLayout()
        self.scan_button = QPushButton(self.t("cl_scan"), objectName="secondaryButton")
        self.scan_button.clicked.connect(self.scan)
        self.clean_button = QPushButton(self.t("cl_clean"), objectName="primaryButton")
        self.clean_button.clicked.connect(self.clean)
        close = QPushButton(self.t("close"), objectName="secondaryButton")
        close.clicked.connect(self.reject)
        buttons.addWidget(self.scan_button)
        buttons.addStretch(1)
        buttons.addWidget(close)
        buttons.addWidget(self.clean_button)
        layout.addLayout(buttons)
        self.scan()

    def reject(self) -> None:
        if not self.task.running() and self.user_cleaner is None:
            super().reject()

    def scan(self) -> None:
        if self.scanner is not None:
            return
        self.tree.clear()
        self.total.setText(self.t("cl_scanning"))
        self.clean_button.setEnabled(False)
        fixture = os.environ.get("EUS_CLEAN_FIXTURE")
        if fixture:
            try:
                self.populate(json.loads(Path(fixture).read_text(encoding="utf-8")))
            except (OSError, ValueError):
                self.populate([])
            return
        self.scanner = QProcess(self)
        self.scanner.finished.connect(self.scanned)
        self.scanner.errorOccurred.connect(lambda _e: self.scanned(1))
        command = tool_command("scan-clean")
        self.scanner.start(command[0], command[1:])

    def scanned(self, exit_code: int, _status=None) -> None:
        if self.scanner is None:
            return
        scanner, self.scanner = self.scanner, None
        try:
            data = json.loads(bytes(scanner.readAllStandardOutput()).decode("utf-8", "replace")) \
                if exit_code == 0 else []
        except ValueError:
            data = []
        scanner.deleteLater()
        self.populate(data)

    def populate(self, items: list[dict]) -> None:
        self.items = items
        self.tree.blockSignals(True)
        self.tree.clear()
        for scope in ("system", "user"):
            scoped = [i for i in items if i.get("scope") == scope]
            if not scoped:
                continue
            group = QTreeWidgetItem([self.t("cl_scope_" + scope)])
            group.setFlags(Qt.ItemFlag.ItemIsEnabled)
            font = group.font(0)
            font.setBold(True)
            group.setFont(0, font)
            self.tree.addTopLevelItem(group)
            group.setFirstColumnSpanned(True)
            for item in scoped:
                row = QTreeWidgetItem(group, [item["title"], format_bytes(item["size"]) if item["size"] else "—",
                                              item.get("detail", "")])
                row.setFlags(row.flags() | Qt.ItemFlag.ItemIsUserCheckable)
                row.setCheckState(0, Qt.CheckState.Checked if item.get("default") else Qt.CheckState.Unchecked)
                row.setData(0, Qt.ItemDataRole.UserRole, item)
                row.setToolTip(2, item.get("detail", ""))
            group.setExpanded(True)
        self.tree.blockSignals(False)
        if not items:
            self.total.setText(self.t("cl_nothing"))
        self.update_total()

    def checked(self) -> list[dict]:
        result = []
        for index in range(self.tree.topLevelItemCount()):
            group = self.tree.topLevelItem(index)
            for child in range(group.childCount()):
                row = group.child(child)
                if row.checkState(0) == Qt.CheckState.Checked:
                    result.append(row.data(0, Qt.ItemDataRole.UserRole))
        return result

    def update_total(self) -> None:
        selected = self.checked()
        if self.items:
            self.total.setText(self.t("cl_total", count=len(selected),
                                      size=format_bytes(sum(i["size"] for i in selected))))
        self.clean_button.setEnabled(bool(selected) and not self.task.running())

    def clean(self) -> None:
        selected = self.checked()
        if not selected:
            return
        answer = QMessageBox.question(self, self.t("cl_title"),
                                      self.t("cl_confirm", size=format_bytes(sum(i["size"] for i in selected))),
                                      QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                      QMessageBox.StandardButton.No)
        if answer != QMessageBox.StandardButton.Yes:
            return
        self.clean_button.setEnabled(False)
        self.pending_system = [i["id"] for i in selected if i["scope"] == "system"]
        user_items = [i["id"] for i in selected if i["scope"] == "user"]
        if user_items:
            # Personal caches belong to the user: no administrator rights needed.
            self.user_cleaner = QProcess(self)
            self.user_cleaner.finished.connect(self.user_cleaned)
            self.user_cleaner.errorOccurred.connect(lambda _e: self.user_cleaned(1))
            command = tool_command("clean-user", *user_items)
            self.user_cleaner.start(command[0], command[1:])
        else:
            self.start_system_clean()

    def user_cleaned(self, _exit_code: int, _status=None) -> None:
        if self.user_cleaner is not None:
            self.user_cleaner.deleteLater()
            self.user_cleaner = None
        self.start_system_clean()

    def start_system_clean(self) -> None:
        if self.pending_system:
            if not self.task.start("clean", self.pending_system, self.t("working")):
                self.scan()
        else:
            self.system_cleaned(True, "")

    def system_cleaned(self, success: bool, detail: str) -> None:
        self.changed = True
        if not success:
            QMessageBox.critical(self, self.t("cl_title"), detail)
        else:
            QMessageBox.information(self, self.t("cl_title"), self.t("cl_done"))
        self.scan()


class UpdateWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.lang = language_code()
        self.msg = MESSAGES[self.lang]
        version_data = read_key_values(VERSION_FILE)
        self.version = version_data.get("VERSION", EUS_VERSION)
        self.records: list[dict] = []
        self.groups: list[dict] = []
        self.package_items: list[QTreeWidgetItem] = []
        self.progress_widgets: dict[tuple[str, str], QProgressBar] = {}
        self.active_progress_keys: list[tuple[str, str]] = []
        self.process: QProcess | None = None
        self.current_command: dict | None = None
        self.pending_commands: list[dict] = []
        self.process_buffer = ""
        self.operation_kind = ""
        self.operation_started = 0.0
        self.install_had_kernel = False
        self.process_was_timed_out = False
        self.external_busy = False
        self.kernel_probe: QProcess | None = None
        self.changelog_process: QProcess | None = None
        self.changelog_cache: dict[str, str] = {}
        self.process_timeout = QTimer(self)
        self.process_timeout.setSingleShot(True)
        self.process_timeout.timeout.connect(self.stop_stalled_process)
        self.progress_animation = QTimer(self)
        self.progress_animation.setInterval(650)
        self.progress_animation.timeout.connect(self.advance_row_progress)
        self.reload_timer = QTimer(self)
        self.reload_timer.setSingleShot(True)
        self.reload_timer.setInterval(1500)
        self.reload_timer.timeout.connect(self.reload_from_disk)
        self.setWindowTitle("Update Manager — Eduka-Update-System")
        self.setWindowIcon(QIcon(EUS_APP_ICON))
        self.resize(760, 540)
        self.setMinimumSize(560, 400)
        self.build_ui()
        self.apply_style()
        self.setup_window_shortcuts()
        self.setup_watcher()
        self.load_updates()
        self.refresh_banners()

    def t(self, key: str, **values) -> str:
        return translate(self.lang, key, **values)

    # ------------------------------------------------------------------ UI
    def setup_window_shortcuts(self) -> None:
        for sequence, handler in (("F11", self.toggle_fullscreen), ("Ctrl+M", self.showMinimized),
                                  ("Escape", self.leave_fullscreen), ("Ctrl+R", self.check_updates),
                                  ("F5", self.check_updates), ("Ctrl+I", self.install_updates),
                                  ("Ctrl+Q", self.close), ("Ctrl+H", self.show_history)):
            shortcut = QShortcut(QKeySequence(sequence), self)
            shortcut.activated.connect(handler)

    def toggle_fullscreen(self) -> None:
        self.showNormal() if self.isFullScreen() else self.showFullScreen()

    def leave_fullscreen(self) -> None:
        if self.isFullScreen():
            self.showNormal()

    def build_main_menu(self) -> QMenu:
        """Every secondary feature lives in this single menu."""
        menu = QMenu(self)

        def add(text: str, handler, shortcut: str = "") -> QAction:
            action = menu.addAction(text)
            action.triggered.connect(handler)
            if shortcut:
                action.setShortcut(QKeySequence(shortcut))
            return action

        self.select_all_action = add(self.t("mm_select_all"), lambda: self.set_all_checked(True))
        self.clear_action = add(self.t("mm_clear"), lambda: self.set_all_checked(False))
        self.select_security_action = add(self.t("mm_select_security"), self.select_security_only)
        menu.addSeparator()
        self.cleaner_action = add(self.t("mm_cleaner"), self.show_cleaner)
        self.kernel_action = add(self.t("mm_kernels"), self.show_kernels)
        self.upgrade_action = add(self.t("mm_upgrade"), self.show_upgrade_os)
        menu.addSeparator()
        sources = menu.addMenu(self.t("mm_sources"))
        for text, handler in ((self.t("mm_keyfix"), self.show_key_fix),
                              (self.t("mm_addrepo"), self.show_add_repo),
                              (self.t("mm_addkey"), self.show_add_key)):
            action = sources.addAction(text)
            action.triggered.connect(handler)
        self.sources_menu = sources
        menu.addSeparator()
        self.history_action = add(self.t("history"), self.show_history, "Ctrl+H")
        self.settings_action = add(self.t("settings"), self.show_settings)
        add(self.t("action_log"), self.show_log)
        add(self.t("about"), self.show_about)
        menu.addSeparator()
        add(self.t("action_quit"), self.close, "Ctrl+Q")
        self.busy_actions = [self.select_all_action, self.clear_action, self.select_security_action,
                             self.cleaner_action, self.kernel_action, self.upgrade_action,
                             self.history_action, self.settings_action, sources.menuAction()]
        return menu

    def make_banner(self, kind: str, button_text: str, handler) -> tuple[QFrame, QLabel, QPushButton]:
        frame = QFrame(objectName=f"banner_{kind}")
        row = QHBoxLayout(frame)
        row.setContentsMargins(10, 3, 4, 3)
        row.setSpacing(6)
        label = QLabel(objectName="bannerText")
        label.setWordWrap(False)
        label.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        button = QPushButton(button_text, objectName="linkButton")
        button.setCursor(Qt.CursorShape.PointingHandCursor)
        button.clicked.connect(handler)
        row.addWidget(label, 1)
        row.addWidget(button)
        frame.hide()
        return frame, label, button

    def build_ui(self) -> None:
        central = QWidget(objectName="body")
        self.setCentralWidget(central)
        outer = QVBoxLayout(central)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        toolbar = QFrame(objectName="toolbar")
        bar = QHBoxLayout(toolbar)
        bar.setContentsMargins(10, 6, 8, 6)
        bar.setSpacing(6)
        icon = QLabel()
        icon.setPixmap(QIcon(EUS_APP_ICON).pixmap(QSize(22, 22)))
        bar.addWidget(icon)
        self.status_title = QLabel(objectName="statusTitle")
        self.status_title.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        bar.addWidget(self.status_title, 1)
        self.check_button = QPushButton(self.t("tb_refresh"), objectName="secondaryButton")
        self.check_button.setToolTip(self.t("check_updates") + " (Ctrl+R)")
        self.check_button.clicked.connect(self.check_updates)
        self.install_button = QPushButton(self.t("install"), objectName="primaryButton")
        self.install_button.clicked.connect(self.install_updates)
        self.menu_button = QToolButton(objectName="menuButton")
        self.menu_button.setText("☰")
        self.menu_button.setToolTip(self.t("tb_menu"))
        self.menu_button.setPopupMode(QToolButton.ToolButtonPopupMode.InstantPopup)
        self.menu_button.setMenu(self.build_main_menu())
        bar.addWidget(self.check_button)
        bar.addWidget(self.install_button)
        bar.addWidget(self.menu_button)
        outer.addWidget(toolbar)

        body = QWidget()
        layout = QVBoxLayout(body)
        layout.setContentsMargins(8, 6, 8, 0)
        layout.setSpacing(4)
        self.self_banner, self.self_label, _ = self.make_banner("self", self.t("sb_install_first"),
                                                               self.install_self_update)
        self.os_banner, self.os_label, _ = self.make_banner("os", self.t("open_upgrade"), self.show_upgrade_os)
        self.restart_banner, self.restart_label, _ = self.make_banner("restart", self.t("restart_now"),
                                                                      self.confirm_reboot)
        self.repo_banner, self.repo_label, _ = self.make_banner("repo", self.t("open_keyfix"), self.show_key_fix)
        self.pause_banner, self.pause_label, _ = self.make_banner("pause", self.t("resume"), self.resume_updates)
        self.kernel_banner, self.kernel_label, _ = self.make_banner("kernel", self.t("open_kernel"),
                                                                    self.show_kernels)
        self.banners = [self.self_banner, self.os_banner, self.restart_banner, self.repo_banner,
                        self.pause_banner, self.kernel_banner]
        for banner in self.banners:
            layout.addWidget(banner)

        self.tree = QTreeWidget(objectName="updatesTree")
        self.tree.setColumnCount(5)
        self.tree.setHeaderLabels([self.t("col_type"), self.t("col_update"), self.t("new"), self.t("size"),
                                   self.t("progress")])
        self.tree.setRootIsDecorated(False)
        self.tree.setUniformRowHeights(True)
        self.tree.setAlternatingRowColors(True)
        self.tree.setTextElideMode(Qt.TextElideMode.ElideRight)
        self.tree.setVerticalScrollMode(QAbstractItemView.ScrollMode.ScrollPerPixel)
        self.tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self.show_context_menu)
        header_view = self.tree.header()
        header_view.setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        header_view.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        header_view.setSectionResizeMode(2, QHeaderView.ResizeMode.ResizeToContents)
        header_view.setSectionResizeMode(3, QHeaderView.ResizeMode.ResizeToContents)
        header_view.setSectionResizeMode(4, QHeaderView.ResizeMode.Fixed)
        self.tree.setColumnWidth(4, 120)
        self.tree.setColumnHidden(4, True)
        self.tree.itemChanged.connect(self.selection_changed)
        self.tree.currentItemChanged.connect(self.show_description)

        self.details = QTabWidget(objectName="details")
        self.description = QLabel(self.t("choose"))
        self.description.setTextFormat(Qt.TextFormat.RichText)
        self.description.setWordWrap(True)
        self.description.setAlignment(Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignLeft)
        self.description.setContentsMargins(8, 6, 8, 6)
        self.description.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.packages_view = QPlainTextEdit()
        self.packages_view.setReadOnly(True)
        self.packages_view.setFont(mono_font())
        self.changelog_view = QPlainTextEdit()
        self.changelog_view.setReadOnly(True)
        self.changelog_view.setFont(mono_font())
        self.details.addTab(self.description, self.t("tab_description"))
        self.details.addTab(self.packages_view, self.t("tab_packages"))
        self.details.addTab(self.changelog_view, self.t("tab_changelog"))
        self.details.currentChanged.connect(lambda _i: self.load_changelog())

        splitter = QSplitter(Qt.Orientation.Vertical)
        splitter.addWidget(self.tree)
        splitter.addWidget(self.details)
        splitter.setChildrenCollapsible(False)
        splitter.setStretchFactor(0, 3)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([330, 130])
        layout.addWidget(splitter, 1)
        outer.addWidget(body, 1)

        status = self.statusBar()
        status.setSizeGripEnabled(True)
        self.select_all = QCheckBox()
        self.select_all.setToolTip(self.t("select_all"))
        self.select_all.setChecked(True)
        self.select_all.stateChanged.connect(self.toggle_all)
        self.selection_label = QLabel(objectName="selectionLabel")
        self.progress_detail = QLabel(objectName="progressDetail")
        self.progress_detail.hide()
        self.global_progress = QProgressBar(objectName="globalProgress")
        self.global_progress.setRange(0, 0)
        self.global_progress.setTextVisible(False)
        self.global_progress.setFixedSize(110, 6)
        self.global_progress.hide()
        self.last_checked = QLabel(objectName="muted")
        self.schedule_label = self.last_checked
        status.addWidget(self.select_all)
        status.addWidget(self.selection_label)
        status.addWidget(self.progress_detail, 1)
        status.addPermanentWidget(self.global_progress)
        status.addPermanentWidget(self.last_checked)

    def apply_style(self) -> None:
        self.setStyleSheet(
            """
            QWidget#body, QDialog { background: #F6F7F6; }
            QFrame#toolbar { background: #FFFFFF; border-bottom: 1px solid #E1E4E2; }
            QLabel#statusTitle { font-weight: 600; color: #1F2933; padding-left: 4px; }
            QLabel#muted { color: #6B7280; }
            QLabel#selectionLabel { color: #374151; }
            QLabel#progressDetail { color: #374151; }
            QLabel#bannerText { color: #1F2933; }
            QLabel#dialogTitle { color: #14532D; font-weight: 700; }
            QLabel#runningKernel { color: #0F7B4F; font-weight: 600; }
            QLabel#pauseStatus { font-weight: 600; color: #05603A; }
            QLabel#pauseStatus[paused="true"] { color: #93370D; }
            QFrame#banner_self, QFrame#banner_os { background: #EEF2FF; border: 1px solid #C7D2FE; border-radius: 4px; }
            QFrame#banner_restart { background: #FFF7ED; border: 1px solid #FED7AA; border-radius: 4px; }
            QFrame#banner_repo { background: #FEF2F2; border: 1px solid #FECACA; border-radius: 4px; }
            QFrame#banner_pause { background: #FEFCE8; border: 1px solid #FDE68A; border-radius: 4px; }
            QFrame#banner_kernel { background: #F0F9FF; border: 1px solid #BAE6FD; border-radius: 4px; }
            QPushButton { min-height: 24px; padding: 0 10px; border-radius: 4px; }
            QPushButton#secondaryButton, QPushButton#chipButton { background: #FFFFFF; color: #1F2933;
                border: 1px solid #C8CECB; }
            QPushButton#secondaryButton:hover, QPushButton#chipButton:hover { background: #F3F4F6; }
            QPushButton#secondaryButton:disabled { color: #9CA3AF; border-color: #E5E7EB; }
            QPushButton#primaryButton { background: #157A55; color: #FFFFFF; border: 1px solid #0F5C3F;
                font-weight: 600; }
            QPushButton#primaryButton:hover { background: #10684A; }
            QPushButton#primaryButton:disabled { background: #B8CEC5; border-color: #A9BFB6; }
            QPushButton#dangerButton { background: #FFFFFF; color: #B42318; border: 1px solid #F04438; }
            QPushButton#dangerButton:disabled { color: #F5A9A2; border-color: #F8C7C2; }
            QPushButton#linkButton { background: transparent; border: 0; color: #1D4ED8; font-weight: 600;
                min-height: 20px; padding: 0 6px; }
            QPushButton#linkButton:hover { text-decoration: underline; }
            QPushButton#chipButton { min-height: 22px; padding: 0; }
            QToolButton#menuButton { border: 1px solid #C8CECB; border-radius: 4px; background: #FFFFFF;
                min-width: 26px; min-height: 24px; padding: 0 4px; }
            QToolButton#menuButton:hover { background: #F3F4F6; }
            QToolButton#menuButton::menu-indicator { image: none; width: 0; }
            QMenu { background: #FFFFFF; border: 1px solid #D1D5DB; padding: 4px; }
            QMenu::item { padding: 5px 22px 5px 14px; border-radius: 3px; }
            QMenu::item:selected { background: #E8F3EE; color: #0F5C3F; }
            QMenu::item:disabled { color: #9CA3AF; }
            QMenu::separator { height: 1px; background: #E5E7EB; margin: 4px 6px; }
            QTreeWidget { background: #FFFFFF; alternate-background-color: #FAFBFA; border: 1px solid #E1E4E2;
                outline: 0; }
            QTreeWidget::item { min-height: 24px; }
            QTreeWidget::item:selected { background: #DCEFE6; color: #111827; }
            QHeaderView::section { background: #FFFFFF; color: #6B7280; border: 0;
                border-bottom: 1px solid #E1E4E2; padding: 4px 6px; }
            QTabWidget#details::pane { border: 1px solid #E1E4E2; background: #FFFFFF; top: -1px; }
            QTabBar::tab { background: transparent; border: 0; padding: 4px 10px; color: #6B7280; }
            QTabBar::tab:selected { color: #14532D; border-bottom: 2px solid #157A55; }
            QPlainTextEdit { border: 0; background: #FFFFFF; }
            QStatusBar { background: #FFFFFF; border-top: 1px solid #E1E4E2; }
            QStatusBar::item { border: 0; }
            QGroupBox { font-weight: 600; border: 1px solid #E1E4E2; border-radius: 4px; margin-top: 8px;
                padding: 8px 6px 6px 6px; background: #FFFFFF; }
            QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 3px; }
            QLineEdit, QComboBox { min-height: 24px; padding: 0 6px; border: 1px solid #C8CECB;
                border-radius: 4px; background: #FFFFFF; }
            QSpinBox, QTimeEdit { min-height: 24px; min-width: 90px; }
            QProgressBar#rowProgress { border: 1px solid #A7C4B5; border-radius: 3px; background: #EEF4F0;
                text-align: center; max-height: 12px; }
            QProgressBar#rowProgress::chunk { background: #199B61; }
            QProgressBar#globalProgress { border: 0; background: #E5EDE8; border-radius: 3px; }
            QProgressBar#globalProgress::chunk { background: #157A55; border-radius: 3px; }
            QProgressBar#taskProgress { border: 1px solid #A7C4B5; border-radius: 3px; background: #EEF4F0;
                text-align: center; max-height: 14px; }
            QProgressBar#taskProgress::chunk { background: #199B61; }
            QTabWidget::pane { border: 1px solid #E1E4E2; background: #FFFFFF; }
            """
        )

    def setup_watcher(self) -> None:
        """Reload when a background refresh (timer or new repository) changes the state."""
        self.watcher = QFileSystemWatcher(self)
        for path in (STATE_FILE.parent, PAUSE_FILE.parent, OS_UPGRADE_FILE.parent):
            if path.is_dir():
                self.watcher.addPath(str(path))
        self.watcher.directoryChanged.connect(lambda _p: self.reload_timer.start())

    def reload_from_disk(self) -> None:
        if self.is_busy():
            return
        self.load_updates()
        self.refresh_banners()

    # ------------------------------------------------------------- banners
    def refresh_banners(self) -> None:
        upgrade = read_os_upgrade()
        if upgrade:
            self.os_label.setText(self.t("banner_os", os=upgrade.get("os_name", "Edukasaun OS"),
                                         version=upgrade.get("target_version", "").split(".")[0],
                                         codename=upgrade["target_codename"]))
        self.os_banner.setVisible(bool(upgrade))
        self.upgrade_action.setVisible(bool(upgrade))

        until = paused_until()
        self.pause_label.setText(self.t("banner_paused", date=format_date(until)))
        self.pause_banner.setVisible(bool(until))

        problems = repo_problem_text(self.lang, run_tool_json("scan-repos", timeout=8))
        self.repo_label.setText(self.t("banner_repo", details=problems))
        self.repo_banner.setVisible(bool(problems))

        restart = restart_is_required(self.read_state())
        self.restart_label.setText(self.t("restart_pending"))
        self.restart_banner.setVisible(restart)

        schedule = read_schedule()
        if schedule["mode"] == "daily":
            text = self.t("schedule_daily", time=schedule["daily"])
        elif schedule["hours"] == 168:
            text = self.t("schedule_week")
        else:
            text = self.t("schedule_interval", hours=schedule["hours"])
        self.last_checked.setToolTip(self.t("next_check", schedule=text))
        self.probe_kernels()

    def probe_kernels(self) -> None:
        fixture = os.environ.get("EUS_KERNEL_FIXTURE")
        if fixture:
            try:
                data = json.loads(Path(fixture).read_text(encoding="utf-8"))
                self.show_kernel_banner(int(data.get("old_count", 0)))
            except (OSError, ValueError):
                pass
            return
        if self.kernel_probe is not None:
            return
        self.kernel_probe = QProcess(self)

        def done(exit_code: int, _status=None) -> None:
            probe, self.kernel_probe = self.kernel_probe, None
            if probe is None:
                return
            output = bytes(probe.readAllStandardOutput()).decode("utf-8", "replace")
            probe.deleteLater()
            if exit_code == 0:
                self.show_kernel_banner(len([line for line in output.splitlines() if line.strip()]))

        self.kernel_probe.finished.connect(done)
        self.kernel_probe.errorOccurred.connect(lambda _e: done(1))
        command = tool_command("kernels", "--format", "old")
        self.kernel_probe.start(command[0], command[1:])

    def show_kernel_banner(self, count: int) -> None:
        self.kernel_label.setText(self.t("banner_kernel", count=count))
        self.kernel_banner.setVisible(count > 0)

    def resume_updates(self) -> None:
        if self.is_busy():
            QMessageBox.information(self, "EUS", self.t("busy"))
            return
        self.start_queue([self.root_queue_item("pause", ["0"])], "settings")

    # ------------------------------------------------------------- updates
    def read_state(self) -> dict[str, str]:
        return read_key_values(STATE_FILE)

    def load_updates(self, update_panel: bool = True) -> None:
        system_records = parse_updates(TSV_FILE)
        user_records = scan_user_flatpaks()
        known = {(r["source"], r["name"]) for r in system_records}
        self.records = system_records + [r for r in user_records if (r["source"], r["name"]) not in known]
        self.groups = group_updates(self.records)
        state = self.read_state()
        self.tree.blockSignals(True)
        self.tree.clear()
        self.package_items.clear()
        self.progress_widgets.clear()
        for group in self.groups:
            category = group["category"]
            color, _pale, _dark = CATEGORY_COLORS.get(category, CATEGORY_COLORS["normal"])
            title = group["name"]
            if len(group["packages"]) > 1:
                title += f"  ({len(group['packages'])})"
            summary = group["description"].split(" — ")[-1]
            item = QTreeWidgetItem([self.t("type_" + category), f"{title}   {summary}",
                                    group["candidate"], format_bytes(group["size"]), ""])
            item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable | Qt.ItemFlag.ItemIsSelectable)
            item.setCheckState(0, Qt.CheckState.Checked)
            item.setData(0, Qt.ItemDataRole.UserRole, group)
            item.setForeground(0, QBrush(QColor(color)))
            badge = item.font(0)
            badge.setBold(True)
            item.setFont(0, badge)
            item.setToolTip(1, f"{group['name']}\n{group['description']}")
            item.setToolTip(2, f"{group['installed']} → {group['candidate']}")
            self.tree.addTopLevelItem(item)
            row_progress = QProgressBar(objectName="rowProgress")
            row_progress.setRange(0, 100)
            row_progress.setFormat("%p%")
            row_progress.setValue(1)
            row_progress.hide()
            self.tree.setItemWidget(item, 4, row_progress)
            for record in group["packages"]:
                self.progress_widgets[(record["source"], record["name"])] = row_progress
            self.package_items.append(item)
        self.tree.blockSignals(False)

        try:
            checked_epoch = int(state.get("checked_at", "0"))
            if checked_epoch <= 0:
                raise ValueError
            checked_text = format_last_check(checked_epoch)
        except (ValueError, OSError, OverflowError):
            checked_text = "—"
        self.last_checked.setText(self.t("last_check", time=checked_text))
        counts = {c: sum(1 for g in self.groups if g["category"] == c) for c in CATEGORY_RANK}
        if restart_is_required(state):
            self.status_title.setText(self.t("restart_pending"))
        elif self.groups:
            parts = [f"{counts[c]} {self.t('type_' + c).lower()}" for c in CATEGORY_RANK if counts[c]]
            self.status_title.setText(self.t("st_updates", count=len(self.groups), parts=", ".join(parts)))
        elif state.get("state") == "ok":
            self.status_title.setText(self.t("current"))
        else:
            self.status_title.setText(self.t("empty"))
        if state.get("checked_at"):
            self.check_button.setText(self.t("tb_refresh"))
        self_update = next((g for g in self.groups if g["self_update"]), None)
        self.self_label.setText(self.t("sb_self_update"))
        self.self_banner.setVisible(self_update is not None)
        self.select_all.blockSignals(True)
        self.select_all.setChecked(bool(self.package_items))
        self.select_all.blockSignals(False)
        self.select_all.setEnabled(bool(self.package_items) and not self.is_busy())
        if self.package_items:
            self.tree.setCurrentItem(self.package_items[0])
        else:
            self.description.setText(self.t("choose") if self.records or state.get("state") != "ok"
                                     else self.t("current"))
            self.packages_view.clear()
            self.changelog_view.clear()
        self.update_selection_summary()
        if update_panel:
            self.sync_panel_status()

    def sync_panel_status(self) -> None:
        # The open manager is already a visible status surface. The panel icon
        # returns from closeEvent() only when updates are still available.
        set_panel_status("hidden")

    def selected_groups(self) -> list[dict]:
        return [item.data(0, Qt.ItemDataRole.UserRole) for item in self.package_items
                if item.checkState(0) == Qt.CheckState.Checked]

    def selected_records(self) -> list[dict]:
        return [record for group in self.selected_groups() for record in group["packages"]]

    def selection_changed(self, _item=None, _column=0) -> None:
        self.update_selection_summary()

    def update_selection_summary(self) -> None:
        groups = self.selected_groups()
        size = sum(g["size"] for g in groups)
        self.selection_label.setText(self.t("selected", count=len(groups), size=format_bytes(size)))
        self.install_button.setEnabled(bool(groups) and not self.is_busy())
        self.select_all.blockSignals(True)
        self.select_all.setChecked(bool(self.package_items) and len(groups) == len(self.package_items))
        self.select_all.blockSignals(False)

    def set_all_checked(self, checked: bool) -> None:
        self.tree.blockSignals(True)
        for item in self.package_items:
            item.setCheckState(0, Qt.CheckState.Checked if checked else Qt.CheckState.Unchecked)
        self.tree.blockSignals(False)
        self.update_selection_summary()

    def toggle_all(self, state: int) -> None:
        self.set_all_checked(state == Qt.CheckState.Checked.value)

    def select_security_only(self) -> None:
        self.tree.blockSignals(True)
        for item in self.package_items:
            group = item.data(0, Qt.ItemDataRole.UserRole)
            wanted = group["category"] in {"critical", "kernel"}
            item.setCheckState(0, Qt.CheckState.Checked if wanted else Qt.CheckState.Unchecked)
        self.tree.blockSignals(False)
        self.update_selection_summary()

    def install_self_update(self) -> None:
        """Like mintupdate: update the update manager itself before anything else."""
        self.tree.blockSignals(True)
        for item in self.package_items:
            group = item.data(0, Qt.ItemDataRole.UserRole)
            item.setCheckState(0, Qt.CheckState.Checked if group["self_update"] else Qt.CheckState.Unchecked)
        self.tree.blockSignals(False)
        self.update_selection_summary()
        self.install_updates()

    def show_context_menu(self, position) -> None:
        item = self.tree.itemAt(position)
        if item is None or self.is_busy():
            return
        group = item.data(0, Qt.ItemDataRole.UserRole)
        menu = QMenu(self)
        if group["source"] == "apt":
            ignore_version = menu.addAction(self.t("cm_ignore_version", version=group["candidate"]))
            ignore_version.triggered.connect(lambda: self.ignore_group(group, versioned=True))
            ignore_all = menu.addAction(self.t("cm_ignore_all"))
            ignore_all.triggered.connect(lambda: self.ignore_group(group, versioned=False))
            menu.addSeparator()
        same = menu.addAction(self.t("cm_select_type", type=self.t("type_" + group["category"]).lower()))

        def select_same() -> None:
            self.tree.blockSignals(True)
            for other in self.package_items:
                data = other.data(0, Qt.ItemDataRole.UserRole)
                other.setCheckState(0, Qt.CheckState.Checked if data["category"] == group["category"]
                                    else Qt.CheckState.Unchecked)
            self.tree.blockSignals(False)
            self.update_selection_summary()

        same.triggered.connect(select_same)
        menu.exec(self.tree.viewport().mapToGlobal(position))

    def ignore_group(self, group: dict, versioned: bool) -> None:
        name = group["key"][1]
        pattern = f"{name}={group['candidate']}" if versioned else name
        self.start_queue([self.root_queue_item("ignore", ["add", pattern])], "settings")

    def show_description(self, current, _previous) -> None:
        if current is None:
            return
        group = current.data(0, Qt.ItemDataRole.UserRole)
        if not isinstance(group, dict):
            return
        category = group["category"]
        color = CATEGORY_COLORS.get(category, CATEGORY_COLORS["normal"])[0]
        source = self.t(f"source_{group['source']}")
        self.description.setText(
            f"<b>{html.escape(group['name'])}</b> &nbsp;"
            f"<span style='color:{color};font-weight:600'>{self.t('type_' + category)}</span>"
            f" &nbsp;·&nbsp; {source} &nbsp;·&nbsp; "
            f"<span style='color:#6B7280'>{html.escape(group['installed'])} → "
            f"{html.escape(group['candidate'])}</span><br>"
            f"{html.escape(group['description'])}<br>"
            f"<span style='color:#4B5563'>{self.t('fix_' + category)} "
            f"<span style='color:{color}'>{self.t('risk_' + category)}</span> "
            f"{self.t('recommend_' + category)}</span>"
        )
        self.packages_view.setPlainText("\n".join(
            f"{p['name']:<40} {p['installed']} → {p['candidate']}  ({format_bytes(p['size'])})"
            for p in group["packages"]))
        self.changelog_view.clear()
        self.load_changelog()

    def load_changelog(self) -> None:
        """Fetch the changelog only when its tab is visible (like mintupdate)."""
        if self.details.currentWidget() is not self.changelog_view:
            return
        item = self.tree.currentItem()
        group = item.data(0, Qt.ItemDataRole.UserRole) if item is not None else None
        if not isinstance(group, dict):
            return
        if group["source"] != "apt":
            self.changelog_view.setPlainText(self.t("cg_flatpak"))
            return
        package = group["main"]["name"]
        if package in self.changelog_cache:
            self.changelog_view.setPlainText(self.changelog_cache[package])
            return
        if self.changelog_process is not None:
            return
        self.changelog_view.setPlainText(self.t("cg_loading"))
        process = QProcess(self)
        self.changelog_process = process

        def done(exit_code: int, _status=None) -> None:
            if self.changelog_process is not process:
                return
            self.changelog_process = None
            text = bytes(process.readAllStandardOutput()).decode("utf-8", "replace").strip()
            if exit_code != 0 or not text:
                text = bytes(process.readAllStandardError()).decode("utf-8", "replace").strip() \
                    or self.t("cg_none")
            self.changelog_cache[package] = text
            process.deleteLater()
            current = self.tree.currentItem()
            if current is not None and current.data(0, Qt.ItemDataRole.UserRole) is group:
                self.changelog_view.setPlainText(text)
            elif self.details.currentWidget() is self.changelog_view:
                self.load_changelog()

        process.finished.connect(done)
        process.errorOccurred.connect(lambda _e: done(1))
        command = tool_command("changelog", package, group["main"]["installed"])
        process.start(command[0], command[1:])

    def showEvent(self, event) -> None:
        set_panel_status("hidden")
        super().showEvent(event)

    def closeEvent(self, event) -> None:
        if self.is_busy():
            QMessageBox.information(self, "EUS", self.t("busy"))
            event.ignore()
            return
        if self.records and not paused_until():
            set_panel_status("available", count=len(self.groups))
        else:
            set_panel_status("hidden")
        super().closeEvent(event)

    def is_busy(self) -> bool:
        return self.process is not None or self.external_busy

    def set_busy(self, busy: bool, text: str = "") -> None:
        for widget in (self.check_button, self.select_all):
            widget.setEnabled(not busy)
        for action in self.busy_actions:
            action.setEnabled(not busy)
        for banner in self.banners:
            banner.setEnabled(not busy)
        self.install_button.setEnabled(not busy and bool(self.selected_groups()))
        self.tree.setColumnHidden(4, not busy)
        self.progress_detail.setVisible(busy)
        self.selection_label.setVisible(not busy)
        self.global_progress.setVisible(busy)
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

    def failure_detail(self, exit_code: int, started_at: float, timed_out: bool = False) -> str:
        """Explain a failed root action without showing a stale error from an earlier run."""
        if timed_out:
            return self.t("timeout")
        if exit_code in {126, 127}:
            return self.t("auth")
        try:
            if ERROR_FILE.stat().st_mtime >= started_at - 1:
                server_error = ERROR_FILE.read_text(encoding="utf-8", errors="replace").strip()
                if server_error:
                    return server_error
        except OSError:
            pass
        return self.t("failed")

    def root_queue_item(self, action: str, extra: list[str] | None = None,
                        records: list[dict] | None = None) -> dict:
        program, args = self.privileged_command(action, extra or [])
        timeout_ms = 7_200_000 if action in {"upgrade-apt", "install-apt"} else (
            3_700_000 if action == "install-flatpak-system" else 900_000)
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
        if self.is_busy() or not commands:
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
        self.operation_started = datetime.now().timestamp()
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
            self.operation_kind = ""
            self.set_busy(False)
            if command.get("root"):
                detail = self.failure_detail(exit_code, self.operation_started, timed_out)
            else:
                detail = self.t("timeout") if timed_out else self.t("failed")
            self.load_updates()
            self.refresh_banners()
            self.show_failure(detail)
            return
        self.run_next_command()

    def show_failure(self, detail: str) -> None:
        dialog = QMessageBox(self)
        dialog.setIcon(QMessageBox.Icon.Critical)
        dialog.setWindowTitle("EUS")
        dialog.setText(detail)
        keyfix = None
        if "Key Fix" in detail or re.search(r"NO_PUBKEY|GPG|signed|duplicate", detail, re.I):
            keyfix = dialog.addButton(self.t("open_keyfix"), QMessageBox.ButtonRole.ActionRole)
        dialog.addButton(self.t("close"), QMessageBox.ButtonRole.RejectRole)
        dialog.exec()
        if keyfix is not None and dialog.clickedButton() is keyfix:
            self.show_key_fix()

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
            self.refresh_banners()
            if needs_restart:
                self.show_restart_prompt()
            else:
                QMessageBox.information(self, "EUS", self.t("success"))
            return
        self.load_updates()
        self.refresh_banners()

    def request_reboot(self) -> None:
        program, args = self.privileged_command("reboot", [])
        QProcess.startDetached(program, args)

    def confirm_reboot(self) -> None:
        answer = QMessageBox.question(self, self.t("restart_title"), self.t("restart_body"),
                                      QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                                      QMessageBox.StandardButton.No)
        if answer == QMessageBox.StandardButton.Yes:
            self.request_reboot()

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
            self.request_reboot()
            self.close()

    def check_updates(self) -> None:
        if self.is_busy():
            return
        self.check_button.setText(self.t("tb_refresh"))
        commands = []
        if shutil.which("flatpak"):
            commands.append(self.user_flatpak_refresh_item())
        commands.append(self.root_queue_item("refresh"))
        self.start_queue(commands, "check")

    def install_updates(self) -> None:
        selected = self.selected_records()
        if not selected or self.is_busy():
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
        # upgrade-apt, install-apt and install-flatpak-system rebuild updates.tsv
        # themselves; a separate refresh is only needed after user Flatpaks.
        if user_flatpak_records or not (selected_apt or system_flatpak_records):
            commands.append(self.root_queue_item("refresh"))
        self.start_queue(commands, "install")

    # ------------------------------------------------------------- dialogs
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

    def run_dialog(self, dialog: QDialog) -> None:
        if self.is_busy():
            QMessageBox.information(self, "EUS", self.t("busy"))
            return
        dialog.exec()
        if getattr(dialog, "changed", False):
            self.load_updates()
        self.refresh_banners()

    def open_page(self, page: str) -> None:
        handlers = {"kernel": self.show_kernels, "key-fix": self.show_key_fix,
                    "cleaner": self.show_cleaner,
                    "add-repo": self.show_add_repo, "upgrade-os": self.show_upgrade_os,
                    "add-key": self.show_add_key, "settings": self.show_settings}
        if page in handlers and QApplication.activeModalWidget() is None:
            handlers[page]()

    def show_kernels(self) -> None:
        self.run_dialog(KernelDialog(self))

    def show_key_fix(self) -> None:
        self.run_dialog(KeyFixDialog(self))

    def show_cleaner(self) -> None:
        self.run_dialog(CleanerDialog(self))

    def show_add_repo(self) -> None:
        self.run_dialog(AddRepoDialog(self))

    def show_upgrade_os(self) -> None:
        self.run_dialog(UpgradeOSDialog(self))

    def show_add_key(self) -> None:
        self.run_dialog(AddKeyDialog(self))

    def show_settings(self) -> None:
        self.run_dialog(SettingsDialog(self))

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

    def show_log(self) -> None:
        dialog = QDialog(self)
        dialog.setWindowTitle(self.t("log_title"))
        dialog.resize(820, 540)
        layout = QVBoxLayout(dialog)
        viewer = QPlainTextEdit()
        viewer.setReadOnly(True)
        viewer.setFont(mono_font())
        viewer.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        try:
            lines = LOG_FILE.read_text(encoding="utf-8", errors="replace").splitlines()[-1500:]
            viewer.setPlainText("\n".join(lines) or "—")
        except OSError:
            viewer.setPlainText("—")
        viewer.moveCursor(viewer.textCursor().MoveOperation.End)
        layout.addWidget(viewer)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        buttons.button(QDialogButtonBox.StandardButton.Close).setText(self.t("close"))
        buttons.rejected.connect(dialog.reject)
        style_button_box(buttons)
        layout.addWidget(buttons)
        dialog.exec()

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
            # Newest entries first.
            return "\n\n".join(reversed(entries)) if entries else self.t("no_history")

        viewer.setPlainText(render_history())
        layout.addWidget(viewer)
        button_row = QHBoxLayout()
        clear_button = QPushButton(self.t("clear_history"), objectName="secondaryButton")
        close = QPushButton(self.t("close"), objectName="secondaryButton")
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


def log_unexpected(exc_type, exc, trace) -> None:
    """Print unexpected errors instead of letting PyQt6 abort the program."""
    import traceback
    traceback.print_exception(exc_type, exc, trace)


def main() -> int:
    sys.excepthook = log_unexpected
    args = sys.argv[1:]
    page = ""
    if "--open" in args:
        index = args.index("--open")
        page = args[index + 1] if index + 1 < len(args) else ""
        del args[index:index + 2]
    screenshot = args[1] if len(args) >= 2 and args[0] == "--screenshot" else ""

    app = QApplication(sys.argv[:1])
    app.setApplicationName("Eduka-Update-System")
    app.setOrganizationName("Edukasaun OS")
    app.setDesktopFileName("eduka-update-system")
    app.setWindowIcon(QIcon(EUS_APP_ICON))
    if not screenshot and request_existing_window(page):
        return 0
    if not screenshot and gui_pid_is_live():
        # A just-started primary instance may still be creating its local
        # socket. Avoid a second window while it finishes initialization.
        def retry_primary() -> None:
            request_existing_window(page)
            app.quit()

        QTimer.singleShot(250, retry_primary)
        return app.exec()

    server = None
    pid_file = None
    if not screenshot:
        QLocalServer.removeServer(INSTANCE_NAME)
        server = QLocalServer(app)
        if not server.listen(INSTANCE_NAME):
            if request_existing_window(page):
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
    app.aboutToQuit.connect(lambda: [stop_background(p) for p in window.findChildren(QProcess)])

    if server is not None:
        def present_primary_window() -> None:
            requested = ""
            while server.hasPendingConnections():
                connection = server.nextPendingConnection()
                if connection is not None:
                    connection.waitForReadyRead(200)
                    message = bytes(connection.readAll()).decode("utf-8", "replace").strip()
                    if message.startswith("open:"):
                        requested = message[5:]
                    connection.disconnectFromServer()
                    connection.deleteLater()
            if window.isMinimized() or window.isFullScreen():
                window.showNormal()
            else:
                window.show()
            window.raise_()
            window.activateWindow()
            if requested:
                QTimer.singleShot(0, lambda: window.open_page(requested))

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

    if screenshot:
        def save_preview() -> None:
            target = QApplication.activeModalWidget() or window
            image = target.grab()
            menu = window.menu_button.menu()
            if menu.isVisible():
                # Compose the open main menu onto the window image.
                from PyQt6.QtGui import QPainter
                painter = QPainter(image)
                painter.drawPixmap(window.mapFromGlobal(menu.pos()), menu.grab())
                painter.end()
            image.save(screenshot)
            app.exit(0)

        if os.environ.get("EUS_SCREENSHOT_MENU") == "1":
            def open_menu() -> None:
                button = window.menu_button
                menu = button.menu()
                menu.popup(button.mapToGlobal(button.rect().bottomRight()) - QPoint(menu.sizeHint().width(), 0))

            QTimer.singleShot(600, open_menu)

        QTimer.singleShot(1200, save_preview)
    if page:
        QTimer.singleShot(0, lambda: window.open_page(page))
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
