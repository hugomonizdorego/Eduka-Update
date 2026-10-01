#!/usr/bin/python3
"""Repository, keyring and kernel maintenance helper for Eduka-Update-System.

Read-only subcommands (scan-repos, scan-keys, kernels) run unprivileged and
print JSON for the GUI. Changing subcommands run as root, only through the
PolicyKit-approved backend /usr/local/libexec/eduka-update-system-root, and
print the EUS progress protocol ("NN" and "# text" lines) on stdout.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

# EUS_APT_ROOT lets the test suite exercise the parsers on a fake tree.
ROOT = os.environ.get("EUS_APT_ROOT", "").rstrip("/")
APT_DIR = Path(ROOT + "/etc/apt")
SOURCES_LIST = APT_DIR / "sources.list"
SOURCES_DIR = APT_DIR / "sources.list.d"
TRUSTED_DIR = APT_DIR / "trusted.gpg.d"
KEYRINGS_DIR = APT_DIR / "keyrings"
LEGACY_KEYRING = APT_DIR / "trusted.gpg"
STATE_DIR = Path(ROOT + "/var/lib/eus")
APT_UPDATE_LOG = STATE_DIR / "apt-update.log"
REPORT_FILE = STATE_DIR / "repair-report.json"
BACKUP_BASE = Path(ROOT + "/var/backups/eus")
KEYSERVERS = ("hkps://keyserver.ubuntu.com", "hkps://keys.openpgp.org")
MAX_KEY_BYTES = 1024 * 1024
DISABLED_MARK = "# Disabled by Eduka-Update-System (duplicate repository):"
SOURCE_FILE_RE = re.compile(r"^[A-Za-z0-9_.-]+\.(list|sources)$")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,62}$")
URI_RE = re.compile(r"^(https?|ftp|file)://[^\s\[\]\"'<>]+$")
SUITE_RE = re.compile(r"^[A-Za-z0-9._~/+-]+$")
COMPONENT_RE = re.compile(r"^[A-Za-z0-9._+-]+$")
ARCH_RE = re.compile(r"^[a-z0-9-]+$")
KEYID_RE = re.compile(r"^(0x)?([0-9A-Fa-f]{8}|[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$")
KERNEL_PACKAGE_RE = re.compile(r"^linux-(image|headers|modules|modules-extra|image-unsigned)-[a-z0-9][a-z0-9.+~-]*$")

MESSAGES = {
    "en": {
        "scan": "Checking repository configuration...",
        "update": "Refreshing package lists to detect key problems...",
        "fetch": "Downloading missing signing key {key}...",
        "legacy": "Moving keys out of the legacy trusted.gpg keyring...",
        "format": "Repairing keyring formats and permissions...",
        "reinstall": "Reinstalling distribution archive keyrings...",
        "verify": "Verifying repositories...",
        "duplicates": "Disabling duplicate repository entries...",
        "add_key": "Installing the signing key...",
        "add_repo": "Adding the repository...",
        "done": "Complete.",
    },
    "id": {
        "scan": "Memeriksa konfigurasi repositori...",
        "update": "Memperbarui daftar paket untuk mendeteksi masalah kunci...",
        "fetch": "Mengunduh kunci penandatangan {key} yang hilang...",
        "legacy": "Memindahkan kunci dari keyring lama trusted.gpg...",
        "format": "Memperbaiki format dan izin keyring...",
        "reinstall": "Memasang ulang keyring arsip distribusi...",
        "verify": "Memverifikasi repositori...",
        "duplicates": "Menonaktifkan entri repositori duplikat...",
        "add_key": "Memasang kunci penandatangan...",
        "add_repo": "Menambahkan repositori...",
        "done": "Selesai.",
    },
    "pt": {
        "scan": "Verificando a configuracao dos repositorios...",
        "update": "Atualizando listas de pacotes para detetar problemas de chaves...",
        "fetch": "Transferindo a chave de assinatura {key} em falta...",
        "legacy": "Movendo chaves do keyring antigo trusted.gpg...",
        "format": "Reparando formatos e permissoes dos keyrings...",
        "reinstall": "Reinstalando os keyrings do arquivo da distribuicao...",
        "verify": "Verificando os repositorios...",
        "duplicates": "Desativando entradas de repositorio duplicadas...",
        "add_key": "Instalando a chave de assinatura...",
        "add_repo": "Adicionando o repositorio...",
        "done": "Concluido.",
    },
    "tet": {
        "scan": "Verifika konfigurasaun repositoriu...",
        "update": "Atualiza lista pakote atu deteta problema xave...",
        "fetch": "Download xave asinatura {key} nebe lakon...",
        "legacy": "Muda xave sira husi keyring tuan trusted.gpg...",
        "format": "Hadi'a formatu no permisaun keyring...",
        "reinstall": "Instala fali keyring arkivu distribuisaun...",
        "verify": "Verifika repositoriu sira...",
        "duplicates": "Dezativa repositoriu duplikadu...",
        "add_key": "Instala xave asinatura...",
        "add_repo": "Aumenta repositoriu...",
        "done": "Remata.",
    },
}
LANG = "en"


class ToolError(Exception):
    """A user-facing failure; the message is shown by the GUI."""


def msg(key: str, **values) -> str:
    return MESSAGES.get(LANG, MESSAGES["en"]).get(key, MESSAGES["en"][key]).format(**values)


def progress(value: int, text: str) -> None:
    print(f"{max(0, min(100, value))}\n# {text}", flush=True)


def run(args: list[str], *, timeout: int = 120, env: dict | None = None,
        input_bytes: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(args, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, check=False, env=env)


def require_root() -> None:
    if os.geteuid() != 0 and not ROOT:
        raise ToolError("This action must run through the EUS privileged backend.")


# --------------------------------------------------------------------------
# APT source parsing
# --------------------------------------------------------------------------

def normalize_uri(uri: str) -> str:
    """Canonical form used to recognise the same archive written differently."""
    value = uri.strip()
    value = re.sub(r"^https?://", "http://", value, flags=re.IGNORECASE)
    match = re.match(r"^([a-z]+://)([^/]+)(.*)$", value, flags=re.IGNORECASE)
    if match:
        value = match.group(1).lower() + match.group(2).lower() + match.group(3)
    return value.rstrip("/")


def parse_options(text: str) -> dict[str, str]:
    options: dict[str, str] = {}
    for token in text.split():
        if "=" in token:
            key, value = token.split("=", 1)
            options[key.strip().lower().rstrip("+-")] = value.strip()
    return options


def source_files() -> list[Path]:
    files = []
    if SOURCES_LIST.is_file():
        files.append(SOURCES_LIST)
    if SOURCES_DIR.is_dir():
        files.extend(sorted(p for p in SOURCES_DIR.iterdir()
                            if p.is_file() and SOURCE_FILE_RE.match(p.name)))
    return files


def parse_list_file(path: Path) -> list[dict]:
    entries = []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return entries
    pattern = re.compile(r"^\s*(deb|deb-src)\s+(\[[^\]]*\]\s*)?(\S+)\s+(\S+)\s*(.*?)\s*$")
    for number, raw in enumerate(lines):
        line = raw.split("#", 1)[0] if not raw.lstrip().startswith("#") else ""
        match = pattern.match(line)
        if not match:
            continue
        kind, options, uri, suite, rest = match.groups()
        options_map = parse_options((options or "").strip().strip("[]"))
        components = rest.split() if rest else []
        entries.append({
            "file": str(path), "format": "list", "line": number, "text": raw,
            "types": [kind], "uris": [uri], "suites": [suite], "components": components,
            "signed_by": options_map.get("signed-by", ""), "enabled": True,
        })
    return entries


def parse_sources_file(path: Path) -> list[dict]:
    entries = []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return entries
    stanzas: list[tuple[int, int, dict[str, str]]] = []
    fields: dict[str, str] = {}
    start = None
    last_key = None
    for number, raw in enumerate(lines + [""]):
        if raw.strip() == "":
            if fields:
                stanzas.append((start or 0, number, fields))
            fields, start, last_key = {}, None, None
            continue
        if raw.lstrip().startswith("#"):
            continue
        if start is None:
            start = number
        if raw[:1] in (" ", "\t") and last_key:
            fields[last_key] += "\n" + raw.strip()
            continue
        if ":" in raw:
            key, value = raw.split(":", 1)
            last_key = key.strip().lower()
            fields[last_key] = value.strip()
    for index, (first, last, data) in enumerate(stanzas):
        enabled = data.get("enabled", "yes").strip().lower() not in {"no", "false", "0"}
        signed_by = data.get("signed-by", "")
        if "BEGIN PGP" in signed_by:
            signed_by = "(embedded key)"
        entries.append({
            "file": str(path), "format": "sources", "stanza": index,
            "first_line": first, "last_line": last,
            "types": data.get("types", "deb").split(), "uris": data.get("uris", "").split(),
            "suites": data.get("suites", "").split(), "components": data.get("components", "").split(),
            "signed_by": signed_by.strip(), "enabled": enabled,
        })
    return entries


def all_entries() -> list[dict]:
    entries = []
    for path in source_files():
        if path.suffix == ".sources":
            entries.extend(parse_sources_file(path))
        else:
            entries.extend(parse_list_file(path))
    return entries


def entry_keys(entry: dict) -> list[tuple[str, str, str, str]]:
    keys = []
    for kind in entry["types"]:
        for uri in entry["uris"]:
            for suite in entry["suites"]:
                components = entry["components"] or [""]
                for component in components:
                    keys.append((kind, normalize_uri(uri), suite.rstrip("/") or suite, component))
    return keys


def find_duplicates(entries: list[dict]) -> list[dict]:
    """Return one record per entry that repeats an earlier enabled entry."""
    seen: dict[tuple[str, str, str, str], dict] = {}
    duplicates = []
    for entry in entries:
        if not entry["enabled"]:
            continue
        keys = entry_keys(entry)
        repeated = [key for key in keys if key in seen]
        if repeated:
            first = seen[repeated[0]]
            duplicates.append({
                "file": entry["file"], "format": entry["format"],
                "line": entry.get("line", entry.get("first_line", 0)) + 1,
                "uri": entry["uris"][0] if entry["uris"] else "",
                "suite": entry["suites"][0] if entry["suites"] else "",
                "components": sorted({key[3] for key in repeated if key[3]}),
                "complete": len(repeated) == len(keys),
                "first_file": first["file"],
                "first_line": first.get("line", first.get("first_line", 0)) + 1,
                "signed_by_conflict": bool(entry["signed_by"] and first["signed_by"]
                                           and entry["signed_by"] != first["signed_by"]),
                "_entry": entry, "_repeated": repeated,
            })
        for key in keys:
            seen.setdefault(key, entry)
    return duplicates


def public(records: list[dict]) -> list[dict]:
    return [{k: v for k, v in record.items() if not k.startswith("_")} for record in records]


def backup_file(path: Path, stamp: str) -> None:
    destination = BACKUP_BASE / stamp / str(path).lstrip("/")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, destination)


def atomic_write(path: Path, text: str | bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(text.encode("utf-8") if isinstance(text, str) else text)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def fix_duplicates() -> dict:
    require_root()
    progress(10, msg("scan"))
    duplicates = find_duplicates(all_entries())
    stamp = time.strftime("%Y%m%d-%H%M%S")
    fixed, skipped = [], []
    by_file: dict[str, list[dict]] = {}
    for duplicate in duplicates:
        by_file.setdefault(duplicate["file"], []).append(duplicate)
    progress(40, msg("duplicates"))
    for file_name, items in by_file.items():
        path = Path(file_name)
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        # Apply from the bottom so earlier line numbers stay valid.
        items.sort(key=lambda d: d["_entry"].get("line", d["_entry"].get("first_line", 0)), reverse=True)
        changed = False
        for item in items:
            entry = item["_entry"]
            if entry["format"] == "list":
                number = entry["line"]
                if item["complete"]:
                    lines[number] = f"{DISABLED_MARK} {lines[number]}"
                else:
                    keep = [c for c in entry["components"]
                            if (entry["types"][0], normalize_uri(entry["uris"][0]),
                                entry["suites"][0].rstrip("/") or entry["suites"][0], c)
                            not in item["_repeated"]]
                    prefix = re.match(r"^\s*(deb|deb-src)\s+(\[[^\]]*\]\s*)?\S+\s+\S+",
                                      lines[number]).group(0)
                    lines[number:number + 1] = [f"{DISABLED_MARK} {lines[number]}",
                                                f"{prefix} {' '.join(keep)}"]
                changed = True
                fixed.append(public([item])[0])
            else:
                first, last = entry["first_line"], entry["last_line"]
                stanza = lines[first:last]
                simple = len(entry["types"]) == len(entry["uris"]) == len(entry["suites"]) == 1
                if item["complete"]:
                    stanza = [l for l in stanza if not re.match(r"^\s*Enabled\s*:", l, re.I)]
                    stanza = [DISABLED_MARK.rstrip(":"), "Enabled: no"] + stanza
                elif simple:
                    keep = [c for c in entry["components"]
                            if (entry["types"][0], normalize_uri(entry["uris"][0]),
                                entry["suites"][0].rstrip("/") or entry["suites"][0], c)
                            not in item["_repeated"]]
                    stanza = [f"Components: {' '.join(keep)}" if re.match(r"^\s*Components\s*:", l, re.I)
                              else l for l in stanza]
                else:
                    skipped.append(public([item])[0])
                    continue
                lines[first:last] = stanza
                changed = True
                fixed.append(public([item])[0])
        if changed:
            backup_file(path, stamp)
            atomic_write(path, "\n".join(lines) + "\n", path.stat().st_mode & 0o777 or 0o644)
    progress(100, msg("done"))
    return {"fixed": fixed, "skipped": skipped,
            "backup": str(BACKUP_BASE / stamp) if fixed else ""}


# --------------------------------------------------------------------------
# GnuPG keyrings
# --------------------------------------------------------------------------

class GpgHome:
    """A throw-away GnuPG home so root's own keyring is never touched."""

    def __enter__(self) -> "GpgHome":
        self.path = tempfile.mkdtemp(prefix="eus-gpg.")
        os.chmod(self.path, 0o700)
        return self

    def __exit__(self, *_exc) -> None:
        run(["gpgconf", "--homedir", self.path, "--kill", "all"], timeout=10) \
            if shutil.which("gpgconf") else None
        shutil.rmtree(self.path, ignore_errors=True)

    def gpg(self, *args: str, timeout: int = 60, input_bytes: bytes | None = None):
        return run(["gpg", "--homedir", self.path, "--batch", "--no-tty", "--quiet", *args],
                   timeout=timeout, input_bytes=input_bytes)


