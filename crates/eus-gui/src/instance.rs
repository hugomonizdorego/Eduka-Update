//! One window per user: a second start asks the running window to show
//! itself (and optionally a page) through a Unix socket.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::time::Duration;

pub fn runtime_dir() -> PathBuf {
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let writable = |path: &PathBuf| {
        let Ok(text) = std::ffi::CString::new(path.to_string_lossy().as_bytes()) else { return false };
        // SAFETY: access only reads the path we pass.
        path.is_dir() && unsafe { libc::access(text.as_ptr(), libc::W_OK) } == 0
    };
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .filter(writable)
        .or_else(|| Some(PathBuf::from(format!("/run/user/{uid}"))).filter(writable))
        .unwrap_or_else(|| std::env::temp_dir().join(format!("eus-runtime-{uid}")));
    base.join("eduka-update-system")
}

fn socket_path() -> PathBuf {
    runtime_dir().join("gui.sock")
}

/// Ask a running window to come forward; true when one answered.
pub fn request_existing(page: &str) -> bool {
    let Ok(mut stream) = UnixStream::connect(socket_path()) else { return false };
    let _ = stream.set_write_timeout(Some(Duration::from_millis(350)));
    let message = if page.is_empty() { "show\n".to_string() } else { format!("open:{page}\n") };
    stream.write_all(message.as_bytes()).is_ok()
}

/// Listen for later starts; `on_request` receives the requested page ("" = just show).
pub fn listen<F>(on_request: F) -> std::io::Result<()>
where
    F: Fn(String) + Clone + Send + 'static,
{
    let dir = runtime_dir();
    std::fs::create_dir_all(&dir)?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    let path = socket_path();
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let _ = stream.set_read_timeout(Some(Duration::from_millis(300)));
            let mut line = String::new();
            let _ = BufReader::new(stream).read_line(&mut line);
            let page = line.trim().strip_prefix("open:").unwrap_or("").to_string();
            let callback = on_request.clone();
            let _ = slint::invoke_from_event_loop(move || callback(page));
        }
    });
    Ok(())
}

pub fn cleanup() {
    let _ = std::fs::remove_file(socket_path());
}
