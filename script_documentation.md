# Script Documentation: `install_base_apps.sh`

## Overview
This bash script is designed to automate the installation of a set of base applications on Linux systems. It supports systems using `apt` (Debian/Ubuntu), `apk` (Alpine), `dnf` (Fedora/RHEL), `pacman` (Arch Linux), and `zypper` (openSUSE). The script ensures necessary tools are available, handles installation errors gracefully, and provides a summary of actions taken.

## Quick start

```bash
git clone https://github.com/Lsnyder68/server_base_files.git
cd server_base_files

sudo bash install_base_apps.sh --dry-run   # preview; changes nothing
sudo bash install_base_apps.sh             # install, then answer "y" for the shell block
exec bash                                  # apply the new shell configuration
```

Keep the repository layout intact. `install_base_apps.sh` sources
`lib/bashrc_block.sh`, and `--restore-bashrc` reads bundle history from `.git`.
Copying only the `.sh` file to a server exits at startup with a missing-library
error.

## Prerequisites
- **Root Privileges**: Required for real installs (run with `sudo`). The script checks this at startup and exits if not root. `--dry-run`, `--bashrc-check`, `--bashrc-uninstall`, and `--restore-bashrc` are exempt; the last three only touch the invoking user's own `~/.bashrc`.
- **Bash**: The script targets bash 4 or newer (arrays, `declare -p`, `[[ ]]`). `/bin/sh` will not work; invoke it with `bash`.
- **Repository files**: `install_base_apps.sh`, `bashrc`, and `lib/bashrc_block.sh` must remain together.
- **Supported Package Manager**: The system must have one of the following installed: `apt-get`, `dnf`, `pacman`, `zypper`, or `apk`.
- **Git**: Optional. It is installed as one of the base apps, and `--restore-bashrc` uses it when present to identify historical bundle copies.

## Usage

The script is not marked executable in the repository, so invoke it with `bash` (or run `chmod +x install_base_apps.sh` once):

### Normal (interactive) run
```bash
cd /path/to/server_base_files
sudo bash install_base_apps.sh
```
This installs everything, prints the summary, then asks whether to add the managed `server-base` block to your existing `~/.bashrc`.

### Non-interactive run
When stdin is not a terminal, the `.bashrc` prompt is skipped automatically and the script exits normally without touching `~/.bashrc`:
```bash
sudo bash install_base_apps.sh </dev/null
```
To apply the managed block without prompting:
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
Makes no changes: no installs, no `.bashrc` backup, no log file writes. Because the shell block is rendered in full, the output includes a unified diff of the proposed `~/.bashrc`.

### Choosing a mode

| Situation | Command |
| --- | --- |
| Normal fresh install | `sudo bash install_base_apps.sh` |
| Unattended install (Ansible, cloud-init) | `sudo bash install_base_apps.sh --yes` |
| Preview only | `sudo bash install_base_apps.sh --dry-run` |
| Audit an existing host (no root, read-only) | `bash install_base_apps.sh --bashrc-check` |
| Recover a host flattened by an older release | `bash install_base_apps.sh --restore-bashrc` then re-run normally |
| Remove the standardisation but keep host content | `sudo bash install_base_apps.sh --bashrc-uninstall` |

`--bashrc-check` prints one line and exits `0` (current), `1` (outdated or
missing), `2` (hand-edited inside the block), or `3` (malformed markers). It is
safe to run over SSH from a loop or a monitoring check.

### Rolling out to an existing fleet

1. Audit first, to find the hosts that need repair:
   ```bash
   bash install_base_apps.sh --bashrc-check; echo "host $(hostname): $?"
   ```
2. On a host that returns `1` *and* whose `.bashrc` is a bundle copy, restore the
   real file before layering the block:
   ```bash
   sudo bash install_base_apps.sh --restore-bashrc   # shows a diff, asks to confirm
   ```
   Use `--yes` only on a host you have already inspected.
3. Install normally. The block is appended to the restored file, so the
   recovered `PATH` lines keep working.

### Updating an existing host

```bash
git -C /path/to/server_base_files pull
sudo bash /path/to/server_base_files/install_base_apps.sh --yes
```

Only the text between the markers changes. Host lines above the block, and
overrides placed after it, are untouched. A run with no changes writes nothing
and creates no backup.

### Rolling back

```bash
sudo bash install_base_apps.sh --bashrc-uninstall   # remove just the block
```

If something else went wrong, the untouched original is at
`~/.bashrc.pre-server-base`, and the five most recent pre-change copies are in
`~/.local/share/server-base/backups/`.

