//! Tool pages: Cleaner, Kernels, Key Fix, Add Repository, Add Key,
//! Upgrade OS, Settings, History and Log.

use crate::app::{self, color, confirm, context, info, message, model, ss, start_queue, task_cmd, Task};
use crate::data;
use crate::i18n::{t, tf};
use crate::runner;
use crate::{App, CleanRow, KernelRow, TableRow};
use eus_core::util::{format_bytes, read_key_values, read_text};
use regex::Regex;
use serde_json::{json, Value};
use slint::ComponentHandle;
use std::sync::LazyLock;

static NAME_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-z0-9][a-z0-9._-]{0,62}$").unwrap());
static URI_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(https?|ftp|file)://\S+$").unwrap());
static KEYID_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(0x)?([0-9A-Fa-f]{8}|[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})$").unwrap());

#[derive(Default)]
pub struct ToolState {
    clean_items: Vec<Value>,
    clean_checked: Vec<bool>,
    clean_loading: bool,
    kernels: Value,
    kernel_checked: Vec<bool>,
    kernel_loading: bool,
    keyfix_loading: bool,
    os_state: std::collections::BTreeMap<String, String>,
    options: std::collections::BTreeMap<String, String>,
    schedule: Option<data::Schedule>,
    ignored: Vec<String>,
    suggested_name: String,
}

fn table_row(cells: &[&str], hex: &str) -> TableRow {
    let cell = |i: usize| ss(cells.get(i).copied().unwrap_or(""));
    TableRow { a: cell(0), b: cell(1), c: cell(2), d: cell(3), e: cell(4), color: color(hex), ok: false }
}

fn ok_row(text: &str) -> TableRow {
    TableRow { a: ss(text), ok: true, ..table_row(&[], "#0F7B4F") }
}

fn strings(value: &Value) -> Vec<String> {
    value.as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default()
}

/// Load the data a page shows when it opens.
pub fn enter(page: &str) {
    match page {
        "cleaner" => clean_scan(),
        "kernels" => kernel_refresh(),
        "keyfix" => keyfix_scan(),
        "addrepo" => reset_add_repo(),
        "addkey" => reset_add_key(),
        "upgrade" => load_upgrade(),
        "prefs" => load_prefs(),
        "history" => render_history(),
        "log" => load_log(),
        _ => {}
    }
}

/// A privileged task of a tool page has ended.
pub fn task_finished(task: Task, success: bool, detail: String) {
    let report = app::read_report();
    let bullets = |key: &str| -> Vec<String> {
        report[key].as_array().map(|a| a.iter().filter_map(|v| v.as_str()).map(|s| format!("• {s}")).collect()).unwrap_or_default()
    };
    match task {
        Task::HealthFix => {
            if success {
                let mut lines = vec![t("hp_fixed")];
                lines.extend(bullets("errors"));
                info(&t("nav_health"), &lines.join("\n"));
            } else {
                info(&t("nav_health"), &detail);
            }
            app::load_updates();
            app::refresh_banners();
            app::scan_health(true);
        }
        Task::KernelInstall(ref kernels) | Task::KernelRemove(ref kernels) => {
            let install = matches!(task, Task::KernelInstall(_));
            let records: Vec<_> = kernels
                .iter()
                .map(|(name, version)| {
                    if install {
                        ("kernel".to_string(), name.clone(), "—".to_string(), version.clone())
                    } else {
                        ("kernel".to_string(), format!("linux-image-{name}"), version.clone(), "removed".to_string())
                    }
                })
                .collect();
            data::append_history(&records, success);
            if !success {
                info(&t("kernel_title"), &detail);
            } else if install {
                message(&t("kernel_title"), &t("k_installed_ok"),
                        &[("later", t("restart_later"), false), ("now", t("restart_now"), true)], |id| {
                    if id == "now" {
                        app::request_reboot();
                    }
                });
            } else {
                info(&t("kernel_title"), &t("k_removed_ok"));
            }
            app::load_updates();
            app::refresh_banners();
            kernel_refresh();
        }
        Task::FixKeys | Task::FixDuplicates => {
            if success {
                let mut lines = vec![t("kf_done")];
                lines.extend(bullets("actions"));
                for fixed in report["fixed"].as_array().cloned().unwrap_or_default() {
                    lines.push(format!("• {}:{}", fixed["file"].as_str().unwrap_or(""), fixed["line"]));
                }
                let mut problems: Vec<String> = strings(&report["errors"]);
                if let Ok(remaining) = serde_json::from_value::<RemainingProblems>(report["remaining"].clone()) {
                    let text = remaining.text();
                    if !text.is_empty() {
                        problems.push(text);
                    }
                }
                if !problems.is_empty() {
                    lines.push(String::new());
                    lines.push(t("kf_remaining"));
                    lines.extend(problems.iter().map(|p| format!("• {p}")));
                }
                if let Some(backup) = report["backup"].as_str().filter(|b| !b.is_empty()) {
                    lines.push(String::new());
                    lines.push(tf("kf_backup", &[("path", backup)]));
                }
                info(&t("kf_title"), &lines.join("\n"));
            } else {
                info(&t("kf_title"), &detail);
            }
            app::refresh_banners();
            keyfix_scan();
        }
        Task::AddRepo => {
            if !success {
                info(&t("ar_title"), &detail);
                return;
            }
            let mut lines = vec![t("ar_added"), String::new()];
            if let Some(keys) = report["keys"].as_array().filter(|k| !k.is_empty()) {
                lines.push(tf("ar_key_found", &[("source", report["key_source"].as_str().unwrap_or(""))]));
                for key in keys {
                    lines.push(format!("  {}\n  {}", key["uid"].as_str().unwrap_or(""), key["fingerprint"].as_str().unwrap_or("")));
                }
                lines.push(String::new());
            }
            lines.extend(bullets("actions"));
            info(&t("ar_title"), &lines.join("\n"));
            app::load_updates();
            app::refresh_banners();
            app::navigate("sources".into());
        }
        Task::AddKey => {
            if !success {
                info(&t("ak_title"), &detail);
                return;
            }
            let mut lines = vec![t("ak_added"), String::new()];
            for key in report["keys"].as_array().cloned().unwrap_or_default() {
                lines.push(format!("• {} ({})", key["uid"].as_str().unwrap_or(""), key["keyid"].as_str().unwrap_or("")));
            }
            lines.extend(bullets("actions"));
            lines.extend(strings(&report["warnings"]).iter().map(|w| format!("⚠ {w}")));
            info(&t("ak_title"), &lines.join("\n"));
            app::load_updates();
            app::refresh_banners();
            app::navigate("sources".into());
        }
        Task::OsUpgrade => {
            if !success {
                info(&t("os_title"), &detail);
                return;
            }
            message(&t("os_title"), &t("os_done"), &[("later", t("restart_later"), false), ("now", t("restart_now"), true)], |id| {
                if id == "now" {
                    app::request_reboot();
                }
            });
            app::load_updates();
            app::refresh_banners();
            app::navigate("home".into());
        }
        Task::Clean => {
            info(&t("cl_title"), &if success { t("cl_done") } else { detail });
            clean_scan();
        }
        Task::Pause | Task::Unignore | Task::SavePrefs => {
            if !success {
                info(&t("settings_title"), &detail);
            }
            app::load_updates();
            app::refresh_banners();
            if task == Task::SavePrefs && success {
                // The settings queue continues with the next changed value.
                if !run_prefs_queue() {
                    app::navigate("settings".into());
                }
                return;
            }
            load_prefs();
        }
    }
}

