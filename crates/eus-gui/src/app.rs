//! Controller of the main window: state, message boxes, the command queue,
//! updates, banners and System Health.

use crate::data::{self, Group, Record};
use crate::i18n::{t, tf};
use crate::runner::{self, Event, Handle};
use crate::{App, HealthRow, MainWindow, MsgButton, UpdateRow};
use eus_core::util::{format_bytes, read_key_values, read_text};
use serde_json::Value;
use slint::{Color, ComponentHandle, Model, ModelRc, SharedString, VecModel};
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::rc::Rc;
use std::time::Duration;

/// What to do when a privileged task of a tool page ends.
#[derive(Clone, Debug, PartialEq)]
pub enum Task {
    HealthFix,
    KernelInstall(Vec<(String, String)>),
    KernelRemove(Vec<(String, String)>),
    FixKeys,
    FixDuplicates,
    AddRepo,
    AddKey,
    OsUpgrade,
    Clean,
    Pause,
    Unignore,
    SavePrefs,
}

/// One program of the command queue.
#[derive(Clone)]
pub struct Cmd {
    pub program: String,
    pub args: Vec<String>,
    pub root: bool,
    pub records: Vec<Record>,
    pub timeout: u64,
    pub ignore_failure: bool,
    pub task: Option<Task>,
}

#[derive(Default)]
pub struct State {
    pub records: Vec<Record>,
    pub groups: Vec<Group>,
    pub checked: Vec<bool>,
    pub progress: Vec<i32>,
    pub active_rows: Vec<usize>,
    pub queue: VecDeque<Cmd>,
    pub current: Option<Cmd>,
    pub handle: Option<Handle>,
    pub generation: u64,
    pub started_at: i64,
    pub timed_out: bool,
    pub operation: String,
    pub install_had_kernel: bool,
    pub changelog_cache: HashMap<String, String>,
    pub changelog_loading: bool,
    pub health: Value,
    pub health_shown: bool,
    pub health_loading: bool,
    pub health_checked: Vec<bool>,
    pub msg_handler: Option<Box<dyn FnOnce(String)>>,
    pub watch_stamp: u64,
    pub pending_reload: bool,
    pub tools: crate::tools::ToolState,
}

pub struct Ctx {
    pub ui: MainWindow,
    pub st: RefCell<State>,
    pub timeout: slint::Timer,
    pub animation: slint::Timer,
    pub watcher: slint::Timer,
}

thread_local! {
    static CTX: RefCell<Option<Rc<Ctx>>> = const { RefCell::new(None) };
}

pub fn install(ctx: Rc<Ctx>) {
    CTX.with(|c| *c.borrow_mut() = Some(ctx));
}

pub fn context() -> Rc<Ctx> {
    CTX.with(|c| c.borrow().clone().expect("controller"))
}

pub fn ui() -> MainWindow {
    context().ui.clone_strong()
}

pub fn ss(text: impl AsRef<str>) -> SharedString {
    SharedString::from(text.as_ref())
}

pub fn color(hex: &str) -> Color {
    let value = u32::from_str_radix(hex.trim_start_matches('#'), 16).unwrap_or(0x202020);
    Color::from_rgb_u8((value >> 16) as u8, (value >> 8) as u8, value as u8)
}

pub fn model<T: Clone + 'static>(items: Vec<T>) -> ModelRc<T> {
    ModelRc::new(VecModel::from(items))
}

pub fn lang() -> &'static str {
    crate::i18n::language_code()
}

pub fn is_busy() -> bool {
    context().st.borrow().current.is_some()
}

// ------------------------------------------------------------ message box

/// Show a message over the window; `handler` gets the id of the button.
pub fn message(title: &str, text: &str, buttons: &[(&str, String, bool)], handler: impl FnOnce(String) + 'static) {
    let ui = ui();
    let app = ui.global::<App>();
    app.set_msg_title(ss(title));
    app.set_msg_text(ss(text));
    app.set_msg_buttons(model(
        buttons.iter().map(|(id, text, primary)| MsgButton { id: ss(id), text: ss(text), primary: *primary }).collect(),
    ));
    app.set_msg_visible(true);
    context().st.borrow_mut().msg_handler = Some(Box::new(handler));
}

pub fn info(title: &str, text: &str) {
    message(title, text, &[("close", t("close"), true)], |_| {});
}

pub fn confirm(title: &str, text: &str, on_yes: impl FnOnce() + 'static) {
    message(title, text, &[("no", t("cancel"), false), ("yes", t("yes"), true)], move |id| {
        if id == "yes" {
            on_yes();
        }
    });
}

pub fn msg_clicked(id: String) {
    ui().global::<App>().set_msg_visible(false);
    let handler = context().st.borrow_mut().msg_handler.take();
    if let Some(handler) = handler {
        handler(id);
    }
}

// ------------------------------------------------------------ panel and root

