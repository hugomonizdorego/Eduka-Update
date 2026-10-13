//! Background work: child processes with streamed output, and library calls
//! in threads whose results are delivered back on the UI thread.

use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

/// Output events of a running process, delivered on the UI thread.
pub enum Event {
    Line(String),
    Finished(i32),
}

/// A started child process that can be stopped.
#[derive(Clone, Default)]
pub struct Handle {
    pid: Arc<Mutex<Option<u32>>>,
}

impl Handle {
    pub fn terminate(&self, force: bool) {
        if let Some(pid) = *self.pid.lock().unwrap() {
            // SAFETY: kill only sends a signal to the child we started.
            unsafe {
                libc::kill(pid as libc::pid_t, if force { libc::SIGKILL } else { libc::SIGTERM });
            }
        }
    }
}

/// Start `program` with `args`; every stdout/stderr line (carriage returns
/// count as line ends) and then the exit code reach `on_event` on the UI
/// thread. A program that cannot start finishes with 127.
pub fn spawn<F>(program: &str, args: &[String], on_event: F) -> Handle
where
    F: Fn(Event) + Clone + Send + 'static,
{
    let handle = Handle::default();
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("LC_ALL", "C.UTF-8")
        .env("LANG", "C.UTF-8")
        .env("TERM", "dumb");
    let deliver = move |callback: F, event: Event| {
        let _ = slint::invoke_from_event_loop(move || callback(event));
    };
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => {
            deliver(on_event, Event::Finished(127));
            return handle;
        }
    };
    *handle.pid.lock().unwrap() = Some(child.id());
    let readers: Vec<Box<dyn std::io::Read + Send>> = vec![
        Box::new(child.stdout.take().expect("piped stdout")),
        Box::new(child.stderr.take().expect("piped stderr")),
    ];
    let threads: Vec<_> = readers
        .into_iter()
        .map(|stream| {
            let callback = on_event.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream);
                let mut buffer = Vec::new();
                loop {
                    buffer.clear();
                    match reader.read_until(b'\n', &mut buffer) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {
                            for part in String::from_utf8_lossy(&buffer).split(['\r', '\n']) {
                                if !part.trim().is_empty() {
                                    let line = part.to_string();
                                    let callback = callback.clone();
                                    let _ = slint::invoke_from_event_loop(move || callback(Event::Line(line)));
                                }
                            }
                        }
                    }
                }
            })
        })
        .collect();
    let pid = handle.pid.clone();
    std::thread::spawn(move || {
        let code = child.wait().map(|s| s.code().unwrap_or(-1)).unwrap_or(-1);
        for thread in threads {
            let _ = thread.join();
        }
        *pid.lock().unwrap() = None;
        deliver(on_event, Event::Finished(code));
    });
    handle
}

/// Run `work` in a thread and hand its result to `done` on the UI thread.
pub fn background<T, W, D>(work: W, done: D)
where
    T: Send + 'static,
    W: FnOnce() -> T + Send + 'static,
    D: FnOnce(T) + Send + 'static,
{
    std::thread::spawn(move || {
        let result = work();
        let _ = slint::invoke_from_event_loop(move || done(result));
    });
}