#[derive(serde::Deserialize, Default)]
struct RemainingProblems {
    #[serde(default)]
    unreachable: Vec<Value>,
    #[serde(default)]
    missing_keys: Vec<Value>,
    #[serde(default)]
    expired_keys: Vec<Value>,
    #[serde(default)]
    unsigned: Vec<Value>,
}

impl RemainingProblems {
    fn text(&self) -> String {
        [("repo_unreachable", self.unreachable.len()), ("repo_missing", self.missing_keys.len()),
         ("repo_expired", self.expired_keys.len()), ("repo_unsigned", self.unsigned.len())]
            .iter()
            .filter(|(_, n)| *n > 0)
            .map(|(key, n)| tf(key, &[("count", &n.to_string())]))
            .collect::<Vec<_>>()
            .join(", ")
    }
}

// ------------------------------------------------------------ cleaner

pub fn clean_scan() {
    let ctx = context();
    if ctx.st.borrow().tools.clean_loading {
        return;
    }
    let app = ctx.ui.global::<App>();
    app.set_clean_rows(model(vec![]));
    app.set_can_clean(false);
    if let Some(value) = data::fixture("EUS_CLEAN_FIXTURE") {
        populate_clean(value);
        return;
    }
    ctx.st.borrow_mut().tools.clean_loading = true;
    app.set_clean_scanning(true);
    runner::background(
        || {
            let mut items = eus_core::cleaner::scan_system();
            items.extend(eus_core::cleaner::scan_user());
            serde_json::to_value(items).unwrap_or(Value::Null)
        },
        |value| {
            let ctx = context();
            ctx.st.borrow_mut().tools.clean_loading = false;
            ctx.ui.global::<App>().set_clean_scanning(false);
            populate_clean(value);
        },
    );
}

fn populate_clean(value: Value) {
    let ctx = context();
    let mut items = value.as_array().cloned().unwrap_or_default();
    // System items first, then the user's own caches.
    items.sort_by_key(|i| i["scope"].as_str() != Some("system"));
    {
        let mut st = ctx.st.borrow_mut();
        st.tools.clean_checked = items.iter().map(|i| i["default"].as_bool().unwrap_or(false)).collect();
        st.tools.clean_items = items;
    }
    refresh_clean();
}

fn refresh_clean() {
    let ctx = context();
    let st = ctx.st.borrow();
    let mut rows = Vec::new();
    for scope in ["system", "user"] {
        let scoped: Vec<(usize, &Value)> =
            st.tools.clean_items.iter().enumerate().filter(|(_, i)| i["scope"].as_str() == Some(scope)).collect();
        if scoped.is_empty() {
            continue;
        }
        rows.push(CleanRow { header: true, title: ss(t(&format!("cl_scope_{scope}"))), ..Default::default() });
        for (index, item) in scoped {
            let size = item["size"].as_u64().unwrap_or(0);
            rows.push(CleanRow {
                header: false,
                title: ss(item["title"].as_str().unwrap_or("")),
                size: ss(if size > 0 { format_bytes(size) } else { "—".into() }),
                detail: ss(item["detail"].as_str().unwrap_or("")),
                checked: st.tools.clean_checked[index],
            });
        }
    }
    let selected: Vec<&Value> = st.tools.clean_items.iter().zip(&st.tools.clean_checked).filter(|(_, c)| **c).map(|(i, _)| i).collect();
    let size: u64 = selected.iter().map(|i| i["size"].as_u64().unwrap_or(0)).sum();
    let app = ctx.ui.global::<App>();
    app.set_clean_total(ss(if st.tools.clean_items.is_empty() {
        t("cl_nothing")
    } else {
        tf("cl_total", &[("count", &selected.len().to_string()), ("size", &format_bytes(size))])
    }));
    app.set_can_clean(!selected.is_empty());
    app.set_clean_rows(model(rows));
}

/// Row in the list (with scope headers) -> item index.
fn clean_index(row: i32) -> Option<usize> {
    let ctx = context();
    let st = ctx.st.borrow();
    let mut position = 0;
    for scope in ["system", "user"] {
        let scoped: Vec<usize> =
            st.tools.clean_items.iter().enumerate().filter(|(_, i)| i["scope"].as_str() == Some(scope)).map(|(i, _)| i).collect();
        if scoped.is_empty() {
            continue;
        }
        position += 1;
        for index in scoped {
            if position == row {
                return Some(index);
            }
            position += 1;
        }
    }
    None
}

pub fn clean_toggle(row: i32) {
    if let Some(index) = clean_index(row) {
        if let Some(value) = context().st.borrow_mut().tools.clean_checked.get_mut(index) {
            *value = !*value;
        }
        refresh_clean();
    }
}

