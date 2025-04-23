use std::fs::File;
use std::io::{self, BufRead, BufReader};
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;

use async_std::process::Command;
use backoff::ExponentialBackoff;
use clap::Parser;
use futures::future::FutureExt;
use sd_notify::NotifyState;
use tracing::{error, info, trace};
use tracing_subscriber::filter::{EnvFilter, LevelFilter, Targets};
use tracing_subscriber::{fmt, prelude::*};

type Result<T, E = Box<dyn std::error::Error>> = core::result::Result<T, E>;

/// MESSENGER
#[derive(Parser)]
struct Cli {
    /// The path to the vault binary that will run an agent.
    #[clap(long)]
    vault_binary: PathBuf,

    /// The path to the vault agent's config.
    #[clap(long)]
    agent_config: PathBuf,

    /// The path to a file containing a list of files to wait to appear.
    #[clap(long)]
    files_to_monitor: PathBuf,

    /// The verbosity level of the logging.
    #[clap(long, short, action = clap::ArgAction::Count)]
    verbosity: u8,
}

#[async_std::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let crate_filter = Targets::default().with_target(env!("CARGO_PKG_NAME"), LevelFilter::TRACE);
    let env_filter = EnvFilter::builder()
        .with_default_directive(
            match cli.verbosity {
                0 => LevelFilter::WARN,
                1 => LevelFilter::INFO,
                2 => LevelFilter::DEBUG,
                _ => LevelFilter::TRACE,
            }
            .into(),
        )
        .from_env_lossy();

    tracing_subscriber::registry()
        .with(fmt::layer())
        .with(env_filter)
        .with(crate_filter)
        .try_init()?;

    let mut command = Command::new(cli.vault_binary);
    command.arg("agent");
    command.arg("-config");
    command.arg(cli.agent_config);

    trace!(?command, "spawning vault agent");
    match command.spawn() {
        Ok(mut child) => {
            let files: Vec<PathBuf> = self::get_files_to_monitor(cli.files_to_monitor)?;

            // TODO: maybe make the agent run something that will signal the messenger that the files exist, instead of waiting for them:
            // Something to consider is the agent could run something to signal messenger instead of waiting for the files to exist.
            // Then the messenger could restart etc. the target services only if it has finished startup.
            let backoff = self::backoff_until_files_exist(files).fuse();
            let status = child.status().fuse();

            futures::pin_mut!(backoff, status);

            loop {
                futures::select! {
                    backoff = backoff => {
                        if let Err(err) = backoff {
                            error!(%err, "backoff failed");
                            let _ = child.kill();
                            std::process::exit(1);
                        }
                    },
                    status = status => {
                        let status = status?;
                        let mut status_msg = String::from("vault agent exited");

                        let errno = if let Some(errno) = status.code() {
                            status_msg.push_str(&format!(" with code {}", errno));
                            errno
                        } else if let Some(signal) = status.signal() {
                            status_msg.push_str(&format!(" with signal {}", signal));
                            signal
                        } else {
                            status_msg.push_str(" with unknown cause (not exit code or signal)");
                            1
                        };

                        error!(%status_msg);
                        sd_notify::notify(false, &[NotifyState::Status(&status_msg)])?;
                        std::process::exit(errno);
                    },
                    complete => break,
                };
            }
        }
        Err(err) => {
            error!(?command, "failed to spawn vault agent");
            error!(%err);
            sd_notify::notify(false, &[NotifyState::Status("failed to spawn vault agent")])?;
            std::process::exit(1);
        }
    }

    Ok(())
}

/// Reads the file at `path` and constructs a `Vec<PathBuf>` from the files
/// listed on each line.
fn get_files_to_monitor(path: PathBuf) -> Result<Vec<PathBuf>> {
    info!("reading {} to find files to monitor", path.display());
    let atlas = File::open(path)?;
    let reader = BufReader::new(atlas);
    let mut files = Vec::new();

    for line in reader.lines() {
        let line = match line {
            Ok(line) if !line.is_empty() => line,
            Ok(_) => continue,
            Err(err) => {
                error!("while reading line: {:?}", err);
                continue;
            }
        };

        trace!("adding {} to list of files to monitor", line);
        let file = PathBuf::from(line);
        files.push(file);
    }

    Ok(files)
}

/// Checks if the files specified by the input `&Vec<PathBuf>` exist and returns
/// a `Vec<PathBuf>` of files that don't.
fn check_if_files_exist(files: &[PathBuf]) -> Vec<PathBuf> {
    let mut not_exists = Vec::new();

    for path in files {
        trace!("checking if {} exists", path.display());

        if path.exists() {
            trace!("{} exists", path.display());
        } else {
            trace!("{} does not exist", path.display());
            not_exists.push(path.clone());
        }
    }

    not_exists
}

/// Uses [`backoff::ExponentialBackoff`] to wait for all listed files to exist,
/// up to a maximum of 15 minutes. Uses [`sd_notify::notify`] to inform systemd
/// if the files existed before the backoff hit its maximum.
async fn backoff_until_files_exist(paths: Vec<PathBuf>) -> async_std::io::Result<()> {
    info!("waiting for all files to exist");

    async fn backoff_waiter(not_exists: Vec<PathBuf>) -> Result<(), backoff::Error<&'static str>> {
        let not_exists = self::check_if_files_exist(&not_exists);

        if not_exists.is_empty() {
            info!("all files exist");
            Ok(())
        } else {
            info!("still waiting for some files to exist: {:?}", not_exists);
            Err(backoff::Error::transient(
                "still waiting for some files to exist",
            ))
        }
    }

    let backoff_notify = |err, dur| {
        let _ = err;
        info!("backing off for {:?}", dur);
    };

    // Backs off to a maximum interval of 1 minute, and a maximum elapsed time of 15 minutes.
    let backoff = ExponentialBackoff::default();
    let ret =
        backoff::future::retry_notify(backoff, || backoff_waiter(paths.clone()), backoff_notify)
            .await
            .map_err(|_| {
                io::Error::new(
                    io::ErrorKind::Other,
                    "files did not exist in a timely fashion",
                )
            });

    if ret.is_ok() {
        trace!("backoff succeeded, notifying systemd we're ready");
        sd_notify::notify(false, &[NotifyState::Ready])?;
    }

    ret
}

#[cfg(test)]
mod tests {
    use tracing_test::traced_test;

    #[test]
    #[traced_test]
    fn test_check_if_files_exist() {
        let temp_dir = tempfile::tempdir().unwrap();
        let files = vec![
            temp_dir.path().join("file1"),
            temp_dir.path().join("file2"),
            temp_dir.path().join("file3"),
        ];

        let not_exist = super::check_if_files_exist(&files);
        assert_eq!(files, not_exist);

        for file in &files {
            std::fs::File::create(file).unwrap();
        }

        let not_exist = super::check_if_files_exist(&files);
        assert!(not_exist.is_empty());
    }

    #[test]
    #[traced_test]
    fn test_backoff_until_files_exist() {
        let temp_dir = tempfile::tempdir().unwrap();
        let files = vec![
            temp_dir.path().join("file1"),
            temp_dir.path().join("file2"),
            temp_dir.path().join("file3"),
        ];

        let backoff_files = files.clone();
        let backoff_handle =
            async_std::task::spawn(super::backoff_until_files_exist(backoff_files));

        // Wait for 50ms so that the backoff functionality has time to see that
        // the files don't exist and wait at least once.
        std::thread::sleep(std::time::Duration::from_millis(50));

        for file in &files {
            std::fs::File::create(file).unwrap();
        }

        assert!(async_std::task::block_on(backoff_handle).is_ok());
    }
}
