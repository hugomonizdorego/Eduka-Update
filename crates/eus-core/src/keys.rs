//! GnuPG keyrings: inspection, placement rules, automatic key discovery,
//! Key Fix, Add Key and Add Repository.

use crate::apt::{self, apt_problems, apt_update_capture, apt_update_isolated, entry_release, entry_role, fetch_url,
                 http_get, uri_host, AptProblems, MAX_KEY_BYTES};
use crate::sources::{self, all_entries, entry_keys, normalize_uri, set_signed_by, Entry};
use crate::util::{self, atomic_write, backup_file, plain, progress, require_root, run, run_with, sys, RunOptions};
use anyhow::{anyhow, bail, Result};
use regex::Regex;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

pub const KEYSERVERS: [&str; 2] = ["hkps://keyserver.ubuntu.com", "hkps://keys.openpgp.org"];
pub const DISTRO_ROLES: [&str; 4] = ["debian", "debian-security", "edukasaun", "ubuntu"];
pub const ARCHIVE_KEYRING_PACKAGES: [&str; 4] =
    ["debian-archive-keyring", "edukasaun-archive-keyring", "edukasaun-keyring", "ubuntu-keyring"];
const KEY_FILE_NAMES: [&str; 12] = ["Release.key", "KEY.gpg", "key.gpg", "public.key", "pubkey.gpg", "gpg.key",
                                    "gpg", "repo.key", "archive.key", "signing.key", "key.asc", "public.gpg"];
pub static NAME_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-z0-9][a-z0-9._-]{0,62}$").unwrap());
pub static URI_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"^(https?|ftp|file)://[^\s\[\]"'<>]+$"#).unwrap());
pub static SUITE_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9._~/+-]+$").unwrap());
pub static COMPONENT_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9._+-]+$").unwrap());
pub static ARCH_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-z0-9-]+$").unwrap());
pub static KEYID_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(0x)?([0-9A-Fa-f]{8}|[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$").unwrap());

pub fn role_text(role: &str) -> &'static str {
    match role {
        "package" => "Package keyring (managed by dpkg, never edited by EUS)",
        "scoped" => "Repository keyring (used only through Signed-By)",
        "global" => "Global keyring in /etc/apt/trusted.gpg.d (trusted for every repository)",
        "legacy" => "Deprecated legacy keyring /etc/apt/trusted.gpg",
        "embedded" => "Key embedded in the .sources file",
        _ => "No Signed-By: verified with the global keyrings",
    }
}

/// A throw-away GnuPG home so root's own keyring is never touched.
pub struct GpgHome {
    dir: tempfile::TempDir,
}

impl GpgHome {
    pub fn new() -> Result<Self> {
        // A short path: gpg-agent sockets fail in long directories.
        let dir = tempfile::Builder::new().prefix("eus-gpg.").tempdir_in("/tmp")?;
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700))?;
        Ok(Self { dir })
    }

    pub fn gpg(&self, args: &[&str], input: Option<&[u8]>, timeout: u64) -> Result<util::Output> {
        let home = self.dir.path().to_string_lossy().to_string();
        let mut full = vec!["--homedir", home.as_str(), "--batch", "--no-tty", "--quiet"];
        full.extend_from_slice(args);
        run_with("gpg", &full, RunOptions { timeout: Some(timeout), input, env: util::C_LOCALE })
    }
}

