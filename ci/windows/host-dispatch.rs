use std::{env, fs::OpenOptions, io::Write, process::Command};
fn json_string(value: &str) -> String {
    let mut escaped = String::new();
    for ch in value.chars() {
        match ch {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            c if c <= '\u{001f}' => escaped.push_str(&format!("\\u{:04x}", c as u32)),
            c => escaped.push(c),
        }
    }
    format!("\"{escaped}\"")
}
fn main() {
    let tool = env::var("HELIOS_HOST_RUST_SCRIPT").expect("explicit host rust-script required");
    let version = Command::new(&tool).arg("--version").output().expect("host version read");
    let text = String::from_utf8_lossy(&version.stdout).trim().to_owned();
    if !version.status.success() || text != "rust-script 0.36.0" {
        let invocation = env::var("HELIOS_PRODUCER_INVOCATION").expect("producer invocation required");
        let profile = env::var("HELIOS_PRODUCER_PROFILE").expect("producer profile required");
        let dispatcher = env::current_exe().expect("selected dispatcher path required");
        let log = env::var("HELIOS_RUST_SCRIPT_AUDIT").expect("audit path required");
        let line = format!("{{\"event\":\"host-helper-rejected\",\"invocation\":{},\"profile\":{},\"version\":{},\"executable\":{},\"dispatcher\":{},\"exitCode\":92}}\n",
            json_string(&invocation), json_string(&profile), json_string(&text), json_string(&tool),
            json_string(&dispatcher.to_string_lossy()));
        OpenOptions::new().create(true).append(true).open(log).expect("audit open")
            .write_all(line.as_bytes()).expect("audit append");
        eprintln!("HOST_RUST_SCRIPT_CONTRACT_FAIL path={tool:?} version={text:?}");
        std::process::exit(92);
    }
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.len() == 1 && args[0] == "--version" {
        print!("{text}\n");
        std::process::exit(0);
    }
    let task = env::var("CARGO_MAKE_CURRENT_TASK_NAME").expect("cargo-make task identity required");
    let invocation = env::var("HELIOS_PRODUCER_INVOCATION").expect("producer invocation required");
    let profile = env::var("HELIOS_PRODUCER_PROFILE").expect("producer profile required");
    let dispatcher = env::current_exe().expect("selected dispatcher path required");
    let args_json = format!("[{}]", args.iter().map(|arg| json_string(&arg.to_string_lossy())).collect::<Vec<_>>().join(","));
    let log = env::var("HELIOS_RUST_SCRIPT_AUDIT").expect("audit path required");
    let status = Command::new(&tool).args(&args).status();
    let (exit_code, launch_error) = match status {
        Ok(status) => (status.code().unwrap_or(93), String::new()),
        Err(error) => (94, error.to_string()),
    };
    let line = format!("{{\"event\":\"host-run\",\"invocation\":{},\"profile\":{},\"task\":{},\"version\":{},\"executable\":{},\"dispatcher\":{},\"args\":{},\"exitCode\":{},\"launchError\":{}}}\n",
        json_string(&invocation), json_string(&profile), json_string(&task), json_string(&text),
        json_string(&tool), json_string(&dispatcher.to_string_lossy()), args_json, exit_code,
        json_string(&launch_error));
    OpenOptions::new().create(true).append(true).open(log).expect("audit open")
        .write_all(line.as_bytes()).expect("audit append");
    eprint!("{line}");
    std::process::exit(exit_code);
}