pub fn clean_run() {
    let selected: Vec<Value> = {
        let ctx = context();
        let st = ctx.st.borrow();
        st.tools.clean_items.iter().zip(&st.tools.clean_checked).filter(|(_, c)| **c).map(|(i, _)| i.clone()).collect()
    };
    if selected.is_empty() {
        return;
    }
    let size = format_bytes(selected.iter().map(|i| i["size"].as_u64().unwrap_or(0)).sum());
    confirm(&t("cl_title"), &tf("cl_confirm", &[("size", &size)]), move || {
        let ids = |scope: &str| -> Vec<String> {
            selected.iter().filter(|i| i["scope"].as_str() == Some(scope)).filter_map(|i| i["id"].as_str().map(str::to_string)).collect()
        };
        let (system, user) = (ids("system"), ids("user"));
        context().ui.global::<App>().set_can_clean(false);
        // Personal caches belong to the user: no administrator rights needed.
        runner::background(
            move || {
                if !user.is_empty() {
                    let _ = eus_core::cleaner::clean_user(&user);
                }
            },
            move |_| {
                if system.is_empty() {
                    task_finished(Task::Clean, true, String::new());
                } else {
                    start_queue(vec![task_cmd("clean", &system, Task::Clean)], "task");
                }
            },
        );
    });
}

// ------------------------------------------------------------ kernels

pub fn kernel_refresh() {
    let ctx = context();
    if ctx.st.borrow().tools.kernel_loading {
        return;
    }
    if let Some(value) = data::fixture("EUS_KERNEL_FIXTURE") {
        populate_kernels(value);
        return;
    }
    ctx.st.borrow_mut().tools.kernel_loading = true;
    let app = ctx.ui.global::<App>();
    app.set_kernel_loading(true);
    app.set_kernel_running(ss(t("k_loading")));
    runner::background(
        || serde_json::to_value(eus_core::kernels::list_kernels(true)).unwrap_or(Value::Null),
        |value| {
            let ctx = context();
            ctx.st.borrow_mut().tools.kernel_loading = false;
            ctx.ui.global::<App>().set_kernel_loading(false);
            populate_kernels(value);
        },
    );
}

fn populate_kernels(value: Value) {
    let ctx = context();
    let installed = value["installed"].as_array().cloned().unwrap_or_default();
    {
        let mut st = ctx.st.borrow_mut();
        st.tools.kernel_checked = installed.iter().map(|k| ["old", "residual"].contains(&k["state"].as_str().unwrap_or(""))).collect();
        st.tools.kernels = value.clone();
    }
    let app = ctx.ui.global::<App>();
    let running = value["running"].as_str().map(str::to_string).unwrap_or_else(eus_core::kernels::running_release);
    app.set_kernel_running(ss(format!("● {}", tf("kernel_running", &[("release", &running)]))));
    let available: Vec<slint::SharedString> = value["available"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|k| {
            let package = k["package"].as_str().unwrap_or("");
            if k["meta"].as_bool().unwrap_or(false) {
                ss(tf("k_meta", &[("package", package)]))
            } else {
                ss(format!("{package}   ({}, {})", k["version"].as_str().unwrap_or(""), format_bytes(k["size"].as_u64().unwrap_or(0))))
            }
        })
        .collect();
    app.set_kernel_note(ss(if available.is_empty() { t("k_none_available") } else { String::new() }));
    app.set_kernel_available(model(available));
    app.set_kernel_choice(0);
    app.set_kernel_headers(value["headers_installed"].as_bool().unwrap_or(false));
    refresh_kernels();
}

fn refresh_kernels() {
    let ctx = context();
    let st = ctx.st.borrow();
    let installed = st.tools.kernels["installed"].as_array().cloned().unwrap_or_default();
    let rows: Vec<KernelRow> = installed
        .iter()
        .enumerate()
        .map(|(index, kernel)| {
            let state = kernel["state"].as_str().unwrap_or("");
            let (fg, bg) = match state {
                "running" => ("#0F7B4F", "#E9F7EF"),
                "old" => ("#9A5B00", "#FFF6E0"),
                "newer" => ("#1260A8", "#EAF3FD"),
                "residual" => ("#6B7280", "#F3F4F6"),
                _ => ("#202020", "#FFFFFF"),
            };
            KernelRow {
                release: ss(kernel["release"].as_str().unwrap_or("")),
                state: ss(state),
                label: ss(t(&format!("k_state_{state}"))),
                version: ss(kernel["version"].as_str().unwrap_or("")),
                size: ss(format_bytes(kernel["size_kb"].as_u64().unwrap_or(0) * 1024)),
                checkable: state != "running",
                checked: st.tools.kernel_checked.get(index).copied().unwrap_or(false),
                color: color(fg),
                background: color(bg),
            }
        })
        .collect();
    let app = ctx.ui.global::<App>();
    app.set_can_remove_kernel(rows.iter().any(|r| r.checkable && r.checked));
    app.set_can_remove_old(rows.iter().any(|r| r.state == "old" || r.state == "residual"));
    app.set_kernels(model(rows));
}

pub fn kernel_toggle(row: i32) {
    if let Some(value) = context().st.borrow_mut().tools.kernel_checked.get_mut(row as usize) {
        *value = !*value;
    }
    refresh_kernels();
}