pub fn set_panel_status(state: &str, count: usize, progress: i32) {
    if !std::path::Path::new(data::PANEL_STATUS).is_file() {
        return;
    }
    let mut args = vec![state.to_string()];
    if count > 0 {
        args.extend(["--count".into(), count.to_string()]);
    }
    if progress >= 0 {
        args.extend(["--progress".into(), progress.clamp(0, 100).to_string()]);
    }
    let _ = std::process::Command::new(data::PANEL_STATUS)
        .args(args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map(|mut child| std::thread::spawn(move || child.wait()));
}

pub fn privileged(action: &str, extra: &[String]) -> (String, Vec<String>) {
    let mut args = vec![action.to_string(), lang().to_string()];
    args.extend_from_slice(extra);
    if eus_core::util::is_root() {
        (data::ROOT_HELPER.into(), args)
    } else {
        let mut full = vec![data::ROOT_HELPER.to_string()];
        full.extend(args);
        ("pkexec".into(), full)
    }
}

pub fn root_cmd(action: &str, extra: &[String], records: Vec<Record>) -> Cmd {
    let (program, args) = privileged(action, extra);
    let timeout = match action {
        "upgrade-apt" | "install-apt" => 7200,
        "install-flatpak-system" => 3700,
        "major-upgrade" => 6 * 3600,
        "os-upgrade" | "kernel-install" | "kernel-remove" | "health-fix" | "clean" => 7200,
        _ => 900,
    };
    Cmd { program, args, root: true, records, timeout, ignore_failure: false, task: None }
}

pub fn task_cmd(action: &str, extra: &[String], task: Task) -> Cmd {
    Cmd { task: Some(task), ..root_cmd(action, extra, vec![]) }
}

pub fn request_reboot() {
    let (program, args) = privileged("reboot", &[]);
    let _ = std::process::Command::new(program).args(args).spawn();
}

pub fn confirm_reboot() {
    confirm(&t("restart_title"), &t("restart_body"), request_reboot);
}

/// Explain a failed root action without showing a stale earlier error.
pub fn failure_detail(code: i32, started_at: i64, timed_out: bool) -> String {
    if timed_out {
        return t("timeout");
    }
    if code == 126 || code == 127 {
        return t("auth");
    }
    let path = data::error_file();
    let fresh = std::fs::metadata(&path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
        .is_some_and(|m| m.as_secs() as i64 >= started_at - 1);
    if fresh {
        if let Some(text) = read_text(&path).map(|t| t.trim().to_string()).filter(|t| !t.is_empty()) {
            return text;
        }
    }
    t("failed")
}

pub fn read_report() -> Value {
    read_text(&data::report_file()).and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null)
}

// ------------------------------------------------------------ command queue

pub fn start_queue(commands: Vec<Cmd>, operation: &str) {
    if is_busy() || commands.is_empty() {
        if is_busy() {
            info("EUS", &t("busy"));
        }
        return;
    }
    {
        let ctx = context();
        let mut st = ctx.st.borrow_mut();
        st.operation = operation.into();
        st.queue = commands.into();
    }
    if operation == "check" || operation == "install" {
        set_panel_status("hidden", 0, -1);
    }
    run_next();
}

fn row_of(st: &State, record: &Record) -> Option<usize> {
    st.groups.iter().position(|g| g.packages.iter().any(|p| p.source == record.source && p.name == record.name))
}

fn run_next() {
    let ctx = context();
    let next = ctx.st.borrow_mut().queue.pop_front();
    let Some(cmd) = next else {
        finish_operation();
        return;
    };
    let app = ctx.ui.global::<App>();
    let operation = ctx.st.borrow().operation.clone();
    let text = match (&cmd.task, operation.as_str()) {
        (Some(Task::SavePrefs), _) => t("saving"),
        (Some(_), _) => t("working"),
        (None, "check") => t("checking"),
        (None, "settings") => t("saving"),
        _ => t("installing"),
    };
    let generation = {
        let mut st = ctx.st.borrow_mut();
        st.generation += 1;
        st.started_at = eus_core::util::now();
        st.timed_out = false;
        st.active_rows = cmd.records.iter().filter_map(|r| row_of(&st, r)).collect();
        st.active_rows.sort();
        st.active_rows.dedup();
        for row in st.active_rows.clone() {
            st.progress[row] = 1;
        }
        st.current = Some(cmd.clone());
        st.generation
    };
    app.set_busy(true);
    app.set_progress_detail(ss(&text));
    if cmd.task.is_some() {
        app.set_task_visible(true);
        app.set_task_text(ss(&text));
        app.set_task_value(1);
    } else {
        app.set_status_title(ss(&text));
        app.set_show_progress(true);
        refresh_rows();
        if !ctx.st.borrow().active_rows.is_empty() {
            ctx.animation.start(slint::TimerMode::Repeated, Duration::from_millis(650), advance_rows);
        }
    }
    ctx.timeout.start(slint::TimerMode::SingleShot, Duration::from_secs(cmd.timeout), move || stop_stalled(generation));
    let handle = runner::spawn(&cmd.program, &cmd.args, move |event| {
        let ctx = context();
        if ctx.st.borrow().generation != generation {
            return;
        }
        match event {
            Event::Line(line) => handle_line(&line),
            Event::Finished(code) => process_finished(code),
        }
    });
    ctx.st.borrow_mut().handle = Some(handle);
}

fn handle_line(line: &str) {
    static PERCENT: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r"(?:^|[^\d])(\d{1,3})%").unwrap());
    let ctx = context();
    let app = ctx.ui.global::<App>();
    let text = line.trim();
    let is_task = ctx.st.borrow().current.as_ref().is_some_and(|c| c.task.is_some());
    let value = if !text.is_empty() && text.chars().all(|c| c.is_ascii_digit()) {
        text.parse::<i32>().ok()
    } else if let Some(detail) = text.strip_prefix("# ") {
        app.set_progress_detail(ss(detail));
        if is_task {
            app.set_task_text(ss(detail));
        }
        None
    } else if !is_task {
        PERCENT.captures_iter(text).last().and_then(|c| c[1].parse().ok())
    } else {
        None
    };
    if let Some(value) = value {
        let value = value.clamp(1, 100);
        if is_task {
            app.set_task_value(app.get_task_value().max(value));
        } else {
            let mut st = ctx.st.borrow_mut();
            for row in st.active_rows.clone() {
                st.progress[row] = st.progress[row].max(value);
            }
            drop(st);
            refresh_rows();
        }
    }
}

