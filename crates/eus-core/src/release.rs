//! Debian release tracking: codename upgrades and the continuous 'stable' policy.

use crate::apt::{cached_release, entry_role, http_get, release_fields, url_exists};
use crate::keys::DISTRO_ROLES;
use crate::sources::{all_entries, read_lines, rewrite_suites, source_files, write_lines, Entry};
use crate::util::{self, atomic_write, backup_file, major, require_root, sys};
use anyhow::{bail, Result};
use regex::Regex;
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

pub const CONTINUOUS_SUFFIXES: [&str; 5] = ["", "-updates", "-security", "-backports", "-proposed-updates"];

pub fn debian_name(major: i64) -> String {
    match major {
        10 => "buster".into(),
        11 => "bullseye".into(),
        12 => "bookworm".into(),
        13 => "trixie".into(),
        14 => "forky".into(),
        15 => "duke".into(),
        0 => String::new(),
        other => format!("Debian {other}"),
    }
}

pub fn os_release() -> BTreeMap<String, String> {
    let mut data = BTreeMap::new();
    if let Some(text) = util::read_text(&sys("/etc/os-release")) {
        for line in text.lines() {
            if let Some((key, value)) = line.split_once('=') {
                data.insert(key.to_string(), value.trim().trim_matches('"').to_string());
            }
        }
    }
    data
}

pub fn installed_debian_version() -> String {
    let value = util::read_text(&sys("/etc/debian_version")).unwrap_or_default().trim().to_string();
    if value.starts_with(|c: char| c.is_ascii_digit()) { value } else { String::new() }
}

#[derive(Debug, Clone, Default)]
pub struct CurrentRelease {
    pub codename: String,
    pub suite: String,
    pub version: String,
    pub uri: String,
}

/// The Debian release the system is based on, from APT's own metadata.
pub fn current_release() -> Option<CurrentRelease> {
    let mut best: Option<CurrentRelease> = None;
    for entry in all_entries() {
        if !entry.enabled || !entry.types.iter().any(|t| t == "deb") || entry.uris.is_empty() {
            continue;
        }
        for suite in &entry.suites {
            if suite.contains('-') || suite.contains('/') {
                continue;
            }
            let release = cached_release(entry.uri(), suite);
            if entry_role(&entry, &release) != "debian" {
                continue;
            }
            let candidate = CurrentRelease {
                codename: release.get("Codename").cloned().unwrap_or_else(|| suite.clone()),
                suite: suite.clone(),
                version: release.get("Version").cloned().unwrap_or_default(),
                uri: entry.uri().trim_end_matches('/').to_string(),
            };
            if best.as_ref().is_none_or(|b| b.version.is_empty() && !candidate.version.is_empty()) {
                best = Some(candidate);
            }
        }
    }
    if let Some(best) = best.as_mut() {
        if best.version.is_empty() {
            best.version = installed_debian_version();
        }
    }
    best
}

fn value_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.replace('\n', " "),
        other => other.to_string(),
    }
}

pub fn write_os_state(state: &Map<String, Value>) -> Result<()> {
    let lines: Vec<String> = state.iter().map(|(k, v)| format!("{k}={}", value_text(v))).collect();
    atomic_write(&util::os_upgrade_file(), format!("{}\n", lines.join("\n")).as_bytes(), 0o644)
}

/// Enabled Debian entries that use the codename-free 'stable' suite.
pub fn continuous_entries() -> Vec<Entry> {
    all_entries()
        .into_iter()
        .filter(|entry| {
            if !entry.enabled || entry.uris.is_empty() || !entry.types.iter().any(|t| t == "deb") {
                return false;
            }
            let release = if entry.suites.is_empty() { BTreeMap::new() } else { cached_release(entry.uri(), entry.suite()) };
            ["debian", "debian-security"].contains(&entry_role(entry, &release))
                && entry.suites.iter().any(|s| s == "stable" || s.starts_with("stable-"))
        })
        .collect()
}

/// With 'stable' repositories a new Debian release arrives as package
/// updates. Detect it by comparing the archive's version with the installed
/// base, so EUS can present it as one major system update.
pub fn check_continuous_release() -> Option<Map<String, Value>> {
    let main = continuous_entries().into_iter().find(|e| e.suites.iter().any(|s| s == "stable"))?;
    let archive = cached_release(main.uri(), "stable");
    let installed = installed_debian_version();
    let current_major = major(&installed);
    let target_version = archive.get("Version").cloned().unwrap_or_default();
    let mut state = Map::new();
    state.insert("mode".into(), "continuous".into());
    state.insert("current_version".into(), installed.clone().into());
    state.insert("current_codename".into(), debian_name(current_major).into());
    state.insert("target_codename".into(), archive.get("Codename").cloned().unwrap_or_default().into());
    state.insert("target_version".into(), target_version.clone().into());
    let mut available = 0;
    let mut reason = String::new();
    if archive.is_empty() {
        reason = "the stable package lists have not been downloaded yet".into();
    } else if current_major != 0 && major(&target_version) > current_major {
        available = 1;
    }
    state.insert("available".into(), available.into());
    state.insert("reason".into(), reason.into());
    Some(state)
}

