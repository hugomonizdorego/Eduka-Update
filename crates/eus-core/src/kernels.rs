//! Installed and installable Linux kernels.

use crate::util::{compare_versions, run_with, version_key, RunOptions, C_LOCALE};
use anyhow::{bail, Result};
use regex::Regex;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::LazyLock;

static KERNEL_PACKAGE_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^linux-(image|headers|modules|modules-extra|image-unsigned)-[a-z0-9][a-z0-9.+~-]*$").unwrap()
});
static RELEASE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^linux-image-(?:unsigned-)?(\d\S*?)(?:-unsigned)?$").unwrap());
static FLAVOUR_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\d+\.\d+(?:\.\d+)?(?:-\d+)?(?:[+~][^-]*)?-(.+)$").unwrap());
static REMOVED_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^(?:Remv|Purg) (\S+)").unwrap());

/// linux-image-6.12.38+deb13-amd64 -> 6.12.38+deb13-amd64; "" for metapackages.
pub fn kernel_release(package: &str) -> String {
    if package.ends_with("-dbg") {
        return String::new();
    }
    RELEASE_RE.captures(package).map(|c| c[1].to_string()).unwrap_or_default()
}

pub fn kernel_flavour(release: &str) -> String {
    FLAVOUR_RE.captures(release).map(|c| c[1].to_string()).unwrap_or_default()
}

pub fn running_release() -> String {
    if let Ok(value) = std::env::var("EUS_TEST_RUNNING_KERNEL") {
        return value;
    }
    // SAFETY: uname fills a zeroed struct we own.
    unsafe {
        let mut name: libc::utsname = std::mem::zeroed();
        if libc::uname(&mut name) != 0 {
            return String::new();
        }
        std::ffi::CStr::from_ptr(name.release.as_ptr()).to_string_lossy().to_string()
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct DpkgPackage {
    pub name: String,
    pub version: String,
    pub status: String,
    pub size_kb: u64,
}

pub fn dpkg_packages(pattern: &str) -> Vec<DpkgPackage> {
    let format = "-f=${Package}\t${Version}\t${db:Status-Status}\t${Installed-Size}\n";
    let Ok(output) = run_with("dpkg-query", &["-W", format, pattern],
                              RunOptions { timeout: Some(30), ..Default::default() }) else { return vec![] };
    output
        .out()
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            if fields.len() != 4
                || !["installed", "config-files", "half-configured", "unpacked", "half-installed"].contains(&fields[2])
            {
                return None;
            }
            Some(DpkgPackage { name: fields[0].into(), version: fields[1].into(), status: fields[2].into(),
                               size_kb: fields[3].parse().unwrap_or(0) })
        })
        .collect()
}

pub fn related_packages(release: &str, installed: &BTreeSet<String>) -> Vec<String> {
    let mut names: Vec<String> = ["image", "image-unsigned", "modules", "modules-extra", "headers", "tools", "cloud-tools"]
        .iter()
        .map(|prefix| format!("linux-{prefix}-{release}"))
        .collect();
    names.push(format!("linux-image-{release}-unsigned"));
    let flavour = kernel_flavour(release);
    if !flavour.is_empty() {
        let base = &release[..release.len() - flavour.len() - 1];
        let others: BTreeSet<String> =
            installed.iter().map(|n| kernel_release(n)).filter(|r| !r.is_empty() && r != release).collect();
        if !others.iter().any(|r| r.starts_with(&format!("{base}-"))) {
            // Debian: linux-headers-<abi>-common; Ubuntu: linux-headers-<abi>.
            names.push(format!("linux-headers-{base}-common"));
            names.push(format!("linux-headers-{base}"));
        }
    }
    names.into_iter().filter(|n| installed.contains(n)).collect()
}

