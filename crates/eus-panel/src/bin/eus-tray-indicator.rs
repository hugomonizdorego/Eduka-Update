//! Tray icon (StatusNotifierItem) shown while updates are available;
//! clicking it opens the update manager.

use eus_panel::{message, state_dir, state_file, ICON_DIR};
use ksni::blocking::TrayMethods;
use std::time::{Duration, Instant, SystemTime};

const EUS_COMMAND: &str = "/usr/local/bin/eduka-update-system";

struct Indicator {
    count: i64,
    message: String,
    icon: Vec<ksni::Icon>,
    last_launch: Option<Instant>,
}

/// PNG -> ARGB32 (network byte order) as StatusNotifierItem expects.
fn load_icon(path: &str) -> Vec<ksni::Icon> {
    let Ok(file) = std::fs::File::open(path) else { return vec![] };
    let mut decoder = png::Decoder::new(std::io::BufReader::new(file));
    decoder.set_transformations(png::Transformations::normalize_to_color8() | png::Transformations::ALPHA);
    let Ok(mut reader) = decoder.read_info() else { return vec![] };
    let Some(size) = reader.output_buffer_size() else { return vec![] };
    let mut buffer = vec![0; size];
    let Ok(info) = reader.next_frame(&mut buffer) else { return vec![] };
    let channels = info.color_type.samples();
    let mut data = Vec::with_capacity((info.width * info.height * 4) as usize);
    for pixel in buffer[..info.buffer_size()].chunks(channels) {
        let (r, g, b, a) = match channels {
            4 => (pixel[0], pixel[1], pixel[2], pixel[3]),
            2 => (pixel[0], pixel[0], pixel[0], pixel[1]),
            _ => (pixel[0], *pixel.get(1).unwrap_or(&pixel[0]), *pixel.get(2).unwrap_or(&pixel[0]), 255),
        };
        data.extend_from_slice(&[a, r, g, b]);
    }
    vec![ksni::Icon { width: info.width as i32, height: info.height as i32, data }]
}

fn launch_manager(last: &mut Option<Instant>) {
    if last.is_some_and(|t| t.elapsed() < Duration::from_millis(1200)) {
        return;
    }
    *last = Some(Instant::now());
    let _ = std::process::Command::new(EUS_COMMAND)
        .arg("--ui")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|mut child| std::thread::spawn(move || child.wait()));
}

impl ksni::Tray for Indicator {
    fn id(&self) -> String {
        "eduka-update-system".into()
    }
    fn title(&self) -> String {
        "Eduka-Update-System".into()
    }
    fn icon_name(&self) -> String {
        "eduka-update-system".into()
    }
    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        self.icon.clone()
    }
    fn tool_tip(&self) -> ksni::ToolTip {
        let text = if self.message.is_empty() {
            message("updates_available_count").replace("{count}", &self.count.to_string())
        } else {
            self.message.clone()
        };
        ksni::ToolTip { title: text, icon_pixmap: self.icon.clone(), ..Default::default() }
    }
    fn activate(&mut self, _x: i32, _y: i32) {
        launch_manager(&mut self.last_launch);
    }
    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        vec![ksni::menu::StandardItem {
            label: message("open_manager"),
            activate: Box::new(|tray: &mut Self| launch_manager(&mut tray.last_launch)),
            ..Default::default()
        }
        .into()]
    }
}

/// One indicator per session.
fn acquire_lock() -> Option<std::fs::File> {
    use std::os::unix::io::AsRawFd;
    std::fs::create_dir_all(state_dir()).ok()?;
    let file = std::fs::OpenOptions::new().create(true).append(true).open(state_dir().join("tray-indicator.lock")).ok()?;
    // SAFETY: flock on a descriptor we own.
    (unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0).then_some(file)
}

/// (count, message) while updates are available, else None.
fn read_state() -> Option<(i64, String)> {
    let data: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(state_file()).ok()?).ok()?;
    let count = data["count"].as_i64().unwrap_or(0);
    (data["state"].as_str() == Some("available") && count > 0)
        .then(|| (count, data["message"].as_str().unwrap_or("").trim().to_string()))
}

fn main() {
    let Some(_lock) = acquire_lock() else { return };
    let icon = load_icon(&format!("{ICON_DIR}/eus-update-available.png"));
    let mut handle: Option<ksni::blocking::Handle<Indicator>> = None;
    let mut signature: Option<(SystemTime, u64)> = None;
    let mut retry_at = Instant::now();
    loop {
        let current = std::fs::metadata(state_file()).ok().and_then(|m| Some((m.modified().ok()?, m.len())));
        let closed = handle.as_ref().is_some_and(|h| h.is_closed());
        if current != signature || closed {
            signature = current;
            match read_state() {
                Some((count, text)) => {
                    if closed {
                        handle = None;
                    }
                    if let Some(existing) = &handle {
                        existing.update(|tray| {
                            tray.count = count;
                            tray.message = text.clone();
                        });
                    } else if Instant::now() >= retry_at {
                        let tray = Indicator { count, message: text, icon: icon.clone(), last_launch: None };
                        match tray.assume_sni_available(true).spawn() {
                            Ok(new) => handle = Some(new),
                            Err(error) => {
                                eprintln!("eus-tray-indicator: {error}");
                                retry_at = Instant::now() + Duration::from_secs(30);
                                signature = None;
                            }
                        }
                    } else {
                        signature = None;
                    }
                }
                None => {
                    if let Some(old) = handle.take() {
                        old.shutdown().wait();
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_millis(750));
    }
}