/// Ask the Debian mirror which release is stable now and compare.
pub fn check_os_upgrade() -> Result<Map<String, Value>> {
    let info = os_release();
    let mut state = Map::new();
    state.insert("available".into(), 0.into());
    state.insert("os_name".into(), info.get("PRETTY_NAME").cloned().unwrap_or_else(|| "Edukasaun OS".into()).into());
    state.insert("checked_at".into(), util::now().into());
    for key in ["current_codename", "current_version", "target_codename", "target_version", "reason"] {
        state.insert(key.into(), "".into());
    }
    if let Some(continuous) = check_continuous_release() {
        // Edukasaun OS: a new Debian stable is a major system update.
        state.extend(continuous);
        write_os_state(&state)?;
        return Ok(state);
    }
    match current_release() {
        None => {
            state.insert("reason".into(), "no Debian repository is configured".into());
        }
        Some(current) if ["stable", "testing", "unstable", "sid", "oldstable"].contains(&current.suite.as_str()) => {
            state.insert("reason".into(), format!("repositories follow the '{}' suite", current.suite).into());
            state.insert("current_codename".into(), current.codename.into());
        }
        Some(current) => {
            state.insert("current_codename".into(), current.codename.clone().into());
            state.insert("current_version".into(), current.version.clone().into());
            let mut stable = BTreeMap::new();
            for name in ["Release", "InRelease"] {
                match http_get(&format!("{}/dists/stable/{name}", current.uri), 4 * 1024 * 1024, 25) {
                    Ok(data) => {
                        stable = release_fields(&String::from_utf8_lossy(&data));
                        break;
                    }
                    Err(error) => {
                        state.insert("reason".into(), error.to_string().into());
                    }
                }
            }
            if let Some(codename) = stable.get("Codename") {
                let version = stable.get("Version").cloned().unwrap_or_default();
                state.insert("target_codename".into(), codename.clone().into());
                state.insert("target_version".into(), version.clone().into());
                state.insert("reason".into(), "".into());
                if *codename != current.codename && major(&version) > major(&current.version) {
                    state.insert("available".into(), 1.into());
                }
            }
        }
    }
    write_os_state(&state)?;
    Ok(state)
}

pub fn map_suite(suite: &str, old: &str, new: &str) -> String {
    if suite == old {
        return new.to_string();
    }
    for separator in ['-', '/'] {
        if suite.starts_with(&format!("{old}{separator}")) {
            return format!("{new}{}", &suite[old.len()..]);
        }
    }
    String::new()
}

