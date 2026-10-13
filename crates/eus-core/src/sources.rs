//! APT source lists: one-line `.list` files and deb822 `.sources` files.

use crate::util::{self, atomic_write, backup_file, file_mode, progress, read_text, require_root};
use anyhow::{bail, Result};
use regex::Regex;
use serde::Serialize;
use serde_json::json;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

pub const DISABLED_MARK: &str = "# Disabled by Eduka-Update-System (duplicate repository):";
static SOURCE_FILE_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9_.-]+\.(list|sources)$").unwrap());
static LIST_LINE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*(deb|deb-src)\s+(\[[^\]]*\]\s*)?(\S+)\s+(\S+)\s*(.*?)\s*$").unwrap());
static LIST_PREFIX_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*(deb|deb-src)\s+(\[[^\]]*\]\s*)?\S+\s+\S+").unwrap());

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Entry {
    pub file: String,
    pub format: String,
    /// list: the line index; sources: the first line of the stanza (0-based)
    pub line: usize,
    /// sources: one past the last line of the stanza
    pub last_line: usize,
    pub types: Vec<String>,
    pub uris: Vec<String>,
    pub suites: Vec<String>,
    pub components: Vec<String>,
    pub signed_by: String,
    pub enabled: bool,
}

impl Entry {
    pub fn is_list(&self) -> bool { self.format == "list" }
    pub fn uri(&self) -> &str { self.uris.first().map(String::as_str).unwrap_or("") }
    pub fn suite(&self) -> &str { self.suites.first().map(String::as_str).unwrap_or("") }
    /// 1-based line number shown to people.
    pub fn display_line(&self) -> usize { self.line + 1 }
}

pub type Key = (String, String, String, String);

/// Canonical form used to recognise the same archive written differently.
pub fn normalize_uri(uri: &str) -> String {
    let mut value = uri.trim().to_string();
    let lower = value.to_ascii_lowercase();
    if lower.starts_with("https://") {
        value = format!("http://{}", &value[8..]);
    } else if lower.starts_with("http://") {
        value = format!("http://{}", &value[7..]);
    }
    if let Some(index) = value.find("://") {
        let (scheme, rest) = value.split_at(index + 3);
        let (host, path) = match rest.find('/') {
            Some(slash) => rest.split_at(slash),
            None => (rest, ""),
        };
        value = format!("{}{}{}", scheme.to_ascii_lowercase(), host.to_ascii_lowercase(), path);
    }
    value.trim_end_matches('/').to_string()
}

pub fn parse_options(text: &str) -> HashMap<String, String> {
    let mut options = HashMap::new();
    for token in text.split_whitespace() {
        if let Some((key, value)) = token.split_once('=') {
            options.insert(key.trim().to_lowercase().trim_end_matches(['+', '-']).to_string(), value.trim().to_string());
        }
    }
    options
}

pub fn source_files() -> Vec<PathBuf> {
    let mut files = Vec::new();
    if util::sources_list().is_file() {
        files.push(util::sources_list());
    }
    if let Ok(dir) = std::fs::read_dir(util::sources_dir()) {
        let mut names: Vec<PathBuf> = dir
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_file() && SOURCE_FILE_RE.is_match(&p.file_name().unwrap_or_default().to_string_lossy()))
            .collect();
        names.sort();
        files.extend(names);
    }
    files
}

fn lines_of(path: &Path) -> Vec<String> {
    read_text(path).map(|t| t.lines().map(str::to_string).collect()).unwrap_or_default()
}

