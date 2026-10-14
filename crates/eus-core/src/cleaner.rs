//! System cleaner (ideas from ubuntu-cleaner's janitor plugins, GPL-3+).

use crate::kernels::{dpkg_packages, kernel_plan, list_kernels, simulated_removals};
use crate::util::{self, progress, require_root, run, run_with, sys, RunOptions, C_LOCALE};
use anyhow::{anyhow, bail, Result};
use regex::Regex;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

static ROTATED_LOG_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^.*\.(\d+|\d+\.gz|gz|old|xz|bz2)$").unwrap());

/// Cache directories that are safe to empty (applications rebuild them).
pub const USER_CACHES: &[(&str, &str, &[&str])] = &[
    ("thumbnails", "Thumbnail cache", &["~/.cache/thumbnails", "~/.thumbnails"]),
    ("firefox", "Firefox cache", &["~/.cache/mozilla/firefox/*/cache2",
                                    "~/snap/firefox/common/.cache/mozilla/firefox/*/cache2",
                                    "~/.var/app/org.mozilla.firefox/cache/mozilla/firefox/*/cache2"]),
    ("thunderbird", "Thunderbird cache", &["~/.cache/thunderbird/*/cache2"]),
    ("chrome", "Google Chrome cache", &["~/.cache/google-chrome/*/Cache", "~/.cache/google-chrome/*/Code Cache"]),
    ("chromium", "Chromium cache", &["~/.cache/chromium/*/Cache", "~/.cache/chromium/*/Code Cache",
                                      "~/snap/chromium/common/.cache/chromium/*/Cache"]),
    ("brave", "Brave cache", &["~/.cache/BraveSoftware/Brave-Browser/*/Cache",
                                "~/.cache/BraveSoftware/Brave-Browser/*/Code Cache"]),
    ("edge", "Microsoft Edge cache", &["~/.cache/microsoft-edge*/*/Cache", "~/.cache/microsoft-edge*/*/Code Cache"]),
    ("opera", "Opera cache", &["~/.cache/opera/Cache", "~/.opera/cache"]),
    ("pip", "Python pip cache", &["~/.cache/pip"]),
    ("trash", "Trash", &["~/.local/share/Trash/files", "~/.local/share/Trash/info"]),
];
const USER_DEFAULT_OFF: [&str; 2] = ["trash", "pip"];

#[derive(Debug, Clone, Serialize)]
pub struct CleanItem {
    pub id: String,
    pub title: String,
    pub scope: String,
    pub size: u64,
    pub detail: String,
    pub default: bool,
}

fn item(id: &str, title: &str, scope: &str, size: u64, detail: String, default: bool) -> CleanItem {
    CleanItem { id: id.into(), title: title.into(), scope: scope.into(), size, detail, default }
}

/// Total size of the files below a directory (symlinks are not followed).
pub fn dir_size(path: &Path) -> u64 {
    let mut total = 0;
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(read) = std::fs::read_dir(&dir) else { continue };
        for entry in read.flatten() {
            let Ok(meta) = entry.path().symlink_metadata() else { continue };
            if meta.is_dir() {
                stack.push(entry.path());
            } else {
                total += meta.len();
            }
        }
    }
    total
}

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

fn user_cache_dirs(patterns: &[&str]) -> Vec<PathBuf> {
    let home = home_dir();
    let mut found: Vec<PathBuf> = Vec::new();
    for pattern in patterns {
        let expanded = pattern.replacen('~', &home.to_string_lossy(), 1);
        let Ok(matches) = glob::glob(&expanded) else { continue };
        for path in matches.flatten() {
            let is_link = path.symlink_metadata().map(|m| m.file_type().is_symlink()).unwrap_or(true);
            if path.is_dir() && !is_link && !found.contains(&path) {
                found.push(path);
            }
        }
    }
    found
}

