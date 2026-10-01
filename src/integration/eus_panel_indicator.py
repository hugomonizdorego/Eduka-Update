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