pub fn parse_list_file(path: &Path) -> Vec<Entry> {
    let mut entries = Vec::new();
    for (number, raw) in lines_of(path).iter().enumerate() {
        if raw.trim_start().starts_with('#') {
            continue;
        }
        let line = raw.split('#').next().unwrap_or("");
        let Some(caps) = LIST_LINE_RE.captures(line) else { continue };
        let options = parse_options(caps.get(2).map(|m| m.as_str().trim().trim_matches(['[', ']'])).unwrap_or(""));
        entries.push(Entry {
            file: path.to_string_lossy().to_string(),
            format: "list".into(),
            line: number,
            last_line: number + 1,
            types: vec![caps[1].to_string()],
            uris: vec![caps[3].to_string()],
            suites: vec![caps[4].to_string()],
            components: caps.get(5).map(|m| m.as_str().split_whitespace().map(str::to_string).collect()).unwrap_or_default(),
            signed_by: options.get("signed-by").cloned().unwrap_or_default(),
            enabled: true,
        });
    }
    entries
}

pub fn parse_sources_file(path: &Path) -> Vec<Entry> {
    let mut lines = lines_of(path);
    lines.push(String::new());
    let mut stanzas: Vec<(usize, usize, HashMap<String, String>)> = Vec::new();
    let mut fields: HashMap<String, String> = HashMap::new();
    let mut start: Option<usize> = None;
    let mut last_key: Option<String> = None;
    for (number, raw) in lines.iter().enumerate() {
        if raw.trim().is_empty() {
            if !fields.is_empty() {
                stanzas.push((start.unwrap_or(0), number, std::mem::take(&mut fields)));
            }
            start = None;
            last_key = None;
            continue;
        }
        if raw.trim_start().starts_with('#') {
            continue;
        }
        if start.is_none() {
            start = Some(number);
        }
        if raw.starts_with([' ', '\t']) {
            if let Some(key) = &last_key {
                if let Some(value) = fields.get_mut(key) {
                    value.push('\n');
                    value.push_str(raw.trim());
                }
                continue;
            }
        }
        if let Some((key, value)) = raw.split_once(':') {
            let key = key.trim().to_lowercase();
            fields.insert(key.clone(), value.trim().to_string());
            last_key = Some(key);
        }
    }
    let words = |data: &HashMap<String, String>, key: &str, default: &str| -> Vec<String> {
        data.get(key).map(String::as_str).unwrap_or(default).split_whitespace().map(str::to_string).collect()
    };
    stanzas
        .into_iter()
        .map(|(first, last, data)| {
            let enabled = !matches!(data.get("enabled").map(|v| v.trim().to_lowercase()).as_deref(),
                                    Some("no") | Some("false") | Some("0"));
            let mut signed_by = data.get("signed-by").cloned().unwrap_or_default();
            if signed_by.contains("BEGIN PGP") {
                signed_by = "(embedded key)".into();
            }
            Entry {
                file: path.to_string_lossy().to_string(),
                format: "sources".into(),
                line: first,
                last_line: last,
                types: words(&data, "types", "deb"),
                uris: words(&data, "uris", ""),
                suites: words(&data, "suites", ""),
                components: words(&data, "components", ""),
                signed_by: signed_by.trim().to_string(),
                enabled,
            }
        })
        .collect()
}

pub fn all_entries() -> Vec<Entry> {
    let mut entries = Vec::new();
    for path in source_files() {
        if path.extension().is_some_and(|e| e == "sources") {
            entries.extend(parse_sources_file(&path));
        } else {
            entries.extend(parse_list_file(&path));
        }
    }
    entries
}

fn suite_key(suite: &str) -> String {
    let trimmed = suite.trim_end_matches('/');
    if trimmed.is_empty() { suite.to_string() } else { trimmed.to_string() }
}

pub fn entry_keys(entry: &Entry) -> Vec<Key> {
    let mut keys = Vec::new();
    let components = if entry.components.is_empty() { vec![String::new()] } else { entry.components.clone() };
    for kind in &entry.types {
        for uri in &entry.uris {
            for suite in &entry.suites {
                for component in &components {
                    keys.push((kind.clone(), normalize_uri(uri), suite_key(suite), component.clone()));
                }
            }
        }
    }
    keys
}

#[derive(Debug, Clone, Serialize)]
pub struct Duplicate {
    pub file: String,
    pub format: String,
    pub line: usize,
    pub uri: String,
    pub suite: String,
    pub components: Vec<String>,
    pub complete: bool,
    pub first_file: String,
    pub first_line: usize,
    pub signed_by_conflict: bool,
    #[serde(skip)]
    pub entry: Entry,
    #[serde(skip)]
    pub repeated: Vec<Key>,
}

