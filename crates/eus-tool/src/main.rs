//! eduka-update-system-tool: repositories, keys, releases, kernels, cleaner
//! and System Health for the EUS backend, GUI and terminal.
//!
//! Exit codes: 0 success, 1 `--check` found nothing, 2 a user-facing error
//! (printed on stderr), 3 a timeout or a blocked upgrade plan.

use anyhow::{bail, Result};
use clap::{Parser, Subcommand, ValueEnum};
use eus_core::{apt, cleaner, health, i18n, kernels, keys, release, repos, sources, util};
use serde::Serialize;
use serde_json::Value;
use std::process::ExitCode;

#[derive(Parser)]
#[command(name = "eduka-update-system-tool", version, about = "Eduka-Update-System maintenance helper")]
struct Cli {
    /// Language of progress messages (en, id, pt, tet).
    #[arg(long, default_value = "en", global = true)]
    lang: String,
    #[command(subcommand)]
    command: Command,
}

#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
enum KernelFormat { Json, Text, Old }

#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
enum PlanFormat { Json, Text }

#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
enum HealthFormat { Json, Text, Fixes }

#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
enum Scope { All, System, User }

#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
enum Mode { Install, Remove }

#[derive(clap::Args)]
struct RepoArgs {
    #[arg(long)]
    name: String,
    #[arg(long)]
    repo_uri: Option<String>,
    #[arg(long)]
    suite: Option<String>,
    #[arg(long)]
    components: Option<String>,
    #[arg(long)]
    arch: Option<String>,
    #[arg(long)]
    with_source: bool,
}

#[derive(Subcommand)]
enum Command {
    /// Source files, duplicates and APT problems (JSON).
    ScanRepos,
    /// Keyrings, their roles and problems (JSON).
    ScanKeys,
    /// Problems in the last `apt-get update` output.
    AptProblems {
        /// Exit 0 when key or repository-definition problems exist, else 1.
        #[arg(long)]
        check: bool,
        /// With --check: only missing, expired or unsigned keys count.
        #[arg(long)]
        keys_only: bool,
    },
    /// Describe the public keys in a file.
    ShowKey { file: String },
    FixDuplicates,
    FixKeys,
    AddKey {
        #[command(flatten)]
        repo: RepoArgs,
        #[arg(long)]
        file: Option<String>,
        #[arg(long)]
        url: Option<String>,
        #[arg(long)]
        keyserver: Option<String>,
    },
    AddRepo {
        #[command(flatten)]
        repo: RepoArgs,
        #[arg(long)]
        line: Option<String>,
        #[arg(long)]
        auto_key: bool,
    },
    /// Every source entry with role, release and status (JSON).
    Repositories,
    /// Where the key of the repository serving URL belongs (JSON).
    KeyTarget { url: String, keyid: String },
    Kernels {
        #[arg(long, value_enum, default_value = "json")]
        format: KernelFormat,
    },
    KernelPlan {
        #[arg(value_enum)]
        mode: Mode,
        #[arg(required = true)]
        items: Vec<String>,
        #[arg(long)]
        headers: bool,
    },
    OsCheck,
    OsPlan {
        #[arg(long, default_value = "")]
        target: String,
        #[arg(long, value_enum, default_value = "json")]
        format: PlanFormat,
    },
    OsSwitch { target: String },
    OsRestore { backup: String },
    ContinuousStable {
        #[arg(long)]
        apply: bool,
    },
    ScanClean {
        #[arg(long, value_enum, default_value = "all")]
        scope: Scope,
        #[arg(long, value_enum, default_value = "json")]
        format: PlanFormat,
    },
    CleanUser {
        #[arg(required = true)]
        items: Vec<String>,
    },
    CleanSystem {
        #[arg(required = true)]
        items: Vec<String>,
    },
    Health {
        /// Skip verifying core package files.
        #[arg(long)]
        quick: bool,
        /// Also store the result for the notifier.
        #[arg(long)]
        save: bool,
        #[arg(long, value_enum, default_value = "json")]
        format: HealthFormat,
    },
    /// The saved health result for notifications: problem ids, first title.
    HealthSummary,
    HealthFix {
        #[arg(required = true)]
        items: Vec<String>,
    },
    Changelog {
        package: String,
        #[arg(default_value = "")]
        installed: String,
    },
}

