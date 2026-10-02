#!/usr/bin/python3
"""Tests for keyring placement, automatic key discovery and the OS upgrade.

A local HTTP server plays the Debian mirror and a third-party repository, so
nothing on the host or the internet is touched.
"""

import functools
import http.server
import importlib.util
import os
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
ROOT = Path(tempfile.mkdtemp(prefix="eus-smart-test."))
WWW = ROOT / "www"
os.environ["EUS_APT_ROOT"] = str(ROOT)

spec = importlib.util.spec_from_file_location("eus_tool", PROJECT / "src/backend/eduka-update-system-tool.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
tool.progress = lambda *_a, **_k: None


def release(path: str, **fields) -> None:
    target = WWW / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("".join(f"{k}: {v}\n" for k, v in fields.items()))


# ---- fake mirror: trixie (13) is installed, forky (14) became stable ----
release("debian/dists/stable/Release", Origin="Debian", Label="Debian", Suite="stable",
        Version="14.0", Codename="forky")
for suite in ("forky", "forky-updates"):
    release(f"debian/dists/{suite}/InRelease", Origin="Debian", Codename="forky")
release("debian-security/dists/forky-security/InRelease", Origin="Debian", Label="Debian-Security")
release("vendor-a/dists/forky/InRelease", Origin="Vendor A")       # third-party, has forky
release("vendor-b/dists/trixie/InRelease", Origin="Vendor B")      # third-party, no forky

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        pass


handler = functools.partial(QuietHandler, directory=str(WWW))
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_port}"

apt = ROOT / "etc/apt"
(apt / "sources.list.d").mkdir(parents=True)
(apt / "sources.list").write_text(
    f"deb {base}/debian trixie main contrib non-free-firmware\n"
    f"deb {base}/debian trixie-updates main\n"
    f"deb {base}/debian-security trixie-security main\n")
(apt / "sources.list.d/vendor-a.list").write_text(f"deb {base}/vendor-a trixie main\n")
(apt / "sources.list.d/vendor-b.sources").write_text(
    f"Types: deb\nURIs: {base}/vendor-b\nSuites: trixie\nComponents: main\n")
(apt / "sources.list.d/vendor-c.list").write_text(f"deb {base}/vendor-c stable main\n")

lists = ROOT / "var/lib/apt/lists"
lists.mkdir(parents=True)
host = f"127.0.0.1:{server.server_port}"
(lists / f"{host}_debian_dists_trixie_InRelease").write_text(
    "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\nOrigin: Debian\nLabel: Debian\n"
    "Suite: stable\nVersion: 13.1\nCodename: trixie\n")
(lists / f"{host}_debian-security_dists_trixie-security_InRelease").write_text(
    "Origin: Debian\nLabel: Debian-Security\nCodename: trixie-security\n")
(lists / f"{host}_vendor-a_dists_trixie_InRelease").write_text("Origin: Vendor A\n")

# ---- knowledge: roles and the current release ----
repos = {Path(r["file"]).name + r["suites"][0]: r for r in tool.describe_repositories()}
assert repos["sources.listtrixie"]["role"] == "debian", repos
assert repos["sources.listtrixie-security"]["role"] == "debian-security"
assert repos["vendor-a.listtrixie"]["role"] == "third-party"
current = tool.current_release()
assert current["codename"] == "trixie" and current["version"] == "13.1", current

# ---- new stable release is detected ----
state = tool.check_os_upgrade()
assert state["available"] == 1 and state["target_codename"] == "forky", state
assert "available=1" in (ROOT / "var/lib/eus/os-upgrade").read_text()

plan = tool.os_upgrade_plan("forky")
actions = {(Path(r["file"]).name, r["suite"]): r["action"] for r in plan["entries"]}
assert actions[("sources.list", "trixie")] == "switch"
assert actions[("sources.list", "trixie-updates")] == "switch"
assert actions[("sources.list", "trixie-security")] == "switch"
assert actions[("vendor-a.list", "trixie")] == "switch"           # offers forky
assert actions[("vendor-b.sources", "trixie")] == "keep"          # third-party without forky
assert actions[("vendor-c.list", "stable")] == "unchanged"
assert not plan["blocking"], plan

backup = tool.os_switch("forky")
main = (apt / "sources.list").read_text()
assert "debian forky main contrib non-free-firmware" in main and "forky-updates" in main, main
assert "debian-security forky-security main" in main, main
assert "vendor-a forky main" in (apt / "sources.list.d/vendor-a.list").read_text()
assert "Suites: trixie" in (apt / "sources.list.d/vendor-b.sources").read_text()
assert "vendor-c stable main" in (apt / "sources.list.d/vendor-c.list").read_text()
tool.os_restore(backup)
assert "debian trixie main" in (apt / "sources.list").read_text()
assert "vendor-a trixie main" in (apt / "sources.list.d/vendor-a.list").read_text()

