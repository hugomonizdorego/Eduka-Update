//! State files of the backend, update records, schedule and history.

use eus_core::util::{read_key_values, read_text, run_with, RunOptions};
use regex::Regex;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

fn path_from_env(name: &str, default: &str) -> PathBuf {
    std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(|| PathBuf::from(default))
}

pub fn tsv_file() -> PathBuf { path_from_env("EUS_TSV_FILE", "/var/lib/eus/updates.tsv") }
pub fn state_file() -> PathBuf { path_from_env("EUS_STATE_FILE", "/var/lib/eus/status") }
pub fn error_file() -> PathBuf { path_from_env("EUS_ERROR_FILE", "/var/lib/eus/last-error") }
pub fn log_file() -> PathBuf { path_from_env("EUS_LOG_FILE", "/var/log/eus/eus.log") }
pub fn version_file() -> PathBuf { path_from_env("EUS_VERSION_FILE", "/etc/eus/version") }
pub fn interval_file() -> PathBuf { path_from_env("EUS_INTERVAL_FILE", "/etc/eus/interval-hours") }
pub fn restart_file() -> PathBuf { path_from_env("EUS_RESTART_FILE", "/var/lib/eus/restart-required") }
pub fn pause_file() -> PathBuf { path_from_env("EUS_PAUSE_FILE", "/etc/eus/pause") }
pub fn schedule_file() -> PathBuf { path_from_env("EUS_SCHEDULE_FILE", "/etc/eus/schedule") }
pub fn apt_update_log() -> PathBuf { path_from_env("EUS_APT_UPDATE_LOG", "/var/lib/eus/apt-update.log") }
pub fn report_file() -> PathBuf { path_from_env("EUS_REPORT_FILE", "/var/lib/eus/repair-report.json") }
pub fn config_file() -> PathBuf { path_from_env("EUS_CONFIG_FILE", "/etc/eus/eus.conf") }
pub fn ignore_file() -> PathBuf { path_from_env("EUS_IGNORE_FILE", "/etc/eus/ignored-updates") }
pub fn health_file() -> PathBuf { path_from_env("EUS_HEALTH_FILE", "/var/lib/eus/health.json") }
pub fn os_upgrade_file() -> PathBuf { path_from_env("EUS_OS_UPGRADE_FILE", "/var/lib/eus/os-upgrade") }
pub const ROOT_HELPER: &str = "/usr/local/libexec/eduka-update-system-root";
pub const PANEL_STATUS: &str = "/usr/local/bin/eus-panel-status";
pub const EUS_VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

pub fn history_file() -> PathBuf {
    if let Some(path) = std::env::var_os("EUS_HISTORY_FILE").filter(|v| !v.is_empty()) {
        return PathBuf::from(path);
    }
    let state = std::env::var_os("XDG_STATE_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".local/state"));
    state.join("eus/update-history.tsv")
}

/// A JSON fixture used to document the interface (screenshots), if set.
pub fn fixture(name: &str) -> Option<serde_json::Value> {
    let path = std::env::var_os(name).filter(|v| !v.is_empty())?;
    serde_json::from_str(&read_text(Path::new(&path))?).ok()
}

pub fn version() -> String {
    let short = EUS_VERSION.trim_end_matches(".0").to_string();
    read_key_values(&version_file()).get("VERSION").cloned().unwrap_or(short)
}

#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    pub category: String,
    pub source: String,
    pub name: String,
    pub installed: String,
    pub candidate: String,
    pub size: u64,
    pub description: String,
    pub srcpkg: String,
}

pub fn parse_size(value: &str) -> u64 {
    static NUMBER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"([0-9]+(?:\.[0-9]+)?)").unwrap());
    let text = value.trim().to_uppercase().replace(',', ".");
    let Some(number) = NUMBER.captures(&text).and_then(|c| c[1].parse::<f64>().ok()) else { return 0 };
    for (unit, multiplier) in [("KB", 1u64 << 10), ("KIB", 1 << 10), ("MB", 1 << 20), ("MIB", 1 << 20), ("GB", 1 << 30),
                               ("GIB", 1 << 30), ("TB", 1 << 40), ("TIB", 1 << 40)] {
        if text.contains(unit) {
            return (number * multiplier as f64) as u64;
        }
    }
    number as u64
}