pub fn apt_show(packages: &[String]) -> HashMap<String, BTreeMap<String, String>> {
    let mut info = HashMap::new();
    if packages.is_empty() {
        return info;
    }
    let mut args = vec!["show".to_string(), "--no-all-versions".to_string()];
    args.extend_from_slice(packages);
    let Ok(output) = run_with("apt-cache", &args, RunOptions { timeout: Some(60), env: C_LOCALE, ..Default::default() })
    else {
        return info;
    };
    let mut current: BTreeMap<String, String> = BTreeMap::new();
    for line in output.out().lines().chain(std::iter::once("")) {
        if line.trim().is_empty() {
            if let Some(name) = current.get("Package").cloned() {
                info.entry(name).or_insert_with(|| current.clone());
            }
            current.clear();
        } else if !line.starts_with(' ') {
            if let Some((key, value)) = line.split_once(':') {
                current.entry(key.to_string()).or_insert_with(|| value.trim().to_string());
            }
        }
    }
    info
}

#[derive(Debug, Clone, Serialize)]
pub struct InstalledKernel {
    pub release: String,
    pub package: String,
    pub version: String,
    pub status: String,
    pub size_kb: u64,
    pub boot_image: bool,
    pub packages: Vec<String>,
    pub state: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct MetaPackage {
    pub package: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct AvailableKernel {
    pub package: String,
    pub release: String,
    pub version: String,
    pub meta: bool,
    pub size: u64,
    pub description: String,
    pub headers: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct KernelList {
    pub running: String,
    pub flavour: String,
    pub installed: Vec<InstalledKernel>,
    pub metas: Vec<MetaPackage>,
    pub available: Vec<AvailableKernel>,
    pub headers_installed: bool,
    pub old_count: usize,
}

pub fn list_kernels(include_available: bool) -> KernelList {
    let running = running_release();
    let flavour = kernel_flavour(&running);
    let images = dpkg_packages("linux-image-*");
    let installed_names: BTreeSet<String> = dpkg_packages("linux-*").into_iter().map(|p| p.name).collect();
    let mut kernels: BTreeMap<String, InstalledKernel> = BTreeMap::new();
    let mut metas = Vec::new();
    for package in images {
        let release = kernel_release(&package.name);
        if release.is_empty() {
            if package.status == "installed" && !package.name.ends_with("-dbg") {
                metas.push(MetaPackage { package: package.name, version: package.version });
            }
            continue;
        }
        let entry = kernels.entry(release.clone()).or_insert_with(|| InstalledKernel {
            release: release.clone(), package: package.name.clone(), version: package.version.clone(),
            status: package.status.clone(), size_kb: 0, boot_image: false, packages: vec![], state: String::new(),
        });
        entry.size_kb += package.size_kb;
    }
    for (release, entry) in kernels.iter_mut() {
        entry.packages = related_packages(release, &installed_names);
        entry.boot_image = std::path::Path::new(&format!("/boot/vmlinuz-{release}")).exists();
        entry.state = if entry.status == "config-files" {
            "residual"
        } else if *release == running {
            "running"
        } else if compare_versions(release, &running) == std::cmp::Ordering::Less {
            "old"
        } else {
            "newer"
        }
        .into();
    }
    let mut ordered: Vec<InstalledKernel> = kernels.values().cloned().collect();
    ordered.sort_by_key(|k| std::cmp::Reverse(version_key(&k.release)));
    let old_count = ordered.iter().filter(|k| k.state == "old" || k.state == "residual").count();
    let mut result = KernelList { running: running.clone(), flavour: flavour.clone(), installed: ordered, metas,
                                  available: vec![], headers_installed: false, old_count };
    if !include_available {
        return result;
    }
    let names: BTreeSet<String> = run_with("apt-cache", &["pkgnames", "linux-image-"],
                                           RunOptions { timeout: Some(60), ..Default::default() })
        .map(|o| o.out().split_whitespace().map(str::to_string).collect())
        .unwrap_or_default();
    let mut versioned = Vec::new();
    let mut meta_names = Vec::new();
    for name in names {
        let release = kernel_release(&name);
        if !release.is_empty() {
            if name.contains("unsigned") || kernel_flavour(&release) != flavour || kernels.contains_key(&release) {
                continue;
            }
            versioned.push(name);
        } else if !flavour.is_empty() && name.contains(&flavour) && !name.ends_with("-dbg")
            && !name.ends_with("-unsigned") && !name.contains("signed-")
        {
            meta_names.push(name);
        }
    }
    versioned.sort_by_key(|n| std::cmp::Reverse(version_key(&kernel_release(n))));
    versioned.truncate(15);
    meta_names.sort();
    meta_names.truncate(10);
    let details = apt_show(&versioned.iter().chain(meta_names.iter()).cloned().collect::<Vec<_>>());
    let installed_meta: BTreeSet<String> = result.metas.iter().map(|m| m.package.clone()).collect();
    for name in meta_names.iter().chain(versioned.iter()) {
        let Some(data) = details.get(name) else { continue };
        let release = kernel_release(name);
        if release.is_empty() && installed_meta.contains(name) {
            continue;
        }
        let headers = if release.is_empty() { name.replacen("linux-image-", "linux-headers-", 1) } else { format!("linux-headers-{release}") };
        result.available.push(AvailableKernel {
            package: name.clone(), meta: release.is_empty(), release,
            version: data.get("Version").cloned().unwrap_or_default(),
            size: data.get("Size").and_then(|s| s.parse().ok()).unwrap_or(0),
            description: data.get("Description").or_else(|| data.get("Description-en")).cloned().unwrap_or_default(),
            headers,
        });
    }
    result.headers_installed = installed_names.iter().any(|n| n.starts_with(&format!("linux-headers-{running}")));
    result
}

/// Validate a kernel request and return the exact package list for APT.
pub fn kernel_plan(mode: &str, items: &[String], with_headers: bool) -> Result<Vec<String>> {
    static IMAGE_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^linux-image-[a-z0-9][a-z0-9.+~-]*$").unwrap());
    static RELEASE_ARG_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\d[a-z0-9.+~-]*$").unwrap());
    let running = running_release();
    if items.is_empty() || items.len() > 40 {
        bail!("No kernel was selected.");
    }
    let mut packages: Vec<String> = Vec::new();
    if mode == "install" {
        let known = apt_show(items);
        for name in items {
            if !IMAGE_RE.is_match(name) || !known.contains_key(name) {
                bail!("Kernel package is not available: {name}");
            }
            packages.push(name.clone());
            if with_headers {
                let release = kernel_release(name);
                let headers = if release.is_empty() { name.replacen("linux-image-", "linux-headers-", 1) } else { format!("linux-headers-{release}") };
                if !apt_show(std::slice::from_ref(&headers)).is_empty() {
                    packages.push(headers);
                }
            }
        }
        return Ok(packages);
    }
    let installed: BTreeSet<String> = dpkg_packages("linux-*").into_iter().map(|p| p.name).collect();
    for release in items {
        if !RELEASE_ARG_RE.is_match(release) {
            bail!("Invalid kernel release: {release}");
        }
        if *release == running {
            bail!("The running kernel cannot be removed.");
        }
        let found = related_packages(release, &installed);
        if !found.iter().any(|n| n.starts_with("linux-image-")) {
            bail!("Kernel {release} is not installed.");
        }
        for name in found {
            if !packages.contains(&name) {
                packages.push(name);
            }
        }
    }
    if packages.iter().any(|n| !KERNEL_PACKAGE_RE.is_match(n) && !n.ends_with("-common")) {
        bail!("Unexpected package in the removal plan.");
    }
    let mut args = vec!["-s".to_string(), "-o".into(), "Debug::NoLocking=1".into(), "purge".into()];
    args.extend(packages.iter().cloned());
    let simulation = run_with("apt-get", &args, RunOptions { timeout: Some(120), env: C_LOCALE, ..Default::default() })?;
    if !simulation.ok() {
        bail!("APT could not plan the kernel removal.");
    }
    for caps in REMOVED_RE.captures_iter(&simulation.out()) {
        let name = &caps[1];
        if kernel_release(name) == running || name == format!("linux-modules-{running}") {
            bail!("The removal would also remove the running kernel; it was cancelled.");
        }
        if name.starts_with("linux-image-") && kernel_release(name).is_empty() && !name.ends_with("-dbg") {
            bail!("The removal would also remove the kernel metapackage {name}. Remove an older kernel instead.");
        }
    }
    Ok(packages)
}

/// Removed package names in an `apt-get -s` simulation.
pub fn simulated_removals(text: &str) -> Vec<String> {
    REMOVED_RE.captures_iter(text).map(|c| c[1].to_string()).collect()
}