/// Keep slow APT/Flatpak operations visibly active between reports.
fn advance_rows() {
    let ctx = context();
    {
        let mut st = ctx.st.borrow_mut();
        for row in st.active_rows.clone() {
            if st.progress[row] < 95 {
                st.progress[row] += 1;
            }
        }
    }
    refresh_rows();
}

fn stop_stalled(generation: u64) {
    let ctx = context();
    let handle = {
        let mut st = ctx.st.borrow_mut();
        if st.generation != generation || st.current.is_none() {
            return;
        }
        st.timed_out = true;
        st.handle.clone()
    };
    ctx.ui.global::<App>().set_progress_detail(ss(t("timeout")));
    if let Some(handle) = handle {
        handle.terminate(false);
        slint::Timer::single_shot(Duration::from_secs(5), move || handle.terminate(true));
    }
}

fn process_finished(code: i32) {
    let ctx = context();
    ctx.timeout.stop();
    ctx.animation.stop();
    let (cmd, timed_out, started_at, operation) = {
        let mut st = ctx.st.borrow_mut();
        st.handle = None;
        (st.current.take().expect("running command"), st.timed_out, st.started_at, st.operation.clone())
    };
    let success = code == 0 && !timed_out;
    if operation == "install" && !cmd.records.is_empty() {
        let records: Vec<_> = cmd.records.iter()
            .map(|r| (r.source.clone(), r.name.clone(), r.installed.clone(), r.candidate.clone())).collect();
        data::append_history(&records, success);
    }
    {
        let mut st = ctx.st.borrow_mut();
        for row in st.active_rows.clone() {
            st.progress[row] = if success { 100 } else { -2 };
        }
        st.active_rows.clear();
    }
    refresh_rows();
    let app = ctx.ui.global::<App>();
    if let Some(task) = cmd.task.clone() {
        app.set_task_visible(false);
        app.set_busy(false);
        ctx.st.borrow_mut().queue.clear();
        let detail = if success { String::new() } else { failure_detail(code, started_at, timed_out) };
        crate::tools::task_finished(task, success, detail);
        return;
    }
    if !success {
        if cmd.ignore_failure {
            run_next();
            return;
        }
        ctx.st.borrow_mut().queue.clear();
        ctx.st.borrow_mut().operation.clear();
        app.set_busy(false);
        let detail = if cmd.root { failure_detail(code, started_at, timed_out) } else if timed_out { t("timeout") } else { t("failed") };
        load_updates();
        refresh_banners();
        show_failure(&detail);
        return;
    }
    run_next();
}

fn show_failure(detail: &str) {
    static KEYS: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r"(?i)NO_PUBKEY|GPG|signed|duplicate").unwrap());
    let mut buttons = vec![("close", t("close"), false)];
    if detail.contains("Key Fix") || KEYS.is_match(detail) {
        buttons.push(("keyfix", t("open_keyfix"), true));
    }
    message("EUS", detail, &buttons, |id| {
        if id == "keyfix" {
            navigate("keyfix".into());
        }
    });
}

fn finish_operation() {
    let ctx = context();
    let operation = std::mem::take(&mut ctx.st.borrow_mut().operation);
    ctx.ui.global::<App>().set_busy(false);
    if operation == "install" {
        let state = read_key_values(&data::state_file());
        let needs_restart = data::restart_is_required(&state) || ctx.st.borrow().install_had_kernel;
        ctx.st.borrow_mut().install_had_kernel = false;
        set_panel_status("hidden", 0, -1);
        let cache = std::env::var_os("XDG_CACHE_HOME").map(std::path::PathBuf::from).unwrap_or_else(|| data::home().join(".cache"));
        let _ = std::fs::remove_file(cache.join("eus/last-notified"));
        load_updates();
        refresh_banners();
        if needs_restart {
            message(&t("restart_title"), &format!("{}\n\n{}", t("success"), t("restart_body")),
                    &[("later", t("restart_later"), false), ("now", t("restart_now"), true)], |id| {
                if id == "now" {
                    request_reboot();
                }
            });
        } else {
            info("EUS", &t("success"));
        }
        return;
    }
    load_updates();
    refresh_banners();
}

// ------------------------------------------------------------ updates