pub fn scan_user() -> Vec<CleanItem> {
    USER_CACHES
        .iter()
        .filter_map(|(id, title, patterns)| {
            let dirs = user_cache_dirs(patterns);
            let size: u64 = dirs.iter().map(|d| dir_size(d)).sum();
            (size > 0).then(|| {
                let detail = dirs.iter().take(3).map(|d| d.to_string_lossy().to_string()).collect::<Vec<_>>().join(", ");
                item(id, title, "user", size, detail, !USER_DEFAULT_OFF.contains(id))
            })
        })
        .collect()
}

/// Empty the selected per-user caches. Never runs as root.
pub fn clean_user(ids: &[String]) -> Result<Value> {
    if util::is_root() && util::root().is_empty() {
        bail!("User caches are cleaned as the user, not as root.");
    }
    let home = home_dir().canonicalize().unwrap_or_else(|_| home_dir());
    let mut freed = 0;
    let mut cleaned = Vec::new();
    for (id, title, patterns) in USER_CACHES {
        if !ids.iter().any(|i| i == id) {
            continue;
        }
        for directory in user_cache_dirs(patterns) {
            let Ok(resolved) = directory.canonicalize() else { continue };
            if !resolved.starts_with(&home) || resolved == home {
                continue;
            }
            freed += dir_size(&resolved);
            if let Ok(read) = std::fs::read_dir(&resolved) {
                for child in read.flatten() {
                    let path = child.path();
                    let is_dir = path.symlink_metadata().map(|m| m.is_dir()).unwrap_or(false);
                    let _ = if is_dir { std::fs::remove_dir_all(&path) } else { std::fs::remove_file(&path) };
                }
            }
        }
        cleaned.push(*title);
    }
    Ok(json!({"freed": freed, "cleaned": cleaned}))
}

#[derive(Debug, Clone)]
pub struct Removable {
    pub name: String,
    pub size: u64,
}

/// Packages `apt-get autoremove` would remove (simulated, unprivileged).
pub fn autoremove_candidates() -> Vec<Removable> {
    let Ok(output) = run_with("apt-get", &["-s", "-o", "Debug::NoLocking=1", "autoremove", "--purge"],
                              RunOptions { timeout: Some(120), env: C_LOCALE, ..Default::default() }) else { return vec![] };
    let names = simulated_removals(&output.out());
    if names.is_empty() {
        return vec![];
    }
    let sizes: HashMap<String, u64> = dpkg_packages("*").into_iter().map(|p| (p.name, p.size_kb)).collect();
    names
        .into_iter()
        .map(|name| {
            let size = sizes.get(name.split(':').next().unwrap_or("")).copied().unwrap_or(0) * 1024;
            Removable { name, size }
        })
        .collect()
}

pub fn residual_configs() -> Vec<String> {
    dpkg_packages("*").into_iter().filter(|p| p.status == "config-files").map(|p| p.name).collect()
}

pub fn rotated_logs() -> Vec<PathBuf> {
    let mut logs = Vec::new();
    let mut stack = vec![sys("/var/log")];
    while let Some(dir) = stack.pop() {
        let Ok(read) = std::fs::read_dir(&dir) else { continue };
        for entry in read.flatten() {
            let path = entry.path();
            let Ok(meta) = path.symlink_metadata() else { continue };
            if meta.is_dir() {
                stack.push(path);
            } else if ROTATED_LOG_RE.is_match(&entry.file_name().to_string_lossy()) {
                logs.push(path);
            }
        }
    }
    logs.sort();
    logs
}

pub fn journal_size() -> u64 {
    static RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"take up ([\d.]+)([KMGT]?)").unwrap());
    if !util::which("journalctl") {
        return 0;
    }
    let Ok(output) = run("journalctl", &["--disk-usage"], 20) else { return 0 };
    let text = output.out();
    let Some(caps) = RE.captures(&text) else { return 0 };
    let unit: u64 = match &caps[2] {
        "K" => 1 << 10,
        "M" => 1 << 20,
        "G" => 1 << 30,
        "T" => 1 << 40,
        _ => 1,
    };
    (caps[1].parse::<f64>().unwrap_or(0.0) * unit as f64) as u64
}