impl Drop for GpgHome {
    fn drop(&mut self) {
        if util::which("gpgconf") {
            let home = self.dir.path().to_string_lossy().to_string();
            let _ = run("gpgconf", &["--homedir", &home, "--kill", "all"], 10);
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct KeyInfo {
    pub keyid: String,
    pub validity: String,
    pub expires: i64,
    pub created: i64,
    pub fingerprint: String,
    pub uid: String,
    pub subkeys: Vec<String>,
    pub expired: bool,
    pub revoked: bool,
}

/// Public keys in armored or binary data; secret keys are refused.
pub fn describe_keys(data: &[u8]) -> Result<Vec<KeyInfo>> {
    if !util::which("gpg") {
        bail!("GnuPG (gpg) is not installed.");
    }
    let home = GpgHome::new()?;
    let output = home.gpg(&["--with-colons", "--fixed-list-mode", "--show-keys"], Some(data), 60)?;
    if !output.ok() {
        bail!("The file is not a valid OpenPGP public key.");
    }
    let mut keys: Vec<KeyInfo> = Vec::new();
    let mut in_subkey = false;
    for line in output.out().lines() {
        let fields: Vec<&str> = line.split(':').collect();
        let field = |i: usize| fields.get(i).copied().unwrap_or("");
        match field(0) {
            "sec" | "ssb" => bail!("Secret keys are refused. Provide the public key only."),
            "pub" => {
                keys.push(KeyInfo {
                    keyid: field(4).into(),
                    validity: field(1).into(),
                    expires: field(6).parse().unwrap_or(0),
                    created: field(5).parse().unwrap_or(0),
                    fingerprint: String::new(),
                    uid: String::new(),
                    subkeys: vec![],
                    expired: false,
                    revoked: false,
                });
                in_subkey = false;
            }
            "sub" if !keys.is_empty() => {
                keys.last_mut().unwrap().subkeys.push(field(4).into());
                in_subkey = true;
            }
            "fpr" if !keys.is_empty() && in_subkey => keys.last_mut().unwrap().subkeys.push(field(9).into()),
            "fpr" if !keys.is_empty() && keys.last().unwrap().fingerprint.is_empty() => {
                keys.last_mut().unwrap().fingerprint = field(9).into()
            }
            "uid" if !keys.is_empty() && keys.last().unwrap().uid.is_empty() => {
                keys.last_mut().unwrap().uid = field(9).replace("\\x3a", ":")
            }
            _ => {}
        }
    }
    if keys.is_empty() {
        bail!("No public key was found in the provided data.");
    }
    let now = util::now();
    for key in &mut keys {
        key.expired = key.validity == "e" || (key.expires != 0 && key.expires < now);
        key.revoked = key.validity == "r";
    }
    Ok(keys)
}

/// A binary public keyring containing exactly the keys in `data`.
pub fn to_binary_keyring(data: &[u8]) -> Result<Vec<u8>> {
    describe_keys(data)?;
    let home = GpgHome::new()?;
    let imported = home.gpg(&["--import"], Some(data), 60)?;
    if imported.code != 0 && imported.code != 2 {
        bail!("GnuPG could not import the key.");
    }
    let exported = home.gpg(&["--export"], None, 60)?;
    if !exported.ok() || exported.stdout.is_empty() {
        bail!("GnuPG could not export the key.");
    }
    Ok(exported.stdout)
}

pub fn merge_keyrings(blobs: &[&[u8]]) -> Result<Vec<u8>> {
    let home = GpgHome::new()?;
    for blob in blobs.iter().filter(|b| !b.is_empty()) {
        home.gpg(&["--import"], Some(blob), 60)?;
    }
    let exported = home.gpg(&["--export"], None, 60)?;
    if !exported.ok() || exported.stdout.is_empty() {
        bail!("GnuPG could not merge the keyrings.");
    }
    Ok(exported.stdout)
}

/// True when `data` holds the key (primary or signing subkey) with this ID.
pub fn key_matches(data: &[u8], keyid: &str) -> bool {
    let wanted = keyid.to_uppercase().trim_start_matches("0X").to_string();
    let Ok(keys) = describe_keys(data) else { return false };
    keys.iter().any(|key| {
        std::iter::once(&key.fingerprint)
            .chain(std::iter::once(&key.keyid))
            .chain(key.subkeys.iter())
            .any(|id| !id.is_empty() && (id.to_uppercase().ends_with(&wanted) || wanted.ends_with(&id.to_uppercase())))
    })
}

pub fn fetch_from_keyserver(keyid: &str) -> Result<Vec<u8>> {
    if std::env::var("EUS_TEST_NO_KEYSERVER").is_ok() {
        bail!("Key {keyid} could not be downloaded: keyservers disabled for testing");
    }
    let keyid = keyid.to_uppercase().trim_start_matches("0X").to_string();
    let mut last_error = String::from("no keyserver answered");
    for server in KEYSERVERS {
        let home = GpgHome::new()?;
        let result = home.gpg(&["--keyserver", server, "--recv-keys", &keyid], None, 90);
        if let Ok(result) = result {
            if result.ok() {
                let exported = home.gpg(&["--export", &keyid], None, 60)?;
                if exported.ok() && !exported.stdout.is_empty() && key_matches(&exported.stdout, &keyid) {
                    return Ok(exported.stdout);
                }
            }
            if let Some(line) = result.err().trim().lines().last() {
                last_error = line.to_string();
            }
        }
    }
    // dirmngr often fails behind proxies or firewalls; HKPS is plain HTTPS.
    for server in KEYSERVERS {
        let url = format!("{}/pks/lookup?op=get&options=mr&search=0x{keyid}", server.replace("hkps://", "https://"));
        match fetch_url(&url) {
            Ok(data) if key_matches(&data, &keyid) => return to_binary_keyring(&data),
            Ok(_) => last_error = format!("{server} returned a different key"),
            Err(error) => last_error = error.to_string(),
        }
    }
    bail!("Key {keyid} could not be downloaded: {last_error}")
}

pub fn read_key_file(path_text: &str) -> Result<Vec<u8>> {
    let path = Path::new(path_text);
    if !path.is_absolute() {
        bail!("The key file path must be absolute.");
    }
    let resolved = path.canonicalize().map_err(|_| anyhow!("The key file does not exist."))?;
    let text = resolved.to_string_lossy();
    if ["/proc/", "/sys/", "/dev/", "/run/"].iter().any(|p| text.starts_with(p)) {
        bail!("This location cannot contain a key file.");
    }
    if !resolved.is_file() {
        bail!("The key file does not exist.");
    }
    if std::fs::metadata(&resolved)?.len() as usize > MAX_KEY_BYTES {
        bail!("The key file is too large.");
    }
    Ok(std::fs::read(&resolved)?)
}

pub fn keyring_files() -> Vec<PathBuf> {
    let mut files = Vec::new();
    for dir in [util::trusted_dir(), util::keyrings_dir()] {
        if let Ok(read) = std::fs::read_dir(&dir) {
            let mut found: Vec<PathBuf> = read
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.is_file() && p.extension().is_some_and(|e| e == "gpg" || e == "asc" || e == "pgp"))
                .collect();
            found.sort();
            files.extend(found);
        }
    }
    files
}

/// Debian package that ships a file, or "" (dpkg-query works unprivileged).
pub fn package_owner(path: &str) -> String {
    if !util::root().is_empty() {
        // Tests: EUS_TEST_PACKAGE_OWNER="<path prefix>=<package>".
        return std::env::var("EUS_TEST_PACKAGE_OWNER")
            .ok()
            .and_then(|v| v.split_once('=').map(|(p, n)| (p.to_string(), n.to_string())))
            .filter(|(prefix, _)| path.starts_with(prefix.as_str()))
            .map(|(_, name)| name)
            .unwrap_or_default();
    }
    if !util::which("dpkg-query") {
        return String::new();
    }
    match run("dpkg-query", &["-S", path], 20) {
        Ok(output) if output.ok() => output
            .out()
            .lines()
            .next()
            .and_then(|l| l.split(':').next())
            .and_then(|l| l.split(',').next())
            .map(|l| l.trim().to_string())
            .unwrap_or_default(),
        _ => String::new(),
    }
}

pub fn keyring_role(path: &str) -> &'static str {
    let real = sys(path);
    if real == util::legacy_keyring() {
        "legacy"
    } else if real.parent() == Some(util::trusted_dir().as_path()) {
        "global"
    } else if !package_owner(path).is_empty() {
        "package"
    } else {
        "scoped"
    }
}

pub fn repo_slug(entry: &Entry) -> String {
    static NON_SLUG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^a-z0-9._-]+").unwrap());
    static NON_ALNUM: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^a-z0-9]+").unwrap());
    static SCHEME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-z0-9+.-]+://").unwrap());
    let path = PathBuf::from(&entry.file);
    let alone = all_entries().iter().filter(|e| e.file == entry.file).count() == 1;
    let slug = if path.parent() == Some(util::sources_dir().as_path()) && alone {
        let stem = path.file_stem().unwrap_or_default().to_string_lossy().to_lowercase();
        NON_SLUG.replace_all(&stem, "-").trim_matches(['-', '.']).to_string()
    } else {
        let uri = if entry.uris.is_empty() { "repository".to_string() } else { entry.uri().to_lowercase() };
        NON_ALNUM.replace_all(&SCHEME.replace(&uri, ""), "-").trim_matches('-').to_string()
    };
    let slug = if slug.is_empty() { "repository".to_string() } else { slug };
    slug.chars().take(60).collect()
}

