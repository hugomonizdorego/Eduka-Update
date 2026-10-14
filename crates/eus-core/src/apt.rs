//! Diagnosis of `apt-get update` output, HTTP downloads, release metadata.

use crate::sources::{normalize_uri, Entry};
use crate::util::{self, atomic_write, read_text, run_with, RunOptions};
use anyhow::{anyhow, bail, Result};
use regex::Regex;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::io::Read;
use std::path::Path;
use std::sync::LazyLock;

pub const MAX_KEY_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct KeyProblem {
    pub keyid: String,
    pub url: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Unreachable {
    pub url: String,
    pub reason: String,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct AptProblems {
    pub unreachable: Vec<Unreachable>,
    pub missing_keys: Vec<KeyProblem>,
    pub expired_keys: Vec<KeyProblem>,
    pub unsigned: Vec<String>,
    pub signed_by_conflicts: Vec<String>,
    pub configured_multiple_times: Vec<String>,
    pub legacy_warning: bool,
}

impl AptProblems {
    /// Key or repository-definition problems (what Key Fix can repair).
    pub fn has_repairable(&self, keys_only: bool) -> bool {
        let keys = !self.missing_keys.is_empty() || !self.expired_keys.is_empty() || !self.unsigned.is_empty();
        if keys_only {
            keys
        } else {
            keys || !self.signed_by_conflicts.is_empty() || !self.configured_multiple_times.is_empty()
        }
    }
}

fn push_unique(list: &mut Vec<KeyProblem>, keyid: &str, url: &str) {
    let keyid = keyid.to_uppercase();
    if !list.iter().any(|k| k.keyid == keyid) {
        list.push(KeyProblem { keyid, url: url.to_string() });
    }
}

/// Extract key and repository problems from `apt-get update` output
/// (the saved log when `text` is None).
pub fn apt_problems(text: Option<&str>) -> AptProblems {
    static FAILED: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^E: Failed to fetch (\S+)\s+(.*)$").unwrap());
    static KEYISH: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"NO_PUBKEY|signatures|not signed").unwrap());
    static DETAIL_KEYISH: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"NO_PUBKEY|EXPKEYSIG|KEYEXPIRED|REVKEYSIG|signatures|not signed|Signed-By").unwrap());
    static ERR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^Err:\d+ (\S+)").unwrap());
    static URL: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?:GPG error|repository '?)[: ]*\s*((?:https?|ftp|file)://\S+)").unwrap());
    static NO_PUBKEY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"NO_PUBKEY ([0-9A-Fa-f]{8,40})").unwrap());
    static EXPIRED: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"(?:EXPKEYSIG|KEYEXPIRED|REVKEYSIG) ([0-9A-Fa-f]{8,40})").unwrap());
    static REGARDING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"regarding source (\S+)").unwrap());
    static TARGET: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"Target \S+ \(([^)]+)\) is configured multiple times").unwrap());
    static DISTS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"/dists/.*$").unwrap());

    let owned;
    let text = match text {
        Some(t) => t,
        None => {
            owned = read_text(&util::apt_update_log()).unwrap_or_default();
            &owned
        }
    };
    let mut result = AptProblems::default();
    let mut unreachable: Vec<(String, String)> = Vec::new();
    let mut unsigned: BTreeSet<String> = BTreeSet::new();
    let mut conflicts: BTreeSet<String> = BTreeSet::new();
    let mut duplicated: BTreeSet<String> = BTreeSet::new();
    let mut current_url = String::new();
    let lines: Vec<&str> = text.lines().collect();
    let add_unreachable = |list: &mut Vec<(String, String)>, url: String, reason: String| {
        if !list.iter().any(|(u, _)| *u == url) {
            list.push((url, reason));
        }
    };
    let short = |line: &str| line.trim().chars().take(160).collect::<String>();
    for (index, line) in lines.iter().enumerate() {
        if let Some(caps) = FAILED.captures(line) {
            if !KEYISH.is_match(&caps[2]) {
                add_unreachable(&mut unreachable, DISTS.replace(&caps[1], "").to_string(), caps[2].trim().to_string());
            }
        }
        if let Some(caps) = ERR.captures(line) {
            current_url = caps[1].to_string();
            let detail = lines.get(index + 1).copied().unwrap_or("");
            // "Err:" is also printed for signature failures (key problems).
            if detail.starts_with("  ") && !DETAIL_KEYISH.is_match(detail) {
                add_unreachable(&mut unreachable, caps[1].to_string(), detail.trim().to_string());
            }
        }
        let url_match = URL.captures(line);
        if let Some(caps) = &url_match {
            current_url = caps[1].trim_matches('\'').to_string();
        }
        for caps in NO_PUBKEY.captures_iter(line) {
            push_unique(&mut result.missing_keys, &caps[1], &current_url);
        }
        for caps in EXPIRED.captures_iter(line) {
            push_unique(&mut result.expired_keys, &caps[1], &current_url);
        }
        if line.contains("is not signed") && url_match.is_some() {
            unsigned.insert(current_url.clone());
        }
        if line.contains("Conflicting values set for option Signed-By") {
            conflicts.insert(REGARDING.captures(line).map(|c| c[1].to_string()).unwrap_or_else(|| short(line)));
        }
        if line.contains("configured multiple times") {
            duplicated.insert(TARGET.captures(line).map(|c| c[1].to_string()).unwrap_or_else(|| short(line)));
        }
        if line.contains("legacy trusted.gpg keyring") {
            result.legacy_warning = true;
        }
    }
    // An unreachable repository is also "not signed": a network problem.
    // "is not signed" also follows a missing/expired key: the key is the problem.
    let keyed: Vec<String> = result
        .missing_keys
        .iter()
        .chain(result.expired_keys.iter())
        .filter(|k| !k.url.is_empty())
        .map(|k| normalize_uri(&k.url))
        .collect();
    result.unsigned = unsigned
        .into_iter()
        .filter(|url| {
            let n = normalize_uri(url);
            !unreachable.iter().any(|(base, _)| n.starts_with(&normalize_uri(base)))
                && !keyed.iter().any(|k| n.starts_with(k.as_str()) || k.starts_with(n.as_str()))
        })
        .collect();
    result.unreachable = unreachable.into_iter().map(|(url, reason)| Unreachable { url, reason }).collect();
    result.signed_by_conflicts = conflicts.into_iter().collect();
    result.configured_multiple_times = duplicated.into_iter().collect();
    result
}