fn removable(only_checked: bool) -> Vec<Value> {
    let ctx = context();
    let st = ctx.st.borrow();
    st.tools.kernels["installed"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .zip(st.tools.kernel_checked.iter().copied())
        .filter(|(k, checked)| {
            let state = k["state"].as_str().unwrap_or("");
            state != "running" && if only_checked { *checked } else { state == "old" || state == "residual" }
        })
        .map(|(k, _)| k)
        .collect()
}

fn confirm_remove(kernels: Vec<Value>) {
    if kernels.is_empty() {
        info(&t("kernel_title"), &t("k_no_old"));
        return;
    }
    let items: Vec<String> = kernels
        .iter()
        .map(|k| format!("• {} — {}", k["release"].as_str().unwrap_or(""), t(&format!("k_state_{}", k["state"].as_str().unwrap_or("")))))
        .collect();
    confirm(&t("kernel_title"), &tf("k_confirm_remove", &[("items", &items.join("\n"))]), move || {
        let releases: Vec<String> = kernels.iter().filter_map(|k| k["release"].as_str().map(str::to_string)).collect();
        let pending = kernels
            .iter()
            .map(|k| (k["release"].as_str().unwrap_or("").to_string(), k["version"].as_str().unwrap_or("").to_string()))
            .collect();
        start_queue(vec![task_cmd("kernel-remove", &releases, Task::KernelRemove(pending))], "task");
    });
}

pub fn kernel_remove() {
    let kernels = removable(true);
    if kernels.is_empty() {
        info(&t("kernel_title"), &t("k_select"));
    } else {
        confirm_remove(kernels);
    }
}

pub fn kernel_remove_old() {
    confirm_remove(removable(false));
}

pub fn kernel_install() {
    let ctx = context();
    let app = ctx.ui.global::<App>();
    let index = app.get_kernel_choice();
    let Some(kernel) = ctx.st.borrow().tools.kernels["available"].get(index as usize).cloned() else { return };
    let package = kernel["package"].as_str().unwrap_or("").to_string();
    let headers = app.get_kernel_headers();
    confirm(&t("kernel_title"), &tf("k_confirm_install", &[("package", &package)]), move || {
        let mut extra = vec![package.clone()];
        if headers {
            extra.push("--headers".into());
        }
        let pending = vec![(package.clone(), kernel["version"].as_str().unwrap_or("").to_string())];
        start_queue(vec![task_cmd("kernel-install", &extra, Task::KernelInstall(pending))], "task");
    });
}

// ------------------------------------------------------------ Key Fix

struct KeyScan {
    repos: Value,
    overview: Value,
    keys: Value,
    targets: Vec<Value>,
}

pub fn keyfix_scan() {
    let ctx = context();
    if ctx.st.borrow().tools.keyfix_loading {
        return;
    }
    ctx.st.borrow_mut().tools.keyfix_loading = true;
    let app = ctx.ui.global::<App>();
    app.set_keyfix_scanning(true);
    app.set_dups_tab(ss(t("kf_tab_repos")));
    if let Ok(tab) = std::env::var("EUS_KEYFIX_TAB") {
        app.set_keyfix_tab(tab.parse().unwrap_or(0));
    }
    runner::background(
        || {
            use eus_core::{apt, keys, repos, sources};
            let entries = sources::all_entries();
            let files: Vec<String> = sources::source_files().iter().map(|p| p.to_string_lossy().to_string()).collect();
            let repo_scan = json!({"files": files, "entries": entries.len(), "duplicates": sources::find_duplicates(&entries),
                                   "apt": apt::apt_problems(None)});
            let overview = data::fixture("EUS_REPOSITORIES_FIXTURE")
                .unwrap_or_else(|| serde_json::to_value(repos::describe_repositories()).unwrap_or(Value::Null));
            let key_scan = keys::scan_keys();
            let targets = key_scan["apt"]["missing_keys"]
                .as_array()
                .into_iter()
                .chain(key_scan["apt"]["expired_keys"].as_array())
                .flatten()
                .map(|item| {
                    let url = item["url"].as_str().unwrap_or("");
                    let keyid = item["keyid"].as_str().unwrap_or("").to_uppercase();
                    let entries = if url.is_empty() { vec![] } else { keys::entries_for_url(url) };
                    serde_json::to_value(keys::key_target(entries.first(), &keyid)).unwrap_or(Value::Null)
                })
                .collect();
            KeyScan { repos: repo_scan, overview, keys: key_scan, targets }
        },
        |scan| {
            let ctx = context();
            ctx.st.borrow_mut().tools.keyfix_loading = false;
            ctx.ui.global::<App>().set_keyfix_scanning(false);
            populate_keyfix(scan);
        },
    );
}

fn populate_keyfix(scan: KeyScan) {
    let ui = crate::app::ui();
    let app = ui.global::<App>();
    // Overview of every source entry.
    let overview: Vec<TableRow> = scan
        .overview
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|repo| {
            let keyring = repo["signed_by"].as_str().unwrap_or("");
            let role = repo["keyring_role"].as_str().unwrap_or("none");
            let keyring_text = if keyring.starts_with('/') {
                format!("{keyring}  ({})", t(&format!("kr_{role}")))
            } else {
                t(&format!("kr_{role}"))
            };
            let status = repo["status"].as_str().unwrap_or("ok");
            let hex = match status {
                "ok" => "#0F7B4F",
                "disabled" => "#6B7280",
                "duplicate" => "#9A5B00",
                _ => "#B42318",
            };
            let repo_text = format!("{}  {}", repo["uri"].as_str().unwrap_or(""), strings(&repo["components"]).join(" "));
            table_row(&[&t(&format!("rp_status_{status}")), &repo_text, &strings(&repo["suites"]).join(" "),
                        &t(&format!("rp_role_{}", repo["role"].as_str().unwrap_or("third-party"))), &keyring_text], hex)
        })
        .collect();
    app.set_repo_overview(model(overview));

    // GPG keys: problems first, then every keyring with its location role.
    let apt = &scan.keys["apt"];
    let mut rows = Vec::new();
    for item in apt["unreachable"].as_array().cloned().unwrap_or_default() {
        rows.push(table_row(&[item["url"].as_str().unwrap_or(""),
                              &format!("{}: {}", t("kf_unreachable"), item["reason"].as_str().unwrap_or(""))], "#9A5B00"));
    }
    let mut targets = scan.targets.iter();
    for (key, items) in [("kf_missing", &apt["missing_keys"]), ("kf_expired", &apt["expired_keys"])] {
        for item in items.as_array().cloned().unwrap_or_default() {
            let mut text = t(key);
            if let Some(target) = targets.next().filter(|t| t["path"].as_str().is_some_and(|p| !p.is_empty())) {
                let role = t(&format!("kr_{}", target["role"].as_str().unwrap_or("scoped")));
                text.push_str(&format!(" — {}", tf("kf_target", &[("path", target["path"].as_str().unwrap_or("")), ("where", &role)])));
            }
            rows.push(table_row(&[&format!("{}  {}", item["keyid"].as_str().unwrap_or(""), item["url"].as_str().unwrap_or("")), &text],
                                "#B42318"));
        }
    }
    for url in strings(&apt["unsigned"]) {
        rows.push(table_row(&[&url, &t("kf_unsigned")], "#B42318"));
    }
    for source in strings(&apt["signed_by_conflicts"]) {
        rows.push(table_row(&[&source, &t("kf_conflict")], "#B42318"));
    }
    if apt["legacy_warning"].as_bool().unwrap_or(false) {
        rows.push(table_row(&["/etc/apt/trusted.gpg", &t("kf_legacy")], "#9A5B00"));
    }
    for path in strings(&scan.keys["missing_signed_by"]) {
        rows.push(table_row(&[&path, &t("kf_missing_file")], "#B42318"));
    }
    let files = scan.keys["files"].as_array().cloned().unwrap_or_default();
    for keyring in &files {
        let problems = strings(&keyring["problems"]);
        if !problems.is_empty() {
            let joined = problems.join("; ");
            rows.push(table_row(&[keyring["path"].as_str().unwrap_or(""), &joined],
                                if joined.contains("expired") { "#9A5B00" } else { "#B42318" }));
        }
    }
    if rows.is_empty() {
        rows.push(ok_row(&t("kf_ok_keys")));
    }
    for keyring in files.iter().filter(|k| strings(&k["problems"]).is_empty()) {
        let package = keyring["package"].as_str().filter(|p| !p.is_empty()).map(|p| format!(" ({p})")).unwrap_or_default();
        let role = keyring["role"].as_str().unwrap_or("scoped");
        let count = keyring["used_by"].as_array().map(|a| a.len()).unwrap_or(0).to_string();
        let info = tf(if role == "global" || role == "legacy" { "kf_keyring_global" } else { "kf_keyring_info" },
                      &[("role", &t(&format!("kr_{role}"))), ("package", &package), ("count", &count)]);
        rows.push(table_row(&[keyring["path"].as_str().unwrap_or(""), &info], "#4B5563"));
    }
    app.set_key_rows(model(rows));
    let note = std::fs::metadata(data::apt_update_log())
        .and_then(|m| m.modified())
        .ok()
        .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| tf("kf_last_update", &[("time", &data::format_date(d.as_secs() as i64))]))
        .unwrap_or_else(|| t("kf_no_refresh"));
    app.set_keys_note(ss(note));

    // Duplicate repositories.
    let duplicates = scan.repos["duplicates"].as_array().cloned().unwrap_or_default();
    let mut dup_rows: Vec<TableRow> = duplicates
        .iter()
        .map(|d| {
            let first = format!("{}:{}", d["first_file"].as_str().unwrap_or(""), d["first_line"]);
            let mut text = tf(if d["complete"].as_bool().unwrap_or(false) { "kf_dup_complete" } else { "kf_dup_partial" },
                              &[("first", &first)]);
            if d["signed_by_conflict"].as_bool().unwrap_or(false) {
                text.push_str(&format!(" · {}", t("kf_conflict")));
            }
            let item = format!("{}:{}  {} {}", d["file"].as_str().unwrap_or(""), d["line"], d["uri"].as_str().unwrap_or(""),
                               d["suite"].as_str().unwrap_or(""));
            table_row(&[&item, &text], "#9A5B00")
        })
        .collect();
    if duplicates.is_empty() {
        for target in strings(&scan.repos["apt"]["configured_multiple_times"]) {
            dup_rows.push(table_row(&[&target, &t("kf_multiple")], "#9A5B00"));
        }
    }
    if dup_rows.is_empty() {
        dup_rows.push(ok_row(&t("kf_ok_repos")));
    }
    app.set_dup_rows(model(dup_rows));
    app.set_dups_note(ss(strings(&scan.repos["files"]).join(", ")));
    app.set_dups_tab(ss(if duplicates.is_empty() {
        t("kf_tab_repos")
    } else {
        format!("{} ({})", t("kf_tab_repos"), duplicates.len())
    }));
}

