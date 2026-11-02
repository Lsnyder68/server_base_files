# Plan: Generate `~/command_cheatsheet.txt` at the End of `install_base_apps.sh`

## Goal

Add a final step to `install_base_apps.sh` that writes a colored, terminal-friendly
quick-reference to the invoking user's home directory each time the script runs.

- **File:** `~/command_cheatsheet.txt`
- **Overwrite behavior:** replaced on every run; no backup, no append.
- **Format:** plain text with ANSI color escape codes (readable with `cat` or
  `less -R`).
- **Sections:**
  1. All 16 commands the script installs, each with a one-sentence summary and
     one or two basic usage examples.
  2. The aliases that actually apply from the bundled `bashrc` on this machine.

## Decisions Confirmed

| Question | Decision |
| :--- | :--- |
| File format | ANSI-colored `.txt`, not Markdown |
| Command scope | All 16 installed apps |
| Usage examples | Curated statically in the script |
| Alias source | Evaluate the bundled `bashrc` in a subshell |
| Generation timing | Always at the end, even if the `.bashrc` step is skipped |
| Dry run | Report the target path; write nothing |
| Failure handling | A failed cheatsheet write makes the script exit `1` |

## Output Specification

### Header

```
COMMAND CHEATSHEET
Generated 2026-11-02 by install_base_apps.sh
View: cat ~/command_cheatsheet.txt    or: less -R ~/command_cheatsheet.txt
```

### Section 1 — Installed Commands

Each entry is rendered as:

```
bat  A cat clone with syntax highlighting and Git integration.
     $ bat file.txt
     $ bat -p file.txt          # plain output, no decorations
```

- Command name: bold green.
- Summary: default/white.
- `$` prompt: dim yellow; example command: yellow.
- Optional dim `(not installed)` tag when the tool is not on `PATH`
  (e.g. an install failed).
- Optional dim `binary: batcat` note where the distro package name differs.

### Section 2 — Shell Aliases

```
hs      history | grep
ld      stat -c "%a %n" *
octal   stat --printf="..." * | numfmt ...
bat     batcat
fd      fdfind
ls      eza -a --long --group-directories-first --octal-permissions --git
grep    grep --color=auto
...
```

- Alias name: bold magenta.
- Definition: default/white.
- If alias extraction fails, print a short note instead of failing the whole
  step, and fall back to statically parsing `alias` lines from `bashrc`.

## Draft Content for Section 1

Summaries are adapted from the projects' official README/taglines. Examples are
deliberately short and avoid pipes (`|`) because `|` is the internal field
delimiter in the script's data table.

| Command | Probe | Summary | Example 1 | Example 2 |
| :--- | :--- | :--- | :--- | :--- |
| `nano` | `nano` | A small and friendly text editor. | `nano file.txt` | `nano -w file.txt` |
| `git` | `git` | A distributed version control system. | `git clone https://github.com/user/repo.git` | `git status` |
| `curl` | `curl` | A command line tool for transferring data with URL syntax. | `curl -O https://example.com/file.tar.gz` | `curl -fsSL https://example.com -o out.html` |
| `wget` | `wget` | A non-interactive downloader for files from the web. | `wget https://example.com/file.tar.gz` | `wget -c https://example.com/big.iso` |
| `htop` | `htop` | An interactive process viewer for Unix systems. | `htop` | `htop -u "$USER"` |
| `tmux` | `tmux` | A terminal multiplexer for managing multiple sessions. | `tmux new -s work` | `tmux attach -t work` |
| `fd` | `fd/fdfind` | A simple, fast and user-friendly alternative to `find`. | `fd pattern` | `fd -e py . src/` |
| `zoxide` | `zoxide` | A smarter `cd` command that learns your habits. | `z proj` | `zi` |
| `duf` | `duf` | A disk usage and free space utility, a better `df` alternative. | `duf` | `duf /home` |
| `tree` | `tree` | A recursive directory listing rendered as an indented tree. | `tree` | `tree -L 2 -d` |
| `neomutt` | `neomutt` | A command line mail reader (MUA). | `neomutt` | `neomutt -f ~/Mail/INBOX` |
| `bat` | `bat/batcat` | A `cat` clone with syntax highlighting and Git integration. | `bat file.txt` | `bat -p file.txt` |
| `eza` | `eza` | A modern replacement for `ls`. | `eza -l` | `eza --tree --level=2` |
| `mcfly` | `mcfly` | A shell history search replacement that learns from your usage. | `mcfly search` | `mcfly add "make test"` |
| `nala` | `nala` | A friendlier frontend for APT with clearer output. | `nala install pkg` | `nala update` |
| `gping` | `gping` | Ping with a live graph. | `gping google.com` | `gping 1.1.1.1 --interval 1` |

