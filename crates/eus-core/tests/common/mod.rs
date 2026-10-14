//! Helpers for the integration tests: a fake root, a static HTTP server, gpg.
#![allow(dead_code)]

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::Command;

/// A temporary system root; must be created before any eus_core call.
pub fn fake_root(prefix: &str) -> tempfile::TempDir {
    let root = tempfile::Builder::new().prefix(prefix).tempdir().unwrap();
    std::env::set_var("EUS_APT_ROOT", root.path());
    std::env::set_var("EUS_TEST_NO_KEYSERVER", "1");
    std::fs::create_dir_all(root.path().join("etc/apt/sources.list.d")).unwrap();
    root
}

pub fn write(path: &Path, text: impl AsRef<[u8]>) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

pub fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

/// Serve files below `dir` over HTTP on 127.0.0.1; returns the base URL.
pub fn serve(dir: PathBuf) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let dir = dir.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut request = String::new();
                if reader.read_line(&mut request).is_err() {
                    return;
                }
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim().is_empty() {
                        break;
                    }
                }
                let path = request.split_whitespace().nth(1).unwrap_or("/").split('?').next().unwrap().to_string();
                let file = dir.join(path.trim_start_matches('/'));
                let mut stream = stream;
                let response = match std::fs::read(&file) {
                    Ok(body) if file.is_file() && !path.contains("..") => {
                        let mut head = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len())
                            .into_bytes();
                        head.extend(body);
                        head
                    }
                    _ => b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec(),
                };
                let _ = stream.write_all(&response);
            });
        }
    });
    format!("http://127.0.0.1:{port}")
}

pub fn has_gpg() -> bool {
    Command::new("gpg").arg("--version").output().is_ok()
}

pub fn gpg(home: &Path, args: &[&str]) -> Vec<u8> {
    let output = Command::new("gpg").arg("--homedir").arg(home).arg("--batch").args(args).output().unwrap();
    assert!(output.status.success(), "gpg {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    output.stdout
}

pub fn gen_key(home: &Path, uid: &str) {
    gpg(home, &["--passphrase", "", "--quick-gen-key", uid, "ed25519", "sign", "1y"]);
}

pub fn gpg_home() -> tempfile::TempDir {
    let home = tempfile::Builder::new().prefix("eus-gpg.").tempdir_in("/tmp").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(home.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    home
}

pub fn kill_agent(home: &Path) {
    let _ = Command::new("gpgconf").arg("--homedir").arg(home).args(["--kill", "all"]).output();
}