fn files_in(dir: &Path, suffix: &str) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .map(|read| {
            read.flatten()
                .map(|e| e.path())
                .filter(|p| p.is_file() && p.to_string_lossy().ends_with(suffix))
                .collect()
        })
        .unwrap_or_default()
}

fn size_of(paths: &[PathBuf]) -> u64 {
    paths.iter().filter_map(|p| std::fs::metadata(p).ok()).map(|m| m.len()).sum()
}

fn summary(names: &[String]) -> String {
    let mut text = names.iter().take(8).cloned().collect::<Vec<_>>().join(", ");
    if names.len() > 8 {
        text.push_str(" …");
    }
    text
}

pub fn scan_system() -> Vec<CleanItem> {
    let mut items = Vec::new();
    let debs = files_in(&sys("/var/cache/apt/archives"), ".deb");
    if !debs.is_empty() {
        items.push(item("apt-cache", "Downloaded package files (APT cache)", "system", size_of(&debs),
                        format!("{} files in /var/cache/apt/archives", debs.len()), true));
    }
    let unneeded: Vec<Removable> = autoremove_candidates().into_iter().filter(|p| !p.name.starts_with("linux-image")).collect();
    if !unneeded.is_empty() {
        let names: Vec<String> = unneeded.iter().map(|p| p.name.clone()).collect();
        items.push(item("autoremove", "Packages that are no longer needed", "system",
                        unneeded.iter().map(|p| p.size).sum(), summary(&names), true));
    }
    let configs = residual_configs();
    if !configs.is_empty() {
        items.push(item("configs", "Leftover configuration of removed packages", "system", 0, summary(&configs), true));
    }
    let old: Vec<_> = list_kernels(false).installed.into_iter().filter(|k| k.state == "old").collect();
    if !old.is_empty() {
        items.push(item("old-kernels", "Old kernels (the running kernel is kept)", "system",
                        old.iter().map(|k| k.size_kb).sum::<u64>() * 1024,
                        old.iter().map(|k| k.release.clone()).collect::<Vec<_>>().join(", "), true));
    }
    let logs = rotated_logs();
    if !logs.is_empty() {
        items.push(item("logs", "Old rotated log files", "system", size_of(&logs), format!("{} files in /var/log", logs.len()), true));
    }
    let crashes = files_in(&sys("/var/crash"), "");
    if !crashes.is_empty() {
        items.push(item("crash", "Crash reports", "system", size_of(&crashes), "/var/crash".into(), true));
    }
    let size = journal_size();
    if size > 64 * 1024 * 1024 {
        items.push(item("journal", "System journal older than 2 weeks", "system", size,
                        "journalctl --vacuum-time=2weeks".into(), false));
    }
    if util::which("flatpak") {
        items.push(item("flatpak", "Unused Flatpak runtimes", "system", 0, "flatpak uninstall --unused".into(), false));
    }
    items
}

const APT_ARGS: [&str; 8] = ["-y", "-q", "-o", "DPkg::Lock::Timeout=120", "-o", "Dpkg::Options::=--force-confdef",
                             "-o", "Dpkg::Options::=--force-confold"];

fn apt_get(extra: &[String], timeout: u64) -> Result<bool> {
    let mut args: Vec<String> = APT_ARGS.iter().map(|s| s.to_string()).collect();
    args.extend_from_slice(extra);
    Ok(run_with("apt-get", &args, RunOptions { timeout: Some(timeout), env: util::APT_ENV, ..Default::default() })?.ok())
}