Notes to render in the file where relevant:

- `fd`: Debian/Ubuntu installs the binary as `fdfind`; the `bashrc` adds
  `alias fd='fdfind'`.
- `bat`: Debian/Ubuntu installs the binary as `batcat`; the `bashrc` adds
  `alias bat='batcat'`.
- `eza`: the `bashrc` replaces the `ls` alias with a long `eza` invocation.
- `mcfly`: the primary interaction is `Ctrl-R`, mentioned in the entry note.
- `nala`: APT-only; skipped on non-APT systems.

### Description Sources

- bat: <https://github.com/sharkdp/bat>
- eza: <https://github.com/eza-community/eza>
- fd: <https://github.com/sharkdp/fd>
- zoxide: <https://github.com/ajeetdsouza/zoxide>
- duf: <https://github.com/muesli/duf>
- mcfly: <https://github.com/cantino/mcfly>
- gping: <https://github.com/orf/gping>
- nala: <https://gitlab.com/volian/nala>
- Remaining tools: their upstream man pages / project sites.

## Implementation Plan

### 1. Add constants and data near the top of `install_base_apps.sh`

After the existing constants (around line 20), add:

```bash
CHEATSHEET_FILE="command_cheatsheet.txt"
```

Add a `cheatsheet_entries` array of `label|probe|summary|example1|example2`
strings immediately above the new function, populated from the table above.
`probe` supports alternatives with `/` (for `fd/fdfind`, `bat/batcat`).

Add ANSI color variables:

```bash
C_RESET=$'\033[0m'
C_TITLE=$'\033[1;37;44m'   # bold white on blue
C_SECTION=$'\033[1;36m'    # bold cyan
C_CMD=$'\033[1;32m'        # bold green
C_ALIAS=$'\033[1;35m'      # bold magenta
C_EXAMPLE=$'\033[0;33m'    # yellow
C_DIM=$'\033[2;37m'        # dim
```

If `NO_COLOR` is set in the environment, set all of these to an empty string so
the generated file is plain text.

### 2. Extract shared target-home logic

`install_bashrc` currently computes `target_home` and `target_user` inline
(lines 649–660). Extract that into a helper so both the `.bashrc` install and
the cheatsheet use the same account:

```bash
resolve_target_account() {
    TARGET_USER=""
    TARGET_HOME="${HOME:-}"
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; then
        TARGET_USER="$SUDO_USER"
        TARGET_HOME=$(resolve_user_home "$SUDO_USER")
    fi
    [ -z "$TARGET_HOME" ] && TARGET_HOME="${HOME:-}"
    [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ]
}
```

Update `install_bashrc` to call it and use `$TARGET_HOME` / `$TARGET_USER`
(behavior-preserving refactor).

### 3. Add `generate_cheatsheet()`

Place it after `install_bashrc` (after line 767), before `usage()`.

Responsibilities:

1. Call `resolve_target_account`; on failure print an error and return 1.
2. If `DRY_RUN=true`, print
   `[DRY RUN] Would write <path>` and return 0.
3. Build the content into a temporary file in the target home:
   - Header with date and view hint.
   - Section 1: `MODERN COMMANDS & INSTALLED TOOLS`.
   - Section 2: `SHELL ALIASES (from bashrc)`.
4. For each data row:
   - Split on `|` using `IFS='|' read -r`.
   - Determine whether any probe binary exists with `command -v`.
   - Print command, summary, examples; append `(not installed)` when missing.
5. Collect aliases:
   ```bash
   HOME="$safe_home" bash --noprofile --norc -c '
       source "$1" >/dev/null 2>&1 || exit 1
       alias
   ' _ "$bashrc_source"
   ```
   - `$bashrc_source` is the bundled repo `bashrc` (source of truth), resolved
     the same way as `install_bashrc` does.
   - `HOME` is pointed at a freshly created empty temp directory so the
     bundled bashrc's `~/.bash_aliases` hook cannot execute the target user's
     file as root. Add that temp directory to a new `TEMP_DIRS` array.
   - Bash's `alias` builtin runs in non-interactive mode and returns the final
     effective alias set, so conditional aliases whose tools are absent are
     correctly omitted and `ls` shows its final `eza` value.
6. Parse each `alias name='value'` line and render name/definition. Strip
   non-printable control characters from the definition before writing
   (defense-in-depth against escape injection from the source text).
7. If alias collection yields nothing, fall back to:
   ```bash
   grep -E "^[[:space:]]*alias [A-Za-z0-9_]+=" "$bashrc_source"
   ```
   and print a dim note that conditional aliases may be listed.