/// One record per enabled entry that repeats an earlier enabled entry.
pub fn find_duplicates(entries: &[Entry]) -> Vec<Duplicate> {
    let mut seen: HashMap<Key, Entry> = HashMap::new();
    let mut duplicates = Vec::new();
    for entry in entries.iter().filter(|e| e.enabled) {
        let keys = entry_keys(entry);
        let repeated: Vec<Key> = keys.iter().filter(|k| seen.contains_key(*k)).cloned().collect();
        if let Some(first_key) = repeated.first() {
            let first = seen[first_key].clone();
            let components: BTreeSet<String> = repeated.iter().filter(|k| !k.3.is_empty()).map(|k| k.3.clone()).collect();
            duplicates.push(Duplicate {
                file: entry.file.clone(),
                format: entry.format.clone(),
                line: entry.display_line(),
                uri: entry.uri().to_string(),
                suite: entry.suite().to_string(),
                components: components.into_iter().collect(),
                complete: repeated.len() == keys.len(),
                first_file: first.file.clone(),
                first_line: first.display_line(),
                signed_by_conflict: !entry.signed_by.is_empty() && !first.signed_by.is_empty()
                    && entry.signed_by != first.signed_by,
                entry: entry.clone(),
                repeated: repeated.clone(),
            });
        }
        for key in keys {
            seen.entry(key).or_insert_with(|| entry.clone());
        }
    }
    duplicates
}

pub fn write_lines(path: &Path, lines: &[String]) -> Result<()> {
    let mut text = lines.join("\n");
    text.push('\n');
    atomic_write(path, text.as_bytes(), file_mode(path))
}

/// Disable duplicate entries (comment out / `Enabled: no` / drop repeated components).
pub fn fix_duplicates() -> Result<serde_json::Value> {
    require_root()?;
    progress(10, "Checking repository configuration...");
    let duplicates = find_duplicates(&all_entries());
    let stamp = util::stamp();
    let mut fixed = Vec::new();
    let mut skipped = Vec::new();
    let mut by_file: Vec<(String, Vec<Duplicate>)> = Vec::new();
    for duplicate in duplicates {
        match by_file.iter_mut().find(|(f, _)| *f == duplicate.file) {
            Some((_, items)) => items.push(duplicate),
            None => by_file.push((duplicate.file.clone(), vec![duplicate])),
        }
    }
    progress(40, "Disabling duplicate repository entries...");
    for (file, mut items) in by_file {
        let path = PathBuf::from(&file);
        let mut lines = lines_of(&path);
        // From the bottom so earlier line numbers stay valid.
        items.sort_by(|a, b| b.entry.line.cmp(&a.entry.line));
        let mut changed = false;
        for item in items {
            let entry = &item.entry;
            let keep: Vec<String> = entry
                .components
                .iter()
                .filter(|c| {
                    let key = (entry.types[0].clone(), normalize_uri(entry.uri()), suite_key(entry.suite()), (*c).clone());
                    !item.repeated.contains(&key)
                })
                .cloned()
                .collect();
            if entry.is_list() {
                let number = entry.line;
                if item.complete {
                    lines[number] = format!("{DISABLED_MARK} {}", lines[number]);
                } else {
                    let prefix = LIST_PREFIX_RE.find(&lines[number]).map(|m| m.as_str().to_string()).unwrap_or_default();
                    let original = lines[number].clone();
                    lines.splice(number..=number, [format!("{DISABLED_MARK} {original}"), format!("{prefix} {}", keep.join(" "))]);
                }
            } else {
                let (first, last) = (entry.line, entry.last_line);
                let simple = entry.types.len() == 1 && entry.uris.len() == 1 && entry.suites.len() == 1;
                let stanza: Vec<String> = if item.complete {
                    let mut new = vec![DISABLED_MARK.trim_end_matches(':').to_string(), "Enabled: no".to_string()];
                    new.extend(lines[first..last].iter().filter(|l| !is_field(l, "enabled")).cloned());
                    new
                } else if simple {
                    lines[first..last]
                        .iter()
                        .map(|l| if is_field(l, "components") { format!("Components: {}", keep.join(" ")) } else { l.clone() })
                        .collect()
                } else {
                    skipped.push(serde_json::to_value(&item)?);
                    continue;
                };
                lines.splice(first..last, stanza);
            }
            changed = true;
            fixed.push(serde_json::to_value(&item)?);
        }
        if changed {
            backup_file(&path, &stamp)?;
            write_lines(&path, &lines)?;
        }
    }
    progress(100, "Complete.");
    let backup = if fixed.is_empty() { String::new() } else { util::backup_base().join(&stamp).to_string_lossy().to_string() };
    Ok(json!({"fixed": fixed, "skipped": skipped, "backup": backup}))
}

