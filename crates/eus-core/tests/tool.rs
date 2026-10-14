//! Repository, keyring, kernel, cleaner and health helpers on a fake APT tree.

mod common;

use common::*;
use eus_core::{apt, cleaner, health, kernels, keys, sources, util};
use std::path::Path;

#[test]
fn tool_on_fake_tree() {
    let root = fake_root("eus-tool-test.");
    let apt_dir = root.path().join("etc/apt");
    write(&apt_dir.join("sources.list"),
          "deb http://deb.debian.org/debian trixie main contrib\n\
           deb http://security.debian.org/debian-security trixie-security main\n");
    write(&apt_dir.join("sources.list.d/vendor.list"),
          "# vendor repository added in a terminal\n\
           deb [arch=amd64 signed-by=/etc/apt/keyrings/vendor.gpg] https://deb.debian.org/debian/ trixie main non-free\n\
           deb https://repo.example.org/apt stable main\n\
           deb https://repo.example.org/apt stable main\n");
    write(&apt_dir.join("sources.list.d/debian.sources"),
          "Types: deb\nURIs: http://deb.debian.org/debian\nSuites: trixie\nComponents: main contrib\n\n\
           Types: deb\nURIs: https://other.example.org/\nSuites: stable\nComponents: main\n");

    // Duplicates: partial, complete, and across formats.
    let dups = sources::find_duplicates(&sources::all_entries());
    let summary: Vec<(String, usize, bool)> = dups
        .iter()
        .map(|d| (Path::new(&d.file).file_name().unwrap().to_string_lossy().to_string(), d.line, d.complete))
        .collect();
    assert!(summary.contains(&("vendor.list".into(), 2, false)), "{summary:?}");
    assert!(summary.contains(&("vendor.list".into(), 4, true)), "{summary:?}");
    assert!(summary.contains(&("debian.sources".into(), 1, true)), "{summary:?}");
    assert_eq!(dups.len(), 3, "{summary:?}");

    let result = sources::fix_duplicates().unwrap();
    assert_eq!(result["fixed"].as_array().unwrap().len(), 3, "{result}");
    assert!(sources::find_duplicates(&sources::all_entries()).is_empty(), "duplicates remain after fix");
    let vendor = read(&apt_dir.join("sources.list.d/vendor.list"));
    assert!(vendor.contains("trixie non-free"), "{vendor}");
    assert_eq!(vendor.matches(sources::DISABLED_MARK).count(), 2, "{vendor}");
    assert!(read(&apt_dir.join("sources.list.d/debian.sources")).contains("Enabled: no"));
    assert!(Path::new(result["backup"].as_str().unwrap()).is_dir());

    // Diagnosis of apt-get update output.
    let problems = apt::apt_problems(Some(
        "W: GPG error: https://repo.example.org/apt stable InRelease: The following signatures \
         couldn't be verified because the public key is not available: NO_PUBKEY 0123456789ABCDEF\n\
         E: The repository 'https://repo.example.org/apt stable InRelease' is not signed.\n\
         W: Target Packages (main/binary-amd64/Packages) is configured multiple times in a and b\n\
         W: http://x/dists/y/InRelease: Key is stored in legacy trusted.gpg keyring\n"));
    assert_eq!(problems.missing_keys,
               vec![apt::KeyProblem { keyid: "0123456789ABCDEF".into(), url: "https://repo.example.org/apt".into() }]);
    assert!(problems.unsigned.is_empty() && problems.legacy_warning, "the missing key explains it");
    assert!(!problems.configured_multiple_times.is_empty());
    let blocked = apt::apt_problems(Some(
        "Err:1 http://ppa.example.org/ubuntu noble InRelease\n  403  Forbidden [IP: 1.2.3.4 80]\n\
         E: Failed to fetch http://ppa.example.org/ubuntu/dists/noble/InRelease  403  Forbidden\n\
         E: The repository 'http://ppa.example.org/ubuntu noble InRelease' is not signed.\n"));
    assert!(blocked.unsigned.is_empty(), "{blocked:?}");
    assert_eq!(blocked.unreachable[0].url, "http://ppa.example.org/ubuntu");
    let signature = apt::apt_problems(Some(
        "Err:1 http://127.0.0.1:8765 stable InRelease\n  The following signatures couldn't be verified \
         because the public key is not available: NO_PUBKEY EDFA432B3307B9AD\n\
         W: GPG error: http://127.0.0.1:8765 stable InRelease: The following signatures couldn't be verified \
         because the public key is not available: NO_PUBKEY EDFA432B3307B9AD\n\
         E: The repository 'http://127.0.0.1:8765 stable InRelease' is not signed.\n"));
    assert!(signature.unreachable.is_empty() && signature.unsigned.is_empty(), "{signature:?}");
    assert_eq!(signature.missing_keys,
               vec![apt::KeyProblem { keyid: "EDFA432B3307B9AD".into(), url: "http://127.0.0.1:8765".into() }]);

    // Kernels.
    assert_eq!(kernels::kernel_release("linux-image-6.12.38+deb13-amd64"), "6.12.38+deb13-amd64");
    assert_eq!(kernels::kernel_release("linux-image-6.8.0-45-generic"), "6.8.0-45-generic");
    assert_eq!(kernels::kernel_release("linux-image-unsigned-6.8.0-45-generic"), "6.8.0-45-generic");
    assert_eq!(kernels::kernel_release("linux-image-amd64"), "");
    assert_eq!(kernels::kernel_flavour("6.12.38+deb13-amd64"), "amd64");
    assert_eq!(kernels::kernel_flavour("6.1.0-18-cloud-amd64"), "cloud-amd64");
    assert_eq!(kernels::kernel_flavour("6.8.0-45-generic"), "generic");
    assert!(util::version_key("6.12.10") > util::version_key("6.12.9"));
    let installed = ["linux-image-6.1.0-18-amd64", "linux-headers-6.1.0-18-amd64", "linux-headers-6.1.0-18-common",
                     "linux-image-6.1.0-20-amd64"].iter().map(|s| s.to_string()).collect();
    let mut related = kernels::related_packages("6.1.0-18-amd64", &installed);
    related.sort();
    assert_eq!(related, ["linux-headers-6.1.0-18-amd64", "linux-headers-6.1.0-18-common", "linux-image-6.1.0-18-amd64"]);

    // Add Key: keyring placement, no duplicate entries, secret keys refused.
    if has_gpg() {
        let home = gpg_home();
        gen_key(home.path(), "EUS Test <eus@example.org>");
        let key_file = root.path().join("vendor.asc");
        write(&key_file, gpg(home.path(), &["--armor", "--export"]));
        let mut spec = keys::RepoSpec {
            name: "vendor-tools".into(), file: Some(key_file.to_string_lossy().to_string()),
            repo_uri: Some("https://tools.example.org/apt".into()), suite: Some("stable".into()),
            components: Some("main".into()), arch: Some("amd64".into()), ..Default::default()
        };
        keys::add_key(&spec).unwrap();
        let keyring = apt_dir.join("keyrings/vendor-tools.gpg");
        assert!(keyring.is_file() && !std::fs::read(&keyring).unwrap().starts_with(b"-----BEGIN"));
        let stanza = read(&apt_dir.join("sources.list.d/vendor-tools.sources"));
        assert!(stanza.contains("Signed-By: /etc/apt/keyrings/vendor-tools.gpg"), "{stanza}");
        spec.name = "vendor-again".into();
        let again = keys::add_key(&spec).unwrap();
        assert!(!apt_dir.join("sources.list.d/vendor-again.sources").exists());
        assert!(!again["warnings"].as_array().unwrap().is_empty(), "{again}");
        let key_only = keys::RepoSpec { name: "plain".into(), file: spec.file.clone(), ..Default::default() };
        keys::add_key(&key_only).unwrap();
        assert!(apt_dir.join("trusted.gpg.d/plain.gpg").is_file());
        write(&key_file, gpg(home.path(), &["--pinentry-mode", "loopback", "--passphrase", "", "--armor",
                                            "--export-secret-keys"]));
        assert!(keys::add_key(&key_only).is_err(), "secret key was accepted");
        write(&apt_dir.join("trusted.gpg.d/broken.gpg"), "not a key");
        let scan = keys::scan_keys();
        let broken = scan["files"].as_array().unwrap().iter().find(|f| f["path"].as_str().unwrap().ends_with("broken.gpg")).unwrap();
        assert!(!broken["problems"].as_array().unwrap().is_empty(), "{broken}");
        kill_agent(home.path());
    }

    // System Cleaner: per-user caches are found and emptied, never deleted outside $HOME.
    let home = root.path().join("home");
    write(&home.join(".cache/thumbnails/normal/a.png"), vec![b'x'; 4096]);
    let firefox = home.join(".cache/mozilla/firefox/abc.default-esr/cache2");
    write(&firefox.join("entry"), vec![b'y'; 8192]);
    std::env::set_var("HOME", &home);
    let found: std::collections::HashMap<String, cleaner::CleanItem> =
        cleaner::scan_user().into_iter().map(|i| (i.id.clone(), i)).collect();
    assert_eq!(found["thumbnails"].size, 4096);
    assert_eq!(found["firefox"].size, 8192);
    assert!(!found.contains_key("trash"));
    let result = cleaner::clean_user(&["thumbnails".into(), "firefox".into()]).unwrap();
    assert_eq!(result["freed"], 12288, "{result}");
    assert!(home.join(".cache/thumbnails").is_dir());
    assert_eq!(std::fs::read_dir(home.join(".cache/thumbnails")).unwrap().count(), 0);
    assert!(firefox.is_dir() && std::fs::read_dir(&firefox).unwrap().count() == 0);
    write(&root.path().join("var/log/syslog.2.gz"), "x");
    write(&root.path().join("var/log/apt/term.log.1"), "x");
    write(&root.path().join("var/log/syslog"), "x");
    let logs: Vec<String> = cleaner::rotated_logs().iter().map(|p| p.file_name().unwrap().to_string_lossy().to_string()).collect();
    assert_eq!(logs.len(), 2, "{logs:?}");
    assert!(!logs.contains(&"syslog".to_string()));

    // System Health: dpkg --verify output.
    let verify = "??5?????? c /etc/bash.bashrc\n\
                  missing     /usr/share/doc/bash/NEWS.gz\n\
                  ??5??????   /usr/bin/sudo\n\
                  missing     /usr/lib/x86_64-linux-gnu/libfoo.so.1\n";
    assert_eq!(health::damaged_paths(verify), ["/usr/bin/sudo", "/usr/lib/x86_64-linux-gnu/libfoo.so.1"]);
    for fix in ["dpkg-configure", "fix-broken", "reinstall-damaged", "continuous-stable", "install-timeshift"] {
        assert!(health::is_health_fix(fix));
    }
    assert!(!health::is_health_fix("rm-rf"));
}
