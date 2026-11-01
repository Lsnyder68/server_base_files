# Script Documentation: `install_base_apps.sh`

## Overview
This bash script is designed to automate the installation of a set of base applications on Linux systems. It supports systems using `apt` (Debian/Ubuntu), `apk` (Alpine), `dnf` (Fedora/RHEL), `pacman` (Arch Linux), and `zypper` (openSUSE). The script ensures necessary tools are available, handles installation errors gracefully, and provides a summary of actions taken.

## Prerequisites
- **Root Privileges**: Required for real installs (run with `sudo`). The script checks this at startup and exits if not root. `--dry-run` is exempt and can be run as a normal user, though some package-manager queries are more reliable as root.
- **Supported Package Manager**: The system must have one of the following installed: `apt-get`, `dnf`, `pacman`, `zypper`, or `apk`.

## Usage

The script is not marked executable in the repository, so invoke it with `bash` (or run `chmod +x install_base_apps.sh` once):

### Normal (interactive) run
```bash
cd /path/to/server_base_files
sudo bash install_base_apps.sh
```
This installs everything, prints the summary, then asks whether to back up and install the bundled `.bashrc`.

### Non-interactive run
When stdin is not a terminal, the `.bashrc` prompt is skipped automatically and the script exits normally without touching `~/.bashrc`:
```bash
sudo bash install_base_apps.sh </dev/null
```
To apply the bundled `.bashrc` without prompting:
```bash
sudo bash install_base_apps.sh --yes
```

### Detached run
To survive an SSH disconnect or terminal job-control signal, run it in the background:
```bash
sudo nohup bash install_base_apps.sh --yes > /tmp/install_base_apps.out 2>&1 &
wait $!
cat /tmp/install_base_apps.out
```
`wait` returns when the script finishes. With GNU `tail`, `tail --pid=$! -f /tmp/install_base_apps.out` also exits with the job. Do not use a bare `tail -f` and expect it to stop — it follows the file forever.

### Dry run
```bash
sudo bash install_base_apps.sh --dry-run
```
Makes no changes: no installs, no `.bashrc` backup, no log file writes.

## Workflow

1.  **Initialization**:
    - Initializes arrays to track installation results: `already_installed`, `newly_installed`, `failed_apps`, and `failed_reasons`.
    - Checks root privileges (skipped for `--dry-run`), acquires the concurrency lock, and probes network connectivity.
    - Detects the package manager (`apt`, `dnf`, `pacman`, `zypper`, or `apk`) and sets the `PKG_MANAGER` variable, then checks for an in-use `dpkg` lock on `apt` systems.

2.  **Helper Functions**:
    - `is_installed`: Checks if an application is already present on the system using `command -v` or manager-specific commands (`dpkg-query`, `dnf list`, `pacman -Qi`, `zypper search`, `apk info`). `dpkg-query` is used instead of piping `dpkg -l` so `pipefail` cannot turn a successful match into a failure.
    - `handle_installation`: Executes the installation command under a timeout, captures stderr to a temporary log, verifies the package is actually installed afterward, and updates the status arrays based on success or failure.
    - `install_app`: High-level function that checks if an app is installed and, if not, calls `handle_installation` with the appropriate command for the detected package manager.
    - `record_failure`, `failure_hint`: Record failures with the exit code and attach package-specific remediation hints.

3.  **Package List Update**:
    - Runs the appropriate update command: `apt-get update`, `dnf check-update`, `pacman -Sy --noconfirm`, `zypper refresh`, or `apk update`.
    - The result is checked. `dnf` exit code 100 ("updates available") is treated as success. If the update fails while the network check also failed, the script aborts; otherwise it warns and continues with cached metadata.

4.  **Standard Application Installation**:
    - Iterates through a predefined list of applications and installs them using `install_app`.
    - **Common Apps**: `nano`, `git`, `curl`, `wget`, `htop`, `tmux`, `zoxide`, `duf`, `tree`, `neomutt`, `bat`, `eza`.
    - **Differences**: `fd-find` is used for `apt` and `dnf`, while `fd` is used for `pacman`, `zypper`, and `apk`.

5.  **Manual Installations**:
    - **mcfly**: Downloads the pinned installer script from GitHub (`MCFLY_VERSION`) to a temporary file before running it, so a failed download cannot be mistaken for a successful install. The installer is checksum-verified when `MCFLY_INSTALL_SHA256` is set.
    - **nala**: (Only for `apt` systems) Attempts a direct install from the standard repositories first, capturing stderr. A lock or network failure stops there rather than triggering a third-party repository; only a genuine "not found" falls back to the Volian `scar` repository. Repo files created by a failed fallback are removed.
    - **gping**: Installs from the Azlux repository for `apt` systems (using the detected Debian/Ubuntu codename), or via the package manager for others (`apk`, `dnf`, `pacman`, `zypper`). If the codename cannot be detected, the script reports a failure instead of guessing a repository suite.

6.  **Summary**:
    - Prints a detailed summary of:
        - Already installed applications.
        - Newly installed applications.
        - Failed installations (including error messages, exit codes and hints).

7.  **Shell Configuration**:
    - Optionally installs the bundled `bashrc` as `~/.bashrc` (see below).

## Installed Applications