pub fn fix_keys() {
    start_queue(vec![task_cmd("fix-keys", &[], Task::FixKeys)], "task");
}

pub fn fix_duplicates() {
    start_queue(vec![task_cmd("fix-duplicates", &[], Task::FixDuplicates)], "task");
}

// ------------------------------------------------------------ Add Repository

fn reset_add_repo() {
    let ui = crate::app::ui();
    let app = ui.global::<App>();
    for setter in [App::set_ar_name, App::set_ar_line, App::set_ar_uri, App::set_ar_suite, App::set_ar_arch] {
        setter(&app, ss(""));
    }
    app.set_ar_components(ss("main"));
    app.set_ar_line_mode(true);
    app.set_ar_source(false);
    app.set_ar_auto_key(true);
}

/// Suggest a name from the host of the repository line.
pub fn ar_line_edited(line: String) {
    static HOST: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?:https?|ftp)://([^/\s]+)").unwrap());
    static PREFIX: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(www|deb|apt|repo|download|packages|ppa)\.").unwrap());
    static NON_ALNUM: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^a-z0-9]+").unwrap());
    let ui = crate::app::ui();
    let app = ui.global::<App>();
    let Some(caps) = HOST.captures(&line) else { return };
    let host = caps[1].to_lowercase();
    let host = PREFIX.replace(&host, "").to_string();
    let base = host.rsplit_once('.').map(|(a, _)| a.to_string()).unwrap_or(host);
    let name: String = NON_ALNUM.replace_all(&base, "-").trim_matches('-').chars().take(40).collect();
    let current = app.get_ar_name().to_string();
    let ctx = context();
    let suggested = std::mem::take(&mut ctx.st.borrow_mut().tools.suggested_name);
    // Keep a name the user typed; replace only one EUS suggested.
    if current.is_empty() || current == suggested {
        app.set_ar_name(ss(&name));
        ctx.st.borrow_mut().tools.suggested_name = name;
    } else {
        ctx.st.borrow_mut().tools.suggested_name = suggested;
    }
}

