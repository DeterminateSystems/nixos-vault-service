use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::Command;

use backoff::ExponentialBackoff;
use clap::{AppSettings, Parser};
use sd_notify::NotifyState;
use tracing::{error, info, trace};
use tracing_subscriber::filter::{EnvFilter, LevelFilter};
use tracing_subscriber::{fmt, prelude::*};

type Result<T, E = Box<dyn std::error::Error>> = core::result::Result<T, E>;

/// MESSENGER
#[derive(Parser)]
#[clap(global_setting(AppSettings::DeriveDisplayOrder))]
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
    #[clap(long, short, parse(from_occurrences))]
    verbosity: usize,
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    let filter_layer = EnvFilter::builder()
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
        .with(filter_layer)
        .try_init()?;

    let mut command = Command::new(cli.vault_binary);
    command.arg("agent");
    command.arg("-config");
    command.arg(cli.agent_config);

    match command.spawn() {
        Ok(mut child) => {
            let files: Vec<PathBuf> = self::get_files_to_monitor(cli.files_to_monitor)?;

            // TODO: maybe make the agent run something that will signal the messenger that the files exist, instead of waiting for them:
            // Something to consider is the agent could run something to signal messenger instead of waiting for the files to exist.
            // Then the messenger could restart etc. the target services only if it has finished startup.
            self::backoff_until_files_exist(files)?;

            sd_notify::notify(false, &[NotifyState::Ready])?;

            let status = child.wait()?;
            if let Some(errno) = status.code() {
                sd_notify::notify(false, &[NotifyState::Errno(errno.try_into()?)])?;
                std::process::exit(errno);
            }
        }
        Err(err) => {
            error!("failed to spawn vault agent with args: {:?}", command);
            error!("{:?}", err);
            sd_notify::notify(false, &[NotifyState::Errno(1)])?;
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
/// up to a maximum of 15 minutes.
fn backoff_until_files_exist(paths: Vec<PathBuf>) -> Result<()> {
    info!("waiting for all files to exist");
    let mut not_exists = paths;

    let backoff_waiter = || -> Result<(), backoff::Error<&str>> {
        not_exists = self::check_if_files_exist(&not_exists);

        if not_exists.is_empty() {
            info!("all files exist");
            Ok(())
        } else {
            info!("still waiting for some files to exist: {:?}", not_exists);
            Err(backoff::Error::transient(
                "still waiting for some files to exist",
            ))
        }
    };

    let backoff_notify = |err, dur| {
        let _ = err;
        info!("backing off for {:?}", dur);
    };

    // Backs off to a maximum interval of 1 minute, and a maximum elapsed time of 15 minutes.
    let backoff = ExponentialBackoff::default();
    backoff::retry_notify(backoff, backoff_waiter, backoff_notify)
        .map_err(|_| "files did not exist in a timely fashion".into())
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
        let backoff_thread = std::thread::spawn(|| {
            assert!(super::backoff_until_files_exist(backoff_files).is_ok());
        });

        // Wait for 50ms so that the backoff functionality has time to see that
        // the files don't exist and wait at least once.
        std::thread::sleep(std::time::Duration::from_millis(50));

        for file in &files {
            std::fs::File::create(file).unwrap();
        }

        assert!(backoff_thread.join().is_ok());
    }
}