def describe_keys(data: bytes) -> list[dict]:
    """Parse public keys from armored or binary data; raises ToolError when invalid."""
    if not shutil.which("gpg"):
        raise ToolError("GnuPG (gpg) is not installed.")
    with GpgHome() as home:
        result = home.gpg("--with-colons", "--fixed-list-mode", "--show-keys", input_bytes=data)
    if result.returncode != 0:
        raise ToolError("The file is not a valid OpenPGP public key.")
    keys: list[dict] = []
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        fields = line.split(":")
        if fields[0] == "sec":
            raise ToolError("Secret keys are refused. Provide the public key only.")
        if fields[0] == "pub":
            expires = int(fields[6]) if len(fields) > 6 and fields[6].isdigit() else 0
            keys.append({"keyid": fields[4], "validity": fields[1], "expires": expires,
                         "created": int(fields[5]) if fields[5].isdigit() else 0,
                         "fingerprint": "", "uid": ""})
        elif fields[0] == "fpr" and keys and not keys[-1]["fingerprint"]:
            keys[-1]["fingerprint"] = fields[9]
        elif fields[0] == "uid" and keys and not keys[-1]["uid"]:
            keys[-1]["uid"] = fields[9].replace("\\x3a", ":")
    if not keys:
        raise ToolError("No public key was found in the provided data.")
    now = time.time()
    for key in keys:
        key["expired"] = key["validity"] == "e" or bool(key["expires"] and key["expires"] < now)
        key["revoked"] = key["validity"] == "r"
    return keys