pub fn entries_for_url(url: &str) -> Vec<Entry> {
    let wanted = normalize_uri(url);
    let mut matches: Vec<(usize, Entry)> = Vec::new();
    for entry in all_entries().into_iter().filter(|e| e.enabled) {
        for uri in &entry.uris {
            let candidate = normalize_uri(uri);
            if wanted.starts_with(&candidate) {
                matches.push((candidate.len(), entry.clone()));
            }
        }
    }
    matches.sort_by(|a, b| b.0.cmp(&a.0));
    matches.into_iter().map(|(_, e)| e).collect()
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct KeyTarget {
    pub mode: String,
    pub path: String,
    pub role: String,
    pub reason: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub package: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub fallback: String,
}

fn target(mode: &str, path: String, role: &str, reason: &str) -> KeyTarget {
    KeyTarget { mode: mode.into(), path, role: role.into(), reason: reason.into(), package: String::new(), fallback: String::new() }
}

/// Decide where a repository's signing key belongs, before touching anything.
///
/// * Signed-By file owned by a package (usually /usr/share/keyrings): never
///   edited; its package is reinstalled, and only if that does not help a
///   copy plus the new key goes to /etc/apt/keyrings with Signed-By repointed.
/// * Signed-By file not owned by a package: the key is merged into it.
/// * No Signed-By, distribution repository: archive keyring package first,
///   then /etc/apt/trusted.gpg.d/eus-<key>.gpg.
/// * No Signed-By, third-party repository: /etc/apt/keyrings/<repo>.gpg and a
///   Signed-By option, so the key is trusted for that repository only.
pub fn key_target(entry: Option<&Entry>, keyid: &str) -> KeyTarget {
    let short = keyid[keyid.len().saturating_sub(16)..].to_lowercase();
    let global = plain(&util::trusted_dir().join(format!("eus-{short}.gpg")));
    let Some(entry) = entry else {
        return target("global", global, "global", "repository not found in the source lists");
    };
    let signed_by = entry.signed_by.as_str();
    let role = entry_role(entry, &entry_release(entry));
    if signed_by == "(embedded key)" {
        return target("embedded", entry.file.clone(), "embedded", "the key is embedded in the .sources file");
    }
    if signed_by.starts_with('/') {
        let owner = package_owner(signed_by);
        if !owner.is_empty() {
            let mut result = target("reinstall", signed_by.into(), "package", &format!("{signed_by} belongs to package {owner}"));
            result.package = owner;
            result.fallback = plain(&util::keyrings_dir().join(format!("{}.gpg", repo_slug(entry))));
            return result;
        }
        return target("merge", signed_by.into(), keyring_role(signed_by), "Signed-By keyring of this repository");
    }
    if DISTRO_ROLES.contains(&role) {
        return target("global", global, "global", "distribution repository without Signed-By");
    }
    target("add-signed-by", plain(&util::keyrings_dir().join(format!("{}.gpg", repo_slug(entry)))), "scoped",
           "third-party repository: trust its key for it only")
}

/// Places where repositories commonly publish their signing key (HTTPS only).
pub fn candidate_key_urls(entry: Option<&Entry>) -> Vec<String> {
    if let Ok(list) = std::env::var("EUS_TEST_KEY_URLS") {
        return list.split(',').filter(|s| !s.is_empty()).map(str::to_string).collect();
    }
    let Some(entry) = entry.filter(|e| !e.uris.is_empty()) else { return vec![] };
    let mut uri = entry.uri().trim_end_matches('/').to_string();
    if let Some(rest) = uri.strip_prefix("http://") {
        uri = format!("https://{rest}");
    }
    let Some(rest) = uri.strip_prefix("https://") else { return vec![] };
    let (host, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };
    let host = format!("https://{host}");
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    let bases: Vec<String> = (0..=parts.len()).rev().map(|depth| {
        let mut base = host.clone();
        for part in &parts[..depth] {
            base.push('/');
            base.push_str(part);
        }
        base
    }).collect();
    bases.iter().take(3).flat_map(|base| KEY_FILE_NAMES.iter().map(move |name| format!("{base}/{name}"))).collect()
}

/// Search the internet for the key with this ID: (binary keyring, source).
pub fn find_signing_key(keyid: &str, entry: Option<&Entry>) -> Result<(Vec<u8>, String)> {
    let mut dead_hosts: Vec<String> = Vec::new();
    for url in candidate_key_urls(entry) {
        let host = uri_host(&url);
        if dead_hosts.contains(&host) {
            continue;
        }
        match http_get(&url, MAX_KEY_BYTES, 10) {
            Ok(data) => {
                if key_matches(&data, keyid) {
                    return Ok((to_binary_keyring(&data)?, url));
                }
            }
            Err(error) => {
                let text = error.to_string();
                if !text.contains("404") && !text.contains("403") && !text.contains("Not Found") {
                    dead_hosts.push(host);
                }
            }
        }
    }
    match fetch_from_keyserver(keyid) {
        Ok(data) => Ok((data, "keyserver".into())),
        Err(error) => bail!("No public key {keyid} was found on the repository site or the keyservers. \
                             Ask the repository provider for its key and use Add Key. {error}"),
    }
}

pub fn install_key_into(path: &Path, blob: &[u8]) -> Result<()> {
    let existing = if path.is_file() {
        std::fs::read(path).ok().and_then(|data| to_binary_keyring(&data).ok()).unwrap_or_default()
    } else {
        vec![]
    };
    let merged = if existing.is_empty() { blob.to_vec() } else { merge_keyrings(&[&existing, blob])? };
    atomic_write(path, &merged, 0o644)
}

#[derive(Debug, Clone, Serialize)]
pub struct KeyringFile {
    pub path: String,
    pub problems: Vec<String>,
    pub keys: Vec<KeyInfo>,
    pub role: String,
    pub role_text: String,
    pub package: String,
    pub used_by: Vec<String>,
}

pub fn scan_keys() -> Value {
    let entries = all_entries();
    let referenced: std::collections::BTreeSet<String> =
        entries.iter().filter(|e| e.enabled && e.signed_by.starts_with('/')).map(|e| e.signed_by.clone()).collect();
    let mut paths = keyring_files();
    if util::legacy_keyring().is_file() {
        paths.push(util::legacy_keyring());
    }
    for extra in referenced.iter().map(|p| sys(p)).filter(|p| p.is_file()) {
        if !paths.contains(&extra) {
            paths.push(extra);
        }
    }
    let mut users: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for entry in entries.iter().filter(|e| e.enabled && e.signed_by.starts_with('/')) {
        users.entry(entry.signed_by.clone()).or_default().push(entry.uri().to_string());
    }
    let mut files = Vec::new();
    for path in paths {
        let plain_path = plain(&path);
        let role = keyring_role(&plain_path);
        let mut info = KeyringFile {
            path: path.to_string_lossy().to_string(),
            problems: vec![],
            keys: vec![],
            role: role.into(),
            role_text: role_text(role).into(),
            package: package_owner(&plain_path),
            used_by: users.get(&plain_path).cloned().unwrap_or_default(),
        };
        match (std::fs::metadata(&path), std::fs::read(&path)) {
            (Ok(meta), Ok(data)) => {
                if meta.mode() & 0o004 == 0 {
                    info.problems.push("not world-readable (APT cannot read it)".into());
                }
                let blank = data.iter().all(|b| b.is_ascii_whitespace());
                if blank {
                    info.problems.push("empty file".into());
                } else if path.extension().is_some_and(|e| e == "gpg")
                    && String::from_utf8_lossy(&data).trim_start().starts_with("-----BEGIN PGP")
                {
                    info.problems.push("ASCII-armored data in a .gpg file".into());
                }
                if !blank {
                    match describe_keys(&data) {
                        Ok(keys) => {
                            for key in &keys {
                                if key.expired {
                                    info.problems.push(format!("key {} has expired", key.keyid));
                                }
                                if key.revoked {
                                    info.problems.push(format!("key {} is revoked", key.keyid));
                                }
                            }
                            info.keys = keys;
                        }
                        Err(_) => info.problems.push("damaged or not an OpenPGP keyring".into()),
                    }
                }
            }
            (Err(error), _) | (_, Err(error)) => info.problems.push(format!("unreadable: {error}")),
        }
        if path == util::legacy_keyring() {
            info.problems.push("deprecated legacy keyring /etc/apt/trusted.gpg".into());
        }
        files.push(info);
    }
    let missing: Vec<String> = referenced.into_iter().filter(|p| !sys(p).is_file()).collect();
    json!({"files": files, "missing_signed_by": missing, "apt": apt_problems(None)})
}

fn apply_key(item: &apt::KeyProblem, entry: Option<&Entry>, target: &KeyTarget, blob: &[u8], origin: &str,
             stamp: &str, actions: &mut Vec<String>) -> Result<()> {
    let destination = sys(&target.path);
    if destination.is_file() {
        backup_file(&destination, stamp)?;
    }
    std::fs::create_dir_all(util::keyrings_dir())?;
    install_key_into(&destination, blob)?;
    actions.push(format!("Key {} from {origin} -> {} ({}; {})", item.keyid, target.path, role_text(&target.role), target.reason));
    if target.mode == "add-signed-by" {
        if let Some(entry) = entry {
            set_signed_by(entry, &target.path, stamp)?;
            actions.push(format!("Added Signed-By {} to {}", target.path, entry.file));
        }
    }
    Ok(())
}

fn installed_status(package: &str) -> bool {
    run("dpkg-query", &["-W", "-f=${db:Status-Status}", package], 20).map(|o| o.out().trim() == "installed").unwrap_or(false)
}

fn reinstall(package: &str) -> bool {
    run_with("apt-get", &["install", "--reinstall", "-y", "-q", package],
             RunOptions { timeout: Some(600), env: util::APT_ENV, ..Default::default() })
        .map(|o| o.ok())
        .unwrap_or(false)
}

/// Key Fix: missing/expired keys, legacy keyring, formats, permissions.
pub fn fix_keys() -> Result<Value> {
    require_root()?;
    let stamp = util::stamp();
    let mut actions: Vec<String> = Vec::new();
    let mut errors: Vec<String> = Vec::new();
    progress(5, "Refreshing package lists to detect key problems...");
    let problems = apt_problems(Some(&apt_update_capture()?));
    let wanted: Vec<apt::KeyProblem> = problems.missing_keys.iter().chain(problems.expired_keys.iter()).cloned().collect();
    let mut reinstall_plan: Vec<(String, Vec<(apt::KeyProblem, Option<Entry>, KeyTarget)>)> = Vec::new();
    for (index, item) in wanted.iter().enumerate() {
        progress(20 + (index * 30 / wanted.len().max(1)) as i64, &format!("Downloading missing signing key {}...", item.keyid));
        let entry = if item.url.is_empty() { None } else { entries_for_url(&item.url).into_iter().next() };
        let target = key_target(entry.as_ref(), &item.keyid);
        let outcome: Result<()> = (|| {
            if target.mode == "embedded" {
                bail!("Key {} for {}: {}; replace the embedded key with Add Key.", item.keyid, item.url, target.reason);
            }
            if target.mode == "reinstall" {
                // Never edit a file that dpkg owns; its package provides the key.
                match reinstall_plan.iter_mut().find(|(p, _)| *p == target.package) {
                    Some((_, list)) => list.push((item.clone(), entry.clone(), target.clone())),
                    None => reinstall_plan.push((target.package.clone(), vec![(item.clone(), entry.clone(), target.clone())])),
                }
                return Ok(());
            }
            let (blob, origin) = find_signing_key(&item.keyid, entry.as_ref())?;
            apply_key(item, entry.as_ref(), &target, &blob, &origin, &stamp, &mut actions)
        })();
        if let Err(error) = outcome {
            errors.push(error.to_string());
        }
    }
    for (package, items) in &reinstall_plan {
        actions.push(if reinstall(package) {
            format!("Reinstalled {package}, which owns {}", items[0].2.path)
        } else {
            format!("Reinstalling {package} failed")
        });
    }
    if !reinstall_plan.is_empty() {
        let still: Vec<String> = apt_problems(Some(&apt_update_capture()?)).missing_keys.into_iter().map(|k| k.keyid).collect();
        for (package, items) in &reinstall_plan {
            for (item, entry, target) in items {
                if !still.contains(&item.keyid) {
                    continue;
                }
                let outcome: Result<()> = (|| {
                    // The packaged keyring lacks the new key: copy it plus the key to
                    // /etc/apt/keyrings and repoint Signed-By; the package file stays.
                    let (blob, origin) = find_signing_key(&item.keyid, entry.as_ref())?;
                    let packaged = std::fs::read(sys(&target.path))?;
                    let merged = merge_keyrings(&[&to_binary_keyring(&packaged)?, &blob])?;
                    install_key_into(&sys(&target.fallback), &merged)?;
                    let entry = entry.as_ref().ok_or_else(|| anyhow!("repository entry not found"))?;
                    set_signed_by(entry, &target.fallback, &stamp)?;
                    actions.push(format!("{} (package {package}) lacks key {}: copied it with the key from {origin} to {} and pointed {} at it",
                                         target.path, item.keyid, target.fallback, entry.file));
                    Ok(())
                })();
                if let Err(error) = outcome {
                    errors.push(error.to_string());
                }
            }
        }
    }

    progress(55, "Moving keys out of the legacy trusted.gpg keyring...");
    let legacy = util::legacy_keyring();
    if legacy.is_file() {
        let outcome: Result<usize> = (|| {
            let data = std::fs::read(&legacy)?;
            let keys = if data.iter().all(|b| b.is_ascii_whitespace()) { vec![] } else { describe_keys(&data)? };
            let home = GpgHome::new()?;
            home.gpg(&["--import"], Some(&data), 60)?;
            for key in &keys {
                let id = if key.fingerprint.is_empty() { &key.keyid } else { &key.fingerprint };
                let exported = home.gpg(&["--export", id], None, 60)?;
                if !exported.ok() || exported.stdout.is_empty() {
                    bail!("Key {} could not be exported.", key.keyid);
                }
                let short = key.keyid[key.keyid.len().saturating_sub(16)..].to_lowercase();
                atomic_write(&util::trusted_dir().join(format!("eus-legacy-{short}.gpg")), &exported.stdout, 0o644)?;
            }
            backup_file(&legacy, &stamp)?;
            std::fs::remove_file(&legacy)?;
            Ok(keys.len())
        })();
        match outcome {
            Ok(count) => actions.push(format!("Migrated {count} keys from {} to {}", legacy.display(), util::trusted_dir().display())),
            Err(error) => errors.push(format!("Legacy keyring was kept: {error}")),
        }
    }

    progress(65, "Repairing keyring formats and permissions...");
    let quarantine = util::backup_base().join(&stamp).join("damaged-keyrings");
    for path in keyring_files() {
        let outcome: Result<()> = (|| {
            let data = std::fs::read(&path)?;
            if data.iter().all(|b| b.is_ascii_whitespace()) {
                bail!("empty");
            }
            if path.extension().is_some_and(|e| e == "gpg") && String::from_utf8_lossy(&data).trim_start().starts_with("-----BEGIN PGP") {
                backup_file(&path, &stamp)?;
                atomic_write(&path, &to_binary_keyring(&data)?, 0o644)?;
                actions.push(format!("Converted armored keyring {} to binary format", path.display()));
            } else {
                describe_keys(&data)?;
            }
            let meta = std::fs::metadata(&path)?;
            if meta.mode() & 0o777 != 0o644 || meta.uid() != 0 {
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644))?;
                if util::is_root() {
                    std::os::unix::fs::chown(&path, Some(0), Some(0))?;
                }
                actions.push(format!("Fixed permissions on {}", path.display()));
            }
            Ok(())
        })();
        if outcome.is_err() {
            // Quarantine only in trusted.gpg.d: APT loads all of them and a
            // damaged one breaks verification for every repository.
            if path.parent() == Some(util::trusted_dir().as_path()) {
                let _ = std::fs::create_dir_all(&quarantine);
                let target = quarantine.join(path.file_name().unwrap_or_default());
                if std::fs::rename(&path, &target).is_err() {
                    let _ = std::fs::copy(&path, &target).and_then(|_| std::fs::remove_file(&path));
                }
                actions.push(format!("Moved damaged keyring {} to {}", path.display(), quarantine.display()));
            } else {
                errors.push(format!("Damaged keyring {}; re-add it with Add Key.", path.display()));
            }
        }
    }
    for dir in [util::trusted_dir(), util::keyrings_dir()] {
        if let Ok(meta) = std::fs::metadata(&dir) {
            if meta.is_dir() && meta.mode() & 0o755 != 0o755 {
                let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755));
                actions.push(format!("Fixed permissions on {}", dir.display()));
            }
        }
    }

    progress(75, "Reinstalling distribution archive keyrings...");
    for package in ARCHIVE_KEYRING_PACKAGES {
        if reinstall_plan.iter().any(|(p, _)| p == package) || !installed_status(package) {
            continue;
        }
        if reinstall(package) {
            actions.push(format!("Reinstalled {package}"));
        }
    }
    progress(85, "Verifying repositories...");
    let remaining = apt_problems(Some(&apt_update_capture()?));
    progress(100, "Complete.");
    let backup = util::backup_base().join(&stamp);
    Ok(json!({"actions": actions, "errors": errors, "remaining": remaining,
              "backup": if backup.exists() { backup.to_string_lossy().to_string() } else { String::new() }}))
}