pub fn ar_submit() {
    static LINE_RE: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"^(deb|deb-src)\s+(\[[^\]]*\]\s+)?(https?|ftp|file)://\S+\s+\S+").unwrap());
    let ui = crate::app::ui();
    let app = ui.global::<App>();
    let name = app.get_ar_name().trim().to_lowercase();
    if !NAME_RE.is_match(&name) {
        info(&t("ar_title"), &t("ak_invalid_name"));
        return;
    }
    let mut args = vec!["--name".to_string(), name];
    if app.get_ar_line_mode() {
        let line = app.get_ar_line().split_whitespace().collect::<Vec<_>>().join(" ");
        if !LINE_RE.is_match(&line) {
            info(&t("ar_title"), &t("ar_invalid_line"));
            return;
        }
        args.extend(["--line".into(), line]);
    } else {
        let (uri, suite) = (app.get_ar_uri().trim().to_string(), app.get_ar_suite().trim().to_string());
        let components = app.get_ar_components().split_whitespace().collect::<Vec<_>>().join(" ");
        if !URI_RE.is_match(&uri) || suite.is_empty() || (components.is_empty() && !suite.ends_with('/')) {
            info(&t("ar_title"), &t("ak_invalid_repo"));
            return;
        }
        args.extend(["--repo-uri".into(), uri, "--suite".into(), suite]);
        if !components.is_empty() {
            args.extend(["--components".into(), components]);
        }
        let arch = app.get_ar_arch().split_whitespace().collect::<Vec<_>>().join(" ");
        if !arch.is_empty() {
            args.extend(["--arch".into(), arch]);
        }
    }
    if app.get_ar_source() {
        args.push("--with-source".into());
    }
    if app.get_ar_auto_key() {
        args.push("--auto-key".into());
    }
    start_queue(vec![task_cmd("add-repo", &args, Task::AddRepo)], "task");
}

// ------------------------------------------------------------ Add Key

fn reset_add_key() {
    let ui = crate::app::ui();
    let app = ui.global::<App>();
    for setter in [App::set_ak_name, App::set_ak_file, App::set_ak_url, App::set_ak_keyid, App::set_ak_uri, App::set_ak_suite,
                   App::set_ak_arch, App::set_ak_key_info] {
        setter(&app, ss(""));
    }
    app.set_ak_components(ss("main"));
    app.set_ak_source(0);
    app.set_ak_with_repo(false);
    app.set_ak_source_pkgs(false);
    app.set_can_browse(["zenity", "kdialog", "qarma", "yad"].iter().any(|p| eus_core::util::which(p)));
    ak_changed();
}

fn clean_key_name(name: &str) -> String {
    let name = name.trim().to_lowercase();
    name.strip_suffix(".gpg").or_else(|| name.strip_suffix(".asc")).unwrap_or(&name).to_string()
}

pub fn ak_changed() {
    let ui = crate::app::ui();
    let app = ui.global::<App>();
    let name = clean_key_name(&app.get_ak_name());
    let name = if name.is_empty() { "<name>".to_string() } else { name };
    if app.get_ak_with_repo() {
        let mut lines = vec![format!("Types: deb{}", if app.get_ak_source_pkgs() { " deb-src" } else { "" }),
                             format!("URIs: {}", app.get_ak_uri().trim()), format!("Suites: {}", app.get_ak_suite().trim())];
        let components = app.get_ak_components().split_whitespace().collect::<Vec<_>>().join(" ");
        if !components.is_empty() {
            lines.push(format!("Components: {components}"));
        }
        let arch = app.get_ak_arch().split_whitespace().collect::<Vec<_>>().join(" ");
        if !arch.is_empty() {
            lines.push(format!("Architectures: {arch}"));
        }
        lines.push(format!("Signed-By: /etc/apt/keyrings/{name}.gpg"));
        app.set_ak_preview(ss(tf("ak_preview_repo", &[("name", &name), ("stanza", &lines.join("\n"))])));
    } else {
        app.set_ak_preview(ss(tf("ak_preview_key", &[("name", &name)])));
    }
}

pub fn ak_inspect() {
    let ui = crate::app::ui();
    let app = ui.global::<App>();
    let path = app.get_ak_file().trim().to_string();
    if path.is_empty() {
        app.set_ak_key_info(ss(""));
        return;
    }
    runner::background(
        move || {
            let absolute = std::path::absolute(&path).map(|p| p.to_string_lossy().to_string()).unwrap_or(path.clone());
            eus_core::keys::read_key_file(&absolute).and_then(|data| eus_core::keys::describe_keys(&data)).map_err(|e| e.to_string())
        },
        |result| {
            let ui = crate::app::ui();
            let app = ui.global::<App>();
            let text = match result {
                Ok(keys) => keys
                    .iter()
                    .map(|k| tf("ak_key_info", &[("uid", if k.uid.is_empty() { "?" } else { &k.uid }), ("keyid", &k.keyid)]))
                    .collect::<Vec<_>>()
                    .join("\n"),
                Err(error) => format!("⚠ {error}"),
            };
            app.set_ak_key_info(ss(text));
        },
    );
}

/// Pick a key file with the desktop's file chooser helper.
pub fn ak_browse() {
    let home = data::home().to_string_lossy().to_string();
    let title = t("ak_select_file");
    runner::background(
        move || {
            let candidates: [(&str, Vec<String>); 4] = [
                ("zenity", vec!["--file-selection".into(), format!("--title={title}"), format!("--filename={home}/"),
                                "--file-filter=OpenPGP keys | *.asc *.gpg *.pgp *.key *.pub".into(), "--file-filter=All files | *".into()]),
                ("qarma", vec!["--file-selection".into(), format!("--title={title}"), format!("--filename={home}/")]),
                ("kdialog", vec!["--getopenfilename".into(), home.clone(), "*.asc *.gpg *.pgp *.key *.pub".into()]),
                ("yad", vec!["--file".into(), format!("--title={title}"), format!("--filename={home}/")]),
            ];
            for (program, args) in candidates {
                if eus_core::util::which(program) {
                    let output = std::process::Command::new(program).args(&args).output().ok()?;
                    let path = String::from_utf8_lossy(&output.stdout).trim().trim_end_matches('|').to_string();
                    return (!path.is_empty()).then_some(path);
                }
            }
            None
        },
        |path| {
            let Some(path) = path else { return };
            let ui = crate::app::ui();
            let app = ui.global::<App>();
            app.set_ak_file(ss(&path));
            app.set_ak_source(0);
            if app.get_ak_name().trim().is_empty() {
                static NON: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^a-z0-9._-]+").unwrap());
                static SUFFIX: LazyLock<Regex> =
                    LazyLock::new(|| Regex::new(r"[-.](archive-)?(keyring|key|pub|public|signing)$").unwrap());
                let stem = std::path::Path::new(&path).file_stem().unwrap_or_default().to_string_lossy().to_lowercase();
                let guess = NON.replace_all(&stem, "-").trim_matches(['-', '.']).to_string();
                let short = SUFFIX.replace(&guess, "").to_string();
                let name: String = if short.is_empty() { guess } else { short }.chars().take(60).collect();
                app.set_ak_name(ss(name));
            }
            ak_changed();
            ak_inspect();
        },
    );
}