| Application | Description | Installation Method |
| :--- | :--- | :--- |
| **nano** | Text editor | Package Manager |
| **git** | Version control system | Package Manager |
| **curl** | URL transfer tool | Package Manager |
| **wget** | Network downloader | Package Manager |
| **htop** | Interactive process viewer | Package Manager |
| **tmux** | Terminal multiplexer | Package Manager |
| **fd** / **fd-find** | Simple, fast alternative to `find` | Package Manager |
| **zoxide** | Smarter `cd` command | Package Manager |
| **duf** | Disk usage utility | Package Manager |
| **tree** | Directory structure viewer | Package Manager |
| **neomutt** | Command line mail reader | Package Manager |
| **bat** | `cat` clone with syntax highlighting | Package Manager |
| **eza** | Modern replacement for `ls` | Package Manager |
| **mcfly** | Shell history search replacement | Manual (Shell Script, pinned tag) |
| **nala** | Frontend for `apt` | Manual (Direct install, Volian fallback) |
| **gping** | Ping with a graph | Manual (Repo Add + Apt) / Package Manager |

## Features

### Command-Line Options
```bash
sudo bash install_base_apps.sh [OPTIONS]

  -n, --dry-run          Show what would be done without changing the system
  -y, --yes              Apply the bundled .bashrc without prompting
      --ignore-failures  Exit 0 even if some installations fail
  -h, --help             Show help and exit
```
Unknown options or stray arguments exit with status 2 instead of being ignored.

### Dry Run Mode
Run the script with `--dry-run` to simulate the installation process without making any changes to the system. This is useful for verifying what will be installed.
```bash
sudo bash install_base_apps.sh --dry-run
```

### Logging
The script logs all actions to `/var/log/install_base_apps_YYYY-MM-DD.log`. This provides a persistent record of installations and failures for auditing and debugging. Failed installs also append up to 40 lines of captured stderr. If the log file cannot be written, a single warning is printed to stderr and the script continues.

### Exit Status
- `0` — every step succeeded.
- `1` — any installation or package-list update failed, or the `.bashrc` step failed.
- `2` — invalid arguments.
- `130` — interrupted (`INT`/`TERM`).

`--ignore-failures` forces `0` when installations or the package-list update fail, but a `.bashrc` failure still returns `1`. A non-interactive run that skips `.bashrc` is a success and returns `0`.

### Concurrent Runs
A non-blocking `flock` lock (`/var/lock/install_base_apps.lock`) prevents two copies of the script from running at once. On `apt` systems an in-use `dpkg` lock is also detected and reported before any changes are made.

### Timed Commands and Terminal Handling
Installation commands run under `timeout --kill-after=30 900 ...` with stdin redirected from `/dev/null`. GNU `timeout` (without `--foreground`) moves itself and its child into a new process group that is *not* the terminal's foreground group. When `apt-get` finishes running `dpkg`, its pty cleanup calls `tcsetattr()` on stdin, which raises `SIGTTOU` for a background process group and stops it. A stopped process ignores the `TERM` that `timeout` sends, so the run appears to hang — while the package is actually installed — until the 30-second post-timeout `KILL` (or a manual `kill -9`). Redirecting stdin from `/dev/null` makes `tcgetattr()` fail, so `apt` skips that terminal handling and prompts cannot block. If a run ever does appear to hang, check with `ps -o pid,stat,wchan,cmd -p <pid>`: a `T` state means the process was stopped by job control, not by `dpkg`.

### Shell Configuration
After printing the installation summary, the script offers to install the bundled `bashrc` as `~/.bashrc`. If an existing `~/.bashrc` is present, it is first backed up to `~/.bashrc_YYYYMMDD-HH:MM` (for example, `~/.bashrc_20261031-09:19`); if a backup with that name already exists, the seconds are appended. The newest five backups are kept and older ones are pruned.

The prompt defaults to **No**. It is skipped automatically when the script is run non-interactively without a terminal, unless `--yes` is supplied. With `--dry-run`, the script only reports what it would do. When the script is run via `sudo`, the invoking user's home directory and file ownership are used rather than root's (with fallbacks for systems without `getent`).

The new file is written to a temporary file and renamed into place, so an interrupt cannot leave a truncated `.bashrc`. If `~/.bashrc` is a symlink (for example, a dotfiles repository), the link is preserved and its target is updated instead of replacing the link. After installation the file is sourced so its aliases and tool initializers apply to the current session; new shells pick it up automatically.

## Error Handling
- **Network Check**: Probes HTTPS via `curl`, then `wget`, then `ping`, and finally Bash's `/dev/tcp`. The check is advisory: execution continues with a warning, and only aborts if the package-list update also fails.
- **Timeouts**: Downloads use a 60-second timeout and installation commands a 900-second timeout. When GNU `timeout` supports it, `--kill-after=30` force-kills a child that ignores `TERM` or is suspended, so a stalled or stopped process cannot hang the run indefinitely.
- **Verification**: A zero exit code is not treated as success. Each install is confirmed with `is_installed`, which catches installers that exit cleanly without doing anything.
- **Diagnostics**: Failure reasons include the first stderr line and exit code, plus a package-specific hint (for example, EPEL for `eza`/`neomutt`, or `fdfind` vs `fd`). The full captured stderr is appended to the log.
- **Cleanup**: Temporary files are removed on exit or interruption (`INT`/`TERM`), and the interruption is recorded in the log. Third-party repository files created by a failed `nala` or `gping` setup are rolled back, and files that already existed are left untouched.
- **Robustness**: Strict mode (`set -u`, `set -o pipefail`) is enabled, and the script does not stop on individual package failures; it continues and summarizes them.