pub fn load_updates() {
    let ctx = context();
    let mut records = data::parse_updates(&data::tsv_file());
    let known: Vec<(String, String)> = records.iter().map(|r| (r.source.clone(), r.name.clone())).collect();
    records.extend(data::scan_user_flatpaks().into_iter().filter(|r| !known.contains(&(r.source.clone(), r.name.clone()))));
    let mut groups = data::group_updates(&records);
    let upgrade = data::read_os_upgrade();
    if upgrade.get("mode").map(String::as_str) == Some("continuous") {
        // A new Debian stable arrived through "stable": one major update,
        // installed with the safe release-upgrade sequence.
        let apt: Vec<Record> = records.iter().filter(|r| r.source == "apt").cloned().collect();
        if let Some(first) = apt.first().cloned() {
            let get = |key: &str| upgrade.get(key).cloned().unwrap_or_default();
            let major = Group {
                key: ("major".into(), "major".into()),
                name: tf("major_name", &[("version", &data::major_of(&get("target_version"))), ("codename", &get("target_codename"))]),
                source: "apt".into(), category: "major".into(), size: apt.iter().map(|r| r.size).sum(),
                installed: format!("Debian {}", get("current_version")), candidate: format!("Debian {}", get("target_version")),
                description: tf("major_description", &[("count", &apt.len().to_string())]), self_update: false,
                main: first, packages: apt,
            };
            groups.retain(|g| g.source != "apt");
            groups.insert(0, major);
        }
    }
    let state = read_key_values(&data::state_file());
    {
        let mut st = ctx.st.borrow_mut();
        st.checked = vec![true; groups.len()];
        st.progress = vec![-1; groups.len()];
        st.records = records;
        st.groups = groups;
    }
    let app = ctx.ui.global::<App>();
    let checked_text = state.get("checked_at").and_then(|v| v.parse::<i64>().ok()).filter(|v| *v > 0)
        .map(data::format_last_check).unwrap_or_else(|| "—".into());
    app.set_last_checked(ss(tf("last_check", &[("time", &checked_text)])));
    let st = ctx.st.borrow();
    let count = |category: &str| st.groups.iter().filter(|g| g.category == category).count();
    let restart = data::restart_is_required(&state);
    let total = st.groups.len();
    let ok = state.get("state").map(String::as_str) == Some("ok");
    let status = if restart {
        t("restart_pending")
    } else if total > 0 {
        let parts: Vec<String> = ["major", "critical", "kernel", "medium", "normal", "flatpak"]
            .iter()
            .filter(|c| count(c) > 0)
            .map(|c| format!("{} {}", count(c), t(&format!("type_{c}")).to_lowercase()))
            .collect();
        tf("st_updates", &[("count", &total.to_string()), ("parts", &parts.join(", "))])
    } else if ok {
        t("current")
    } else {
        t("empty")
    };
    app.set_status_title(ss(&status));
    let home = if restart {
        t("restart_pending")
    } else if count("major") > 0 {
        t("home_major")
    } else if total > 0 {
        tf("home_updates", &[("count", &total.to_string())])
    } else if ok {
        t("home_ok")
    } else {
        t("empty")
    };
    app.set_home_status(ss(home));
    let security = count("critical");
    app.set_home_detail(ss(if security > 0 {
        tf("home_detail_security", &[("count", &security.to_string())])
    } else {
        tf("last_check", &[("time", &checked_text)])
    }));
    app.set_updates_badge(total as i32);
    let self_update = st.groups.iter().any(|g| g.self_update);
    app.set_self_banner(ss(if self_update { t("sb_self_update") } else { String::new() }));
    let has_rows = total > 0;
    drop(st);
    app.set_show_progress(false);
    app.set_current_update(if has_rows { 0 } else { -1 });
    refresh_rows();
    show_description(if has_rows { 0 } else { -1 });
    set_panel_status("hidden", 0, -1);
}

pub fn refresh_rows() {
    let ctx = context();
    let st = ctx.st.borrow();
    let rows: Vec<UpdateRow> = st
        .groups
        .iter()
        .enumerate()
        .map(|(index, group)| {
            let mut title = group.name.clone();
            if group.packages.len() > 1 {
                title.push_str(&format!("  ({})", group.packages.len()));
            }
            let progress = st.progress.get(index).copied().unwrap_or(-1);
            UpdateRow {
                category: ss(&group.category),
                type_label: ss(t(&format!("type_{}", group.category))),
                color: color(data::category_color(&group.category)),
                title: ss(title),
                summary: ss(group.description.rsplit(" — ").next().unwrap_or("")),
                version: ss(&group.candidate),
                size: ss(format_bytes(group.size)),
                checked: st.checked.get(index).copied().unwrap_or(false),
                progress: if progress == -2 { 100 } else { progress },
                progress_text: ss(match progress {
                    -2 => t("failed_progress"),
                    100 => t("complete_progress"),
                    _ => String::new(),
                }),
                apt: group.source == "apt" && group.category != "major",
            }
        })
        .collect();
    let selected: Vec<&Group> = st.groups.iter().zip(&st.checked).filter(|(_, c)| **c).map(|(g, _)| g).collect();
    let size: u64 = selected.iter().map(|g| g.size).sum();
    let app = ctx.ui.global::<App>();
    app.set_selection_text(ss(tf("selected", &[("count", &selected.len().to_string()), ("size", &format_bytes(size))])));
    app.set_can_install(!selected.is_empty());
    app.set_all_checked(!st.groups.is_empty() && selected.len() == st.groups.len());
    let current = app.get_updates();
    // Update in place when the row count is unchanged (keeps the scroll position).
    if let Some(vec) = current.as_any().downcast_ref::<VecModel<UpdateRow>>().filter(|m| m.row_count() == rows.len()) {
        for (index, row) in rows.into_iter().enumerate() {
            if vec.row_data(index).as_ref() != Some(&row) {
                vec.set_row_data(index, row);
            }
        }
    } else {
        app.set_updates(model(rows));
    }
}

