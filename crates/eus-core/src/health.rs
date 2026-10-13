//! System Health: detect damage, recommend fixes and useful additions.

use crate::apt::{apt_problems, cached_release, entry_role};
use crate::kernels::{dpkg_packages, list_kernels};
use crate::release::{apply_continuous_stable, check_continuous_release, continuous_entries, continuous_stable_plan};
use crate::sources::{all_entries, find_duplicates, is_field, read_lines, write_lines, Entry};
use crate::util::{self, backup_file, major, progress, require_root, run, run_with, sys, RunOptions, C_LOCALE};
use anyhow::{bail, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

pub const CORE_PACKAGES: [&str; 13] = ["base-files", "bash", "coreutils", "dpkg", "apt", "libc6", "systemd", "sudo",
                                       "login", "util-linux", "passwd", "polkitd", "pkexec"];
pub const RECOMMENDED_INSTALLS: [(&str, &str); 5] = [
    ("install-intel-microcode", "intel-microcode"),
    ("install-amd-microcode", "amd64-microcode"),
    ("install-timeshift", "timeshift"),
    ("install-zram", "zram-tools"),
    ("install-fwupd", "fwupd"),
];
const BASE_FIXES: [&str; 5] = ["dpkg-configure", "fix-broken", "reinstall-damaged", "continuous-stable", "enable-firmware"];

pub fn is_health_fix(id: &str) -> bool {
    BASE_FIXES.contains(&id) || RECOMMENDED_INSTALLS.iter().any(|(fix, _)| *fix == id)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Finding {
    pub id: String,
    pub severity: String,
    pub title: String,
    #[serde(default)]
    pub detail: String,
    #[serde(default)]
    pub fix: String,
    #[serde(default)]
    pub page: String,
}

fn finding(id: &str, severity: &str, title: &str, detail: &str, fix: &str, page: &str) -> Finding {
    Finding { id: id.into(), severity: severity.into(), title: title.into(), detail: detail.into(), fix: fix.into(),
              page: page.into() }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct HealthReport {
    pub checked_at: i64,
    pub status: String,
    pub findings: Vec<Finding>,
    pub recommendations: Vec<Finding>,
}

fn package_candidate(name: &str) -> bool {
    static RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"Candidate: (\S+)").unwrap());
    run_with("apt-cache", &["policy", name], RunOptions { timeout: Some(20), env: C_LOCALE, ..Default::default() })
        .ok()
        .and_then(|o| RE.captures(&o.out()).map(|c| &c[1] != "(none)"))
        .unwrap_or(false)
}

fn installed(name: &str) -> bool {
    dpkg_packages(name).iter().any(|p| p.status == "installed")
}

/// Paths `dpkg --verify` reports as changed (not configuration files) or as
/// missing programs/libraries. Missing documentation is normal (dpkg
/// path-exclude) and ignored.
pub fn damaged_paths(verify_output: &str) -> Vec<String> {
    static LOST_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^/(usr/)?(s?bin|lib|lib64|libexec)/").unwrap());
    let mut paths = Vec::new();
    for line in verify_output.lines() {
        let Some(path) = line.split_whitespace().last() else { continue };
        let bytes = line.as_bytes();
        let changed = bytes.len() > 12 && bytes[2] == b'5' && bytes[10] != b'c';
        let lost = line.starts_with("missing") && LOST_RE.is_match(path);
        if changed || lost {
            paths.push(path.to_string());
        }
    }
    paths
}

/// Core packages whose installed files no longer match (dpkg --verify).
pub fn damaged_core_files() -> Vec<String> {
    let present: Vec<&str> = CORE_PACKAGES.iter().copied().filter(|p| installed(p)).collect();
    if present.is_empty() {
        return vec![];
    }
    let mut args = vec!["--verify"];
    args.extend(present);
    let Ok(output) = run("dpkg", &args, 120) else { return vec![] };
    let mut damaged = BTreeSet::new();
    for path in damaged_paths(&output.out()) {
        if let Ok(owner) = run("dpkg-query", &["-S", &path], 20) {
            let text = owner.out();
            if let Some(name) = text.split(':').next().and_then(|t| t.split(',').next()) {
                if !name.trim().is_empty() {
                    damaged.insert(name.trim().to_string());
                }
            }
        }
    }
    damaged.into_iter().collect()
}

pub fn debian_firmware_missing() -> Vec<Entry> {
    let mut candidates = continuous_entries();
    if candidates.is_empty() {
        candidates = all_entries().into_iter().filter(|e| e.enabled).collect();
    }
    candidates
        .into_iter()
        .filter(|entry| {
            if entry.uris.is_empty() || !entry.types.iter().any(|t| t == "deb") {
                return false;
            }
            let release = if entry.suites.is_empty() { Default::default() } else { cached_release(entry.uri(), entry.suite()) };
            entry_role(entry, &release) == "debian"
                && !entry.suites.iter().any(|s| s.contains('-'))
                && entry.components.iter().any(|c| c == "main")
                && !entry.components.iter().any(|c| c == "non-free-firmware")
        })
        .collect()
}

/// (free, total) bytes of the file system holding `path`.
fn disk_usage(path: &Path) -> Option<(u64, u64)> {
    let text = std::ffi::CString::new(path.to_string_lossy().as_bytes()).ok()?;
    // SAFETY: statvfs fills a zeroed struct we own from a valid C string.
    unsafe {
        let mut stat: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(text.as_ptr(), &mut stat) != 0 {
            return None;
        }
        let block = stat.f_frsize as u64;
        Some((stat.f_bavail as u64 * block, stat.f_blocks as u64 * block))
    }
}

fn is_mount(path: &Path) -> bool {
    match (std::fs::metadata(path), path.parent().map(std::fs::metadata)) {
        (Ok(meta), Some(Ok(parent))) => meta.dev() != parent.dev() || meta.ino() == parent.ino(),
        (Ok(_), None) => true,
        _ => false,
    }
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or("").chars().take(160).collect()
}

pub fn scan_health(deep: bool) -> HealthReport {
    let mut found: Vec<Finding> = Vec::new();

    // 1. Interrupted package operations.
    let audit = run_with("dpkg", &["--audit"], RunOptions { timeout: Some(60), env: C_LOCALE, ..Default::default() })
        .map(|o| o.out().trim().to_string())
        .unwrap_or_default();
    let unfinished: Vec<String> = dpkg_packages("*")
        .into_iter()
        .filter(|p| ["half-installed", "half-configured", "unpacked", "triggers-awaited", "triggers-pending"].contains(&p.status.as_str()))
        .map(|p| p.name)
        .collect();
    if !audit.is_empty() || !unfinished.is_empty() {
        let detail = if unfinished.is_empty() { first_line(&audit) } else { unfinished.iter().take(8).cloned().collect::<Vec<_>>().join(", ") };
        found.push(finding("dpkg-interrupted", "critical", "A package installation was interrupted", &detail, "dpkg-configure", ""));
    }
    // 2. Broken dependencies.
    if let Ok(check) = run_with("apt-get", &["-o", "Debug::NoLocking=1", "check"],
                                RunOptions { timeout: Some(120), env: C_LOCALE, ..Default::default() }) {
        let text = check.all();
        if !check.ok() && (text.contains("Unmet dependencies") || text.to_lowercase().contains("broken")) {
            static RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^\s+(\S+) : Depends").unwrap());
            let packages: Vec<String> = RE.captures_iter(&text).take(8).map(|c| c[1].to_string()).collect();
            found.push(finding("broken-deps", "critical", "Some packages have broken dependencies", &packages.join(", "), "fix-broken", ""));
        }
    }
    // 3. Damaged core files.
    if deep {
        let damaged = damaged_core_files();
        if !damaged.is_empty() {
            found.push(finding("damaged-files", "critical", "Files of core system packages are damaged", &damaged.join(", "),
                               "reinstall-damaged", ""));
        }
    }
    // 4. Disk space.
    for (mount, minimum) in [("/", 2u64 << 30), ("/boot", 80u64 << 20), ("/var", 1u64 << 30)] {
        let path = sys(mount);
        let Some((free, total)) = disk_usage(&path) else { continue };
        if mount != "/" && !is_mount(&path) {
            continue;
        }
        if free < minimum || (free as f64) < total as f64 * 0.08 {
            let id = format!("disk-{}", if mount == "/" { "root" } else { mount.trim_matches('/') });
            let detail = format!("{:.1} GB free of {:.1} GB", free as f64 / (1u64 << 30) as f64, total as f64 / (1u64 << 30) as f64);
            found.push(finding(&id, "warning", &format!("Low disk space on {mount}"), &detail, "", "cleaner"));
        }
    }
    // 5. Failed services.
    if util::which("systemctl") && Path::new("/run/systemd/system").is_dir() {
        if let Ok(failed) = run_with("systemctl", &["--failed", "--no-legend", "--plain"],
                                     RunOptions { timeout: Some(20), env: C_LOCALE, ..Default::default() }) {
            let units: Vec<String> = failed.out().lines().filter_map(|l| l.split_whitespace().next().map(str::to_string)).collect();
            if !units.is_empty() {
                found.push(finding("failed-units", "warning", "System services failed to start",
                                   &units.iter().take(8).cloned().collect::<Vec<_>>().join(", "), "", ""));
            }
        }
    }
    // 6. Repositories.
    let problems = apt_problems(None);
    if !problems.missing_keys.is_empty() || !problems.expired_keys.is_empty() || !problems.unsigned.is_empty() {
        found.push(finding("repo-keys", "warning", "Some repositories cannot be verified", "missing or expired GPG keys", "", "key-fix"));
    }
    if !problems.configured_multiple_times.is_empty() || !find_duplicates(&all_entries()).is_empty() {
        found.push(finding("repo-duplicates", "info", "Duplicate repository entries", "", "", "key-fix"));
    }
    if !problems.unreachable.is_empty() {
        let urls: Vec<String> = problems.unreachable.iter().take(3).map(|u| u.url.clone()).collect();
        found.push(finding("repo-unreachable", "info", "Some repositories cannot be reached", &urls.join(", "), "", ""));
    }
    // 7. Release policy: Edukasaun OS follows codename-free "stable".
    let plan = continuous_stable_plan();
    if !plan.is_empty() {
        let suites: BTreeSet<String> = plan.iter().map(|r| r.suite.clone()).collect();
        found.push(finding("codename-repos", "info", "Debian repositories use a release codename",
                           &format!("Switch them to 'stable' so Edukasaun OS keeps updating continuously: {}",
                                    suites.into_iter().collect::<Vec<_>>().join(", ")),
                           "continuous-stable", ""));
    }
    if let Some(release) = check_continuous_release() {
        if release.get("available").and_then(Value::as_i64) == Some(1) {
            let version = release.get("target_version").and_then(Value::as_str).unwrap_or("");
            let codename = release.get("target_codename").and_then(Value::as_str).unwrap_or("");
            found.push(finding("major-update", "info",
                               &format!("Major system update available: Debian {} \"{codename}\"", major(version)), "", "", "updates"));
        }
    }
    // 8. Kernels.
    let kernels = list_kernels(false);
    let old: Vec<String> = kernels.installed.iter().filter(|k| k.state == "old" || k.state == "residual").map(|k| k.release.clone()).collect();
    let newer: Vec<String> = kernels.installed.iter().filter(|k| k.state == "newer").map(|k| k.release.clone()).collect();
    if let Some(first) = newer.first() {
        found.push(finding("kernel-restart", "warning", "A newer kernel is installed but not running",
                           &format!("Restart to use {first}"), "", "restart"));
    }
    if old.len() >= 2 {
        found.push(finding("old-kernels", "info", &format!("{} old kernels use disk space", old.len()), &old.join(", "), "", "kernels"));
    }
    // 9. Held packages.
    let held: Vec<String> = run("apt-mark", &["showhold"], 20)
        .map(|o| o.out().split_whitespace().map(str::to_string).collect())
        .unwrap_or_default();
    if !held.is_empty() {
        found.push(finding("held", "info", "Some packages are held back", &held.iter().take(8).cloned().collect::<Vec<_>>().join(", "), "", ""));
    }

    // Recommendations.
    let mut recommendations = Vec::new();
    let cpuinfo = util::read_text(Path::new("/proc/cpuinfo")).unwrap_or_default();
    for (vendor, fix, package) in [("GenuineIntel", "install-intel-microcode", "intel-microcode"),
                                   ("AuthenticAMD", "install-amd-microcode", "amd64-microcode")] {
        if cpuinfo.contains(vendor) && !installed(package) && package_candidate(package) {
            recommendations.push(finding(fix, "recommend", "Install CPU microcode updates",
                                         &format!("{package} fixes processor bugs and security issues"), fix, ""));
        }
    }
    if !installed("timeshift") && package_candidate("timeshift") {
        recommendations.push(finding("install-timeshift", "recommend", "Install Timeshift",
                                     "System snapshots let you undo a bad update", "install-timeshift", ""));
    }
    static MEM_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"MemTotal:\s+(\d+)").unwrap());
    let total_kb: u64 = util::read_text(Path::new("/proc/meminfo"))
        .and_then(|t| MEM_RE.captures(&t).and_then(|c| c[1].parse().ok()))
        .unwrap_or(0);
    let has_swap = util::read_text(Path::new("/proc/swaps")).map(|t| t.trim().lines().count() > 1).unwrap_or(true);
    if total_kb > 0 && total_kb < 4 * 1024 * 1024 && !has_swap && !installed("zram-tools") && package_candidate("zram-tools") {
        recommendations.push(finding("install-zram", "recommend", "Enable compressed memory (zram)",
                                     "Less than 4 GB of RAM and no swap", "install-zram", ""));
    }
    if !installed("fwupd") && package_candidate("fwupd") && Path::new("/sys/firmware/efi").exists() {
        recommendations.push(finding("install-fwupd", "recommend", "Install firmware updates (fwupd)",
                                     "Updates BIOS/UEFI and device firmware from LVFS", "install-fwupd", ""));
    }
    if !debian_firmware_missing().is_empty() {
        recommendations.push(finding("enable-firmware", "recommend", "Enable the non-free-firmware component",
                                     "Needed for Wi-Fi, graphics and CPU firmware", "enable-firmware", ""));
    }

    let rank = |severity: &str| match severity {
        "critical" => 0,
        "warning" => 1,
        "info" => 2,
        "recommend" => 3,
        _ => 9,
    };
    found.sort_by_key(|f| rank(&f.severity));
    let status = if found.iter().any(|f| f.severity == "critical") {
        "critical"
    } else if found.iter().any(|f| f.severity == "warning") {
        "warning"
    } else {
        "ok"
    };
    HealthReport { checked_at: util::now(), status: status.into(), findings: found, recommendations }
}