#[derive(Debug, Clone, Serialize)]
pub struct PlanRow {
    pub file: String,
    pub line: usize,
    pub uri: String,
    pub suite: String,
    pub new_suite: String,
    pub role: String,
    pub action: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub note: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct UpgradePlan {
    pub current: String,
    pub current_version: String,
    pub target: String,
    pub entries: Vec<PlanRow>,
    pub blocking: Vec<PlanRow>,
}

pub fn os_upgrade_plan(target: &str) -> Result<UpgradePlan> {
    let Some(current) = current_release() else {
        bail!("No Debian repository is configured; the base release is unknown.");
    };
    let old = current.codename.clone();
    let mut plan = UpgradePlan { current: old.clone(), current_version: current.version, target: target.into(),
                                 entries: vec![], blocking: vec![] };
    for entry in all_entries() {
        if !entry.enabled || entry.uris.is_empty() {
            continue;
        }
        let uri = entry.uri().trim_end_matches('/').to_string();
        let release = if entry.suites.is_empty() { BTreeMap::new() } else { cached_release(&uri, entry.suite()) };
        let role = entry_role(&entry, &release);
        for suite in &entry.suites {
            let new = map_suite(suite, &old, target);
            let mut row = PlanRow { file: entry.file.clone(), line: entry.display_line(), uri: uri.clone(),
                                    suite: suite.clone(), new_suite: new.clone(), role: role.into(),
                                    action: String::new(), note: String::new() };
            if new.is_empty() {
                row.action = "unchanged".into();
                row.note = "suite is not tied to the release codename".into();
            } else if url_exists(&format!("{uri}/dists/{new}/InRelease"), 15)
                || url_exists(&format!("{uri}/dists/{new}/Release"), 15)
            {
                row.action = "switch".into();
            } else if DISTRO_ROLES.contains(&role) {
                row.action = "missing".into();
                row.note = format!("the distribution repository has no '{new}' suite yet");
                plan.blocking.push(row.clone());
            } else {
                row.action = "keep".into();
                row.note = format!("third-party repository has no '{new}' suite; left on '{suite}'");
            }
            plan.entries.push(row);
        }
    }
    Ok(plan)
}

/// Rewrite the suites of the given entries (file + display line -> mapping).
fn rewrite_files(switches: &HashMap<(String, usize), HashMap<String, String>>, stamp: &str, backup_all: bool) -> Result<()> {
    let files: Vec<PathBuf> = if backup_all {
        source_files()
    } else {
        let mut list: Vec<PathBuf> = switches.keys().map(|(f, _)| PathBuf::from(f)).collect();
        list.sort();
        list.dedup();
        list
    };
    for path in &files {
        backup_file(path, stamp)?;
    }
    let entries = all_entries();
    for path in files {
        let file = path.to_string_lossy().to_string();
        let mut lines = read_lines(&path);
        let mut changed = false;
        for entry in entries.iter().filter(|e| e.file == file && e.enabled) {
            if let Some(mapping) = switches.get(&(file.clone(), entry.display_line())) {
                changed |= rewrite_suites(&mut lines, entry, mapping);
            }
        }
        if changed {
            write_lines(&path, &lines)?;
        }
    }
    Ok(())
}

/// Rewrite the codename of every repository that offers the new release.
pub fn os_switch(target: &str) -> Result<String> {
    require_root()?;
    if !Regex::new(r"^[a-z][a-z0-9-]{1,30}$").unwrap().is_match(target) {
        bail!("Invalid release codename.");
    }
    let plan = os_upgrade_plan(target)?;
    if let Some(row) = plan.blocking.first() {
        bail!("The upgrade cannot start: {} {}.", row.uri, row.note);
    }
    let mut switches: HashMap<(String, usize), HashMap<String, String>> = HashMap::new();
    for row in plan.entries.iter().filter(|r| r.action == "switch") {
        switches.entry((row.file.clone(), row.line)).or_default().insert(row.suite.clone(), row.new_suite.clone());
    }
    if switches.is_empty() {
        bail!("No repository offers the new release.");
    }
    let stamp = format!("os-upgrade-{}", util::stamp());
    rewrite_files(&switches, &stamp, true)?;
    let backup = util::backup_base().join(&stamp).to_string_lossy().to_string();
    util::write_report("os-switch", json!({"from": plan.current, "to": target, "backup": backup, "entries": plan.entries}));
    Ok(backup)
}

pub fn os_restore(backup: &str) -> Result<()> {
    require_root()?;
    let base = Path::new(backup);
    if !base.is_dir() || !base.starts_with(util::backup_base()) || base == util::backup_base() || backup.contains("..") {
        bail!("Invalid backup directory.");
    }
    let apt_dir = util::apt_dir();
    for saved in glob::glob(&format!("{}/**/*", base.display()))?.flatten() {
        if !saved.is_file() {
            continue;
        }
        // Backups store the full original path (including EUS_APT_ROOT in tests).
        let destination = Path::new("/").join(saved.strip_prefix(base)?);
        if destination.starts_with(&apt_dir) && destination != apt_dir {
            std::fs::copy(&saved, &destination)?;
        }
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize)]
pub struct ContinuousRow {
    pub file: String,
    pub line: usize,
    pub uri: String,
    pub suite: String,
    pub new_suite: String,
}

/// Debian entries that name the *current* stable release by codename and
/// can switch to the codename-free 'stable' suite without changing content.
pub fn continuous_stable_plan() -> Vec<ContinuousRow> {
    let mut plan = Vec::new();
    for entry in all_entries() {
        if !entry.enabled || entry.uris.is_empty() {
            continue;
        }
        let uri = entry.uri();
        for suite in &entry.suites {
            let base = suite.split('-').next().unwrap_or("").split('/').next().unwrap_or("");
            if ["stable", "testing", "unstable", "sid", "oldstable", "experimental"].contains(&base) {
                continue;
            }
            let main_release = cached_release(uri, base);
            let release = if main_release.is_empty() { cached_release(uri, suite) } else { main_release.clone() };
            if !["debian", "debian-security"].contains(&entry_role(&entry, &release)) {
                continue;
            }
            // The archive itself says this codename *is* stable right now.
            if !release.get("Suite").is_some_and(|s| s.starts_with("stable")) {
                continue;
            }
            let rest = &suite[base.len()..];
            if !CONTINUOUS_SUFFIXES.contains(&rest) && !rest.starts_with('/') {
                continue;
            }
            plan.push(ContinuousRow { file: entry.file.clone(), line: entry.display_line(), uri: uri.into(),
                                      suite: suite.clone(), new_suite: format!("stable{rest}") });
        }
    }
    plan
}

/// Rewrite the planned suites (backup first). Used by the package's postinst
/// and by System Health; a no-op on an already continuous system.
pub fn apply_continuous_stable() -> Result<Value> {
    require_root()?;
    let plan = continuous_stable_plan();
    if plan.is_empty() {
        return Ok(json!({"changed": [], "backup": ""}));
    }
    let stamp = format!("continuous-stable-{}", util::stamp());
    let mut switches: HashMap<(String, usize), HashMap<String, String>> = HashMap::new();
    for row in &plan {
        switches.entry((row.file.clone(), row.line)).or_default().insert(row.suite.clone(), row.new_suite.clone());
    }
    rewrite_files(&switches, &stamp, false)?;
    Ok(json!({"changed": plan, "backup": util::backup_base().join(&stamp).to_string_lossy()}))
}
