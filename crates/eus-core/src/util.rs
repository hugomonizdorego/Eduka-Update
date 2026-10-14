//! Process, file and path helpers shared by every EUS component.

use anyhow::{anyhow, bail, Context, Result};
use std::ffi::OsStr;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::Duration;
use wait_timeout::ChildExt;

/// Test prefix: `EUS_APT_ROOT=/tmp/x` makes every system path live below it.
pub fn root() -> &'static str {
    static ROOT: OnceLock<String> = OnceLock::new();
    ROOT.get_or_init(|| std::env::var("EUS_APT_ROOT").unwrap_or_default().trim_end_matches('/').to_string())
}

/// A system path, below the test prefix when one is set.
pub fn sys(path: &str) -> PathBuf {
    PathBuf::from(format!("{}{}", root(), path))
}

/// The path as APT sees it (without the test prefix).
pub fn plain(path: &Path) -> String {
    let text = path.to_string_lossy().to_string();
    match text.strip_prefix(root()) {
        Some(rest) if !root().is_empty() => rest.to_string(),
        _ => text,
    }
}

pub fn apt_dir() -> PathBuf { sys("/etc/apt") }
pub fn sources_list() -> PathBuf { apt_dir().join("sources.list") }
pub fn sources_dir() -> PathBuf { apt_dir().join("sources.list.d") }
pub fn trusted_dir() -> PathBuf { apt_dir().join("trusted.gpg.d") }
pub fn keyrings_dir() -> PathBuf { apt_dir().join("keyrings") }
pub fn legacy_keyring() -> PathBuf { apt_dir().join("trusted.gpg") }
pub fn state_dir() -> PathBuf { sys("/var/lib/eus") }
pub fn apt_update_log() -> PathBuf { state_dir().join("apt-update.log") }
pub fn report_file() -> PathBuf { state_dir().join("repair-report.json") }
pub fn backup_base() -> PathBuf { sys("/var/backups/eus") }
pub fn os_upgrade_file() -> PathBuf { state_dir().join("os-upgrade") }
pub fn health_file() -> PathBuf { state_dir().join("health.json") }
pub fn lists_dir() -> PathBuf {
    match std::env::var("EUS_LISTS_DIR") {
        Ok(value) if !value.is_empty() => PathBuf::from(value),
        _ => sys("/var/lib/apt/lists"),
    }
}

/// Output of a finished command.
#[derive(Debug, Default, Clone)]
pub struct Output {
    pub code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl Output {
    pub fn ok(&self) -> bool { self.code == 0 }
    pub fn out(&self) -> String { String::from_utf8_lossy(&self.stdout).to_string() }
    pub fn err(&self) -> String { String::from_utf8_lossy(&self.stderr).to_string() }
    pub fn all(&self) -> String { format!("{}{}", self.out(), self.err()) }
}

/// Options for [`run`].
#[derive(Default)]
pub struct RunOptions<'a> {
    pub timeout: Option<u64>,
    pub input: Option<&'a [u8]>,
    pub env: &'a [(&'a str, &'a str)],
}

/// Run a program with a timeout, capturing its output. A missing program
/// gives exit code 127, like a shell; a timeout is an error.
pub fn run_with<S: AsRef<OsStr>>(program: &str, args: &[S], options: RunOptions) -> Result<Output> {
    let mut command = Command::new(program);
    command.args(args).stdout(Stdio::piped()).stderr(Stdio::piped());
    command.stdin(if options.input.is_some() { Stdio::piped() } else { Stdio::null() });
    for (key, value) in options.env {
        command.env(key, value);
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Output { code: 127, stdout: vec![], stderr: error.to_string().into_bytes() })
        }
        Err(error) => return Err(error).with_context(|| format!("cannot start {program}")),
    };
    if let (Some(input), Some(mut stdin)) = (options.input, child.stdin.take()) {
        let data = input.to_vec();
        std::thread::spawn(move || {
            let _ = stdin.write_all(&data);
        });
    }
    let mut stdout = child.stdout.take().expect("piped stdout");
    let mut stderr = child.stderr.take().expect("piped stderr");
    let out_thread = std::thread::spawn(move || {
        let mut buffer = Vec::new();
        let _ = stdout.read_to_end(&mut buffer);
        buffer
    });
    let err_thread = std::thread::spawn(move || {
        let mut buffer = Vec::new();
        let _ = stderr.read_to_end(&mut buffer);
        buffer
    });
    let seconds = options.timeout.unwrap_or(120);
    let status = match child.wait_timeout(Duration::from_secs(seconds))? {
        Some(status) => status,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            bail!("A system command timed out: {program}");
        }
    };
    Ok(Output {
        code: status.code().unwrap_or(-1),
        stdout: out_thread.join().unwrap_or_default(),
        stderr: err_thread.join().unwrap_or_default(),
    })
}

/// [`run_with`] with a timeout in seconds and default options.
pub fn run<S: AsRef<OsStr>>(program: &str, args: &[S], timeout: u64) -> Result<Output> {
    run_with(program, args, RunOptions { timeout: Some(timeout), ..Default::default() })
}

/// `C` locale environment for parsing command output.
pub const C_LOCALE: &[(&str, &str)] = &[("LC_ALL", "C"), ("LANG", "C")];
/// Non-interactive APT environment.
pub const APT_ENV: &[(&str, &str)] = &[("LC_ALL", "C"), ("DEBIAN_FRONTEND", "noninteractive")];