pub fn save_health(data: &HealthReport) {
    if let Ok(text) = serde_json::to_string_pretty(data) {
        let _ = util::atomic_write(&util::health_file(), text.as_bytes(), 0o644);
    }
}

pub fn load_health() -> Option<HealthReport> {
    serde_json::from_str(&util::read_text(&util::health_file())?).ok()
}

pub fn enable_firmware_component() -> Result<Vec<String>> {
    let stamp = format!("firmware-{}", util::stamp());
    let mut changed = Vec::new();
    for entry in debian_firmware_missing() {
        let path = PathBuf::from(&entry.file);
        let mut lines = read_lines(&path);
        if entry.is_list() {
            lines[entry.line] = format!("{} non-free-firmware", lines[entry.line].trim_end());
        } else {
            for line in lines.iter_mut().take(entry.last_line).skip(entry.line) {
                if is_field(line, "components") {
                    *line = format!("{} non-free-firmware", line.trim_end());
                }
            }
        }
        backup_file(&path, &stamp)?;
        write_lines(&path, &lines)?;
        changed.push(entry.file.clone());
    }
    Ok(changed)
}

const APT_ARGS: [&str; 8] = ["-y", "-q", "-o", "DPkg::Lock::Timeout=120", "-o", "Dpkg::Options::=--force-confdef",
                             "-o", "Dpkg::Options::=--force-confold"];