pub fn ak_submit() {
    let ui = crate::app::ui();
    let app = ui.global::<App>();
    let name = clean_key_name(&app.get_ak_name());
    if !NAME_RE.is_match(&name) {
        info(&t("ak_title"), &t("ak_invalid_name"));
        return;
    }
    let mut args = vec!["--name".to_string(), name];
    let (file, url, keyid) = (app.get_ak_file().trim().to_string(), app.get_ak_url().trim().to_string(),
                              app.get_ak_keyid().trim().to_string());
    match app.get_ak_source() {
        0 if !file.is_empty() => {
            let path = file.replacen('~', &data::home().to_string_lossy(), 1);
            let absolute = std::path::absolute(&path).map(|p| p.to_string_lossy().to_string()).unwrap_or(path);
            args.extend(["--file".into(), absolute]);
        }
        1 if url.starts_with("https://") => args.extend(["--url".into(), url]),
        2 if KEYID_RE.is_match(&keyid) => args.extend(["--keyserver".into(), keyid]),
        _ => {
            info(&t("ak_title"), &t("ak_missing_source"));
            return;
        }
    }
    if app.get_ak_with_repo() {
        let (uri, suite) = (app.get_ak_uri().trim().to_string(), app.get_ak_suite().trim().to_string());
        let components = app.get_ak_components().split_whitespace().collect::<Vec<_>>().join(" ");
        if !URI_RE.is_match(&uri) || suite.is_empty() || (components.is_empty() && !suite.ends_with('/')) {
            info(&t("ak_title"), &t("ak_invalid_repo"));
            return;
        }
        args.extend(["--repo-uri".into(), uri, "--suite".into(), suite]);
        if !components.is_empty() {
            args.extend(["--components".into(), components]);
        }
        let arch = app.get_ak_arch().split_whitespace().collect::<Vec<_>>().join(" ");
        if !arch.is_empty() {
            args.extend(["--arch".into(), arch]);
        }
        if app.get_ak_source_pkgs() {
            args.extend(["--with-source".into(), "yes".into()]);
        }
    }
    start_queue(vec![task_cmd("add-key", &args, Task::AddKey)], "task");
}

// ------------------------------------------------------------ Upgrade OS

fn load_upgrade() {
    let ctx = context();
    let app = ctx.ui.global::<App>();
    let state = data::read_os_upgrade();
    ctx.st.borrow_mut().tools.os_state = state.clone();
    app.set_os_plan(model(vec![]));
    app.set_can_start_os(false);
    let Some(target) = state.get("target_codename").cloned() else {
        app.set_os_headline(ss(t("os_none")));
        app.set_os_note(ss(""));
        return;
    };
    let get = |key: &str| state.get(key).cloned().unwrap_or_default();
    app.set_os_headline(ss(tf("os_from_to", &[
        ("os", &state.get("os_name").cloned().unwrap_or_else(|| "Edukasaun OS".into())),
        ("current", &format!("{} \"{}\"", data::major_of(&get("current_version")), get("current_codename"))),
        ("target", &format!("{} \"{}\"", data::major_of(&get("target_version")), target)),
    ])));
    app.set_os_note(ss(t("os_checking")));
    if let Some(value) = data::fixture("EUS_OS_PLAN_FIXTURE") {
        populate_upgrade(value);
        return;
    }
    runner::background(
        move || {
            eus_core::release::os_upgrade_plan(&target)
                .ok()
                .and_then(|plan| serde_json::to_value(plan).ok())
                .unwrap_or(Value::Null)
        },
        populate_upgrade,
    );
}

fn populate_upgrade(plan: Value) {
    let ui = crate::app::ui();
    let app = ui.global::<App>();
    let entries = plan["entries"].as_array().cloned().unwrap_or_default();
    let rows: Vec<TableRow> = entries
        .iter()
        .map(|row| {
            let action = row["action"].as_str().unwrap_or("");
            let suite = row["suite"].as_str().unwrap_or("");
            let new = row["new_suite"].as_str().filter(|s| !s.is_empty()).unwrap_or(suite);
            let hex = match action {
                "switch" => "#0F7B4F",
                "keep" => "#9A5B00",
                "unchanged" => "#6B7280",
                "missing" => "#B42318",
                _ => "#202020",
            };
            table_row(&[row["uri"].as_str().unwrap_or(""), suite, new, &t(&format!("os_action_{action}"))], hex)
        })
        .collect();
    let blocking = plan["blocking"].as_array().is_some_and(|b| !b.is_empty());
    app.set_os_note(ss(if plan.is_null() {
        t("failed")
    } else if blocking {
        t("os_blocked")
    } else {
        String::new()
    }));
    app.set_can_start_os(!entries.is_empty() && !blocking);
    app.set_os_plan(model(rows));
}

pub fn os_start() {
    let state = context().st.borrow().tools.os_state.clone();
    let target = state.get("target_codename").cloned().unwrap_or_default();
    let label = format!("{} \"{target}\"", data::major_of(state.get("target_version").map(String::as_str).unwrap_or("")));
    confirm(&t("os_title"), &tf("os_confirm", &[("target", &label)]), move || {
        start_queue(vec![task_cmd("os-upgrade", &[target], Task::OsUpgrade)], "task");
    });
}

// ------------------------------------------------------------ settings

fn notifier_override() -> std::path::PathBuf {
    data::home().join(".config/autostart/eduka-update-system-notifier.desktop")
}

fn notifier_enabled() -> bool {
    read_text(&notifier_override()).is_none_or(|text| !text.contains("Hidden=true"))
}

