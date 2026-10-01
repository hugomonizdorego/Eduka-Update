#!/usr/bin/python3
"""Non-destructive tests for eduka-update-system-tool on a fake APT tree."""

import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
ROOT = Path(tempfile.mkdtemp(prefix="eus-tool-test."))
os.environ["EUS_APT_ROOT"] = str(ROOT)

spec = importlib.util.spec_from_file_location(
    "eus_tool", PROJECT / "src/backend/eduka-update-system-tool.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)

apt = ROOT / "etc/apt"
(apt / "sources.list.d").mkdir(parents=True)
(apt / "sources.list").write_text(
    "deb http://deb.debian.org/debian trixie main contrib\n"
    "deb http://security.debian.org/debian-security trixie-security main\n")
(apt / "sources.list.d/vendor.list").write_text(
    "# vendor repository added in a terminal\n"
    "deb [arch=amd64 signed-by=/etc/apt/keyrings/vendor.gpg] https://deb.debian.org/debian/ trixie main non-free\n"
    "deb https://repo.example.org/apt stable main\n"
    "deb https://repo.example.org/apt stable main\n")
(apt / "sources.list.d/debian.sources").write_text(
    "Types: deb\nURIs: http://deb.debian.org/debian\nSuites: trixie\nComponents: main contrib\n\n"
    "Types: deb\nURIs: https://other.example.org/\nSuites: stable\nComponents: main\n")

dups = tool.find_duplicates(tool.all_entries())
summary = [(Path(d["file"]).name, d["line"], d["complete"]) for d in dups]
assert ("vendor.list", 2, False) in summary, summary
assert ("vendor.list", 4, True) in summary, summary
assert ("debian.sources", 1, True) in summary, summary
assert len(dups) == 3, summary

tool.progress = lambda *_a, **_k: None
result = tool.fix_duplicates()
assert len(result["fixed"]) == 3, result
assert not tool.find_duplicates(tool.all_entries()), "duplicates remain after fix"
vendor = (apt / "sources.list.d/vendor.list").read_text()
assert "trixie non-free" in vendor, vendor
assert vendor.count(tool.DISABLED_MARK) == 2, vendor
assert "Enabled: no" in (apt / "sources.list.d/debian.sources").read_text()
assert Path(result["backup"]).is_dir()

problems = tool.apt_problems(
    "W: GPG error: https://repo.example.org/apt stable InRelease: The following signatures "
    "couldn't be verified because the public key is not available: NO_PUBKEY 0123456789ABCDEF\n"
    "E: The repository 'https://repo.example.org/apt stable InRelease' is not signed.\n"
    "W: Target Packages (main/binary-amd64/Packages) is configured multiple times in a and b\n"
    "W: http://x/dists/y/InRelease: Key is stored in legacy trusted.gpg keyring\n")
assert problems["missing_keys"] == [{"keyid": "0123456789ABCDEF",
                                     "url": "https://repo.example.org/apt"}], problems
assert problems["unsigned"] and problems["legacy_warning"]
assert problems["configured_multiple_times"]
blocked = tool.apt_problems(
    "Err:1 http://ppa.example.org/ubuntu noble InRelease\n  403  Forbidden [IP: 1.2.3.4 80]\n"
    "E: Failed to fetch http://ppa.example.org/ubuntu/dists/noble/InRelease  403  Forbidden\n"
    "E: The repository 'http://ppa.example.org/ubuntu noble InRelease' is not signed.\n")
assert not blocked["unsigned"], blocked
assert blocked["unreachable"][0]["url"] == "http://ppa.example.org/ubuntu", blocked

assert tool.kernel_release("linux-image-6.12.38+deb13-amd64") == "6.12.38+deb13-amd64"
assert tool.kernel_release("linux-image-6.8.0-45-generic") == "6.8.0-45-generic"
assert tool.kernel_release("linux-image-unsigned-6.8.0-45-generic") == "6.8.0-45-generic"
assert tool.kernel_release("linux-image-amd64") == ""
assert tool.kernel_flavour("6.12.38+deb13-amd64") == "amd64"
assert tool.kernel_flavour("6.1.0-18-cloud-amd64") == "cloud-amd64"
assert tool.kernel_flavour("6.8.0-45-generic") == "generic"
assert tool.version_key("6.12.10") > tool.version_key("6.12.9")
installed = {"linux-image-6.1.0-18-amd64", "linux-headers-6.1.0-18-amd64",
             "linux-headers-6.1.0-18-common", "linux-image-6.1.0-20-amd64"}
assert sorted(tool.related_packages("6.1.0-18-amd64", installed)) == [
    "linux-headers-6.1.0-18-amd64", "linux-headers-6.1.0-18-common", "linux-image-6.1.0-18-amd64"]

import shutil
import subprocess
from types import SimpleNamespace

if shutil.which("gpg"):
    home = tempfile.mkdtemp(prefix="eus-gpg-test.")
    subprocess.run(["gpg", "--homedir", home, "--batch", "--passphrase", "",
                    "--quick-gen-key", "EUS Test <eus@example.org>", "ed25519", "sign", "1y"],
                   check=True, capture_output=True)
    armored = subprocess.run(["gpg", "--homedir", home, "--armor", "--export"],
                             check=True, capture_output=True).stdout
    key_file = ROOT / "vendor.asc"
    key_file.write_bytes(armored)
    args = SimpleNamespace(name="vendor-tools", file=str(key_file), url=None, keyserver=None,
                           repo_uri="https://tools.example.org/apt", suite="stable",
                           components="main", arch="amd64", with_source=False)
    added = tool.add_key(args)
    keyring = apt / "keyrings/vendor-tools.gpg"
    assert keyring.is_file() and not keyring.read_bytes().startswith(b"-----BEGIN")
    sources = (apt / "sources.list.d/vendor-tools.sources").read_text()
    assert "Signed-By: /etc/apt/keyrings/vendor-tools.gpg" in sources, sources
    # Adding the same repository again must not create a duplicate entry.
    args.name = "vendor-again"
    again = tool.add_key(args)
    assert not (apt / "sources.list.d/vendor-again.sources").exists()
    assert again["warnings"], again
    # A key-only install goes to trusted.gpg.d; secret keys are refused.
    key_only = SimpleNamespace(name="plain", file=str(key_file), url=None, keyserver=None,
                               repo_uri="", suite="", components="", arch="", with_source=False)
    tool.add_key(key_only)
    assert (apt / "trusted.gpg.d/plain.gpg").is_file()
    secret = subprocess.run(["gpg", "--homedir", home, "--batch", "--pinentry-mode", "loopback",
                             "--passphrase", "", "--armor", "--export-secret-keys"],
                            check=True, capture_output=True).stdout
    key_file.write_bytes(secret)
    try:
        tool.add_key(key_only)
        raise AssertionError("secret key was accepted")
    except tool.ToolError:
        pass
    (apt / "trusted.gpg.d/broken.gpg").write_bytes(b"not a key")
    scan = tool.scan_keys()
    broken = [f for f in scan["files"] if f["path"].endswith("broken.gpg")][0]
    assert broken["problems"], broken
    shutil.rmtree(home, ignore_errors=True)

shutil.rmtree(ROOT, ignore_errors=True)
print(json.dumps({"tool_tests": "passed"}))