/// `apt-get update`, keeping the output for Key Fix.
pub fn apt_update_capture() -> Result<String> {
    let output = run_with("apt-get", &["-o", "Acquire::Retries=2", "update"],
                          RunOptions { timeout: Some(900), env: util::C_LOCALE, ..Default::default() })?;
    let text = output.all();
    let _ = atomic_write(&util::apt_update_log(), text.as_bytes(), 0o644);
    Ok(text)
}

/// `apt-get update` for one source file only, keeping every other list.
pub fn apt_update_isolated(source_file: &Path) -> Result<String> {
    let parts = tempfile::Builder::new().prefix("eus-source.").tempdir()?;
    let name = source_file.file_name().ok_or_else(|| anyhow!("bad source file"))?;
    std::fs::copy(source_file, parts.path().join(name))?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(parts.path(), std::fs::Permissions::from_mode(0o755))?;
    let parts_option = format!("Dir::Etc::SourceParts={}", parts.path().display());
    let output = run_with(
        "apt-get",
        &["-o", "Dir::Etc::SourceList=/dev/null", "-o", &parts_option, "-o", "APT::Get::List-Cleanup=0",
          "-o", "Acquire::Retries=2", "update"],
        RunOptions { timeout: Some(600), env: util::C_LOCALE, ..Default::default() },
    )?;
    Ok(output.all())
}

/// True when NO_PROXY/no_proxy exempts this host (suffix match, `*` = all).
fn bypass_proxy(host: &str) -> bool {
    if host == "localhost" || host == "127.0.0.1" || host == "::1" {
        return true;
    }
    let list = std::env::var("NO_PROXY").or_else(|_| std::env::var("no_proxy")).unwrap_or_default();
    list.split(',').map(|e| e.trim().trim_start_matches('.').to_lowercase()).filter(|e| !e.is_empty()).any(|entry| {
        let entry = entry.split(':').next().unwrap_or("").to_string();
        entry == "*" || host == entry || host.ends_with(&format!(".{entry}"))
    })
}

fn agent(url: &str, timeout: u64) -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(timeout))
        .user_agent("Eduka-Update-System")
        .try_proxy_from_env(!bypass_proxy(&uri_host(url)))
        .build()
}