fn set_notifier_enabled(enabled: bool) {
    let path = notifier_override();
    let result = if enabled {
        match std::fs::remove_file(&path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    } else {
        path.parent().map(std::fs::create_dir_all).transpose().and_then(|_| std::fs::write(&path, "[Desktop Entry]\nHidden=true\n"))
    };
    if let Err(error) = result {
        info("EUS", &error.to_string());
    }
}

const AUTO_CHOICES: [&str; 3] = ["off", "security", "all"];

fn load_prefs() {
    let ctx = context();
    let app = ctx.ui.global::<App>();
    let schedule = data::read_schedule();
    let config = read_key_values(&data::config_file());
    let options: std::collections::BTreeMap<String, String> = [("AUTO_UPGRADE", "off"), ("AUTO_CLEAN", "1"), ("TIMESHIFT_SNAPSHOT", "0")]
        .iter()
        .map(|(key, default)| (key.to_string(), config.get(*key).cloned().unwrap_or_else(|| default.to_string())))
        .collect();
    app.set_pref_intervals(model(
        data::INTERVAL_CHOICES
            .iter()
            .map(|h| ss(if *h == 168 { t("st_week") } else { tf("hours", &[("hours", &h.to_string())]) }))
            .collect(),
    ));
    app.set_pref_interval(data::INTERVAL_CHOICES.iter().position(|h| *h == schedule.hours).unwrap_or(2) as i32);
    app.set_pref_daily(schedule.daily);
    app.set_pref_time(ss(&schedule.time));
    app.set_pref_auto_choices(model(AUTO_CHOICES.iter().map(|v| ss(t(&format!("st_auto_{v}")))).collect()));
    app.set_pref_auto(AUTO_CHOICES.iter().position(|v| options["AUTO_UPGRADE"] == *v).unwrap_or(0) as i32);
    app.set_pref_clean(options["AUTO_CLEAN"] == "1");
    app.set_has_timeshift(eus_core::util::which("timeshift"));
    app.set_pref_timeshift(options["TIMESHIFT_SNAPSHOT"] == "1");
    app.set_pref_notify(notifier_enabled());
    if let Ok(tab) = std::env::var("EUS_SETTINGS_TAB") {
        app.set_pref_tab(tab.parse().unwrap_or(0));
    }
    let until = data::paused_until();
    app.set_paused(until > 0);
    app.set_pause_status(ss(if until > 0 { tf("st_paused_until", &[("date", &data::format_date(until))]) } else { t("st_not_paused") }));
    let ignored = data::ignored_patterns();
    app.set_ignored(model(if ignored.is_empty() {
        vec![table_row(&[&t("st_ignored_none")], "#6B7280")]
    } else {
        ignored.iter().map(|p| table_row(&[p], "#202020")).collect()
    }));
    app.set_ignored_current(-1);
    let mut st = ctx.st.borrow_mut();
    st.tools.options = options;
    st.tools.schedule = Some(schedule);
    st.tools.ignored = ignored;
}

pub fn pause(days: i32) {
    start_queue(vec![task_cmd("pause", &[days.to_string()], Task::Pause)], "task");
}

pub fn unignore() {
    let ctx = context();
    let index = ctx.ui.global::<App>().get_ignored_current();
    let pattern = ctx.st.borrow().tools.ignored.get(index as usize).cloned();
    if let Some(pattern) = pattern {
        start_queue(vec![task_cmd("ignore", &["remove".into(), pattern], Task::Unignore)], "task");
    }
}

thread_local! {
    static PREFS_QUEUE: std::cell::RefCell<Vec<(String, Vec<String>)>> = const { std::cell::RefCell::new(Vec::new()) };
}

pub fn save_prefs() {
    let ctx = context();
    let app = ctx.ui.global::<App>();
    set_notifier_enabled(app.get_pref_notify());
    let (schedule, options) = {
        let st = ctx.st.borrow();
        (st.tools.schedule.clone().unwrap_or_else(data::read_schedule), st.tools.options.clone())
    };
    let mut queue: Vec<(String, Vec<String>)> = Vec::new();
    let new = if app.get_pref_daily() {
        let time = app.get_pref_time().trim().to_string();
        if !data::valid_time(&time) {
            info(&t("settings_title"), "HH:MM (00:00–23:59)");
            return;
        }
        ("daily".to_string(), time)
    } else {
        ("interval".to_string(), data::INTERVAL_CHOICES[app.get_pref_interval().clamp(0, 6) as usize].to_string())
    };
    let old = if schedule.daily { ("daily".to_string(), schedule.time.clone()) } else { ("interval".to_string(), schedule.hours.to_string()) };
    if new != old {
        queue.push(("set-schedule".into(), vec![new.0, new.1]));
    }
    let wanted = [
        ("AUTO_UPGRADE", AUTO_CHOICES[app.get_pref_auto().clamp(0, 2) as usize].to_string()),
        ("AUTO_CLEAN", if app.get_pref_clean() { "1" } else { "0" }.to_string()),
        ("TIMESHIFT_SNAPSHOT", if app.get_pref_timeshift() { "1" } else { "0" }.to_string()),
    ];
    for (key, value) in wanted {
        if options.get(key) != Some(&value) {
            queue.push(("set-option".into(), vec![key.into(), value]));
        }
    }
    queue.reverse();
    PREFS_QUEUE.with(|q| *q.borrow_mut() = queue);
    if !run_prefs_queue() {
        app::navigate("settings".into());
    }
}

/// Start the next settings change; false when nothing is left.
fn run_prefs_queue() -> bool {
    let Some((action, args)) = PREFS_QUEUE.with(|q| q.borrow_mut().pop()) else { return false };
    start_queue(vec![task_cmd(&action, &args, Task::SavePrefs)], "task");
    true
}

// ------------------------------------------------------------ history and log

fn render_history() {
    let entries = data::read_history();
    let text = if entries.is_empty() {
        t("no_history")
    } else {
        entries
            .iter()
            .map(|(time, success, name, installed, candidate)| {
                let (marker, status) = if *success { ("✓", t("history_success")) } else { ("✕", t("history_failed")) };
                format!("[{time}]\n{marker} {name} — {status}\n  {installed} → {candidate}")
            })
            .collect::<Vec<_>>()
            .join("\n\n")
    };
    context().ui.global::<App>().set_history_text(ss(text));
}

pub fn clear_history() {
    confirm(&t("clear_history"), &t("clear_history_confirm"), || {
        match std::fs::remove_file(data::history_file()) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => info("EUS", &t("failed")),
            _ => {
                render_history();
                info("EUS", &t("history_cleared"));
            }
        }
    });
}

fn load_log() {
    let text = read_text(&data::log_file()).unwrap_or_default();
    let lines: Vec<&str> = text.lines().collect();
    let tail = lines[lines.len().saturating_sub(1500)..].join("\n");
    context().ui.global::<App>().set_log_text(ss(if tail.is_empty() { "—".into() } else { tail }));
}
