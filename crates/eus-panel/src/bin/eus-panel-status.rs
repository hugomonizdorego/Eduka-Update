//! eus-panel-status STATE [--count N] [--progress P] [--message TEXT]
//! Write the EUS panel state atomically for Eduka-Panel and the tray icon.

use eus_panel::{state_dir, state_file, VALID_STATES};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::process::ExitCode;

fn usage() -> ExitCode {
    eprintln!("usage: eus-panel-status {{{}}} [--count N] [--progress P] [--message TEXT]", VALID_STATES.join(","));
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(state) = args.first().filter(|s| VALID_STATES.contains(&s.as_str())).cloned() else { return usage() };
    let (mut count, mut progress, mut message) = (0i64, -1i64, String::new());
    let mut index = 1;
    while index < args.len() {
        let Some(value) = args.get(index + 1) else { return usage() };
        match args[index].as_str() {
            "--count" => count = value.parse().unwrap_or(0),
            "--progress" => progress = value.parse().unwrap_or(-1),
            "--message" => message = value.trim().to_string(),
            _ => return usage(),
        }
        index += 2;
    }
    let payload = serde_json::json!({
        "version": 1,
        "state": state,
        "count": count.max(0),
        "progress": progress.clamp(-1, 100),
        "message": message,
        "updated_at": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
    });
    let dir = state_dir();
    let write = || -> std::io::Result<()> {
        std::fs::create_dir_all(&dir)?;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
        let temporary = dir.join(format!("panel-status.{}.tmp", std::process::id()));
        let mut file = std::fs::File::create(&temporary)?;
        writeln!(file, "{payload}")?;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        std::fs::rename(&temporary, state_file())
    };
    match write() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("eus-panel-status: {error}");
            ExitCode::from(1)
        }
    }
}
