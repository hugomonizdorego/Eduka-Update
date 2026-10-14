//! Keyring placement, automatic key discovery, the OS upgrade and the
//! continuous 'stable' policy. A local HTTP server plays the Debian mirror
//! and third-party repositories, so nothing on the host or internet is used.

mod common;

use common::*;
use eus_core::{keys, release, repos, sources};
use std::collections::{HashMap, HashSet};
use std::path::Path;

fn release_file(www: &Path, path: &str, fields: &[(&str, &str)]) {
    let text: String = fields.iter().map(|(k, v)| format!("{k}: {v}\n")).collect();
    write(&www.join(path), text);
}

fn name(file: &str) -> String {
    Path::new(file).file_name().unwrap().to_string_lossy().to_string()
}

#[test]
fn smart_updater() {
    let root = fake_root("eus-smart-test.");
    let www = root.path().join("www");
    // Fake mirror: trixie (13) is installed, forky (14) became stable.
    release_file(&www, "debian/dists/stable/Release",
                 &[("Origin", "Debian"), ("Label", "Debian"), ("Suite", "stable"), ("Version", "14.0"), ("Codename", "forky")]);
    for suite in ["forky", "forky-updates"] {
        release_file(&www, &format!("debian/dists/{suite}/InRelease"), &[("Origin", "Debian"), ("Codename", "forky")]);
    }
    release_file(&www, "debian-security/dists/forky-security/InRelease", &[("Origin", "Debian"), ("Label", "Debian-Security")]);
    release_file(&www, "vendor-a/dists/forky/InRelease", &[("Origin", "Vendor A")]);
    release_file(&www, "vendor-b/dists/trixie/InRelease", &[("Origin", "Vendor B")]);
    let base = serve(www.clone());
    let host = base.trim_start_matches("http://").to_string();

    let apt = root.path().join("etc/apt");
    write(&apt.join("sources.list"), format!(
        "deb {base}/debian trixie main contrib non-free-firmware\n\
         deb {base}/debian trixie-updates main\n\
         deb {base}/debian-security trixie-security main\n"));
    write(&apt.join("sources.list.d/vendor-a.list"), format!("deb {base}/vendor-a trixie main\n"));
    write(&apt.join("sources.list.d/vendor-b.sources"),
          format!("Types: deb\nURIs: {base}/vendor-b\nSuites: trixie\nComponents: main\n"));
    write(&apt.join("sources.list.d/vendor-c.list"), format!("deb {base}/vendor-c stable main\n"));
    let lists = root.path().join("var/lib/apt/lists");
    write(&lists.join(format!("{host}_debian_dists_trixie_InRelease")),
          "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\nOrigin: Debian\nLabel: Debian\n\
           Suite: stable\nVersion: 13.1\nCodename: trixie\n");
    write(&lists.join(format!("{host}_debian-security_dists_trixie-security_InRelease")),
          "Origin: Debian\nLabel: Debian-Security\nCodename: trixie-security\n");
    write(&lists.join(format!("{host}_vendor-a_dists_trixie_InRelease")), "Origin: Vendor A\n");

    // Knowledge: roles and the current release.
    let roles: HashMap<String, String> =
        repos::describe_repositories().into_iter().map(|r| (format!("{}{}", name(&r.file), r.suites[0]), r.role)).collect();
    assert_eq!(roles["sources.listtrixie"], "debian", "{roles:?}");
    assert_eq!(roles["sources.listtrixie-security"], "debian-security");
    assert_eq!(roles["vendor-a.listtrixie"], "third-party");
    let current = release::current_release().unwrap();
    assert_eq!((current.codename.as_str(), current.version.as_str()), ("trixie", "13.1"));

    // A new stable release is detected.
    let state = release::check_os_upgrade().unwrap();
    assert_eq!(state["available"], 1, "{state:?}");
    assert_eq!(state["target_codename"], "forky");
    assert!(read(&root.path().join("var/lib/eus/os-upgrade")).contains("available=1"));

    let plan = release::os_upgrade_plan("forky").unwrap();
    let actions: HashMap<(String, String), String> =
        plan.entries.iter().map(|r| ((name(&r.file), r.suite.clone()), r.action.clone())).collect();
    let action = |file: &str, suite: &str| actions[&(file.to_string(), suite.to_string())].clone();
    assert_eq!(action("sources.list", "trixie"), "switch");
    assert_eq!(action("sources.list", "trixie-updates"), "switch");
    assert_eq!(action("sources.list", "trixie-security"), "switch");
    assert_eq!(action("vendor-a.list", "trixie"), "switch");          // offers forky
    assert_eq!(action("vendor-b.sources", "trixie"), "keep");         // third-party without forky
    assert_eq!(action("vendor-c.list", "stable"), "unchanged");
    assert!(plan.blocking.is_empty());

    let backup = release::os_switch("forky").unwrap();
    let main = read(&apt.join("sources.list"));
    assert!(main.contains("debian forky main contrib non-free-firmware") && main.contains("forky-updates"), "{main}");
    assert!(main.contains("debian-security forky-security main"), "{main}");
    assert!(read(&apt.join("sources.list.d/vendor-a.list")).contains("vendor-a forky main"));
    assert!(read(&apt.join("sources.list.d/vendor-b.sources")).contains("Suites: trixie"));
    assert!(read(&apt.join("sources.list.d/vendor-c.list")).contains("vendor-c stable main"));
    release::os_restore(&backup).unwrap();
    assert!(read(&apt.join("sources.list")).contains("debian trixie main"));
    assert!(read(&apt.join("sources.list.d/vendor-a.list")).contains("vendor-a trixie main"));
    assert!(release::os_restore("/tmp").is_err());

    // The security archive missing the new suite blocks the upgrade.
    std::fs::remove_dir_all(www.join("debian-security/dists/forky-security")).unwrap();
    assert!(!release::os_upgrade_plan("forky").unwrap().blocking.is_empty());

    // Keyring placement is decided per repository.
    let entries: HashMap<(String, String), sources::Entry> =
        sources::all_entries().into_iter().map(|e| ((name(&e.file), e.suites[0].clone()), e)).collect();
    let entry = |file: &str, suite: &str| entries[&(file.to_string(), suite.to_string())].clone();
    let debian = keys::key_target(Some(&entry("sources.list", "trixie")), "0123456789ABCDEF");
    assert_eq!(debian.mode, "global");
    assert_eq!(debian.path, "/etc/apt/trusted.gpg.d/eus-0123456789abcdef.gpg");
    let third = keys::key_target(Some(&entry("vendor-b.sources", "trixie")), "0123456789ABCDEF");
    assert_eq!((third.mode.as_str(), third.path.as_str()), ("add-signed-by", "/etc/apt/keyrings/vendor-b.gpg"));

    write(&apt.join("sources.list.d/vendor-d.list"),
          format!("deb [signed-by=/usr/share/keyrings/vendor-d.gpg] {base}/vendor-d stable main\n"));
    write(&apt.join("sources.list.d/vendor-e.list"),
          format!("deb [signed-by=/etc/apt/keyrings/vendor-e.gpg arch=amd64] {base}/vendor-e stable main\n"));
    let by_file: HashMap<String, sources::Entry> = sources::all_entries().into_iter().map(|e| (name(&e.file), e)).collect();
    std::env::set_var("EUS_TEST_PACKAGE_OWNER", "/usr/share/keyrings/=vendor-d-keyring");
    let packaged = keys::key_target(Some(&by_file["vendor-d.list"]), "0123456789ABCDEF");
    assert_eq!((packaged.mode.as_str(), packaged.package.as_str()), ("reinstall", "vendor-d-keyring"));
    assert_eq!(packaged.fallback, "/etc/apt/keyrings/vendor-d.gpg");
    let admin = keys::key_target(Some(&by_file["vendor-e.list"]), "0123456789ABCDEF");
    assert_eq!((admin.mode.as_str(), admin.path.as_str()), ("merge", "/etc/apt/keyrings/vendor-e.gpg"));
    std::env::remove_var("EUS_TEST_PACKAGE_OWNER");

    // Signed-By is written correctly in both formats.
    sources::set_signed_by(&by_file["vendor-e.list"], "/etc/apt/keyrings/new.gpg", "test").unwrap();
    let line = read(&apt.join("sources.list.d/vendor-e.list"));
    assert!(line.contains("[arch=amd64 signed-by=/etc/apt/keyrings/new.gpg]"), "{line}");
    sources::set_signed_by(&by_file["vendor-b.sources"], "/etc/apt/keyrings/vendor-b.gpg", "test").unwrap();
    assert!(read(&apt.join("sources.list.d/vendor-b.sources")).contains("Signed-By: /etc/apt/keyrings/vendor-b.gpg"));

    // Automatic key discovery verifies the key ID.
    if has_gpg() {
        let home = gpg_home();
        gen_key(home.path(), "Vendor B <b@example.org>");
        gen_key(home.path(), "Someone Else <x@example.org>");
        let listing = String::from_utf8(gpg(home.path(), &["--with-colons", "--list-keys"])).unwrap();
        let fingerprints: Vec<String> =
            listing.lines().filter(|l| l.starts_with("fpr")).map(|l| l.split(':').nth(9).unwrap().to_string()).collect();
        let (vendor, other) = (&fingerprints[0], &fingerprints[1]);
        write(&www.join("vendor-b/wrong.key"), gpg(home.path(), &["--armor", "--export", other]));
        write(&www.join("vendor-b/Release.key"), gpg(home.path(), &["--armor", "--export", vendor]));
        std::env::set_var("EUS_TEST_KEY_URLS", format!("{base}/vendor-b/missing.key,{base}/vendor-b/wrong.key,{base}/vendor-b/Release.key"));
        let short = &vendor[vendor.len() - 16..];
        let (blob, origin) = keys::find_signing_key(short, None).unwrap();
        assert!(origin.ends_with("/vendor-b/Release.key"), "{origin}");   // the wrong key was skipped
        assert!(keys::key_matches(&blob, short));
        assert!(keys::find_signing_key("00000000DEADBEEF", None).is_err(), "an unrelated key was accepted");
        std::env::remove_var("EUS_TEST_KEY_URLS");
        kill_agent(home.path());
    }
    let urls = keys::candidate_key_urls(Some(&by_file["vendor-e.list"]));
    assert!(urls.iter().all(|u| u.starts_with("https://")), "{urls:?}");
    assert!(urls.contains(&format!("https://{host}/vendor-e/Release.key")), "{urls:?}");
    assert!(urls.contains(&format!("https://{host}/Release.key")), "{urls:?}");

    // Continuous stable (Edukasaun OS policy).
    for file in ["vendor-a.list", "vendor-b.sources", "vendor-c.list", "vendor-d.list", "vendor-e.list"] {
        let _ = std::fs::remove_file(apt.join("sources.list.d").join(file));
    }
    write(&apt.join("sources.list"), format!(
        "deb {base}/debian trixie main contrib\n\
         deb {base}/debian trixie-updates main\n\
         deb {base}/debian-security trixie-security main\n\
         deb {base}/vendor-a trixie main\n"));
    write(&lists.join(format!("{host}_debian_dists_trixie_InRelease")),
          "Origin: Debian\nLabel: Debian\nSuite: stable\nVersion: 13.1\nCodename: trixie\n");
    write(&lists.join(format!("{host}_debian_dists_trixie-updates_InRelease")),
          "Origin: Debian\nLabel: Debian\nSuite: stable-updates\nCodename: trixie-updates\n");
    write(&lists.join(format!("{host}_debian-security_dists_trixie-security_InRelease")),
          "Origin: Debian\nLabel: Debian-Security\nSuite: stable-security\nCodename: trixie-security\n");
    write(&root.path().join("etc/debian_version"), "13.1\n");
    let plan: HashSet<(String, String)> =
        release::continuous_stable_plan().into_iter().map(|r| (r.suite, r.new_suite)).collect();
    let expected: HashSet<(String, String)> = [("trixie", "stable"), ("trixie-updates", "stable-updates"),
                                               ("trixie-security", "stable-security")]
        .iter().map(|(a, b)| (a.to_string(), b.to_string())).collect();
    assert_eq!(plan, expected);                                          // vendor-a is untouched
    let result = release::apply_continuous_stable().unwrap();
    let main = read(&apt.join("sources.list"));
    assert!(main.contains("debian stable main contrib") && main.contains("debian stable-updates main"), "{main}");
    assert!(main.contains("debian-security stable-security main") && main.contains("vendor-a trixie main"), "{main}");
    assert!(Path::new(result["backup"].as_str().unwrap()).is_dir());
    assert!(release::continuous_stable_plan().is_empty());                // idempotent
    // Lists for "stable" still describe trixie: nothing to do.
    write(&lists.join(format!("{host}_debian_dists_stable_InRelease")),
          "Origin: Debian\nLabel: Debian\nSuite: stable\nVersion: 13.2\nCodename: trixie\n");
    let state = release::check_continuous_release().unwrap();
    assert_eq!((state["mode"].as_str(), state["available"].as_i64()), (Some("continuous"), Some(0)));
    // Debian 14 is released: "stable" now carries forky -> one major system update.
    write(&lists.join(format!("{host}_debian_dists_stable_InRelease")),
          "Origin: Debian\nLabel: Debian\nSuite: stable\nVersion: 14.0\nCodename: forky\n");
    let state = release::check_os_upgrade().unwrap();
    assert_eq!(state["available"], 1, "{state:?}");
    assert_eq!(state["mode"], "continuous");
    assert_eq!((state["target_codename"].as_str(), state["current_codename"].as_str()), (Some("forky"), Some("trixie")));
    assert!(read(&root.path().join("var/lib/eus/os-upgrade")).contains("mode=continuous"));
}