/// `Field:` line of a deb822 stanza (case-insensitive).
pub fn is_field(line: &str, field: &str) -> bool {
    line.trim_start()
        .split_once(':')
        .is_some_and(|(name, _)| name.trim().eq_ignore_ascii_case(field))
}

/// Point one entry at a keyring (backup first).
pub fn set_signed_by(entry: &Entry, keyring: &str, stamp: &str) -> Result<()> {
    let path = PathBuf::from(&entry.file);
    let mut lines = lines_of(&path);
    if entry.is_list() {
        static RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(\s*(?:deb|deb-src))\s+(\[([^\]]*)\]\s*)?(.*)$").unwrap());
        let number = entry.line;
        let Some(caps) = RE.captures(&lines[number]) else { bail!("Cannot update {}:{}", entry.file, number + 1) };
        let mut options: Vec<String> = caps
            .get(3)
            .map(|m| m.as_str().split_whitespace().filter(|o| !o.to_lowercase().starts_with("signed-by")).map(str::to_string).collect())
            .unwrap_or_default();
        options.push(format!("signed-by={keyring}"));
        lines[number] = format!("{} [{}] {}", &caps[1], options.join(" "), &caps[4]);
    } else {
        let (first, last) = (entry.line, entry.last_line);
        let mut stanza = Vec::new();
        let mut skipping = false;
        for line in &lines[first..last] {
            if is_field(line, "signed-by") {
                skipping = true;
                continue;
            }
            if skipping && line.starts_with([' ', '\t']) {
                continue;
            }
            skipping = false;
            stanza.push(line.clone());
        }
        stanza.push(format!("Signed-By: {keyring}"));
        lines.splice(first..last, stanza);
    }
    backup_file(&path, stamp)?;
    write_lines(&path, &lines)
}

/// Replace suites of one entry (list: the suite token; sources: Suites field).
pub fn rewrite_suites(lines: &mut [String], entry: &Entry, mapping: &HashMap<String, String>) -> bool {
    static RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^(\s*(?:deb|deb-src)\s+(?:\[[^\]]*\]\s*)?\S+\s+)(\S+)(.*)$").unwrap());
    let mut changed = false;
    if entry.is_list() {
        if let Some(caps) = RE.captures(&lines[entry.line]) {
            if let Some(new) = mapping.get(&caps[2]) {
                lines[entry.line] = format!("{}{}{}", &caps[1], new, &caps[3]);
                changed = true;
            }
        }
    } else {
        for line in lines.iter_mut().take(entry.last_line).skip(entry.line) {
            if is_field(line, "suites") {
                let (head, value) = line.split_once(':').unwrap();
                let suites: Vec<String> = value.split_whitespace().map(|s| mapping.get(s).cloned().unwrap_or_else(|| s.to_string())).collect();
                *line = format!("{}: {}", head.trim_end(), suites.join(" "));
                changed = true;
            }
        }
    }
    changed
}

pub fn read_lines(path: &Path) -> Vec<String> { lines_of(path) }
