use std::{env, fs::OpenOptions, io::Write, process::{Command, exit}};
fn main() {
    let tool = env::var("HELIOS_HOST_RUST_SCRIPT").expect("explicit host rust-script required");
    let version = Command::new(&tool).arg("--version").output().expect("host version read");
    let text = String::from_utf8_lossy(&version.stdout).trim().to_owned();
    if !version.status.success() || text != "rust-script 0.36.0" {
        eprintln!("HOST_RUST_SCRIPT_CONTRACT_FAIL path={tool:?} version={text:?}"); exit(92);
    }
    let args: Vec<_> = env::args_os().skip(1).collect();
    let task = env::var("CARGO_MAKE_CURRENT_TASK_NAME").unwrap_or_else(|_| "load-or-condition".into());
    let line = format!("HOST_RUST_SCRIPT_EXEC path={tool:?} version={text:?} task={task:?} args={args:?}\n");
    let log = env::var("HELIOS_RUST_SCRIPT_AUDIT").expect("audit path required");
    OpenOptions::new().create(true).append(true).open(log).expect("audit open")
        .write_all(line.as_bytes()).expect("audit append");
    eprint!("{line}");
    let status = Command::new(&tool).args(args).status().expect("host rust-script execution");
    exit(status.code().unwrap_or(93));
}