pub fn set_checked(apply: impl Fn(usize, &Group) -> bool) {
    let ctx = context();
    {
        let mut st = ctx.st.borrow_mut();
        let values: Vec<bool> = st.groups.iter().enumerate().map(|(i, g)| apply(i, g)).collect();
        st.checked = values;
    }
    refresh_rows();
}

pub fn toggle_update(index: i32) {
    let ctx = context();
    if let Some(value) = ctx.st.borrow_mut().checked.get_mut(index as usize) {
        *value = !*value;
    }
    refresh_rows();
}

pub fn show_description(index: i32) {
    let ctx = context();
    let app = ctx.ui.global::<App>();
    let st = ctx.st.borrow();
    let Some(group) = usize::try_from(index).ok().and_then(|i| st.groups.get(i)) else {
        app.set_d_name(ss(""));
        app.set_packages_text(ss(""));
        app.set_changelog_text(ss(""));
        return;
    };
    let category = &group.category;
    app.set_d_name(ss(&group.name));
    app.set_d_type(ss(t(&format!("type_{category}"))));
    app.set_d_color(color(data::category_color(category)));
    app.set_d_meta(ss(format!("{}  ·  {} → {}", t(&format!("source_{}", group.source)), group.installed, group.candidate)));
    app.set_d_text(ss(&group.description));
    app.set_d_advice(ss(format!("{} {} {}", t(&format!("fix_{category}")), t(&format!("risk_{category}")),
                                t(&format!("recommend_{category}")))));
    let packages: Vec<String> = group.packages.iter()
        .map(|p| format!("{:<40} {} → {}  ({})", p.name, p.installed, p.candidate, format_bytes(p.size))).collect();
    app.set_packages_text(ss(packages.join("\n")));
    app.set_changelog_text(ss(""));
    drop(st);
    load_changelog();
}

/// Fetch the changelog only while its tab is visible (like mintupdate).
pub fn load_changelog() {
    let ctx = context();
    let app = ctx.ui.global::<App>();
    if app.get_details_tab() != 2 {
        return;
    }
    let index = app.get_current_update();
    let (package, installed, source) = {
        let st = ctx.st.borrow();
        let Some(group) = usize::try_from(index).ok().and_then(|i| st.groups.get(i)) else { return };
        (group.main.name.clone(), group.main.installed.clone(), group.source.clone())
    };
    if source != "apt" {
        app.set_changelog_text(ss(t("cg_flatpak")));
        return;
    }
    if let Some(text) = ctx.st.borrow().changelog_cache.get(&package) {
        app.set_changelog_text(ss(text));
        return;
    }
    if ctx.st.borrow().changelog_loading {
        return;
    }
    ctx.st.borrow_mut().changelog_loading = true;
    app.set_changelog_text(ss(t("cg_loading")));
    let name = package.clone();
    runner::background(
        move || eus_core::cleaner::changelog(&name, &installed, 400).map_err(|e| e.to_string()),
        move |result| {
            let ctx = context();
            let text = match result {
                Ok(text) if !text.is_empty() => text,
                Ok(_) => t("cg_none"),
                Err(error) => error,
            };
            {
                let mut st = ctx.st.borrow_mut();
                st.changelog_loading = false;
                st.changelog_cache.insert(package.clone(), text);
            }
            load_changelog();
        },
    );
}

pub fn check_updates() {
    if is_busy() {
        return;
    }
    let mut commands = Vec::new();
    if eus_core::util::which("flatpak") {
        commands.push(Cmd {
            program: "flatpak".into(),
            args: ["update", "--user", "--appstream", "--noninteractive"].iter().map(|s| s.to_string()).collect(),
            root: false, records: vec![], timeout: 120, ignore_failure: true, task: None,
        });
    }
    commands.push(root_cmd("refresh", &[], vec![]));
    start_queue(commands, "check");
}