/// Download repository metadata over HTTP(S); APT verifies signed content.
pub fn http_get(url: &str, limit: usize, timeout: u64) -> Result<Vec<u8>> {
    if !(url.starts_with("http://") || url.starts_with("https://")) || url.contains(char::is_whitespace) {
        bail!("Unsupported URL: {url}");
    }
    let response = agent(url, timeout).get(url).call().map_err(|error| match error {
        ureq::Error::Status(code, response) => anyhow!("{url}: HTTP Error {code}: {}", response.status_text()),
        other => anyhow!("{url}: {other}"),
    })?;
    let mut data = Vec::new();
    response.into_reader().take(limit as u64 + 1).read_to_end(&mut data)?;
    if data.len() > limit {
        bail!("{url}: response too large");
    }
    Ok(data)
}

pub fn url_exists(url: &str, timeout: u64) -> bool {
    http_get(url, 8 * 1024 * 1024, timeout).is_ok()
}

/// HTTPS only, for keys given by people.
pub fn fetch_url(url: &str) -> Result<Vec<u8>> {
    if !url.starts_with("https://") || url.contains(char::is_whitespace) {
        bail!("Only HTTPS key URLs are accepted.");
    }
    http_get(url, MAX_KEY_BYTES, 60).map_err(|e| anyhow!("The key could not be downloaded: {e}"))
}

/// Header fields of a Release or clearsigned InRelease file.
pub fn release_fields(text: &str) -> BTreeMap<String, String> {
    let mut lines: Vec<&str> = text.lines().collect();
    if lines.first().is_some_and(|l| l.starts_with("-----BEGIN PGP SIGNED MESSAGE")) {
        lines = match lines.iter().position(|l| l.is_empty()) {
            Some(index) => lines[index + 1..].to_vec(),
            None => vec![],
        };
    }
    let mut fields = BTreeMap::new();
    for line in lines {
        if line.trim().is_empty() || line.starts_with("-----BEGIN PGP SIGNATURE") {
            break;
        }
        if line.starts_with([' ', '\t']) {
            continue;
        }
        if let Some((key, value)) = line.split_once(':') {
            fields.insert(key.trim().to_string(), value.trim().to_string());
        }
    }
    fields
}

/// Name prefix APT uses in /var/lib/apt/lists for a repository.
pub fn lists_prefix(uri: &str, suite: &str) -> String {
    static SCHEME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^[a-z0-9+.-]+://").unwrap());
    let base = SCHEME.replace(uri, "").trim_end_matches('/').to_string();
    let path = if suite.ends_with('/') {
        format!("{base}/{suite}").replace("/./", "/")
    } else {
        format!("{base}/dists/{suite}/")
    };
    path.replace('/', "_")
}

pub fn cached_release(uri: &str, suite: &str) -> BTreeMap<String, String> {
    let prefix = lists_prefix(uri, suite);
    for name in [format!("{prefix}InRelease"), format!("{prefix}Release")] {
        if let Some(text) = read_text(&util::lists_dir().join(name)) {
            return release_fields(&text);
        }
    }
    BTreeMap::new()
}

pub fn uri_host(uri: &str) -> String {
    static HOST: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)^[a-z0-9+.-]+://(?:[^@/]*@)?([^/:]+)").unwrap());
    HOST.captures(uri).map(|c| c[1].to_lowercase()).unwrap_or_default()
}

/// debian, debian-security, edukasaun, ubuntu or third-party.
pub fn entry_role(entry: &Entry, release: &BTreeMap<String, String>) -> &'static str {
    static DEBIAN_PATH: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"/debian(-security)?/?$").unwrap());
    let origin = release.get("Origin").map(|s| s.to_lowercase()).unwrap_or_default();
    let label = release.get("Label").map(|s| s.to_lowercase()).unwrap_or_default();
    let uri = entry.uri();
    let host = uri_host(uri);
    let suite = entry.suite();
    if origin.contains("edukasaun") || label.contains("edukasaun") || host.contains("edukasaun") {
        return "edukasaun";
    }
    if origin == "debian" || host.ends_with("debian.org") || DEBIAN_PATH.is_match(uri) {
        if label.contains("security") || host.contains("security") || suite.ends_with("-security")
            || uri.trim_end_matches('/').ends_with("-security")
        {
            return "debian-security";
        }
        return "debian";
    }
    if origin == "ubuntu" || host.ends_with(".ubuntu.com") || host.ends_with("ubuntu.com") {
        return "ubuntu";
    }
    "third-party"
}

pub fn entry_release(entry: &Entry) -> BTreeMap<String, String> {
    if entry.uris.is_empty() || entry.suites.is_empty() {
        BTreeMap::new()
    } else {
        cached_release(entry.uri(), entry.suite())
    }
}