pub fn parse_updates(path: &Path) -> Vec<Record> {
    let Some(text) = read_text(path) else { return vec![] };
    text.lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            if fields.len() < 7
                || !["critical", "kernel", "medium", "normal", "flatpak"].contains(&fields[0])
                || !["apt", "flatpak-system", "flatpak-user"].contains(&fields[1])
            {
                return None;
            }
            let srcpkg = fields.get(7).filter(|s| !s.is_empty()).unwrap_or(&fields[2]);
            Some(Record {
                category: fields[0].into(), source: fields[1].into(), name: fields[2].into(),
                installed: fields[3].into(), candidate: fields[4].into(),
                size: fields[5].parse().unwrap_or_else(|_| parse_size(fields[5])),
                description: fields[6].into(), srcpkg: srcpkg.to_string(),
            })
        })
        .collect()
}

/// Updates of per-user Flatpaks (the backend only sees system ones).
pub fn scan_user_flatpaks() -> Vec<Record> {
    static APP_ID: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._+-]+$").unwrap());
    if std::env::var("EUS_DISABLE_USER_FLATPAK").as_deref() == Ok("1") || !eus_core::util::which("flatpak") {
        return vec![];
    }
    let options = || RunOptions { timeout: Some(8), ..Default::default() };
    let mut installed: BTreeMap<String, String> = BTreeMap::new();
    if let Ok(output) = run_with("flatpak", &["list", "--user", "--columns=application,version"], options()) {
        for line in output.out().lines() {
            let mut parts = line.splitn(2, '\t');
            let id = parts.next().unwrap_or("").trim();
            if !id.is_empty() {
                installed.insert(id.into(), parts.next().map(|v| v.trim().to_string()).unwrap_or_else(|| "—".into()));
            }
        }
    }
    let Ok(output) = run_with("flatpak", &["remote-ls", "--user", "--updates", "--cached",
                                           "--columns=application,name,version,download-size,description"], options())
    else {
        return vec![];
    };
    output
        .out()
        .lines()
        .filter_map(|line| {
            let mut fields: Vec<String> = line.splitn(5, '\t').map(|f| f.trim().to_string()).collect();
            fields.resize(5, String::new());
            let (id, name) = (&fields[0], &fields[1]);
            if !id.contains('.') || !APP_ID.is_match(id) {
                return None;
            }
            let mut description = if fields[4].is_empty() { "Flatpak application or runtime update".to_string() } else { fields[4].clone() };
            if !name.is_empty() && name != id {
                description = format!("{name} — {description}");
            }
            Some(Record {
                category: "flatpak".into(), source: "flatpak-user".into(), name: id.clone(),
                installed: installed.get(id).cloned().unwrap_or_else(|| "—".into()),
                candidate: if fields[2].is_empty() { "—".into() } else { fields[2].clone() },
                size: parse_size(&fields[3]), description, srcpkg: id.clone(),
            })
        })
        .collect()
}

pub const SELF_PACKAGE: &str = "eduka-update-system";

pub fn category_rank(category: &str) -> i32 {
    match category {
        "major" => -1,
        "critical" => 0,
        "kernel" => 1,
        "medium" => 2,
        "normal" => 3,
        "flatpak" => 4,
        _ => 9,
    }
}

/// (strong colour, pale background, dark text) of a category.
pub fn category_color(category: &str) -> &'static str {
    match category {
        "critical" => "#D92D20",
        "kernel" => "#7C3AED",
        "major" => "#553C9A",
        "medium" => "#B7791F",
        "flatpak" => "#1677D2",
        _ => "#169B62",
    }
}

#[derive(Debug, Clone)]
pub struct Group {
    pub key: (String, String),
    pub name: String,
    pub source: String,
    pub category: String,
    pub packages: Vec<Record>,
    pub size: u64,
    pub main: Record,
    pub installed: String,
    pub candidate: String,
    pub description: String,
    pub self_update: bool,
}