pub fn install_updates() {
    let ctx = context();
    let (selected_groups, selected, all_apt) = {
        let st = ctx.st.borrow();
        let groups: Vec<Group> = st.groups.iter().zip(&st.checked).filter(|(_, c)| **c).map(|(g, _)| g.clone()).collect();
        let records: Vec<Record> = groups.iter().flat_map(|g| g.packages.clone()).collect();
        let all_apt = st.records.iter().filter(|r| r.source == "apt").count();
        (groups, records, all_apt)
    };
    if selected.is_empty() || is_busy() {
        return;
    }
    if let Some(major) = selected_groups.iter().find(|g| g.category == "major").cloned() {
        let upgrade = data::read_os_upgrade();
        let get = |key: &str| upgrade.get(key).cloned().unwrap_or_default();
        let text = tf("major_confirm", &[("version", &data::major_of(&get("target_version"))), ("codename", &get("target_codename")),
                                        ("count", &major.packages.len().to_string()), ("size", &format_bytes(major.size))]);
        confirm(&t("major_title"), &text, move || {
            context().st.borrow_mut().install_had_kernel = true;
            start_queue(vec![root_cmd("major-upgrade", &[], major.packages.clone())], "install");
        });
        return;
    }
    let size = format_bytes(selected.iter().map(|r| r.size).sum());
    let mut text = format!("{}\n\n{}", tf("confirm", &[("count", &selected.len().to_string()), ("size", &size)]), t("partial_warning"));
    let restart = selected.iter().any(data::restart_sensitive);
    if restart {
        text.push_str(&format!("\n\n{}", t("restart_may_be_required")));
    }
    confirm(&t("confirm_title"), &text, move || {
        context().st.borrow_mut().install_had_kernel = restart;
        let by_source = |source: &str| selected.iter().filter(|r| r.source == source).cloned().collect::<Vec<_>>();
        let (apt, system, user) = (by_source("apt"), by_source("flatpak-system"), by_source("flatpak-user"));
        let names = |records: &[Record]| records.iter().map(|r| r.name.clone()).collect::<Vec<_>>();
        let mut commands = Vec::new();
        if !apt.is_empty() {
            commands.push(if apt.len() == all_apt {
                root_cmd("upgrade-apt", &[], apt.clone())
            } else {
                root_cmd("install-apt", &names(&apt), apt.clone())
            });
        }
        if !system.is_empty() {
            commands.push(root_cmd("install-flatpak-system", &names(&system), system.clone()));
        }
        if !user.is_empty() {
            let mut args: Vec<String> = ["update", "--user", "--noninteractive", "-y"].iter().map(|s| s.to_string()).collect();
            args.extend(names(&user));
            commands.push(Cmd { program: "flatpak".into(), args, root: false, records: user.clone(),
                                timeout: 3700, ignore_failure: false, task: None });
        }
        // The APT and system Flatpak actions rebuild updates.tsv themselves.
        if !user.is_empty() || (apt.is_empty() && system.is_empty()) {
            commands.push(root_cmd("refresh", &[], vec![]));
        }
        start_queue(commands, "install");
    });
}

pub fn install_self_update() {
    set_checked(|_, g| g.self_update);
    install_updates();
}

pub fn ignore_group(index: i32, versioned: bool) {
    let group = context().st.borrow().groups.get(index as usize).cloned();
    if let Some(group) = group {
        let pattern = if versioned { format!("{}={}", group.key.1, group.candidate) } else { group.key.1.clone() };
        start_queue(vec![root_cmd("ignore", &["add".into(), pattern], vec![])], "settings");
    }
}

// ------------------------------------------------------------ banners

fn repo_problem_text(problems: &eus_core::apt::AptProblems, duplicates: usize) -> String {
    let mut parts = Vec::new();
    for (key, count) in [("repo_unreachable", problems.unreachable.len()), ("repo_missing", problems.missing_keys.len()),
                         ("repo_expired", problems.expired_keys.len()), ("repo_unsigned", problems.unsigned.len())] {
        if count > 0 {
            parts.push(tf(key, &[("count", &count.to_string())]));
        }
    }
    let duplicates = if duplicates > 0 { duplicates } else { problems.configured_multiple_times.len() };
    if duplicates > 0 {
        parts.push(tf("repo_duplicates", &[("count", &duplicates.to_string())]));
    }
    if !problems.signed_by_conflicts.is_empty() {
        parts.push(t("repo_conflict"));
    }
    if problems.legacy_warning {
        parts.push(t("repo_legacy"));
    }
    parts.join(", ")
}

pub fn repo_problems_now() -> String {
    let problems = eus_core::apt::apt_problems(None);
    let duplicates = eus_core::sources::find_duplicates(&eus_core::sources::all_entries()).len();
    repo_problem_text(&problems, duplicates)
}