pub fn which(program: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(program).is_file()))
        .unwrap_or(false)
}

pub fn is_root() -> bool {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() == 0 }
}

pub fn require_root() -> Result<()> {
    if !is_root() && root().is_empty() {
        bail!("This action must run through the EUS privileged backend.");
    }
    Ok(())
}

/// The EUS progress protocol understood by the GUI and the terminal.
pub fn progress(value: i64, text: &str) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{}\n# {}", value.clamp(0, 100), crate::i18n::translate(text));
    let _ = out.flush();
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Local time stamp for backup directories, e.g. 20261013-141500.
pub fn stamp() -> String {
    let mut buffer = [0u8; 32];
    // SAFETY: localtime_r and strftime write into stack buffers we own.
    unsafe {
        let time = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&time, &mut tm);
        let length = libc::strftime(buffer.as_mut_ptr() as *mut libc::c_char, buffer.len(),
                                    c"%Y%m%d-%H%M%S".as_ptr(), &tm);
        String::from_utf8_lossy(&buffer[..length]).to_string()
    }
}

pub fn read_text(path: &Path) -> Option<String> {
    fs::read(path).ok().map(|bytes| String::from_utf8_lossy(&bytes).to_string())
}

/// Write a file atomically (temporary file + rename) with the given mode.
pub fn atomic_write(path: &Path, data: &[u8], mode: u32) -> Result<()> {
    let parent = path.parent().ok_or_else(|| anyhow!("{} has no parent", path.display()))?;
    fs::create_dir_all(parent)?;
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let mut temporary = tempfile::Builder::new().prefix(&format!(".{name}.")).tempfile_in(parent)?;
    temporary.write_all(data)?;
    temporary.as_file().set_permissions(fs::Permissions::from_mode(mode))?;
    temporary.persist(path).map_err(|e| anyhow!("cannot write {}: {}", path.display(), e.error))?;
    Ok(())
}

/// Keep the current permission bits of a file (default 0644).
pub fn file_mode(path: &Path) -> u32 {
    fs::metadata(path).map(|m| m.permissions().mode() & 0o777).ok().filter(|m| *m != 0).unwrap_or(0o644)
}

/// Copy a file below /var/backups/eus/<stamp>/ keeping its full path.
pub fn backup_file(path: &Path, stamp: &str) -> Result<()> {
    let relative = path.to_string_lossy().trim_start_matches('/').to_string();
    let destination = backup_base().join(stamp).join(relative);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(path, &destination).with_context(|| format!("cannot back up {}", path.display()))?;
    Ok(())
}

pub fn write_report(kind: &str, payload: serde_json::Value) {
    let mut object = serde_json::Map::new();
    object.insert("kind".into(), kind.into());
    object.insert("time".into(), now().into());
    if let serde_json::Value::Object(map) = payload {
        object.extend(map);
    }
    let text = serde_json::to_string_pretty(&serde_json::Value::Object(object)).unwrap_or_default();
    let _ = atomic_write(&report_file(), text.as_bytes(), 0o644);
}

/// Natural sort key: 6.12.10 sorts after 6.12.9.
pub fn version_key(text: &str) -> Vec<(u8, u64, String)> {
    let mut key = Vec::new();
    let mut digits = String::new();
    let mut other = String::new();
    for ch in text.chars() {
        if ch.is_ascii_digit() {
            if !other.is_empty() {
                key.push((1, 0, std::mem::take(&mut other)));
            }
            digits.push(ch);
        } else {
            if !digits.is_empty() {
                key.push((0, digits.parse().unwrap_or(u64::MAX), String::new()));
                digits.clear();
            }
            other.push(ch);
        }
    }
    if !digits.is_empty() {
        key.push((0, digits.parse().unwrap_or(u64::MAX), String::new()));
    }
    if !other.is_empty() {
        key.push((1, 0, other));
    }
    key
}

/// Compare Debian versions with dpkg when available, else naturally.
pub fn compare_versions(left: &str, right: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    if which("dpkg") {
        for (operator, value) in [("lt", Ordering::Less), ("gt", Ordering::Greater)] {
            if run("dpkg", &["--compare-versions", left, operator, right], 5).map(|o| o.ok()).unwrap_or(false) {
                return value;
            }
        }
        return Ordering::Equal;
    }
    version_key(left).cmp(&version_key(right))
}

/// Major number of a version such as "13.1" (0 when there is none).
pub fn major(version: &str) -> i64 {
    version.chars().take_while(|c| c.is_ascii_digit()).collect::<String>().parse().unwrap_or(0)
}

/// Parse simple KEY=value files (shell-style quotes are removed).
pub fn read_key_values(path: &Path) -> std::collections::BTreeMap<String, String> {
    let mut result = std::collections::BTreeMap::new();
    if let Some(text) = read_text(path) {
        for line in text.lines() {
            let trimmed = line.trim_start();
            if trimmed.starts_with('#') {
                continue;
            }
            if let Some((key, value)) = line.split_once('=') {
                result.insert(key.trim().to_string(), value.trim().trim_matches(|c| c == '\'' || c == '"').to_string());
            }
        }
    }
    result
}

pub fn format_bytes(value: u64) -> String {
    let mut size = value as f64;
    for unit in ["B", "KB", "MB", "GB"] {
        if size < 1024.0 || unit == "GB" {
            return if unit == "B" { format!("{size:.0} {unit}") } else { format!("{size:.1} {unit}") };
        }
        size /= 1024.0;
    }
    "0 B".into()
}