fn apt_get(extra: &[&str], timeout: u64) -> Result<bool> {
    let mut args: Vec<&str> = APT_ARGS.to_vec();
    args.extend_from_slice(extra);
    Ok(run_with("apt-get", &args, RunOptions { timeout: Some(timeout), env: util::APT_ENV, ..Default::default() })?.ok())
}

/// Apply the selected System Health fixes (root, through the backend).
pub fn fix_health(ids: &[String]) -> Result<Value> {
    require_root()?;
    let mut order: Vec<&str> = BASE_FIXES.to_vec();
    order.extend(RECOMMENDED_INSTALLS.iter().map(|(fix, _)| *fix));
    let selected: Vec<&str> = order.into_iter().filter(|i| ids.iter().any(|x| x == i)).collect();
    let mut done = Vec::new();
    let mut errors = Vec::new();
    let mut need_update = false;
    for (index, id) in selected.iter().enumerate() {
        progress(5 + (index * 85 / selected.len().max(1)) as i64, &format!("Fixing: {id}"));
        let outcome: Result<()> = (|| {
            match *id {
                "dpkg-configure" => {
                    let output = run_with("dpkg", &["--configure", "-a"], RunOptions { timeout: Some(3600), env: util::APT_ENV, ..Default::default() })?;
                    if !output.ok() {
                        bail!("dpkg --configure -a failed");
                    }
                }
                "fix-broken" => {
                    if !apt_get(&["--fix-broken", "install"], 3600)? {
                        bail!("apt-get --fix-broken install failed");
                    }
                }
                "reinstall-damaged" => {
                    let damaged = damaged_core_files();
                    if !damaged.is_empty() {
                        let mut args = vec!["install", "--reinstall"];
                        args.extend(damaged.iter().map(String::as_str));
                        if !apt_get(&args, 3600)? {
                            bail!("reinstalling {} failed", damaged.join(", "));
                        }
                    }
                }
                "continuous-stable" => {
                    apply_continuous_stable()?;
                    need_update = true;
                }
                "enable-firmware" => {
                    enable_firmware_component()?;
                    need_update = true;
                }
                other => {
                    let Some((_, package)) = RECOMMENDED_INSTALLS.iter().find(|(fix, _)| *fix == other) else { return Ok(()) };
                    if need_update {
                        let _ = run_with("apt-get", &["-q", "update"], RunOptions { timeout: Some(900), env: util::APT_ENV, ..Default::default() });
                        need_update = false;
                    }
                    if !apt_get(&["install", package], 3600)? {
                        bail!("installing {package} failed");
                    }
                }
            }
            Ok(())
        })();
        match outcome {
            Ok(()) => done.push(id.to_string()),
            Err(error) => errors.push(format!("{id}: {error}")),
        }
    }
    progress(95, "Verifying repositories...");
    save_health(&scan_health(false));
    progress(100, "Complete.");
    Ok(json!({"fixed": done, "errors": errors, "refresh": need_update}))
}