def to_binary_keyring(data: bytes) -> bytes:
    """Return a binary public keyring containing exactly the keys in data."""
    describe_keys(data)
    with GpgHome() as home:
        imported = home.gpg("--import", input_bytes=data)
        if imported.returncode not in (0, 2):
            raise ToolError("GnuPG could not import the key.")
        exported = home.gpg("--export")
    if exported.returncode != 0 or not exported.stdout:
        raise ToolError("GnuPG could not export the key.")
    return exported.stdout


def merge_keyrings(*blobs: bytes) -> bytes:
    with GpgHome() as home:
        for blob in blobs:
            if blob:
                home.gpg("--import", input_bytes=blob)
        exported = home.gpg("--export")
    if exported.returncode != 0 or not exported.stdout:
        raise ToolError("GnuPG could not merge the keyrings.")
    return exported.stdout


def fetch_from_keyserver(keyid: str) -> bytes:
    keyid = keyid.upper().removeprefix("0X")
    last_error = "no keyserver answered"
    for server in KEYSERVERS:
        with GpgHome() as home:
            result = home.gpg("--keyserver", server, "--recv-keys", keyid, timeout=90)
            if result.returncode == 0:
                exported = home.gpg("--export", keyid)
                if exported.returncode == 0 and exported.stdout:
                    return exported.stdout
            last_error = result.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or [last_error]
            last_error = last_error[0]
    # dirmngr often fails behind proxies or firewalls; HKPS is plain HTTPS.
    for server in KEYSERVERS:
        url = server.replace("hkps://", "https://") + f"/pks/lookup?op=get&options=mr&search=0x{keyid}"
        try:
            # The keyserver matched on this ID (primary key or signing subkey).
            return to_binary_keyring(fetch_url(url))
        except ToolError as exc:
            last_error = str(exc)
    raise ToolError(f"Key {keyid} could not be downloaded: {last_error}")


