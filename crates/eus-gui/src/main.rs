//! Eduka-Update-System graphical update manager.
//!
//! Usage: eduka-update-system-gui [--open PAGE] [--screenshot FILE.png]
//!        eduka-update-system-gui --self-test UPDATES.tsv

mod app;
mod data;
mod i18n;
mod instance;
mod runner;
mod tools;

slint::include_modules!();

use app::{Ctx, State};
use slint::ComponentHandle;
use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

/// Parser check used by the test suite: category counts of an updates.tsv.
fn self_test(path: &str) -> i32 {
    let records = data::parse_updates(std::path::Path::new(path));
    let mut result = serde_json::Map::new();
    result.insert("total".into(), records.len().into());
    result.insert("bytes".into(), records.iter().map(|r| r.size).sum::<u64>().into());
    for category in ["critical", "kernel", "medium", "normal", "flatpak"] {
        result.insert(category.into(), records.iter().filter(|r| r.category == category).count().into());
    }
    let groups: std::collections::BTreeSet<(String, String)> = records.iter().map(|r| (r.source.clone(), r.srcpkg.clone())).collect();
    result.insert("groups".into(), groups.len().into());
    println!("{}", serde_json::Value::Object(result));
    0
}

fn save_png(path: &str, buffer: &slint::SharedPixelBuffer<slint::Rgba8Pixel>) -> std::io::Result<()> {
    let file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let mut encoder = png::Encoder::new(file, buffer.width(), buffer.height());
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(std::io::Error::other)?;
    writer.write_image_data(buffer.as_bytes()).map_err(std::io::Error::other)?;
    Ok(())
}

fn wire(ui: &MainWindow) {
    ui.global::<Tr>().on_t(|key| app::ss(i18n::t(&key)));
    let a = ui.global::<App>();
    a.on_navigate(|page| app::navigate(page.to_string()));
    a.on_reboot(app::confirm_reboot);
    a.on_banner(|kind| app::banner(kind.to_string()));
    a.on_msg_clicked(|id| app::msg_clicked(id.to_string()));
    a.on_check_updates(app::check_updates);
    a.on_install(app::install_updates);
    a.on_toggle_update(app::toggle_update);
    a.on_select_all(|checked| app::set_checked(|_, _| checked));
    a.on_select_security(|| app::set_checked(|_, g| g.category == "critical" || g.category == "kernel"));
    a.on_select_category(|index| {
        let category = app::context().st.borrow().groups.get(index as usize).map(|g| g.category.clone());
        if let Some(category) = category {
            app::set_checked(move |_, g| g.category == category);
        }
    });
    a.on_ignore(app::ignore_group);
    a.on_current_changed(app::show_description);
    a.on_details_changed(|_| app::load_changelog());
    a.on_scan_health(|| app::scan_health(true));
    a.on_fix_health(app::fix_health);
    a.on_toggle_health(app::toggle_health);
    a.on_open_health(app::open_health);
    a.on_clean_scan(tools::clean_scan);
    a.on_clean_toggle(tools::clean_toggle);
    a.on_clean_run(tools::clean_run);
    a.on_kernel_refresh(tools::kernel_refresh);
    a.on_kernel_toggle(tools::kernel_toggle);
    a.on_kernel_remove(tools::kernel_remove);
    a.on_kernel_remove_old(tools::kernel_remove_old);
    a.on_kernel_install(tools::kernel_install);
    a.on_keyfix_scan(tools::keyfix_scan);
    a.on_fix_keys(tools::fix_keys);
    a.on_fix_duplicates(tools::fix_duplicates);
    a.on_ar_line_edited(|line| tools::ar_line_edited(line.to_string()));
    a.on_ar_submit(tools::ar_submit);
    a.on_ak_changed(tools::ak_changed);
    a.on_ak_inspect(tools::ak_inspect);
    a.on_ak_browse(tools::ak_browse);
    a.on_ak_submit(tools::ak_submit);
    a.on_os_start(tools::os_start);
    a.on_pause(tools::pause);
    a.on_unignore(tools::unignore);
    a.on_save_prefs(tools::save_prefs);
    a.on_clear_history(tools::clear_history);
    ui.window().on_close_requested(|| {
        if app::request_close() { slint::CloseRequestResponse::HideWindow } else { slint::CloseRequestResponse::KeepWindowShown }
    });
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() >= 2 && args[0] == "--self-test" {
        std::process::exit(self_test(&args[1]));
    }
    if args.iter().any(|a| a == "--version") {
        println!("Eduka-Update-System {}", data::version());
        return;
    }
    let mut take = |flag: &str| -> String {
        match args.iter().position(|a| a == flag) {
            Some(index) if index + 1 < args.len() => {
                let value = args.remove(index + 1);
                args.remove(index);
                value
            }
            _ => String::new(),
        }
    };
    let page = take("--open");
    let screenshot = take("--screenshot");

    // SAFETY: setlocale is called once, before any thread starts.
    unsafe {
        libc::setlocale(libc::LC_TIME, c"".as_ptr());
    }
    if screenshot.is_empty() && instance::request_existing(&page) {
        return;
    }

    let ui = match MainWindow::new() {
        Ok(ui) => ui,
        Err(error) => {
            eprintln!("EUS could not open its window: {error}");
            std::process::exit(70);
        }
    };
    let ctx = Rc::new(Ctx {
        ui: ui.clone_strong(),
        st: RefCell::new(State::default()),
        timeout: slint::Timer::default(),
        animation: slint::Timer::default(),
        watcher: slint::Timer::default(),
    });
    app::install(ctx.clone());
    wire(&ui);
    ui.global::<App>().set_version(app::ss(data::version()));

    if screenshot.is_empty() {
        if let Err(error) = instance::listen(|page| {
            let ui = app::ui();
            let _ = ui.show();
            if !page.is_empty() {
                app::navigate(page);
            }
        }) {
            eprintln!("EUS could not create its single-instance socket: {error}");
        }
    }

    app::load_updates();
    app::refresh_banners();
    app::load_saved_health();
    if ctx.st.borrow().health.is_null() {
        app::scan_health(false);
    }
    ctx.watcher.start(slint::TimerMode::Repeated, Duration::from_secs(2), app::watch_files);
    app::watch_files();

    if !page.is_empty() {
        let page = page.clone();
        slint::Timer::single_shot(Duration::from_millis(0), move || app::navigate(page));
    }
    if !screenshot.is_empty() {
        let delay = std::env::var("EUS_SCREENSHOT_DELAY").ok().and_then(|v| v.parse().ok()).unwrap_or(1500);
        slint::Timer::single_shot(Duration::from_millis(delay), move || {
            let ui = app::ui();
            match ui.window().take_snapshot() {
                Ok(buffer) => {
                    if let Err(error) = save_png(&screenshot, &buffer) {
                        eprintln!("{screenshot}: {error}");
                    }
                }
                Err(error) => eprintln!("snapshot: {error}"),
            }
            let _ = slint::quit_event_loop();
        });
    }
    if let Err(error) = ui.run() {
        eprintln!("EUS: {error}");
    }
    instance::cleanup();
}
