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