/// JSON with one-space indentation, like the earlier releases printed.
fn print_json<T: Serialize>(value: &T) -> Result<()> {
    let mut buffer = Vec::new();
    let formatter = serde_json::ser::PrettyFormatter::with_indent(b" ");
    let mut serializer = serde_json::Serializer::with_formatter(&mut buffer, formatter);
    value.serialize(&mut serializer)?;
    println!("{}", String::from_utf8_lossy(&buffer));
    Ok(())
}

fn repo_spec(repo: RepoArgs) -> keys::RepoSpec {
    keys::RepoSpec {
        name: repo.name, repo_uri: repo.repo_uri, suite: repo.suite, components: repo.components, arch: repo.arch,
        with_source: repo.with_source, ..Default::default()
    }
}

fn kernel_label(state: &str) -> &str {
    match state {
        "running" => "RUNNING (in use)",
        "old" => "OLD KERNEL - safe to remove",
        "newer" => "NEW - restart to use",
        "residual" => "leftover configuration",
        other => other,
    }
}

fn execute(command: Command) -> Result<u8> {
    match command {
        Command::ScanRepos => {
            let entries = sources::all_entries();
            let files: Vec<String> = sources::source_files().iter().map(|p| p.to_string_lossy().to_string()).collect();
            print_json(&serde_json::json!({"files": files, "entries": entries.len(),
                                           "duplicates": sources::find_duplicates(&entries),
                                           "apt": apt::apt_problems(None)}))?;
        }
        Command::ScanKeys => print_json(&keys::scan_keys())?,
        Command::AptProblems { check, keys_only } => {
            let found = apt::apt_problems(None);
            if check {
                return Ok(if found.has_repairable(keys_only) { 0 } else { 1 });
            }
            print_json(&found)?;
        }
        Command::ShowKey { file } => {
            let path = std::path::absolute(&file)?;
            print_json(&keys::describe_keys(&keys::read_key_file(&path.to_string_lossy())?)?)?;
        }
        Command::FixDuplicates => util::write_report("fix-duplicates", sources::fix_duplicates()?),
        Command::FixKeys => util::write_report("fix-keys", keys::fix_keys()?),
        Command::AddKey { repo, file, url, keyserver } => {
            let spec = keys::RepoSpec { file, url, keyserver, ..repo_spec(repo) };
            util::write_report("add-key", keys::add_key(&spec)?);
        }
        Command::AddRepo { repo, line, auto_key } => {
            let spec = keys::RepoSpec { line, auto_key, ..repo_spec(repo) };
            util::write_report("add-repo", keys::add_repo(&spec)?);
        }
        Command::Repositories => print_json(&repos::describe_repositories())?,
        Command::KeyTarget { url, keyid } => {
            let entries = keys::entries_for_url(&url);
            print_json(&keys::key_target(entries.first(), &keyid.to_uppercase()))?;
        }
        Command::Kernels { format } => {
            let data = kernels::list_kernels(format != KernelFormat::Old);
            match format {
                KernelFormat::Old => {
                    let old: Vec<&str> = data.installed.iter()
                        .filter(|k| k.state == "old" || k.state == "residual").map(|k| k.release.as_str()).collect();
                    println!("{}", old.join("\n"));
                }
                KernelFormat::Text => {
                    println!("Running kernel: {}", data.running);
                    for kernel in &data.installed {
                        println!("  {:<36} {}", kernel.release, kernel_label(&kernel.state));
                    }
                    if !data.available.is_empty() {
                        println!("Installable kernels:");
                        for kernel in &data.available {
                            println!("  {:<42} {}", kernel.package, kernel.version);
                        }
                    }
                }
                KernelFormat::Json => print_json(&data)?,
            }
        }
        Command::KernelPlan { mode, items, headers } => {
            let mode = if mode == Mode::Install { "install" } else { "remove" };
            println!("{}", kernels::kernel_plan(mode, &items, headers)?.join("\n"));
        }
        Command::OsCheck => print_json(&release::check_os_upgrade()?)?,
        Command::OsPlan { mut target, format } => {
            if target.is_empty() {
                target = util::read_key_values(&util::os_upgrade_file()).get("target_codename").cloned().unwrap_or_default();
            }
            if target.is_empty() {
                target = release::check_os_upgrade()?.get("target_codename").and_then(Value::as_str).unwrap_or("").to_string();
            }
            if target.is_empty() {
                bail!("The new release could not be determined.");
            }
            let plan = release::os_upgrade_plan(&target)?;
            if format == PlanFormat::Text {
                for row in &plan.entries {
                    let new = if row.new_suite.is_empty() { &row.suite } else { &row.new_suite };
                    let note = if row.note.is_empty() { String::new() } else { format!("  ({})", row.note) };
                    println!("  {:<9} {} {} -> {new}{note}", row.action, row.uri, row.suite);
                }
                if !plan.blocking.is_empty() {
                    println!("\nThe upgrade is blocked until every distribution repository offers the new release.");
                    return Ok(3);
                }
            } else {
                print_json(&plan)?;
            }
        }
        Command::OsSwitch { target } => println!("{}", release::os_switch(&target)?),
        Command::OsRestore { backup } => release::os_restore(&backup)?,
        Command::ContinuousStable { apply } => {
            if apply {
                print_json(&release::apply_continuous_stable()?)?;
            } else {
                print_json(&release::continuous_stable_plan())?;
            }
        }
        Command::ScanClean { scope, format } => {
            let mut found = Vec::new();
            if scope != Scope::User {
                found.extend(cleaner::scan_system());
            }
            if scope != Scope::System {
                found.extend(cleaner::scan_user());
            }
            if format == PlanFormat::Text {
                for item in &found {
                    println!("  {:<11} {:>8.1} MB  {}", item.id, item.size as f64 / 1048576.0, item.title);
                }
            } else {
                print_json(&found)?;
            }
        }
        Command::CleanUser { items } => print_json(&cleaner::clean_user(&items)?)?,
        Command::CleanSystem { items } => util::write_report("clean-system", cleaner::clean_system(&items)?),
        Command::Health { quick, save, format } => {
            let data = health::scan_health(!quick);
            if save {
                health::save_health(&data);
            }
            match format {
                HealthFormat::Json => print_json(&data)?,
                HealthFormat::Fixes => {
                    for finding in data.findings.iter().filter(|f| !f.fix.is_empty()) {
                        println!("{}", finding.fix);
                    }
                }
                HealthFormat::Text => {
                    for finding in data.findings.iter().chain(data.recommendations.iter()) {
                        let fix = if finding.fix.is_empty() { String::new() } else { format!(" -> fix: {}", finding.fix) };
                        println!("[{:<9}] {}{fix}", finding.severity, finding.title);
                        if !finding.detail.is_empty() {
                            println!("            {}", finding.detail);
                        }
                    }
                    if data.findings.is_empty() {
                        println!("No problem found.");
                    }
                }
            }
        }
        Command::HealthSummary => {
            let data = health::load_health().unwrap_or_default();
            let serious: Vec<&health::Finding> =
                data.findings.iter().filter(|f| f.severity == "critical" || f.severity == "warning").collect();
            let mut ids: Vec<&str> = serious.iter().map(|f| f.id.as_str()).collect();
            ids.sort();
            println!("{}", ids.join("|"));
            println!("{}", serious.first().map(|f| f.title.as_str()).unwrap_or(""));
        }
        Command::HealthFix { items } => {
            if let Some(bad) = items.iter().find(|i| !health::is_health_fix(i)) {
                bail!("Unknown fix: {bad}");
            }
            util::write_report("health-fix", health::fix_health(&items)?);
        }
        Command::Changelog { package, installed } => println!("{}", cleaner::changelog(&package, &installed, 400)?),
    }
    Ok(0)
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    i18n::set_lang(&cli.lang);
    match execute(cli.command) {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            let text = error.to_string();
            eprintln!("{text}");
            ExitCode::from(if text.starts_with("A system command timed out") { 3 } else { 2 })
        }
    }
}