pub fn refresh_banners() {
    let ctx = context();
    let app = ctx.ui.global::<App>();
    let upgrade = data::read_os_upgrade();
    if upgrade.is_empty() {
        app.set_os_banner(ss(""));
    } else {
        let continuous = upgrade.get("mode").map(String::as_str) == Some("continuous");
        let get = |key: &str| upgrade.get(key).cloned().unwrap_or_default();
        app.set_os_action(ss(if continuous { t("hb_open") } else { t("open_upgrade") }));
        let os_name = upgrade.get("os_name").cloned().unwrap_or_else(|| "Edukasaun OS".into());
        app.set_os_banner(ss(tf(if continuous { "banner_major" } else { "banner_os" },
                                &[("os", &os_name), ("version", &data::major_of(&get("target_version"))),
                                  ("codename", &get("target_codename"))])));
    }
    app.set_show_major(!upgrade.is_empty());
    let until = data::paused_until();
    app.set_pause_banner(ss(if until > 0 { tf("banner_paused", &[("date", &data::format_date(until))]) } else { String::new() }));
    let state = read_key_values(&data::state_file());
    app.set_restart_banner(ss(if data::restart_is_required(&state) { t("restart_pending") } else { String::new() }));
    runner::background(
        || {
            let repos = repo_problems_now();
            let old = match data::fixture("EUS_KERNEL_FIXTURE") {
                Some(value) => value["old_count"].as_u64().unwrap_or(0) as usize,
                None => eus_core::kernels::list_kernels(false).old_count,
            };
            (repos, old)
        },
        |(repos, old)| {
            let ui = crate::app::ui();
            let app = ui.global::<App>();
            app.set_repo_banner(ss(if repos.is_empty() { String::new() } else { tf("banner_repo", &[("details", &repos)]) }));
            app.set_kernel_banner(ss(if old > 0 { tf("banner_kernel", &[("count", &old.to_string())]) } else { String::new() }));
        },
    );
}

pub fn banner(kind: String) {
    match kind.as_str() {
        "self" => install_self_update(),
        "os" => open_major_update(),
        "restart" => confirm_reboot(),
        "health" => navigate("health".into()),
        "repo" => navigate("keyfix".into()),
        "pause" => resume_updates(),
        "kernel" => navigate("kernels".into()),
        _ => {}
    }
}

pub fn open_major_update() {
    if data::read_os_upgrade().get("mode").map(String::as_str) == Some("continuous") {
        navigate("updates".into());
    } else {
        navigate("upgrade".into());
    }
}

fn resume_updates() {
    start_queue(vec![root_cmd("pause", &["0".into()], vec![])], "settings");
}

/// Reload when a background refresh (timer or new repository) changed the state.
pub fn watch_files() {
    let paths = [data::state_file(), data::tsv_file(), data::pause_file(), data::os_upgrade_file(), data::health_file(),
                 data::restart_file()];
    let stamp: u64 = paths
        .iter()
        .filter_map(|p| std::fs::metadata(p).ok())
        .filter_map(|m| m.modified().ok())
        .filter_map(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .sum();
    let ctx = context();
    let changed = {
        let mut st = ctx.st.borrow_mut();
        let changed = st.watch_stamp != 0 && st.watch_stamp != stamp;
        st.watch_stamp = stamp;
        changed || st.pending_reload
    };
    if changed {
        if is_busy() || ctx.ui.global::<App>().get_msg_visible() {
            ctx.st.borrow_mut().pending_reload = true;
            return;
        }
        ctx.st.borrow_mut().pending_reload = false;
        load_updates();
        refresh_banners();
        load_saved_health();
    }
}

// ------------------------------------------------------------ System Health

pub fn scan_health(deep: bool) {
    let ctx = context();
    if ctx.st.borrow().health_loading {
        return;
    }
    if let Some(value) = data::fixture("EUS_HEALTH_FIXTURE") {
        populate_health(value, true);
        return;
    }
    ctx.st.borrow_mut().health_loading = true;
    ctx.ui.global::<App>().set_health_scanning(true);
    runner::background(
        move || serde_json::to_value(eus_core::health::scan_health(deep)).unwrap_or(Value::Null),
        |value| {
            let ctx = context();
            ctx.st.borrow_mut().health_loading = false;
            ctx.ui.global::<App>().set_health_scanning(false);
            populate_health(value, true);
        },
    );
}

pub fn load_saved_health() {
    if let Some(value) = read_text(&data::health_file()).and_then(|t| serde_json::from_str::<Value>(&t).ok()) {
        let shown = context().st.borrow().health_shown;
        populate_health(value, shown);
    }
}

fn severity_color(severity: &str) -> &'static str {
    match severity {
        "critical" => "#B42318",
        "warning" => "#B45309",
        "info" => "#1D4ED8",
        "recommend" => "#0F7B4F",
        _ => "#374151",
    }
}

fn health_items(data: &Value) -> Vec<Value> {
    ["findings", "recommendations"].iter().flat_map(|k| data[k].as_array().cloned().unwrap_or_default()).collect()
}

pub fn populate_health(data: Value, shown: bool) {
    let ctx = context();
    let items = health_items(&data);
    let checked: Vec<bool> = items
        .iter()
        .map(|i| i["fix"].as_str().is_some_and(|f| !f.is_empty()) && ["critical", "warning"].contains(&i["severity"].as_str().unwrap_or("")))
        .collect();
    {
        let mut st = ctx.st.borrow_mut();
        st.health = data;
        st.health_shown = shown;
        st.health_checked = checked;
    }
    refresh_health();
}

