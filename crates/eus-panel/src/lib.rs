//! Panel status file shared by EUS and Eduka-Panel:
//! `$XDG_RUNTIME_DIR/eduka-update-system/panel-status.json` with
//! `{"version":1,"state":"available","count":3,"progress":-1,"message":"","updated_at":…}`.

use std::path::PathBuf;

pub const VALID_STATES: [&str; 5] = ["hidden", "idle", "available", "running", "finished"];
pub const ICON_DIR: &str = "/usr/lib/EUS-ICONS";

pub fn uid() -> u32 {
    // SAFETY: getuid has no preconditions.
    unsafe { libc::getuid() }
}

pub fn runtime_base() -> PathBuf {
    if let Some(dir) = std::env::var_os("XDG_RUNTIME_DIR").filter(|v| !v.is_empty()) {
        return PathBuf::from(dir);
    }
    let normal = PathBuf::from(format!("/run/user/{}", uid()));
    if normal.is_dir() {
        normal
    } else {
        std::env::temp_dir().join(format!("eus-runtime-{}", uid()))
    }
}

pub fn state_dir() -> PathBuf {
    runtime_base().join("eduka-update-system")
}

pub fn state_file() -> PathBuf {
    state_dir().join("panel-status.json")
}

/// Indicator texts from eus-i18n.json in the user's language (English fallback).
pub fn message(key: &str) -> String {
    let defaults = [
        ("updates_available", "Updates available"),
        ("updates_available_count", "{count} updates available"),
        ("update_running", "Update in progress"),
        ("update_finished", "Update finished"),
        ("open_manager", "Open Update Manager"),
    ];
    let fallback = defaults.iter().find(|(k, _)| *k == key).map(|(_, v)| v.to_string()).unwrap_or_default();
    let Ok(text) = std::fs::read_to_string(format!("{ICON_DIR}/eus-i18n.json")) else { return fallback };
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(&text) else { return fallback };
    let mut candidates: Vec<String> = Vec::new();
    for variable in ["LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"] {
        for value in std::env::var(variable).unwrap_or_default().split(':') {
            let normalized = value.trim().split(['.', '@']).next().unwrap_or("").replace('-', "_").to_lowercase();
            let short = normalized.split('_').next().unwrap_or("").to_string();
            for candidate in [normalized, short] {
                if !candidate.is_empty() && !candidates.contains(&candidate) {
                    candidates.push(candidate);
                }
            }
        }
    }
    candidates.push("en".into());
    candidates
        .iter()
        .find_map(|lang| payload["translations"][lang][key].as_str().map(str::to_string))
        .unwrap_or(fallback)
}