8. Atomically install the file:
   - `mktemp "$TARGET_HOME/.command_cheatsheet.tmp.XXXXXX"`, add to
     `TEMP_FILES`.
   - `chmod 644`.
   - `chown "$TARGET_USER":` when a non-root target user was detected.
   - `mv -f` into `$TARGET_HOME/$CHEATSHEET_FILE`.
9. Log success with the existing `log` helper:
   `✓ Wrote command cheatsheet to <path>`.

Also extend `cleanup()` so `TEMP_DIRS` entries are removed with `rm -rf`, and
initialize `declare -a TEMP_DIRS=()` beside `TEMP_FILES`.

### 4. Wire it into main execution

Current tail (lines 862–880):

```bash
print_summary

exit_code=0
install_bashrc || exit_code=1
```

Change to:

```bash
print_summary

exit_code=0
install_bashrc || exit_code=1
generate_cheatsheet || exit_code=1
```

The cheatsheet is generated even when the user declines the `.bashrc` install,
when the run is non-interactive, or when `--yes` was not supplied. In that case
the file still documents the bundled aliases, with a dim note that they take
effect after the `.bashrc` is installed or sourced.

### 5. Documentation updates

Update `script_documentation.md`:

- Add workflow step: "Command Cheatsheet" after "Shell Configuration".
- Add a "### Command Cheatsheet" feature subsection describing the path,
  overwrite behavior, color/`less -R` usage, `NO_COLOR`, and the two sections.
- Note that a cheatsheet write failure sets exit status `1`.
- Mention the `TEMP_DIRS` cleanup addition in the cleanup bullet.

No new CLI flags are introduced, so `usage()` is unchanged.

## Edge Cases and Error Handling

| Case | Behavior |
| :--- | :--- |
| `--dry-run` | Prints `[DRY RUN] Would write ...`; no file or temp files created |
| `.bashrc` install declined/skipped | Cheatsheet still generated from bundled `bashrc` |
| Bundled `bashrc` missing | Commands section still generated; alias section prints a note |
| Tool install failed | Entry still listed, tagged `(not installed)` |
| Alias subshell fails | Static `alias`-line fallback plus dim warning |
| Target home not writable | Error to stderr, return 1, script exits 1 |
| Script interrupted | Existing `trap cleanup EXIT` removes temp file and temp dir |
| `NO_COLOR` set | Same layout, no ANSI escapes |
| Re-run | File is replaced atomically; no backups accumulate |
| Symlinked home dotfiles | Not relevant: this is a standalone file, not a symlink |

## Testing Plan

1. `bash -n install_base_apps.sh` and `shellcheck install_base_apps.sh`
   (if available).
2. `sudo bash install_base_apps.sh --dry-run` — confirm the dry-run message and
   that no file appears in the home directory.
3. Run on a disposable VM/container with `--yes`; verify:
   - `~/command_cheatsheet.txt` exists, owned by the invoking user, mode `644`.
   - `cat ~/command_cheatsheet.txt` shows colors; `less -R` renders correctly.
   - Section 1 lists all 16 commands and exactly 1–2 examples each.
   - Section 2 matches the target user's interactive `alias` output
     (`bash -ic 'alias'`), with `bat`/`fd`/`ls` omitted when their tools are
     absent.
4. Delete or rename the bundled `bashrc`, rerun — commands section still works.
5. Simulate a failed install (e.g. temporarily break the app list) — entry shows
   `(not installed)`.
6. `NO_COLOR=1` run — no escape sequences (`grep -P '\x1b'` finds none).
7. Run twice — second run overwrites cleanly, no extra files.
8. Make the home directory read-only and confirm the step fails with exit `1`.
9. Confirm `--ignore-failures` does **not** mask a cheatsheet failure (it only
   affects installation failures), consistent with the chosen behavior.

## Out of Scope (for now)

- Generating a second Markdown copy.
- Dynamic man-page/`--help` parsing.
- New CLI flags such as `--no-cheatsheet`.
- Including aliases from the user's separate `~/.bash_aliases`.
- Paging or auto-opening the file after generation.

## Review Checklist

- [ ] `~/command_cheatsheet.txt`, overwritten each run
- [ ] Colored ANSI output, `NO_COLOR` respected
- [ ] 16 commands, one-line summary + 1–2 examples each
- [ ] Aliases reflect what is actually active on the machine
- [ ] Generated even if `.bashrc` install is skipped
- [ ] Dry run writes nothing; write failure returns exit `1`
- [ ] Documentation updated