def fetch_url(url: str) -> bytes:
    if not re.match(r"^https://[^\s]+$", url):
        raise ToolError("Only HTTPS key URLs are accepted.")
    request = urllib.request.Request(url, headers={"User-Agent": "Eduka-Update-System"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read(MAX_KEY_BYTES + 1)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise ToolError(f"The key could not be downloaded: {exc}") from exc
    if len(data) > MAX_KEY_BYTES:
        raise ToolError("The downloaded key is too large.")
    return data


def read_key_file(path_text: str) -> bytes:
    path = Path(path_text)
    if not path.is_absolute():
        raise ToolError("The key file path must be absolute.")
    resolved = path.resolve()
    if any(str(resolved).startswith(prefix) for prefix in ("/proc/", "/sys/", "/dev/", "/run/")):
        raise ToolError("This location cannot contain a key file.")
    if not resolved.is_file():
        raise ToolError("The key file does not exist.")
    if resolved.stat().st_size > MAX_KEY_BYTES:
        raise ToolError("The key file is too large.")
    return resolved.read_bytes()


def keyring_files() -> list[Path]:
    files: list[Path] = []
    for directory in (TRUSTED_DIR, KEYRINGS_DIR):
        if directory.is_dir():
            files.extend(sorted(p for p in directory.iterdir()
                                if p.is_file() and p.suffix in {".gpg", ".asc", ".pgp"}))
    return files


def apt_problems(text: str | None = None) -> dict:
    """Extract key and repository problems from `apt-get update` output."""
    if text is None:
        try:
            text = APT_UPDATE_LOG.read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = ""
    missing: dict[str, str] = {}
    expired: dict[str, str] = {}
    unsigned, conflicts, duplicated = set(), set(), set()
    unreachable: dict[str, str] = {}
    legacy = False
    current_url = ""
    lines = text.splitlines()
    for index, line in enumerate(lines):
        failed = re.match(r"^E: Failed to fetch (\S+)\s+(.*)$", line)
        if failed:
            base = re.sub(r"/dists/.*$", "", failed.group(1))
            unreachable.setdefault(base, failed.group(2).strip())
        err = re.match(r"^Err:\d+ (\S+)", line)
        if err and index + 1 < len(lines) and lines[index + 1].startswith("  "):
            unreachable.setdefault(err.group(1), lines[index + 1].strip())
        url_match = re.search(r"(?:GPG error|repository '?)[: ]*\s*((?:https?|ftp|file)://\S+)", line)
        if url_match:
            current_url = url_match.group(1).strip("'")
        for keyid in re.findall(r"NO_PUBKEY ([0-9A-Fa-f]{8,40})", line):
            missing.setdefault(keyid.upper(), current_url)
        for keyid in re.findall(r"(?:EXPKEYSIG|KEYEXPIRED|REVKEYSIG) ([0-9A-Fa-f]{8,40})", line):
            expired.setdefault(keyid.upper(), current_url)
        if "is not signed" in line and url_match:
            unsigned.add(current_url)
        if "Conflicting values set for option Signed-By" in line:
            match = re.search(r"regarding source (\S+)", line)
            conflicts.add(match.group(1) if match else line.strip()[:160])
        if "configured multiple times" in line:
            match = re.search(r"Target \S+ \(([^)]+)\) is configured multiple times", line)
            duplicated.add(match.group(1) if match else line.strip()[:160])
        if "legacy trusted.gpg keyring" in line:
            legacy = True
    # A repository that could not be downloaded is also reported as "not
    # signed" by APT; that is a network problem, not a key problem.
    reachable_unsigned = {url for url in unsigned
                          if not any(normalize_uri(url).startswith(normalize_uri(base))
                                     for base in unreachable)}
    unsigned = reachable_unsigned
    return {"unreachable": [{"url": k, "reason": v} for k, v in unreachable.items()],
            "missing_keys": [{"keyid": k, "url": v} for k, v in missing.items()],
            "expired_keys": [{"keyid": k, "url": v} for k, v in expired.items()],
            "unsigned": sorted(unsigned), "signed_by_conflicts": sorted(conflicts),
            "configured_multiple_times": sorted(duplicated), "legacy_warning": legacy}


def scan_keys() -> dict:
    files = []
    referenced = {e["signed_by"] for e in all_entries()
                  if e["enabled"] and e["signed_by"].startswith("/")}
    for path in keyring_files() + ([LEGACY_KEYRING] if LEGACY_KEYRING.is_file() else []):
        info = {"path": str(path), "problems": [], "keys": []}
        try:
            stat = path.stat()
            data = path.read_bytes()
        except OSError as exc:
            info["problems"].append(f"unreadable: {exc.strerror}")
            files.append(info)
            continue
        if stat.st_mode & 0o004 == 0:
            info["problems"].append("not world-readable (APT cannot read it)")
        if not data.strip():
            info["problems"].append("empty file")
        elif path.suffix == ".gpg" and data.lstrip().startswith(b"-----BEGIN PGP"):
            info["problems"].append("ASCII-armored data in a .gpg file")
        if data.strip():
            try:
                info["keys"] = describe_keys(data)
                for key in info["keys"]:
                    if key["expired"]:
                        info["problems"].append(f"key {key['keyid']} has expired")
                    if key["revoked"]:
                        info["problems"].append(f"key {key['keyid']} is revoked")
            except ToolError:
                info["problems"].append("damaged or not an OpenPGP keyring")
        if path == LEGACY_KEYRING:
            info["problems"].append("deprecated legacy keyring /etc/apt/trusted.gpg")
        files.append(info)
    missing_files = sorted(p for p in referenced if not Path(ROOT + p).is_file())
    return {"files": files, "missing_signed_by": missing_files, "apt": apt_problems()}


def signed_by_for_url(url: str) -> str:
    if not url:
        return ""
    wanted = normalize_uri(url)
    best = ""
    best_len = -1
    for entry in all_entries():
        if not entry["enabled"] or not entry["signed_by"].startswith("/"):
            continue
        for uri in entry["uris"]:
            candidate = normalize_uri(uri)
            if wanted.startswith(candidate) and len(candidate) > best_len:
                best, best_len = entry["signed_by"], len(candidate)
    return best


def install_key_into(path: Path, blob: bytes) -> None:
    existing = b""
    if path.is_file():
        try:
            existing = to_binary_keyring(path.read_bytes())
        except ToolError:
            existing = b""
    merged = merge_keyrings(existing, blob) if existing else blob
    atomic_write(path, merged, 0o644)


def apt_update_capture() -> str:
    result = run(["apt-get", "-o", "Acquire::Retries=2", "update"], timeout=900)
    text = (result.stdout + result.stderr).decode("utf-8", "replace")
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        atomic_write(APT_UPDATE_LOG, text, 0o644)
    except OSError:
        pass
    return text


def fix_keys() -> dict:
    require_root()
    stamp = time.strftime("%Y%m%d-%H%M%S")
    actions: list[str] = []
    errors: list[str] = []
    progress(5, msg("update"))
    problems = apt_problems(apt_update_capture())

    wanted = problems["missing_keys"] + problems["expired_keys"]
    for index, item in enumerate(wanted):
        progress(20 + index * 30 // max(1, len(wanted)), msg("fetch", key=item["keyid"]))
        try:
            blob = fetch_from_keyserver(item["keyid"])
            target = signed_by_for_url(item["url"])
            destination = Path(ROOT + target) if target else TRUSTED_DIR / f"eus-{item['keyid'][-16:].lower()}.gpg"
            if destination.is_file():
                backup_file(destination, stamp)
            install_key_into(destination, blob)
            actions.append(f"Installed key {item['keyid']} into {destination}")
        except (ToolError, OSError, subprocess.TimeoutExpired) as exc:
            errors.append(str(exc))

    progress(55, msg("legacy"))
    if LEGACY_KEYRING.is_file():
        try:
            data = LEGACY_KEYRING.read_bytes()
            keys = describe_keys(data) if data.strip() else []
            with GpgHome() as home:
                home.gpg("--import", input_bytes=data)
                for key in keys:
                    exported = home.gpg("--export", key["fingerprint"] or key["keyid"])
                    if exported.returncode != 0 or not exported.stdout:
                        raise ToolError(f"Key {key['keyid']} could not be exported.")
                    atomic_write(TRUSTED_DIR / f"eus-legacy-{key['keyid'][-16:].lower()}.gpg",
                                 exported.stdout, 0o644)
            backup_file(LEGACY_KEYRING, stamp)
            LEGACY_KEYRING.unlink()
            actions.append(f"Migrated {len(keys)} keys from {LEGACY_KEYRING} to {TRUSTED_DIR}")
        except (ToolError, OSError) as exc:
            errors.append(f"Legacy keyring was kept: {exc}")

    progress(65, msg("format"))
    quarantine = BACKUP_BASE / stamp / "damaged-keyrings"
    for path in keyring_files():
        try:
            data = path.read_bytes()
            if not data.strip():
                raise ToolError("empty")
            if path.suffix == ".gpg" and data.lstrip().startswith(b"-----BEGIN PGP"):
                backup_file(path, stamp)
                atomic_write(path, to_binary_keyring(data), 0o644)
                actions.append(f"Converted armored keyring {path} to binary format")
            else:
                describe_keys(data)
            if path.stat().st_mode & 0o777 != 0o644 or path.stat().st_uid != 0:
                os.chmod(path, 0o644)
                if os.geteuid() == 0:
                    os.chown(path, 0, 0)
                actions.append(f"Fixed permissions on {path}")
        except (ToolError, OSError):
            # Only quarantine files in trusted.gpg.d: APT loads all of them and
            # a damaged one breaks verification for every repository.
            if path.parent == TRUSTED_DIR:
                quarantine.mkdir(parents=True, exist_ok=True)
                shutil.move(str(path), quarantine / path.name)
                actions.append(f"Moved damaged keyring {path} to {quarantine}")
            else:
                errors.append(f"Damaged keyring {path}; re-add it with Add Key.")
    for directory in (TRUSTED_DIR, KEYRINGS_DIR):
        if directory.is_dir() and directory.stat().st_mode & 0o755 != 0o755:
            os.chmod(directory, 0o755)
            actions.append(f"Fixed permissions on {directory}")

    progress(75, msg("reinstall"))
    for package in ("debian-archive-keyring", "ubuntu-keyring", "edukasaun-archive-keyring",
                    "edukasaun-keyring"):
        status = run(["dpkg-query", "-W", "-f=${db:Status-Status}", package], timeout=20)
        if status.stdout.decode().strip() == "installed":
            result = run(["apt-get", "install", "--reinstall", "-y", "-q", package], timeout=600,
                         env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"})
            if result.returncode == 0:
                actions.append(f"Reinstalled {package}")

    progress(85, msg("verify"))
    remaining = apt_problems(apt_update_capture())
    progress(100, msg("done"))
    return {"actions": actions, "errors": errors, "remaining": remaining,
            "backup": str(BACKUP_BASE / stamp) if (BACKUP_BASE / stamp).exists() else ""}


def add_key(args: argparse.Namespace) -> dict:
    require_root()
    name = args.name.strip().lower()
    if name.endswith((".gpg", ".asc")):
        name = name[:-4]
    if not NAME_RE.match(name):
        raise ToolError("Invalid name: use lowercase letters, digits, dots, dashes or underscores.")
    progress(10, msg("add_key"))
    if args.file:
        data = read_key_file(args.file)
    elif args.url:
        data = fetch_url(args.url)
    elif args.keyserver:
        if not KEYID_RE.match(args.keyserver.strip()):
            raise ToolError("Invalid key ID or fingerprint.")
        data = fetch_from_keyserver(args.keyserver.strip())
    else:
        raise ToolError("No key source was provided.")
    keys = describe_keys(data)
    blob = to_binary_keyring(data)
    result = {"keys": keys, "actions": [], "warnings": []}
    if any(key["expired"] or key["revoked"] for key in keys):
        result["warnings"].append("The key is expired or revoked; APT may still reject the repository.")

    repo_uri = (args.repo_uri or "").strip()
    if not repo_uri:
        destination = TRUSTED_DIR / f"{name}.gpg"
        install_key_into(destination, blob)
        result["actions"].append(f"Installed key into {destination}")
        progress(100, msg("done"))
        return result

    if not URI_RE.match(repo_uri):
        raise ToolError("Invalid repository URI.")
    suite = (args.suite or "").strip()
    if not SUITE_RE.match(suite):
        raise ToolError("Invalid repository suite.")
    components = (args.components or "").split()
    if any(not COMPONENT_RE.match(c) for c in components) or (not components and not suite.endswith("/")):
        raise ToolError("Invalid repository components.")
    architectures = (args.arch or "").split()
    if any(not ARCH_RE.match(a) for a in architectures):
        raise ToolError("Invalid architecture.")
    types = ["deb"] + (["deb-src"] if args.with_source else [])

    progress(45, msg("add_repo"))
    probe = {"types": types, "uris": [repo_uri], "suites": [suite], "components": components}
    wanted = set(entry_keys(probe))
    existing = [e for e in all_entries() if e["enabled"] and wanted & set(entry_keys(e))]
    if existing:
        # Do not create a duplicate repository; make the key usable for the existing entry.
        target = existing[0]["signed_by"]
        destination = Path(ROOT + target) if target.startswith("/") else TRUSTED_DIR / f"{name}.gpg"
        install_key_into(destination, blob)
        result["actions"].append(f"Installed key into {destination}")
        result["warnings"].append(f"The repository already exists in {existing[0]['file']}; "
                                  "no duplicate entry was added.")
        progress(100, msg("done"))
        return result

    keyring = KEYRINGS_DIR / f"{name}.gpg"
    KEYRINGS_DIR.mkdir(mode=0o755, parents=True, exist_ok=True)
    install_key_into(keyring, blob)
    result["actions"].append(f"Installed key into {keyring}")
    stanza = [f"Types: {' '.join(types)}", f"URIs: {repo_uri}", f"Suites: {suite}"]
    if components:
        stanza.append(f"Components: {' '.join(components)}")
    if architectures:
        stanza.append(f"Architectures: {' '.join(architectures)}")
    stanza.append(f"Signed-By: {str(keyring)[len(ROOT):] if ROOT else keyring}")
    source_file = SOURCES_DIR / f"{name}.sources"
    if source_file.exists():
        backup_file(source_file, time.strftime("%Y%m%d-%H%M%S"))
    atomic_write(source_file, "# Added by Eduka-Update-System\n" + "\n".join(stanza) + "\n", 0o644)
    result["actions"].append(f"Added repository {source_file}")
    progress(100, msg("done"))
    return result


# --------------------------------------------------------------------------
# Kernels
# --------------------------------------------------------------------------

def version_key(text: str) -> list:
    """Natural sort key: 6.12.10 sorts after 6.12.9."""
    return [(0, int(part)) if part.isdigit() else (1, part)
            for part in re.split(r"(\d+)", text) if part]


def compare_versions(left: str, right: str) -> int:
    if shutil.which("dpkg"):
        for operator, value in (("lt", -1), ("gt", 1)):
            if run(["dpkg", "--compare-versions", left, operator, right], timeout=5).returncode == 0:
                return value
        return 0
    a, b = version_key(left), version_key(right)
    return (a > b) - (a < b)


def kernel_release(package: str) -> str:
    """linux-image-6.12.38+deb13-amd64 -> 6.12.38+deb13-amd64; '' for metapackages."""
    match = re.match(r"^linux-image-(?:unsigned-)?(\d[^\s]*?)(?:-unsigned)?$", package)
    if not match or package.endswith("-dbg"):
        return ""
    return match.group(1)


def kernel_flavour(release: str) -> str:
    match = re.match(r"^\d+\.\d+(?:\.\d+)?(?:-\d+)?(?:[+~][^-]*)?-(.+)$", release)
    return match.group(1) if match else ""


def dpkg_packages(pattern: str) -> list[dict]:
    result = run(["dpkg-query", "-W", "-f=${Package}\t${Version}\t${db:Status-Status}\t${Installed-Size}\n",
                  pattern], timeout=30)
    packages = []
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        fields = line.split("\t")
        if len(fields) == 4 and fields[2] in {"installed", "config-files", "half-configured",
                                               "unpacked", "half-installed"}:
            packages.append({"name": fields[0], "version": fields[1], "status": fields[2],
                             "size_kb": int(fields[3]) if fields[3].isdigit() else 0})
    return packages


def related_packages(release: str, installed_names: set[str]) -> list[str]:
    names = [f"linux-{prefix}-{release}" for prefix in
             ("image", "image-unsigned", "modules", "modules-extra", "headers", "tools", "cloud-tools")]
    names.append(f"linux-image-{release}-unsigned")
    flavour = kernel_flavour(release)
    if flavour:
        base = release[: -len(flavour) - 1]
        others = {kernel_release(n) for n in installed_names if kernel_release(n)} - {release}
        if not any(r.startswith(base + "-") for r in others):
            # Debian: linux-headers-<abi>-common; Ubuntu: linux-headers-<abi>.
            names.extend((f"linux-headers-{base}-common", f"linux-headers-{base}"))
    return [name for name in names if name in installed_names]


def apt_show(packages: list[str]) -> dict[str, dict]:
    if not packages:
        return {}
    result = run(["apt-cache", "show", "--no-all-versions", *packages], timeout=60,
                 env={**os.environ, "LC_ALL": "C"})
    info: dict[str, dict] = {}
    current: dict[str, str] = {}
    for line in result.stdout.decode("utf-8", "replace").splitlines() + [""]:
        if not line.strip():
            if current.get("Package"):
                info.setdefault(current["Package"], current)
            current = {}
        elif ":" in line and not line.startswith(" "):
            key, value = line.split(":", 1)
            current.setdefault(key, value.strip())
    return info


def list_kernels(include_available: bool = True) -> dict:
    running = os.uname().release
    flavour = kernel_flavour(running)
    images = dpkg_packages("linux-image-*")
    all_linux = dpkg_packages("linux-*")
    installed_names = {p["name"] for p in all_linux}
    kernels: dict[str, dict] = {}
    metas = []
    for package in images:
        release = kernel_release(package["name"])
        if not release:
            if package["status"] == "installed" and not package["name"].endswith("-dbg"):
                metas.append({"package": package["name"], "version": package["version"]})
            continue
        entry = kernels.setdefault(release, {
            "release": release, "package": package["name"], "version": package["version"],
            "status": package["status"], "size_kb": 0, "boot_image": False,
        })
        entry["size_kb"] += package["size_kb"]
    for release, entry in kernels.items():
        entry["packages"] = related_packages(release, installed_names)
        entry["boot_image"] = Path(f"/boot/vmlinuz-{release}").exists()
        if entry["status"] == "config-files":
            entry["state"] = "residual"
        elif release == running:
            entry["state"] = "running"
        elif compare_versions(release, running) < 0:
            entry["state"] = "old"
        else:
            entry["state"] = "newer"
    ordered = sorted(kernels.values(), key=lambda k: version_key(k["release"]), reverse=True)

    available = []
    if not include_available:
        return {"running": running, "flavour": flavour, "installed": ordered, "metas": metas,
                "available": [], "headers_installed": False,
                "old_count": sum(1 for k in ordered if k["state"] in {"old", "residual"})}
    names = run(["apt-cache", "pkgnames", "linux-image-"], timeout=60).stdout.decode("utf-8", "replace").split()
    versioned, meta_names = [], []
    for name in set(names):
        release = kernel_release(name)
        if release:
            if "unsigned" in name or kernel_flavour(release) != flavour or release in kernels:
                continue
            versioned.append(name)
        elif flavour and flavour in name and not name.endswith(("-dbg", "-unsigned")) \
                and "signed-" not in name:
            meta_names.append(name)
    versioned.sort(key=lambda n: version_key(kernel_release(n)), reverse=True)
    details = apt_show(versioned[:15] + sorted(meta_names)[:10])
    installed_meta = {m["package"] for m in metas}
    for name in sorted(meta_names)[:10] + versioned[:15]:
        data = details.get(name)
        if not data:
            continue
        release = kernel_release(name)
        if not release and name in installed_meta:
            continue
        headers = f"linux-headers-{release}" if release else name.replace("linux-image-", "linux-headers-", 1)
        available.append({
            "package": name, "release": release, "version": data.get("Version", ""),
            "meta": not release, "size": int(data.get("Size", "0") or 0),
            "description": data.get("Description", data.get("Description-en", "")),
            "headers": headers,
        })
    headers_used = any(n.startswith(f"linux-headers-{running}") for n in installed_names)
    return {"running": running, "flavour": flavour, "installed": ordered, "metas": metas,
            "available": available, "headers_installed": headers_used,
            "old_count": sum(1 for k in ordered if k["state"] in {"old", "residual"})}


def kernel_plan(mode: str, items: list[str], with_headers: bool) -> list[str]:
    """Validate a kernel request and return the exact package list for APT."""
    running = os.uname().release
    if not items or len(items) > 40:
        raise ToolError("No kernel was selected.")
    if mode == "install":
        packages = []
        known = apt_show(items)
        for name in items:
            if not re.match(r"^linux-image-[a-z0-9][a-z0-9.+~-]*$", name) or name not in known:
                raise ToolError(f"Kernel package is not available: {name}")
            packages.append(name)
            if with_headers:
                release = kernel_release(name)
                headers = f"linux-headers-{release}" if release else name.replace("linux-image-", "linux-headers-", 1)
                if apt_show([headers]):
                    packages.append(headers)
        return packages
    installed = {p["name"] for p in dpkg_packages("linux-*")}
    packages: list[str] = []
    for release in items:
        if not re.match(r"^\d[a-z0-9.+~-]*$", release):
            raise ToolError(f"Invalid kernel release: {release}")
        if release == running:
            raise ToolError("The running kernel cannot be removed.")
        found = related_packages(release, installed)
        if not any(n.startswith("linux-image-") for n in found):
            raise ToolError(f"Kernel {release} is not installed.")
        packages.extend(n for n in found if n not in packages)
    if any(not KERNEL_PACKAGE_RE.match(n) and not n.endswith("-common") for n in packages):
        raise ToolError("Unexpected package in the removal plan.")
    simulation = run(["apt-get", "-s", "-o", "Debug::NoLocking=1", "purge", *packages], timeout=120,
                     env={**os.environ, "LC_ALL": "C"})
    if simulation.returncode != 0:
        raise ToolError("APT could not plan the kernel removal.")
    removed = re.findall(r"^(?:Remv|Purg) (\S+)", simulation.stdout.decode("utf-8", "replace"), re.M)
    for name in removed:
        if kernel_release(name) == running or name in {f"linux-modules-{running}"}:
            raise ToolError("The removal would also remove the running kernel; it was cancelled.")
        if name.startswith("linux-image-") and not kernel_release(name) and not name.endswith("-dbg"):
            raise ToolError(f"The removal would also remove the kernel metapackage {name}. "
                            "Remove an older kernel instead.")
    return packages


# --------------------------------------------------------------------------

def write_report(kind: str, payload: dict) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        atomic_write(REPORT_FILE, json.dumps({"kind": kind, "time": int(time.time()), **payload},
                                             indent=1), 0o644)
    except OSError:
        pass


def main(argv: list[str]) -> int:
    global LANG
    parser = argparse.ArgumentParser(prog="eduka-update-system-tool")
    parser.add_argument("--lang", default="en")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("scan-repos")
    sub.add_parser("scan-keys")
    kernels = sub.add_parser("kernels")
    kernels.add_argument("--format", choices=("json", "text", "old"), default="json")
    problems = sub.add_parser("apt-problems")
    problems.add_argument("--check", action="store_true",
                          help="exit 0 when key or repository-definition problems exist, else 1")
    show = sub.add_parser("show-key")
    show.add_argument("file")
    sub.add_parser("fix-duplicates")
    sub.add_parser("fix-keys")
    add = sub.add_parser("add-key")
    add.add_argument("--name", required=True)
    add.add_argument("--file")
    add.add_argument("--url")
    add.add_argument("--keyserver")
    add.add_argument("--repo-uri")
    add.add_argument("--suite")
    add.add_argument("--components")
    add.add_argument("--arch")
    add.add_argument("--with-source", action="store_true")
    plan = sub.add_parser("kernel-plan")
    plan.add_argument("mode", choices=("install", "remove"))
    plan.add_argument("items", nargs="+")
    plan.add_argument("--headers", action="store_true")
    args = parser.parse_args(argv)
    LANG = args.lang if args.lang in MESSAGES else "en"
    try:
        if args.command == "scan-repos":
            entries = all_entries()
            print(json.dumps({"files": [str(p) for p in source_files()],
                              "entries": len(entries),
                              "duplicates": public(find_duplicates(entries)),
                              "apt": apt_problems()}, indent=1))
        elif args.command == "scan-keys":
            print(json.dumps(scan_keys(), indent=1))
        elif args.command == "apt-problems":
            found = apt_problems()
            if args.check:
                keys = ("missing_keys", "expired_keys", "unsigned", "signed_by_conflicts",
                        "configured_multiple_times")
                return 0 if any(found[k] for k in keys) else 1
            print(json.dumps(found, indent=1))
        elif args.command == "kernels":
            data = list_kernels(include_available=args.format != "old")
            if args.format == "old":
                print("\n".join(k["release"] for k in data["installed"]
                                if k["state"] in {"old", "residual"}))
            elif args.format == "text":
                labels = {"running": "RUNNING (in use)", "old": "OLD KERNEL - safe to remove",
                          "newer": "NEW - restart to use", "residual": "leftover configuration"}
                print(f"Running kernel: {data['running']}")
                for kernel in data["installed"]:
                    print(f"  {kernel['release']:<36} {labels.get(kernel['state'], kernel['state'])}")
                if data["available"]:
                    print("Installable kernels:")
                    for kernel in data["available"]:
                        print(f"  {kernel['package']:<42} {kernel['version']}")
            else:
                print(json.dumps(data, indent=1))
        elif args.command == "show-key":
            print(json.dumps(describe_keys(read_key_file(os.path.abspath(args.file))), indent=1))
        elif args.command == "fix-duplicates":
            write_report("fix-duplicates", fix_duplicates())
        elif args.command == "fix-keys":
            write_report("fix-keys", fix_keys())
        elif args.command == "add-key":
            write_report("add-key", add_key(args))
        elif args.command == "kernel-plan":
            print("\n".join(kernel_plan(args.mode, args.items, args.headers)))
    except ToolError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except subprocess.TimeoutExpired as exc:
        print(f"A system command timed out: {exc.cmd[0]}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