fn strings(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

/// Clean the selected system items (root, called by the backend).
pub fn clean_system(ids: &[String]) -> Result<Value> {
    require_root()?;
    let order = ["old-kernels", "autoremove", "configs", "apt-cache", "logs", "crash", "journal", "flatpak"];
    let selected: Vec<&str> = order.iter().copied().filter(|i| ids.iter().any(|x| x == i)).collect();
    let mut done = Vec::new();
    let mut errors = Vec::new();
    for (index, id) in selected.iter().enumerate() {
        progress(5 + (index * 90 / selected.len().max(1)) as i64, &format!("Cleaning: {id}"));
        let outcome: Result<()> = (|| {
            match *id {
                "old-kernels" => {
                    let old: Vec<String> =
                        list_kernels(false).installed.into_iter().filter(|k| k.state == "old").map(|k| k.release).collect();
                    if !old.is_empty() {
                        let mut args = strings(&["purge"]);
                        args.extend(kernel_plan("remove", &old, false)?);
                        if !apt_get(&args, 1800)? {
                            bail!("old kernels could not be removed");
                        }
                    }
                }
                "autoremove" => {
                    if !apt_get(&strings(&["autoremove", "--purge"]), 1800)? {
                        bail!("apt-get autoremove failed");
                    }
                }
                "configs" => {
                    let configs = residual_configs();
                    if !configs.is_empty() {
                        let mut args = strings(&["--purge"]);
                        args.extend(configs);
                        let output = run_with("dpkg", &args, RunOptions { timeout: Some(600), env: util::APT_ENV, ..Default::default() })?;
                        if !output.ok() {
                            bail!("residual configuration could not be purged");
                        }
                    }
                }
                "apt-cache" => {
                    apt_get(&strings(&["clean"]), 300)?;
                }
                "logs" => {
                    for path in rotated_logs() {
                        let _ = std::fs::remove_file(path);
                    }
                }
                "crash" => {
                    for path in files_in(&sys("/var/crash"), "") {
                        let _ = std::fs::remove_file(path);
                    }
                }
                "journal" if util::which("journalctl") => {
                    run("journalctl", &["--vacuum-time=2weeks"], 300)?;
                }
                "flatpak" if util::which("flatpak") => {
                    run("flatpak", &["uninstall", "--unused", "--system", "-y", "--noninteractive"], 1800)?;
                }
                _ => {}
            }
            Ok(())
        })();
        match outcome {
            Ok(()) => done.push(id.to_string()),
            Err(error) => errors.push(format!("{id}: {error}")),
        }
    }
    progress(100, "Complete.");
    Ok(json!({"cleaned": done, "errors": errors}))
}

/// New changelog entries of a package (apt-get changelog uses the archive's
/// Changelogs URI from the Release file, so it works for Debian and others).
pub fn changelog(package: &str, installed: &str, limit: usize) -> Result<String> {
    static NAME_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-z0-9][a-z0-9+.:-]*$").unwrap());
    static FETCH_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(Get|Hit|Ign|Err):\d+ ").unwrap());
    static HEADER_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\S+ \(([^)]+)\) ").unwrap());
    if !NAME_RE.is_match(package) {
        bail!("Invalid package name.");
    }
    let output = run_with("apt-get", &["changelog", "-q", package],
                          RunOptions { timeout: Some(40), env: &[("LC_ALL", "C"), ("PAGER", "cat")], ..Default::default() })?;
    let text = output.out();
    if !output.ok() || text.trim().is_empty() {
        return Err(anyhow!("No changelog is available for this update."));
    }
    let plain_installed = installed.split_once(':').map(|(_, v)| v).unwrap_or(installed);
    let mut lines: Vec<&str> = Vec::new();
    for line in text.lines() {
        if lines.is_empty() && FETCH_RE.is_match(line) {
            continue;
        }
        if let Some(caps) = HEADER_RE.captures(line) {
            let version = &caps[1];
            let version = version.split_once(':').map(|(_, v)| v).unwrap_or(version);
            if !installed.is_empty() && installed != "-" && version == plain_installed {
                break;
            }
        }
        lines.push(line);
        if lines.len() >= limit {
            lines.push("…");
            break;
        }
    }
    Ok(lines.join("\n").trim().to_string())
}