/// Group binary packages by source package, like mintupdate: one row for
/// e.g. all WebKitGTK libraries built from webkit2gtk.
pub fn group_updates(records: &[Record]) -> Vec<Group> {
    let mut order: Vec<(String, String)> = Vec::new();
    let mut groups: BTreeMap<(String, String), Group> = BTreeMap::new();
    for record in records {
        let key = if record.source == "apt" {
            ("apt".to_string(), if record.srcpkg.is_empty() { record.name.clone() } else { record.srcpkg.clone() })
        } else {
            (record.source.clone(), record.name.clone())
        };
        let group = groups.entry(key.clone()).or_insert_with(|| {
            order.push(key.clone());
            Group {
                key: key.clone(), name: key.1.clone(), source: record.source.clone(), category: record.category.clone(),
                packages: vec![], size: 0, main: record.clone(), installed: String::new(), candidate: String::new(),
                description: String::new(), self_update: false,
            }
        });
        group.packages.push(record.clone());
        group.size += record.size;
        if category_rank(&record.category) < category_rank(&group.category) {
            group.category = record.category.clone();
        }
        if record.name == key.1 {
            group.main = record.clone();
        }
    }
    let mut result: Vec<Group> = order.into_iter().filter_map(|k| groups.remove(&k)).collect();
    for group in &mut result {
        if group.packages.len() == 1 {
            group.name = group.main.name.clone();
        }
        group.installed = group.main.installed.clone();
        group.candidate = group.main.candidate.clone();
        group.description = group.main.description.clone();
        group.self_update = group.packages.iter().any(|p| p.name == SELF_PACKAGE);
        if group.category == "kernel" && group.packages.len() > 1 {
            group.name = format!("Linux kernel {}", group.candidate);
        }
    }
    result.sort_by(|a, b| {
        (!a.self_update, category_rank(&a.category), &a.name).cmp(&(!b.self_update, category_rank(&b.category), &b.name))
    });
    result
}

/// The available Debian release upgrade (empty when there is none).
pub fn read_os_upgrade() -> BTreeMap<String, String> {
    let data = read_key_values(&os_upgrade_file());
    if data.get("available").map(String::as_str) == Some("1") && data.get("target_codename").is_some_and(|c| !c.is_empty()) {
        data
    } else {
        BTreeMap::new()
    }
}

pub fn major_of(version: &str) -> String {
    version.split('.').next().unwrap_or("").to_string()
}

fn boot_id() -> String {
    read_text(Path::new("/proc/sys/kernel/random/boot_id")).map(|t| t.trim().to_string()).unwrap_or_else(|| "unknown".into())
}

pub fn restart_is_required(state: &BTreeMap<String, String>) -> bool {
    let data = read_key_values(&restart_file());
    let get = |key: &str, fallback: &str| data.get(key).or_else(|| state.get(fallback)).cloned().unwrap_or_default();
    if get("required", "restart_required") != "1" {
        return false;
    }
    let saved = get("boot_id", "restart_boot_id");
    saved.is_empty() || saved == "unknown" || saved == boot_id()
}

pub fn restart_sensitive(record: &Record) -> bool {
    static RE: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"^(linux-|firmware-|intel-microcode|amd64-microcode|systemd|udev|libc6|grub-|initramfs-)").unwrap()
    });
    record.source == "apt" && RE.is_match(&record.name)
}

pub fn paused_until() -> i64 {
    let until: i64 = read_key_values(&pause_file()).get("PAUSED_UNTIL").and_then(|v| v.parse().ok()).unwrap_or(0);
    if until > eus_core::util::now() { until } else { 0 }
}

pub const INTERVAL_CHOICES: [u32; 7] = [1, 3, 6, 12, 24, 48, 168];

#[derive(Debug, Clone, PartialEq)]
pub struct Schedule {
    pub daily: bool,
    pub hours: u32,
    pub time: String,
}

pub fn valid_time(text: &str) -> bool {
    static RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^([01]\d|2[0-3]):[0-5]\d$").unwrap());
    RE.is_match(text)
}

pub fn read_schedule() -> Schedule {
    let data = read_key_values(&schedule_file());
    let hours = data
        .get("INTERVAL_HOURS")
        .cloned()
        .or_else(|| read_text(&interval_file()).map(|t| t.trim().to_string()))
        .and_then(|v| v.parse().ok())
        .filter(|h| INTERVAL_CHOICES.contains(h))
        .unwrap_or(6);
    let time = data.get("DAILY_TIME").cloned().filter(|t| valid_time(t)).unwrap_or_else(|| "09:00".into());
    Schedule { daily: data.get("SCHEDULE_MODE").map(String::as_str) == Some("daily"), hours, time }
}