/// Options shared by Add Key and Add Repository.
#[derive(Debug, Default, Clone)]
pub struct RepoSpec {
    pub name: String,
    pub file: Option<String>,
    pub url: Option<String>,
    pub keyserver: Option<String>,
    pub line: Option<String>,
    pub repo_uri: Option<String>,
    pub suite: Option<String>,
    pub components: Option<String>,
    pub arch: Option<String>,
    pub with_source: bool,
    pub auto_key: bool,
}

fn clean_name(name: &str) -> Result<String> {
    let mut name = name.trim().to_lowercase();
    if name.ends_with(".gpg") || name.ends_with(".asc") {
        name.truncate(name.len() - 4);
    }
    if !NAME_RE.is_match(&name) {
        bail!("Invalid name: use lowercase letters, digits, dots, dashes or underscores.");
    }
    Ok(name)
}

fn words(value: &Option<String>) -> Vec<String> {
    value.as_deref().unwrap_or("").split_whitespace().map(str::to_string).collect()
}

pub fn add_key(spec: &RepoSpec) -> Result<Value> {
    require_root()?;
    let name = clean_name(&spec.name)?;
    progress(10, "Installing the signing key...");
    let data = if let Some(file) = &spec.file {
        read_key_file(file)?
    } else if let Some(url) = &spec.url {
        fetch_url(url)?
    } else if let Some(id) = &spec.keyserver {
        if !KEYID_RE.is_match(id.trim()) {
            bail!("Invalid key ID or fingerprint.");
        }
        fetch_from_keyserver(id.trim())?
    } else {
        bail!("No key source was provided.");
    };
    let keys = describe_keys(&data)?;
    let blob = to_binary_keyring(&data)?;
    let mut actions: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();
    if keys.iter().any(|k| k.expired || k.revoked) {
        warnings.push("The key is expired or revoked; APT may still reject the repository.".into());
    }
    let repo_uri = spec.repo_uri.as_deref().unwrap_or("").trim().to_string();
    if repo_uri.is_empty() {
        let destination = util::trusted_dir().join(format!("{name}.gpg"));
        install_key_into(&destination, &blob)?;
        actions.push(format!("Installed key into {}", destination.display()));
        progress(100, "Complete.");
        return Ok(json!({"keys": keys, "actions": actions, "warnings": warnings}));
    }
    if !URI_RE.is_match(&repo_uri) {
        bail!("Invalid repository URI.");
    }
    let suite = spec.suite.as_deref().unwrap_or("").trim().to_string();
    if !SUITE_RE.is_match(&suite) {
        bail!("Invalid repository suite.");
    }
    let components = words(&spec.components);
    if components.iter().any(|c| !COMPONENT_RE.is_match(c)) || (components.is_empty() && !suite.ends_with('/')) {
        bail!("Invalid repository components.");
    }
    let architectures = words(&spec.arch);
    if architectures.iter().any(|a| !ARCH_RE.is_match(a)) {
        bail!("Invalid architecture.");
    }
    let mut types = vec!["deb".to_string()];
    if spec.with_source {
        types.push("deb-src".into());
    }
    progress(45, "Adding the repository...");
    let probe = probe_entry(&types, &repo_uri, &suite, &components);
    let wanted = entry_keys(&probe);
    let existing: Vec<Entry> =
        all_entries().into_iter().filter(|e| e.enabled && entry_keys(e).iter().any(|k| wanted.contains(k))).collect();
    if let Some(first) = existing.first() {
        // Never create a duplicate; make the key usable for the existing entry.
        let destination = if first.signed_by.starts_with('/') { sys(&first.signed_by) } else { util::trusted_dir().join(format!("{name}.gpg")) };
        install_key_into(&destination, &blob)?;
        actions.push(format!("Installed key into {}", destination.display()));
        warnings.push(format!("The repository already exists in {}; no duplicate entry was added.", first.file));
        progress(100, "Complete.");
        return Ok(json!({"keys": keys, "actions": actions, "warnings": warnings}));
    }
    let keyring = util::keyrings_dir().join(format!("{name}.gpg"));
    std::fs::create_dir_all(util::keyrings_dir())?;
    install_key_into(&keyring, &blob)?;
    actions.push(format!("Installed key into {}", keyring.display()));
    let mut stanza = vec![format!("Types: {}", types.join(" ")), format!("URIs: {repo_uri}"), format!("Suites: {suite}")];
    if !components.is_empty() {
        stanza.push(format!("Components: {}", components.join(" ")));
    }
    if !architectures.is_empty() {
        stanza.push(format!("Architectures: {}", architectures.join(" ")));
    }
    stanza.push(format!("Signed-By: {}", plain(&keyring)));
    let source_file = util::sources_dir().join(format!("{name}.sources"));
    if source_file.exists() {
        backup_file(&source_file, &util::stamp())?;
    }
    atomic_write(&source_file, format!("# Added by Eduka-Update-System\n{}\n", stanza.join("\n")).as_bytes(), 0o644)?;
    actions.push(format!("Added repository {}", source_file.display()));
    progress(100, "Complete.");
    Ok(json!({"keys": keys, "actions": actions, "warnings": warnings}))
}