### Testing

The shell-configuration work has a test suite that needs no root and never
touches the real home:

```bash
bash tests/test_bashrc_block.sh     # library: markers, backups, guards, drift
bash tests/test_install_bashrc.sh   # installer: CLI modes, symlinks, recovery
```

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
    - Optionally inserts the bundled `bashrc` as a managed block inside `~/.bashrc`, preserving host content (see below).

8.  **Command Cheatsheet**:
    - Writes `~/command_cheatsheet.txt` for the invoking user, replacing any existing copy. See "Command Cheatsheet" below.

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

  -n, --dry-run          Show what would be done, including a .bashrc diff
  -y, --yes              Apply the bashrc block without prompting
      --ignore-failures  Exit 0 even if some installations fail
      --bashrc-check     Report drift only and exit (0 current, 1 outdated,
                         2 hand-edited, 3 malformed)
      --bashrc-uninstall Remove only the managed block and exit
      --restore-bashrc   Restore a host flattened by an older release
  -h, --help             Show help and exit
```
Unknown options or stray arguments exit with status 2 instead of being ignored.

The `--bashrc-check`, `--bashrc-uninstall`, and `--restore-bashrc` modes do not install packages, so they may be run without `sudo` against your own home.

### Dry Run Mode
Run the script with `--dry-run` to simulate the installation process without making any changes to the system. This is useful for verifying what will be installed.
```bash
sudo bash install_base_apps.sh --dry-run
```

### Logging
The script logs all actions to `/var/log/install_base_apps_YYYY-MM-DD.log`. This provides a persistent record of installations and failures for auditing and debugging. Failed installs also append up to 40 lines of captured stderr. If the log file cannot be written, a single warning is printed to stderr and the script continues.

### Exit Status
- `0` — every step succeeded.
- `1` — any installation or package-list update failed, or the `.bashrc` or cheatsheet step failed.
- `2` — invalid arguments.
- `130` — interrupted (`INT`/`TERM`).

`--ignore-failures` forces `0` when installations or the package-list update fail, but a `.bashrc` failure still returns `1`. A non-interactive run that skips `.bashrc` is a success and returns `0`.

### Concurrent Runs
A non-blocking `flock` lock (`/var/lock/install_base_apps.lock`) prevents two copies of the script from running at once. On `apt` systems an in-use `dpkg` lock is also detected and reported before any changes are made.

### Timed Commands and Terminal Handling
Installation commands run under `timeout --kill-after=30 900 ...` with stdin redirected from `/dev/null`. GNU `timeout` (without `--foreground`) moves itself and its child into a new process group that is *not* the terminal's foreground group. When `apt-get` finishes running `dpkg`, its pty cleanup calls `tcsetattr()` on stdin, which raises `SIGTTOU` for a background process group and stops it. A stopped process ignores the `TERM` that `timeout` sends, so the run appears to hang — while the package is actually installed — until the 30-second post-timeout `KILL` (or a manual `kill -9`). Redirecting stdin from `/dev/null` makes `tcgetattr()` fail, so `apt` skips that terminal handling and prompts cannot block. If a run ever does appear to hang, check with `ps -o pid,stat,wchan,cmd -p <pid>`: a `T` state means the process was stopped by job control, not by `dpkg`.

### Shell Configuration

The bundled `bashrc` is a **fragment**, not a whole-file replacement. It is
written into `~/.bashrc` as a managed block:

```bash
# >>> server-base (managed) >>>
# server-base: version=2 sha256=...
if [[ $- == *i* ]]; then
...
fi
# <<< server-base (managed) <<<
```

Everything outside the block — `PATH` exports, `JAVA_HOME`, conda/nvm/pyenv
init, vendor blocks, site functions — is preserved byte for byte. The block
is appended at the end, so the standardized aliases and tool initializers win
over an older file's equivalents while host overrides placed after the block
still win over the base.

Behaviour:

- **Idempotent.** The block is replaced in place, never duplicated. Markers
  are deliberately version-free; the version and a hash live on the meta line
  inside the block. A run with no changes writes nothing and creates no backup.
- **Interactive only.** The body is wrapped in an interactive guard, so it is
  silent when sourced non-interactively (for example through `BASH_ENV`, or by
  Debian's ssh handling) and cannot corrupt `scp`/`rsync`.
- **Safe under `set -u`.** The fragment tests readonly or unset history
  variables before assigning them.
- **Refuses malformed markers.** Zero or one begin/end pair is allowed;
  anything else exits non-zero and leaves the file untouched. The generated
  file is syntax-checked with `bash -n` before the atomic rename.
- **Preserves mode and owner.** A `600` `.bashrc` stays `600`; `SUDO_USER`
  and `DOAS_USER` are honoured. If `~/.bashrc` is a symlink (dotfiles repo),
  the link is kept and its target updated. `restorecon` runs when available.
- **Backups.** The first real change keeps a never-pruned copy at
  `~/.bashrc.pre-server-base`. A rotating history of five copies lives in
  `~/.local/share/server-base/backups/`, named `bashrc.YYYYmmdd-HHMMSS` (no
  colons, so the names survive `scp`/`rsync`). Backups deliberately live in
  the home directory, not beside a symlinked dotfiles target, so installing
  does not dirty a repository.
- **Local edits are reported, not ignored.** If the body no longer matches the
  hash recorded in the meta line, the run still updates the block but warns
  and keeps the edited copy in the backup directory.
- **Recovery.** On a host whose `.bashrc` is an exact copy of a previously
  shipped bundle, the script prints the newest backup that is not a bundle
  copy and offers `--restore-bashrc`, which shows a diff and restores it after
  confirmation. Without this, PATH lines lost to older releases stayed lost.
- **No in-process sourcing.** The installer no longer sources the installed
  file (doing so ran user content as root under `set -u`, and could be hijacked
  by an `exec tmux` line). It prints `exec bash` instead.

The prompt defaults to **No** and is skipped when stdin is not a terminal
unless `--yes` is supplied. With `--dry-run`, the block is rendered and a
unified diff is printed without touching the file.

`--bashrc-check` is intended for fleet audits:

| Exit | Meaning |
| ---- | ------- |
| 0 | block present, current version, no hand edits |
| 1 | block missing, or an older bundle/version |
| 2 | body edited by hand since it was written |
| 3 | malformed markers |

See **Testing** above for the commands that exercise this behaviour without
touching the real home.

### Command Cheatsheet
At the very end of every run, the script writes `~/command_cheatsheet.txt` for the invoking user (`SUDO_USER` when run via `sudo`). The file is overwritten on each run, written atomically, and owned by that user with mode `644`. It is generated even when the `.bashrc` install is declined or skipped.

The file has two sections:

1. **Commands installed by this script** — all 16 packages with a one-sentence summary and one or two basic usage examples. Commands that are not present on the system are tagged `(not installed)`, and distro-specific binary names such as `batcat` / `fdfind` are noted.
2. **Shell aliases** — the effective aliases from the bundled `bashrc`, evaluated in a subshell so conditional aliases (`bat`, `fd`, `ls`) appear only when their tools are installed. If evaluation fails, the script falls back to listing the `alias` lines statically and says so.

The file contains ANSI color codes and is intended for the terminal:

```bash
cat ~/command_cheatsheet.txt
less -R ~/command_cheatsheet.txt
```

Set `NO_COLOR=1` when running the script to generate a plain-text version without escape codes. Usage examples are curated in the script rather than parsed from man pages, so the output is deterministic and works offline.

A failure to write the cheatsheet is reported on stderr and returns exit status `1`; `--ignore-failures` does not mask it.

## Error Handling
- **Network Check**: Probes HTTPS via `curl`, then `wget`, then `ping`, and finally Bash's `/dev/tcp`. The check is advisory: execution continues with a warning, and only aborts if the package-list update also fails.
- **Timeouts**: Downloads use a 60-second timeout and installation commands a 900-second timeout. When GNU `timeout` supports it, `--kill-after=30` force-kills a child that ignores `TERM` or is suspended, so a stalled or stopped process cannot hang the run indefinitely.
- **Verification**: A zero exit code is not treated as success. Each install is confirmed with `is_installed`, which catches installers that exit cleanly without doing anything.
- **Diagnostics**: Failure reasons include the first stderr line and exit code, plus a package-specific hint (for example, EPEL for `eza`/`neomutt`, or `fdfind` vs `fd`). The full captured stderr is appended to the log.
- **Cleanup**: Temporary files and the temporary alias-evaluation home directory are removed on exit or interruption (`INT`/`TERM`), and the interruption is recorded in the log. Third-party repository files created by a failed `nala` or `gping` setup are rolled back, and files that already existed are left untouched.
- **Robustness**: Strict mode (`set -u`, `set -o pipefail`) is enabled, and the script does not stop on individual package failures; it continues and summarizes them.
