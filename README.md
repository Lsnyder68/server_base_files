# server_base_files

Provisioning toolkit for fresh Linux servers. One script installs a consistent
set of base applications and layers a standardized shell configuration onto
whatever `~/.bashrc` the host already has — without deleting the `PATH`
entries, tool initializers, or site-specific settings that make that host work.

Supports **Debian/Ubuntu**, **RHEL/Fedora**, **Arch**, **Alpine**, and
**openSUSE**.

## What it does

- Installs: `nano`, `git`, `curl`, `wget`, `htop`, `tmux`, `fd`/`fd-find`,
  `zoxide`, `duf`, `tree`, `neomutt`, `bat`, `eza`, plus `mcfly`, `nala`
  (apt only), and `gping`.
- Adds a **managed block** to `~/.bashrc` with history settings, aliases, and
  tool initialization. Everything outside the block is preserved byte for byte.
- Writes `~/command_cheatsheet.txt` with one-line summaries and examples for the
  installed commands and the effective aliases.
- Logs actions to `/var/log/install_base_apps_YYYY-MM-DD.log`.

## Quick start

```bash
git clone https://github.com/Lsnyder68/server_base_files.git
cd server_base_files

sudo bash install_base_apps.sh --dry-run   # preview; changes nothing
sudo bash install_base_apps.sh             # install, then answer "y" for the shell block
exec bash                                  # apply the new shell configuration
```

Keep the repository layout intact: `install_base_apps.sh` sources
`lib/bashrc_block.sh`. Copying only the `.sh` file to a server exits at startup.

Requirements: root for installs, bash 4+, and a supported package manager.
The read-only modes below run unprivileged.

## Options

```text
-n, --dry-run          Preview only; prints a diff of the proposed .bashrc
-y, --yes              Apply the shell block without prompting
    --ignore-failures  Exit 0 even if some installations fail
    --bashrc-check     Report shell-config drift and exit
    --bashrc-uninstall Remove only the managed block and exit
    --restore-bashrc   Recover a host flattened by an older release
-h, --help             Show help
```

`--bashrc-check` exit codes: `0` current, `1` outdated or missing, `2`
hand-edited inside the block, `3` malformed markers.

## The `~/.bashrc` block

Earlier releases replaced `~/.bashrc` outright. That silently dropped
host-specific `PATH` exports and package-manager init lines. The bundle is now
a fragment inserted between markers:

```bash
# >>> server-base (managed) >>>
# server-base: version=3 sha256=...
if [[ $- == *i* ]]; then
...
fi
# <<< server-base (managed) <<<
```

- Idempotent: replaced in place, never duplicated; a no-op run writes nothing.
- Interactive-only: silent under `BASH_ENV`, so it cannot corrupt `scp`/`rsync`.
- Refuses malformed markers and syntax-checks with `bash -n` before writing.
- Preserves mode and owner; follows a dotfiles symlink instead of replacing it.
- Under `sudo`, backup directories and a newly created `.bashrc` belong to the
  target user, not to root.
- History limits are only raised. Unset, empty, negative, non-numeric, and `0`
  values are left exactly as the host set them, so `HISTFILESIZE=-1` stays
  unlimited and a deliberate `0` stays disabled.
- Keeps a permanent original at `~/.bashrc.pre-server-base` and five rotating
  copies in `~/.local/share/server-base/backups/`.

To remove it, run `--bashrc-uninstall`. To update, `git pull` and re-run; only
the text between the markers changes.

## Recovering an already-flattened host

An older release replaced `~/.bashrc` outright, so the only copy of the host's
own `PATH` and init lines is one of the `~/.bashrc_*` backups beside it.

The installer refuses to layer the block onto a bundle copy. It prints the
newest backup that is not a bundle copy and tells you to restore first:

```bash
bash install_base_apps.sh --bashrc-check          # 1 = needs attention
sudo bash install_base_apps.sh --restore-bashrc   # shows a diff, asks first
sudo bash install_base_apps.sh --yes              # layer the block on top
```

Candidates are ordered by the timestamp in the file name, newest first, across
both the old `~/.bashrc_*` names and `~/.local/share/server-base/backups/`.
Restore keeps working after the block is installed, because the comparison
ignores the managed block. Shipped bundle hashes are built into
`lib/bashrc_block.sh` (`tools/bundle-hashes.sh` regenerates them), so recovery
works from a tarball, a shallow clone, or a git worktree.

## Testing

No root and no real-home changes required:

```bash
bash tests/test_bashrc_block.sh     # markers, backups, guards, drift
bash tests/test_install_bashrc.sh   # CLI modes, symlinks, recovery
```

## Layout

```text
install_base_apps.sh   installer and CLI entry point
bashrc                 shell fragment inserted into ~/.bashrc
lib/bashrc_block.sh    managed-block engine (render, install, check, recover)
tests/                 test suites for the block and the installer
tools/bundle-hashes.sh regenerates the shipped-bundle hash table
planning/              design notes
script_documentation.md  full reference: workflow, exit status, internals
```