/// strftime in the user's locale.
pub fn strftime(epoch: i64, format: &str) -> String {
    let Ok(format) = std::ffi::CString::new(format) else { return String::new() };
    let mut buffer = [0u8; 160];
    // SAFETY: localtime_r and strftime write into buffers we own.
    unsafe {
        let time: libc::time_t = epoch as libc::time_t;
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&time, &mut tm).is_null() {
            return "—".into();
        }
        let length = libc::strftime(buffer.as_mut_ptr() as *mut libc::c_char, buffer.len(), format.as_ptr(), &tm);
        String::from_utf8_lossy(&buffer[..length]).to_string()
    }
}

pub fn format_date(epoch: i64) -> String {
    if epoch <= 0 { "—".into() } else { strftime(epoch, "%A, %d %B %Y · %H:%M") }
}

pub fn format_last_check(epoch: i64) -> String {
    if epoch <= 0 { "—".into() } else { strftime(epoch, "%A, %d %B · %H:%M") }
}

fn history_field(value: &str) -> String {
    value.replace(['\t', '\r', '\n'], " ").trim().to_string()
}

/// Record installation results (refreshes are never history entries).
pub fn append_history(records: &[(String, String, String, String)], success: bool) {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    if records.is_empty() {
        return;
    }
    let path = history_file();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let stamp = strftime(eus_core::util::now(), "%Y-%m-%dT%H:%M:%S%z");
    let status = if success { "success" } else { "failed" };
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(&path) {
        for (source, name, installed, candidate) in records {
            let _ = writeln!(file, "{stamp}\t{status}\t{}\t{}\t{}\t{}", history_field(source), history_field(name),
                             history_field(installed), history_field(candidate));
        }
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
}

/// History entries, newest first: (time, success, name, installed, candidate).
pub fn read_history() -> Vec<(String, bool, String, String, String)> {
    let Some(text) = read_text(&history_file()) else { return vec![] };
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(2000);
    let mut entries: Vec<(String, bool, String, String, String)> = lines[start..]
        .iter()
        .filter_map(|line| {
            let fields: Vec<&str> = line.splitn(6, '\t').collect();
            if fields.len() != 6 || !["success", "failed"].contains(&fields[1]) {
                return None;
            }
            Some((display_time(fields[0]), fields[1] == "success", fields[3].into(), fields[4].into(), fields[5].into()))
        })
        .collect();
    entries.reverse();
    entries
}

/// "2026-10-13T14:15:00+0900" (or with "+09:00") in the user's locale.
fn display_time(stamp: &str) -> String {
    static RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)([+-])(\d\d):?(\d\d)$").unwrap());
    let Some(c) = RE.captures(stamp) else { return stamp.to_string() };
    let n = |i: usize| c[i].parse::<i64>().unwrap_or(0);
    // Days from civil (Howard Hinnant's algorithm).
    let (y, m, d) = (n(1) - if n(2) <= 2 { 1 } else { 0 }, n(2), n(3));
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    let offset = (n(8) * 3600 + n(9) * 60) * if &c[7] == "-" { -1 } else { 1 };
    format_date(days * 86400 + n(4) * 3600 + n(5) * 60 + n(6) - offset)
}

pub fn ignored_patterns() -> Vec<String> {
    read_text(&ignore_file())
        .unwrap_or_default()
        .lines()
        .map(|l| l.split('#').next().unwrap_or("").trim().to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sample_updates_are_parsed_and_grouped() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests");
        let records = parse_updates(&dir.join("sample-updates.tsv"));
        assert_eq!(records.len(), 4);
        for (category, count) in [("critical", 1), ("medium", 1), ("normal", 1), ("flatpak", 1)] {
            assert_eq!(records.iter().filter(|r| r.category == category).count(), count, "{category}");
        }
        let records = parse_updates(&dir.join("sample-updates-015.tsv"));
        assert_eq!(records.len(), 4);
        assert_eq!(records.iter().filter(|r| r.category == "kernel").count(), 1);
        assert_eq!(group_updates(&records).len(), 3);
    }

    #[test]
    fn sizes_and_history_times() {
        assert_eq!(parse_size("1.5 MB"), 1572864);
        assert_eq!(parse_size("12 kB"), 12288);
        assert_eq!(parse_size("300"), 300);
        assert!(display_time("2026-10-13T14:15:00+09:00").contains("2026"));
        assert!(valid_time("09:00") && !valid_time("24:00"));
    }
}