fn probe_entry(types: &[String], uri: &str, suite: &str, components: &[String]) -> Entry {
    Entry {
        file: String::new(), format: "list".into(), line: 0, last_line: 0, types: types.to_vec(),
        uris: vec![uri.to_string()], suites: vec![suite.to_string()], components: components.to_vec(),
        signed_by: String::new(), enabled: true,
    }
}

pub fn parse_repo_line(line: &str) -> Result<(Vec<String>, String, String, Vec<String>, String, String)> {
    static RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^\s*(deb|deb-src)\s+(\[([^\]]*)\]\s*)?(\S+)\s+(\S+)\s*(.*?)\s*$").unwrap());
    let caps = RE.captures(line)
        .ok_or_else(|| anyhow!("Enter a repository line such as: deb https://repo.example.org/debian stable main"))?;
    let options = sources::parse_options(caps.get(3).map(|m| m.as_str()).unwrap_or(""));
    Ok((vec![caps[1].to_string()], caps[4].to_string(), caps[5].to_string(),
        caps[6].split_whitespace().map(str::to_string).collect(),
        options.get("arch").cloned().unwrap_or_default().replace(',', " "),
        options.get("signed-by").cloned().unwrap_or_default()))
}

/// Add a repository, refresh it alone, find and install its key, verify.
pub fn add_repo(spec: &RepoSpec) -> Result<Value> {
    require_root()?;
    let name = spec.name.trim().to_lowercase();
    if !NAME_RE.is_match(&name) {
        bail!("Invalid name: use lowercase letters, digits, dots, dashes or underscores.");
    }
    let (mut types, uri, suite, components, arch, signed_by) = match &spec.line {
        Some(line) => parse_repo_line(line)?,
        None => (vec!["deb".into()], spec.repo_uri.clone().unwrap_or_default().trim().to_string(),
                 spec.suite.clone().unwrap_or_default().trim().to_string(), words(&spec.components),
                 spec.arch.clone().unwrap_or_default(), String::new()),
    };
    if spec.with_source && !types.iter().any(|t| t == "deb-src") {
        types.push("deb-src".into());
    }
    if !URI_RE.is_match(&uri) {
        bail!("Invalid repository URI.");
    }
    if !SUITE_RE.is_match(&suite) {
        bail!("Invalid repository suite.");
    }
    if components.iter().any(|c| !COMPONENT_RE.is_match(c)) || (components.is_empty() && !suite.ends_with('/')) {
        bail!("Invalid repository components.");
    }
    let architectures: Vec<String> = arch.split_whitespace().map(str::to_string).collect();
    if architectures.iter().any(|a| !ARCH_RE.is_match(a)) {
        bail!("Invalid architecture.");
    }
    if !signed_by.is_empty() && !sys(&signed_by).is_file() {
        bail!("The signed-by keyring {signed_by} does not exist.");
    }
    let probe = probe_entry(&types, &uri, &suite, &components);
    let wanted = entry_keys(&probe);
    if let Some(existing) = all_entries().into_iter().find(|e| e.enabled && entry_keys(e).iter().any(|k| wanted.contains(k))) {
        bail!("This repository is already configured in {}.", existing.file);
    }
    let source_file = util::sources_dir().join(format!("{name}.sources"));
    if source_file.exists() {
        bail!("{} already exists; choose another name.", source_file.display());
    }
    let keyring_path = plain(&util::keyrings_dir().join(format!("{name}.gpg")));
    let mut stanza = vec![format!("Types: {}", types.join(" ")), format!("URIs: {uri}"), format!("Suites: {suite}")];
    if !components.is_empty() {
        stanza.push(format!("Components: {}", components.join(" ")));
    }
    if !architectures.is_empty() {
        stanza.push(format!("Architectures: {}", architectures.join(" ")));
    }
    if !signed_by.is_empty() {
        stanza.push(format!("Signed-By: {signed_by}"));
    }
    let write_source = |extra: &[String]| -> Result<()> {
        let mut all = stanza.clone();
        all.extend_from_slice(extra);
        atomic_write(&source_file, format!("# Added by Eduka-Update-System\n{}\n", all.join("\n")).as_bytes(), 0o644)
    };
    progress(5, "Adding the repository...");
    std::fs::create_dir_all(util::sources_dir())?;
    write_source(&[])?;
    let mut created_keyring = false;
    let mut keys: Vec<KeyInfo> = Vec::new();
    let mut key_source = String::new();
    let mut actions: Vec<String> = Vec::new();
    let outcome: Result<()> = (|| {
        progress(15, "Refreshing package lists to detect key problems...");
        let mut problems: AptProblems = apt_problems(Some(&apt_update_isolated(&source_file)?));
        if let Some(item) = problems.unreachable.first() {
            bail!("The repository cannot be reached: {} ({}). Check the address, suite and network.", item.url, item.reason);
        }
        let missing: Vec<apt::KeyProblem> = problems.missing_keys.iter().chain(problems.expired_keys.iter()).cloned().collect();
        if let Some(first) = missing.first() {
            if !spec.auto_key {
                bail!("The repository is signed with key {}, which is not installed. Enable automatic key search or use Add Key.", first.keyid);
            }
        }
        let probe_for_urls = probe_entry(&types, &uri, &suite, &components);
        for (index, item) in missing.iter().enumerate() {
            progress(35 + 10 * index as i64, &format!("Downloading missing signing key {}...", item.keyid));
            let (blob, origin) = find_signing_key(&item.keyid, Some(&probe_for_urls))?;
            std::fs::create_dir_all(util::keyrings_dir())?;
            install_key_into(&sys(&keyring_path), &blob)?;
            created_keyring = true;
            keys.extend(describe_keys(&blob)?);
            key_source = origin.clone();
            actions.push(format!("Found key {} at {origin} and installed it into {keyring_path}", item.keyid));
        }
        if created_keyring {
            write_source(&[format!("Signed-By: {keyring_path}")])?;
            progress(70, "Verifying repositories...");
            problems = apt_problems(Some(&apt_update_isolated(&source_file)?));
            if let Some(left) = problems.missing_keys.iter().chain(problems.expired_keys.iter()).next() {
                bail!("The repository still cannot be verified (key {}).", left.keyid);
            }
        }
        if !problems.unsigned.is_empty() {
            bail!("The repository is not signed (no InRelease or Release.gpg); EUS refuses to add unsigned repositories.");
        }
        Ok(())
    })();
    if let Err(error) = outcome {
        let _ = std::fs::remove_file(&source_file);
        if created_keyring {
            let _ = std::fs::remove_file(sys(&keyring_path));
        }
        return Err(error);
    }
    actions.push(format!("Added repository {}", source_file.display()));
    progress(100, "Complete.");
    Ok(json!({"source": source_file.to_string_lossy(), "keyring": if created_keyring { keyring_path } else { String::new() },
              "keys": keys, "key_source": key_source, "actions": actions, "warnings": Vec::<String>::new()}))
}