# The security archive missing the new suite blocks the upgrade.
shutil.rmtree(WWW / "debian-security/dists/forky-security")
assert tool.os_upgrade_plan("forky")["blocking"]

# ---- keyring placement is decided per repository ----
entries = {(Path(e["file"]).name, e["suites"][0]): e for e in tool.all_entries()}
debian_target = tool.key_target(entries[("sources.list", "trixie")], "0123456789ABCDEF")
assert debian_target["mode"] == "global"
assert debian_target["path"] == "/etc/apt/trusted.gpg.d/eus-0123456789abcdef.gpg", debian_target
third = tool.key_target(entries[("vendor-b.sources", "trixie")], "0123456789ABCDEF")
assert third["mode"] == "add-signed-by" and third["path"] == "/etc/apt/keyrings/vendor-b.gpg", third

(apt / "sources.list.d/vendor-d.list").write_text(
    f"deb [signed-by=/usr/share/keyrings/vendor-d.gpg] {base}/vendor-d stable main\n")
(apt / "sources.list.d/vendor-e.list").write_text(
    f"deb [signed-by=/etc/apt/keyrings/vendor-e.gpg arch=amd64] {base}/vendor-e stable main\n")
entries = {Path(e["file"]).name: e for e in tool.all_entries()}
original_owner = tool.package_owner
tool.package_owner = lambda path: "vendor-d-keyring" if path.startswith("/usr/share/keyrings/") else ""
packaged = tool.key_target(entries["vendor-d.list"], "0123456789ABCDEF")
assert packaged["mode"] == "reinstall" and packaged["package"] == "vendor-d-keyring", packaged
assert packaged["fallback"] == "/etc/apt/keyrings/vendor-d.gpg"
admin = tool.key_target(entries["vendor-e.list"], "0123456789ABCDEF")
assert admin["mode"] == "merge" and admin["path"] == "/etc/apt/keyrings/vendor-e.gpg", admin
tool.package_owner = original_owner

# ---- Signed-By is written correctly in both formats ----
tool.set_signed_by(entries["vendor-e.list"], "/etc/apt/keyrings/new.gpg", "test")
line = (apt / "sources.list.d/vendor-e.list").read_text()
assert "[arch=amd64 signed-by=/etc/apt/keyrings/new.gpg]" in line, line
tool.set_signed_by(entries["vendor-b.sources"], "/etc/apt/keyrings/vendor-b.gpg", "test")
assert "Signed-By: /etc/apt/keyrings/vendor-b.gpg" in (apt / "sources.list.d/vendor-b.sources").read_text()

# ---- automatic key discovery verifies the key ID ----
if shutil.which("gpg"):
    home = tempfile.mkdtemp(prefix="eus-gpg.")
    for uid in ("Vendor B <b@example.org>", "Someone Else <x@example.org>"):
        subprocess.run(["gpg", "--homedir", home, "--batch", "--passphrase", "", "--quick-gen-key",
                        uid, "ed25519", "sign", "1y"], check=True, capture_output=True)
    listing = subprocess.run(["gpg", "--homedir", home, "--with-colons", "--list-keys"],
                             check=True, capture_output=True, text=True).stdout
    fingerprints = [l.split(":")[9] for l in listing.splitlines() if l.startswith("fpr")]
    vendor_fpr, other_fpr = fingerprints[0], fingerprints[1]
    for fpr, name in ((other_fpr, "wrong.key"), (vendor_fpr, "Release.key")):
        key = subprocess.run(["gpg", "--homedir", home, "--armor", "--export", fpr],
                             check=True, capture_output=True).stdout
        (WWW / "vendor-b" / name).write_bytes(key)
    tool.candidate_key_urls = lambda entry: [f"{base}/vendor-b/wrong.key", f"{base}/vendor-b/Release.key"]
    tool.fetch_from_keyserver = lambda keyid: (_ for _ in ()).throw(tool.ToolError("offline"))
    blob, origin = tool.find_signing_key(vendor_fpr[-16:], None)
    assert origin.endswith("/vendor-b/Release.key"), origin          # the wrong key was skipped
    assert tool.key_matches(blob, vendor_fpr[-16:])
    try:
        tool.find_signing_key("00000000DEADBEEF", None)
        raise AssertionError("an unrelated key was accepted")
    except tool.ToolError:
        pass
    shutil.rmtree(home, ignore_errors=True)

server.shutdown()
shutil.rmtree(ROOT, ignore_errors=True)
print('{"smart_tests": "passed"}')