pub fn refresh_health() {
    let ctx = context();
    let st = ctx.st.borrow();
    let data = &st.health;
    let findings = data["findings"].as_array().cloned().unwrap_or_default();
    let recommendations = data["recommendations"].as_array().cloned().unwrap_or_default();
    let problems: Vec<&Value> = findings.iter().filter(|f| ["critical", "warning"].contains(&f["severity"].as_str().unwrap_or(""))).collect();
    let mut rows = Vec::new();
    let mut index = 0;
    for (section, items) in [(t("hp_findings"), &findings), (t("hp_recommendations"), &recommendations)] {
        if items.is_empty() {
            continue;
        }
        rows.push(HealthRow { header: true, title: ss(section), ..Default::default() });
        for item in items {
            let severity = item["severity"].as_str().unwrap_or("info");
            let label = t(&format!("sev_{severity}"));
            let fix = item["fix"].as_str().unwrap_or("");
            let page = item["page"].as_str().unwrap_or("");
            rows.push(HealthRow {
                header: false, ok: false,
                title: ss(item["title"].as_str().unwrap_or("")),
                detail: ss(item["detail"].as_str().unwrap_or("")),
                label: ss(if fix.is_empty() && !page.is_empty() { format!("{label} · {}", t("hp_open")) } else { label }),
                color: color(severity_color(severity)),
                checkable: !fix.is_empty(),
                checked: st.health_checked.get(index).copied().unwrap_or(false),
                page: ss(page),
            });
            index += 1;
        }
    }
    if findings.is_empty() && recommendations.is_empty() {
        rows.push(HealthRow { ok: true, title: ss(t("hp_ok")), ..Default::default() });
    }
    let when = data["checked_at"].as_i64().filter(|v| *v > 0).map(data::format_date).unwrap_or_else(|| "—".into());
    let app = ctx.ui.global::<App>();
    app.set_health_summary(ss(if problems.is_empty() {
        tf("hp_good", &[("time", &when)])
    } else {
        tf("hp_problems", &[("count", &problems.len().to_string()), ("time", &when)])
    }));
    app.set_health_badge(problems.len() as i32);
    app.set_health_banner(ss(problems.first().map(|p| tf("hb_text", &[("title", p["title"].as_str().unwrap_or(""))])).unwrap_or_default()));
    app.set_can_fix_health(st.health_checked.iter().any(|c| *c));
    app.set_health(model(rows));
}

/// Map a list row (with section headers) to the health item index.
fn health_item_index(row: i32) -> Option<usize> {
    let ctx = context();
    let rows = ctx.ui.global::<App>().get_health();
    let mut item = 0;
    for index in 0..rows.row_count() {
        let data = rows.row_data(index)?;
        if data.header || data.ok {
            continue;
        }
        if index as i32 == row {
            return Some(item);
        }
        item += 1;
    }
    None
}

pub fn toggle_health(row: i32) {
    if let Some(item) = health_item_index(row) {
        let ctx = context();
        if let Some(value) = ctx.st.borrow_mut().health_checked.get_mut(item) {
            *value = !*value;
        }
        refresh_health();
    }
}

pub fn open_health(row: i32) {
    let Some(item) = health_item_index(row) else { return };
    let page = health_items(&context().st.borrow().health).get(item).and_then(|i| i["page"].as_str().map(str::to_string));
    match page.as_deref() {
        Some("restart") => confirm_reboot(),
        Some("key-fix") => navigate("keyfix".into()),
        Some("kernel") | Some("kernels") => navigate("kernels".into()),
        Some(page) if !page.is_empty() => navigate(page.into()),
        _ => {}
    }
}

pub fn fix_health() {
    let fixes: Vec<String> = {
        let ctx = context();
        let st = ctx.st.borrow();
        health_items(&st.health)
            .iter()
            .zip(&st.health_checked)
            .filter(|(item, checked)| **checked && item["fix"].as_str().is_some_and(|f| !f.is_empty()))
            .map(|(item, _)| item["fix"].as_str().unwrap().to_string())
            .collect()
    };
    if fixes.is_empty() {
        return;
    }
    confirm(&t("nav_health"), &tf("hp_confirm", &[("count", &fixes.len().to_string())]), move || {
        start_queue(vec![task_cmd("health-fix", &fixes, Task::HealthFix)], "task");
    });
}

// ------------------------------------------------------------ navigation

pub fn navigate(page: String) {
    let ctx = context();
    let app = ctx.ui.global::<App>();
    match page.as_str() {
        "check" => return check_updates(),
        "major" => return open_major_update(),
        "quit" => {
            request_close();
            return;
        }
        _ => {}
    }
    // A running tool task keeps its page.
    if app.get_task_visible() {
        return;
    }
    app.set_page(ss(&page));
    match page.as_str() {
        "health" if !ctx.st.borrow().health_shown => scan_health(true),
        "kernel" => navigate("kernels".into()),
        "key-fix" => navigate("keyfix".into()),
        "add-repo" => navigate("addrepo".into()),
        "add-key" => navigate("addkey".into()),
        "upgrade-os" => navigate("upgrade".into()),
        _ => crate::tools::enter(&page),
    }
}

/// Closing is refused while a task runs; otherwise the panel icon returns
/// when updates are still available.
pub fn request_close() -> bool {
    if is_busy() {
        info("EUS", &t("busy"));
        return false;
    }
    let ctx = context();
    let count = ctx.st.borrow().groups.len();
    if !ctx.st.borrow().records.is_empty() && data::paused_until() == 0 {
        set_panel_status("available", count, -1);
    } else {
        set_panel_status("hidden", 0, -1);
    }
    crate::instance::cleanup();
    let _ = slint::quit_event_loop();
    true
}
