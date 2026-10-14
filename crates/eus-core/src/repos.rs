//! The Repositories overview: everything EUS knows about each source entry.

use crate::apt::{apt_problems, cached_release, entry_role};
use crate::keys::keyring_role;
use crate::sources::{all_entries, find_duplicates, normalize_uri};
use serde::Serialize;
use std::collections::BTreeSet;

#[derive(Debug, Clone, Serialize)]
pub struct Repository {
    pub file: String,
    pub line: usize,
    pub format: String,
    pub enabled: bool,
    pub types: Vec<String>,
    pub uri: String,
    pub suites: Vec<String>,
    pub components: Vec<String>,
    pub role: String,
    pub origin: String,
    pub label: String,
    pub codename: String,
    pub version: String,
    pub signed_by: String,
    pub keyring_role: String,
    pub status: String,
}

pub fn describe_repositories() -> Vec<Repository> {
    let problems = apt_problems(None);
    let entries = all_entries();
    let duplicates: BTreeSet<(String, usize)> =
        find_duplicates(&entries).into_iter().map(|d| (d.file, d.line)).collect();
    let mut result = Vec::new();
    for entry in &entries {
        let uri = entry.uri().to_string();
        let suite = entry.suite();
        let release = if uri.is_empty() || suite.is_empty() { Default::default() } else { cached_release(&uri, suite) };
        let line = entry.display_line();
        let key_role = if entry.signed_by == "(embedded key)" {
            "embedded"
        } else if entry.signed_by.starts_with('/') {
            keyring_role(&entry.signed_by)
        } else {
            "none"
        };
        let mut status = if entry.enabled { "ok" } else { "disabled" };
        let normalized = normalize_uri(&uri);
        let matches = |url: &str| !url.is_empty() && normalize_uri(url).starts_with(&normalized);
        if entry.enabled {
            if problems.unreachable.iter().any(|u| matches(&u.url)) {
                status = "unreachable";
            }
            if problems.missing_keys.iter().any(|k| matches(&k.url)) {
                status = "missing-key";
            }
            if problems.expired_keys.iter().any(|k| matches(&k.url)) {
                status = "expired-key";
            }
            if problems.unsigned.iter().any(|u| normalize_uri(u).starts_with(&normalized)) {
                status = "unsigned";
            }
        }
        if duplicates.contains(&(entry.file.clone(), line)) {
            status = "duplicate";
        }
        let field = |name: &str| release.get(name).cloned().unwrap_or_default();
        result.push(Repository {
            file: entry.file.clone(), line, format: entry.format.clone(), enabled: entry.enabled,
            types: entry.types.clone(), uri: uri.clone(), suites: entry.suites.clone(),
            components: entry.components.clone(), role: entry_role(entry, &release).into(),
            origin: field("Origin"), label: field("Label"), codename: field("Codename"), version: field("Version"),
            signed_by: entry.signed_by.clone(), keyring_role: key_role.into(), status: status.into(),
        });
    }
    result
}
