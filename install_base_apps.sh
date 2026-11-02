#!/bin/bash
set -u
set -o pipefail

# Constants & Globals
LOG_FILE="/var/log/install_base_apps_$(date +%F).log"
LOG_FALLBACK_WARNED=false
DRY_RUN=false
ASSUME_YES=false
IGNORE_FAILURES=false
PKG_MANAGER=""
CONNECTIVITY_OK=false
LOCK_FILE="/var/lock/install_base_apps.lock"
# Pin the mcfly release instead of piping an unpinned script from master
MCFLY_VERSION="v0.9.4"
# Optional: set to the installer script's SHA-256 to verify it before running.
MCFLY_INSTALL_SHA256="${MCFLY_INSTALL_SHA256:-}"
NETWORK_TIMEOUT=60
INSTALL_TIMEOUT=900
MAX_BASHRC_BACKUPS=5
CHEATSHEET_FILE="command_cheatsheet.txt"

# ANSI colors for the generated command cheatsheet. NO_COLOR disables them.
if [ -n "${NO_COLOR:-}" ]; then
    C_RESET=""
    C_TITLE=""
    C_SECTION=""
    C_CMD=""
    C_ALIAS=""
    C_EXAMPLE=""
    C_DIM=""
else
    C_RESET=$'\033[0m'
    C_TITLE=$'\033[1;37;44m'   # bold white on blue
    C_SECTION=$'\033[1;36m'    # bold cyan
    C_CMD=$'\033[1;32m'        # bold green
    C_ALIAS=$'\033[1;35m'      # bold magenta
    C_EXAMPLE=$'\033[0;33m'    # yellow
    C_DIM=$'\033[2;37m'        # dim
fi

# label|probe|summary|example1|example2
# probe may list alternatives with "/" (e.g. the Debian batcat/fdfind names).
# Fields are "|"-separated, so examples must not contain a pipe character.
cheatsheet_entries=(
    'nano|nano|A small and friendly text editor.|nano file.txt|nano -w file.txt'
    'git|git|A distributed version control system.|git clone https://github.com/user/repo.git|git status'
    'curl|curl|A command line tool for transferring data with URL syntax.|curl -O https://example.com/file.tar.gz|curl -fsSL https://example.com -o out.html'
    'wget|wget|A non-interactive downloader for files from the web.|wget https://example.com/file.tar.gz|wget -c https://example.com/big.iso'
    'htop|htop|An interactive process viewer for Unix systems.|htop|htop -u "$USER"'
    'tmux|tmux|A terminal multiplexer for managing multiple sessions.|tmux new -s work|tmux attach -t work'
    'fd|fd/fdfind|A simple, fast and user-friendly alternative to find.|fd pattern|fd -e py . src/'
    'zoxide|zoxide|A smarter cd command that learns your habits.|z proj|zi'
    'duf|duf|A disk usage and free space utility, a better df alternative.|duf|duf /home'
    'tree|tree|A recursive directory listing rendered as an indented tree.|tree|tree -L 2 -d'
    'neomutt|neomutt|A command line mail reader (MUA).|neomutt|neomutt -f ~/Mail/INBOX'
    'bat|bat/batcat|A cat clone with syntax highlighting and Git integration.|bat file.txt|bat -p file.txt'
    'eza|eza|A modern replacement for ls.|eza -l|eza --tree --level=2'
    'mcfly|mcfly|A shell history search replacement that learns from your usage.|mcfly search|mcfly add "make test"'
    'nala|nala|A friendlier frontend for APT with clearer output.|nala install pkg|nala update'
    'gping|gping|Ping with a live graph.|gping google.com|gping 1.1.1.1 --interval 1'
)

# Arrays to store installation results
declare -a already_installed=()
declare -a newly_installed=()
declare -a failed_apps=()
declare -a failed_reasons=()
declare -a apps=()
# Temporary files and repo files that should be removed on failure/exit
declare -a TEMP_FILES=()
declare -a TEMP_DIRS=()
declare -a ROLLBACK_FILES=()

# Helper Functions

log_fallback_warning() {
    if [ "$LOG_FALLBACK_WARNED" = false ]; then
        echo "Warning: cannot write to $LOG_FILE; continuing without file logging." >&2
        LOG_FALLBACK_WARNED=true
    fi
}

log() {
    local message="$1"
    echo "$message"
    # Only log to file if not dry run and we have permissions
    if [ "$DRY_RUN" = false ]; then
        if [ -w "$(dirname "$LOG_FILE")" ]; then
            if ! echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE" 2>/dev/null; then
                log_fallback_warning
            fi
        else
            log_fallback_warning
        fi
    fi
}

rollback_created_files() {
    local file
    for file in "${ROLLBACK_FILES[@]:-}"; do
        [ -n "$file" ] || continue
        if [ -e "$file" ]; then
            rm -f "$file" && echo "Removed incomplete repository file: $file" >&2
        fi
    done
    ROLLBACK_FILES=()
}

cleanup() {
    local file
    if [ -n "${error_log:-}" ] && [ -f "${error_log:-}" ]; then
        rm -f "$error_log"
    fi
    for file in "${TEMP_FILES[@]:-}"; do
        [ -n "$file" ] || continue
        [ -f "$file" ] && rm -f "$file"
    done
    for file in "${TEMP_DIRS[@]:-}"; do
        [ -n "$file" ] || continue
        [ -d "$file" ] && rm -rf "$file"
    done
    rollback_created_files
}

on_interrupt() {
    echo "" >&2
    log "Interrupted by signal; cleaning up temporary files..."
    cleanup
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# Run a command with a timeout when the timeout utility is available.
# --kill-after guarantees that a stopped (SIGTSTP) or TERM-ignoring child
# cannot hang the run forever.
#
# stdin is always /dev/null.  GNU timeout (without --foreground) puts itself
# and its child in a new process group, which is NOT the terminal's foreground
# process group.  apt-get's dpkg pty handling calls tcsetattr(STDIN_FILENO, ...)
# in pkgDPkgPM::StopPtyMagic() after dpkg finishes; a background process group
# that changes terminal attributes receives SIGTTOU and is stopped.  A stopped
# process ignores the TERM that timeout sends, so the install looks hung even
# though the package was already installed.  With stdin on /dev/null,
# tcgetattr() fails and apt skips the terminal handling; maintainer-script
# prompts also get EOF instead of blocking.
run_with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        local help_text=""
        help_text=$(timeout --help 2>&1 || true)
        if [[ "$help_text" == *"--kill-after"* ]]; then
            timeout --kill-after=30 "$seconds" "$@" </dev/null
        else
            timeout "$seconds" "$@" </dev/null
        fi
    else
        "$@" </dev/null
    fi
}

# Remember files that did not exist before we created them, so a failed
# third-party repository setup can be rolled back.
track_created_file() {
    local path="$1"
    if [ ! -e "$path" ]; then
        ROLLBACK_FILES+=("$path")
    fi
}

record_failure() {
    local app="$1"
    local reason="${2:-unknown error}"
    [ -n "$reason" ] || reason="unknown error"
    failed_apps+=("$app")
    failed_reasons+=("$reason")
}

failure_hint() {
    case "$1" in
        neomutt|eza)
            echo "On RHEL/Fedora this package may require the EPEL repository."
            ;;
        fd-find)
            echo "On Debian/Ubuntu the binary is 'fdfind'; other distros may use the 'fd' package."
            ;;
        fd)
            echo "On Debian/Ubuntu the package is named 'fd-find'."
            ;;
        gping)
            echo "gping requires the Azlux repository; see https://github.com/orf/gping for manual install options."
            ;;
        nala)
            echo "Check that your distribution is supported by the Volian/Scar repository."
            ;;
    esac
}

check_connectivity() {
    log "Checking network connectivity..."
    local ok=false

    if command -v curl >/dev/null 2>&1; then
        if curl -fsSI --max-time 10 https://www.google.com >/dev/null 2>&1; then
            ok=true
        fi
    fi
    if [ "$ok" = false ] && command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=10 https://www.google.com >/dev/null 2>&1; then
            ok=true
        fi
    fi
    if [ "$ok" = false ] && command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
            ok=true
        fi
    fi
    # Bash's /dev/tcp works even when curl, wget and ping are all missing.
    if [ "$ok" = false ]; then
        if (exec 3<>/dev/tcp/1.1.1.1/443) 2>/dev/null; then
            ok=true
        fi
    fi

    if [ "$ok" = true ]; then
        CONNECTIVITY_OK=true
        log "✓ Network connectivity check passed"
    else
        CONNECTIVITY_OK=false
        log "Warning: network probes failed (curl, wget, ping and /dev/tcp). Continuing; installations may fail."
    fi
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"
    elif command -v apk >/dev/null 2>&1; then
        PKG_MANAGER="apk"
    else
        echo "Error: No supported package manager found (apt, dnf, pacman, zypper, apk)" >&2
        exit 1
    fi
    log "Detected package manager: $PKG_MANAGER"
}

check_package_manager_lock() {
    [ "$DRY_RUN" = true ] && return 0
    [ "$PKG_MANAGER" = "apt" ] || return 0

    local lock
    for lock in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock; do
        [ -e "$lock" ] || continue
        if command -v fuser >/dev/null 2>&1; then
            if fuser "$lock" >/dev/null 2>&1; then
                echo "Error: another package manager process is using $lock. Wait for it to finish and retry." >&2
                exit 1
            fi
        elif command -v lsof >/dev/null 2>&1; then
            if lsof "$lock" >/dev/null 2>&1; then
                echo "Error: another package manager process is using $lock. Wait for it to finish and retry." >&2
                exit 1
            fi
        fi
    done
}

acquire_lock() {
    [ "$DRY_RUN" = true ] && return 0
    if ! command -v flock >/dev/null 2>&1; then
        log "Warning: flock is not available; skipping concurrency lock."
        return 0
    fi
    mkdir -p /var/lock 2>/dev/null || true
    if ! exec 9>"$LOCK_FILE"; then
        echo "Error: cannot create lock file $LOCK_FILE" >&2
        exit 1
    fi
    if ! flock -n 9; then
        echo "Error: another instance of install_base_apps.sh is already running." >&2
        exit 1
    fi
}

is_installed() {
    local app_name="$1"
    if command -v "$app_name" >/dev/null 2>&1; then
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            local status
            # Use dpkg-query instead of a pipeline so `pipefail` cannot turn a
            # successful match into a failure via SIGPIPE.
            status=$(dpkg-query -W -f='${Status}' "$app_name" 2>/dev/null) || return 1
            [ "$status" = "install ok installed" ] && return 0
            ;;
        dnf)
            dnf list installed "$app_name" >/dev/null 2>&1 && return 0
            ;;
        pacman)
            pacman -Qi "$app_name" >/dev/null 2>&1 && return 0
            ;;
        zypper)
            zypper search -i --match-exact "$app_name" >/dev/null 2>&1 && return 0
            ;;
        apk)
            apk info -e "$app_name" >/dev/null 2>&1 && return 0
            ;;
    esac
    return 1
}

persist_error_details() {
    local app="$1"
    local file="$2"
    [ -s "$file" ] || return 0

    if [ "$DRY_RUN" = false ] && [ -w "$(dirname "$LOG_FILE")" ]; then
        {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] --- stderr for $app ---"
            sed -n '1,40{s/^/    /;p}' "$file"
        } >> "$LOG_FILE" 2>/dev/null || log_fallback_warning
    else
        echo "Full error output for $app:" >&2
        sed -n '1,40{s/^/    /;p}' "$file" >&2
    fi
}

handle_installation() {
    local app_name="$1"
    shift
    local install_cmd=("$@")

    log "Installing $app_name..."

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would execute: ${install_cmd[*]}"
        newly_installed+=("$app_name (dry-run)")
        return 0
    fi

    # Create a temporary file for stderr
    error_log=""
    if ! error_log=$(mktemp "${TMPDIR:-/tmp}/install_base_apps.XXXXXX"); then
        error_log=""
        record_failure "$app_name" "could not create a temporary log file"
        log "✗ Failed to install $app_name: could not create a temporary log file"
        return 1
    fi
    TEMP_FILES+=("$error_log")

    local rc=0
    run_with_timeout "$INSTALL_TIMEOUT" "${install_cmd[@]}" >/dev/null 2>"$error_log" || rc=$?

    if [ "$rc" -ne 0 ]; then
        local reason hint
        if [ "$rc" -eq 124 ]; then
            reason="timed out after ${INSTALL_TIMEOUT}s"
        elif [ "$rc" -eq 137 ]; then
            reason="timed out after ${INSTALL_TIMEOUT}s and was force-killed after the grace period"
        else
            reason=$(head -n 1 "$error_log" 2>/dev/null || true)
        fi
        [ -n "$reason" ] || reason="no error output"
        persist_error_details "$app_name" "$error_log"
        hint=$(failure_hint "$app_name")
        [ -n "$hint" ] && reason="$reason — $hint"
        record_failure "$app_name" "$reason (exit $rc)"
        log "✗ Failed to install $app_name: $reason (exit $rc)"
        rm -f "$error_log"
        return 1
    fi

    # Exit code 0 is not enough: some installers (notably piped scripts)
    # can succeed without actually installing anything.
    if ! is_installed "$app_name"; then
        persist_error_details "$app_name" "$error_log"
        record_failure "$app_name" "installer exited 0 but $app_name was not found"
        log "✗ Failed to install $app_name: installer reported success but the package/binary was not found"
        rm -f "$error_log"
        return 1
    fi

    newly_installed+=("$app_name")
    log "✓ Successfully installed $app_name"
    rm -f "$error_log"
    return 0
}

install_app() {
    local app_name="$1"

    if is_installed "$app_name"; then
        log "✓ $app_name is already installed"
        already_installed+=("$app_name")
        return 0
    fi

    case "$PKG_MANAGER" in
        apt)
            handle_installation "$app_name" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$app_name"
            ;;
        dnf)
            handle_installation "$app_name" dnf install -y "$app_name"
            ;;
        pacman)
            handle_installation "$app_name" pacman -S --noconfirm "$app_name"
            ;;
        zypper)
            handle_installation "$app_name" zypper install -y "$app_name"
            ;;
        apk)
            handle_installation "$app_name" apk add "$app_name"
            ;;
    esac
}

update_package_lists() {
    log "Updating package lists..."
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would update package lists"
        return 0
    fi

    local rc=0
    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update </dev/null || rc=$?
            ;;
        dnf)
            dnf -q check-update </dev/null || rc=$?
            # dnf returns 100 when updates are available; that is not an error.
            [ "$rc" -eq 100 ] && rc=0
            ;;
        pacman)
            # Only refresh metadata here. A full upgrade belongs to the user.
            pacman -Sy --noconfirm </dev/null || rc=$?
            ;;
        zypper)
            zypper --non-interactive refresh </dev/null || rc=$?
            ;;
        apk)
            apk update </dev/null || rc=$?
            ;;
    esac

    if [ "$rc" -ne 0 ]; then
        log "✗ Failed to update package lists (exit $rc)"
        record_failure "package lists" "package manager update failed (exit $rc)"
    fi
    return "$rc"
}

install_mcfly() {
    log "Checking mcfly installation..."
    if is_installed "mcfly"; then
        log "✓ mcfly is already installed"
        already_installed+=("mcfly")
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would download and run the pinned mcfly installer"
        newly_installed+=("mcfly (dry-run)")
        return 0
    fi

    local installer="" url="https://raw.githubusercontent.com/cantino/mcfly/$MCFLY_VERSION/ci/install.sh"
    if ! installer=$(mktemp "${TMPDIR:-/tmp}/mcfly-install.XXXXXX"); then
        record_failure "mcfly" "could not create a temporary installer file"
        log "✗ Failed to install mcfly: could not create a temporary installer file"
        return 1
    fi
    TEMP_FILES+=("$installer")

    # Download first so a failed/partial transfer cannot be mistaken for a
    # successful install (the old `curl | sh` pipeline hid this).
    if ! run_with_timeout "$NETWORK_TIMEOUT" curl -LSfs -o "$installer" "$url"; then
        record_failure "mcfly" "failed to download installer from $url"
        log "✗ Failed to install mcfly: could not download $url"
        rm -f "$installer"
        return 1
    fi
    if [ ! -s "$installer" ]; then
        record_failure "mcfly" "downloaded installer was empty"
        log "✗ Failed to install mcfly: downloaded installer was empty"
        rm -f "$installer"
        return 1
    fi
    if [ -n "$MCFLY_INSTALL_SHA256" ]; then
        if ! echo "$MCFLY_INSTALL_SHA256  $installer" | sha256sum -c - >/dev/null 2>&1; then
            record_failure "mcfly" "installer checksum verification failed"
            log "✗ Failed to install mcfly: installer checksum verification failed"
            rm -f "$installer"
            return 1
        fi
    else
        log "Warning: MCFLY_INSTALL_SHA256 is not set; the downloaded installer is not checksum-verified."
    fi

    local rc=0
    handle_installation "mcfly" sh "$installer" --git cantino/mcfly --tag "$MCFLY_VERSION" || rc=$?
    rm -f "$installer"
    return "$rc"
}

install_nala() {
    [ "$PKG_MANAGER" = "apt" ] || return 0

    log "Checking nala installation..."
    if is_installed "nala"; then
        log "✓ nala is already installed"
        already_installed+=("nala")
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would attempt direct install of nala, falling back to the Volian repository if unavailable"
        newly_installed+=("nala (dry-run)")
        return 0
    fi

    # Try the standard repositories first, capturing stderr for diagnostics.
    local err="" rc=0
    if ! err=$(mktemp "${TMPDIR:-/tmp}/nala-install.XXXXXX"); then
        record_failure "nala" "could not create a temporary log file"
        log "✗ Failed to install nala: could not create a temporary log file"
        return 1
    fi
    TEMP_FILES+=("$err")

    run_with_timeout "$INSTALL_TIMEOUT" env DEBIAN_FRONTEND=noninteractive apt-get install -y nala >/dev/null 2>"$err" || rc=$?
    if [ "$rc" -eq 0 ] && is_installed "nala"; then
        newly_installed+=("nala")
        log "✓ Successfully installed nala from official repositories"
        rm -f "$err"
        return 0
    fi

    local reason
    reason=$(head -n 1 "$err" 2>/dev/null || true)
    [ -n "$reason" ] || reason="no error output"

    # A lock or network problem is not evidence that nala is missing from the
    # repositories, so do not add a third-party repo in that case.
    if grep -qiE 'could not get lock|unable to acquire|temporary failure resolving|network is unreachable|connection (failed|timed out)|could not resolve' "$err" 2>/dev/null; then
        persist_error_details "nala" "$err"
        record_failure "nala" "$reason (exit $rc)"
        log "✗ Failed to install nala: $reason (exit $rc)"
        rm -f "$err"
        return 1
    fi

    # Fall back to the Volian scar repository using a modern signed-by keyring.
    log "nala not in default repositories. Adding the Volian scar repository..."
    local keyring="/usr/share/keyrings/volian-archive-scar-unstable.gpg"
    local sources="/etc/apt/sources.list.d/volian-archive-scar-unstable.list"
    track_created_file "$keyring"
    track_created_file "$sources"

    local install_cmd="(curl -fsSL --max-time $NETWORK_TIMEOUT https://deb.volian.org/volian/scar.key | gpg --dearmor | tee $keyring > /dev/null && \
    [ -s $keyring ] && \
    echo 'deb [signed-by=$keyring] http://deb.volian.org/volian/ scar main' | tee $sources && \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nala)"

    if handle_installation "nala" sh -c "$install_cmd"; then
        ROLLBACK_FILES=()
        rm -f "$err"
        return 0
    fi
    rollback_created_files
    rm -f "$err"
    return 1
}

install_gping() {
    log "Checking gping installation..."
    if is_installed "gping"; then
        log "✓ gping is already installed"
        already_installed+=("gping")
        return 0
    fi

    if [ "$PKG_MANAGER" != "apt" ]; then
        # For others, it's just a package
        install_app "gping"
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would add the Azlux repository and install gping"
        newly_installed+=("gping (dry-run)")
        return 0
    fi

    # Detect the Debian/Ubuntu codename for the Azlux repository instead of
    # hardcoding one that only works on a single release.
    local codename=""
    if command -v lsb_release >/dev/null 2>&1; then
        codename=$(lsb_release -cs 2>/dev/null || true)
    fi
    if [ -z "$codename" ] && [ -r /etc/os-release ]; then
        codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
    fi
    if [ -z "$codename" ]; then
        record_failure "gping" "unable to detect the distribution codename for the Azlux repository"
        log "✗ Failed to install gping: unable to detect the distribution codename; not guessing a repository suite"
        return 1
    fi

    local keyring="/usr/share/keyrings/azlux.gpg"
    local sources="/etc/apt/sources.list.d/azlux.list"
    track_created_file "$keyring"
    track_created_file "$sources"

    local install_cmd="(DEBIAN_FRONTEND=noninteractive apt-get install -y gpg && \
    curl -fsSL --max-time $NETWORK_TIMEOUT https://azlux.fr/repo.gpg.key | gpg --dearmor | tee $keyring > /dev/null && \
    [ -s $keyring ] && \
    echo 'deb [signed-by=$keyring] https://packages.azlux.fr/debian/ $codename main' | tee $sources && \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y gping)"

    if handle_installation "gping" sh -c "$install_cmd"; then
        ROLLBACK_FILES=()
        return 0
    fi
    rollback_created_files
    return 1
}

print_summary() {
    echo -e "\n=== Installation Summary ===\n"
    echo "Already installed applications:"
    if [ ${#already_installed[@]} -eq 0 ]; then echo "None"; else printf '✓ %s\n' "${already_installed[@]}"; fi

    echo -e "\nNewly installed applications:"
    if [ ${#newly_installed[@]} -eq 0 ]; then echo "None"; else printf '✓ %s\n' "${newly_installed[@]}"; fi

    echo -e "\nFailed installations:"
    if [ ${#failed_apps[@]} -eq 0 ]; then echo "None"; else
        for i in "${!failed_apps[@]}"; do
            echo "✗ ${failed_apps[$i]}: ${failed_reasons[$i]}"
        done
    fi
}

resolve_user_home() {
    local user="$1"
    local home=""

    if command -v getent >/dev/null 2>&1; then
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    fi
    if [ -z "$home" ] && [ -r /etc/passwd ]; then
        home=$(awk -F: -v u="$user" '$1 == u { print $6; exit }' /etc/passwd)
    fi
    if [ -z "$home" ]; then
        home=$(eval echo "~$user" 2>/dev/null || true)
    fi
    printf '%s\n' "$home"
}

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

prune_bashrc_backups() {
    local dir="$1"
    local base="$2"
    local old count=0

    while IFS= read -r old; do
        [ -n "$old" ] || continue
        count=$((count + 1))
        if [ "$count" -gt "$MAX_BASHRC_BACKUPS" ]; then
            rm -f -- "$old"
        fi
    done <<< "$(find "$dir" -maxdepth 1 -type f -name "${base}_*" 2>/dev/null | sort -r)"
}

install_bashrc() {
    local script_dir bashrc_source
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    bashrc_source="$script_dir/bashrc"

    if [ ! -f "$bashrc_source" ]; then
        log "No bundled bashrc found at $bashrc_source; skipping shell configuration."
        return 0
    fi

    if ! resolve_target_account; then
        echo "Error: could not determine a valid home directory for the target user." >&2
        return 1
    fi
    local target_home="$TARGET_HOME" target_user="$TARGET_USER"

    local target_rc="$target_home/.bashrc"
    local write_target="$target_rc"

    # Follow an existing symlink (e.g. a dotfiles repo) instead of replacing
    # the link with a regular file.
    if [ -L "$target_rc" ]; then
        local resolved
        resolved=$(readlink -f "$target_rc" 2>/dev/null || true)
        if [ -z "$resolved" ] || [ ! -e "$resolved" ]; then
            echo "Error: $target_rc is a symlink that cannot be resolved safely." >&2
            return 1
        fi
        log "Note: $target_rc is a symlink; updating its target $resolved"
        write_target="$resolved"
    fi

    echo ""
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would offer to back up $write_target and copy $bashrc_source to it"
        return 0
    fi

    local answer=""
    if [ "$ASSUME_YES" = true ]; then
        answer="y"
        log "Applying .bashrc changes automatically (--yes)."
    else
        # Do not block unattended/non-interactive runs.
        if [ ! -t 0 ]; then
            log "Non-interactive session; skipping bashrc setup (use --yes to apply it)."
            return 0
        fi
        read -r -p "Back up your current .bashrc and install the new one? [y/N] " answer || answer=""
    fi

    case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *)
            log "Skipping bashrc installation."
            return 0
            ;;
    esac

    local backup_dir backup_base
    backup_dir=$(dirname "$write_target")
    backup_base=$(basename "$write_target")

    if [ -f "$write_target" ]; then
        local backup="${write_target}_$(date '+%Y%m%d-%H:%M')"
        # Avoid clobbering a backup made within the same minute.
        [ -e "$backup" ] && backup="${backup}-$(date '+%S')"

        if cp -p "$write_target" "$backup"; then
            log "✓ Backed up existing .bashrc to $backup"
        else
            echo "Error: failed to back up $write_target" >&2
            return 1
        fi
        prune_bashrc_backups "$backup_dir" "$backup_base"
    fi

    # Write to a temporary file and rename into place so an interrupt cannot
    # leave a truncated .bashrc behind.
    local tmp_rc=""
    if ! tmp_rc=$(mktemp "${write_target}.tmp.XXXXXX"); then
        echo "Error: failed to create a temporary file next to $write_target" >&2
        return 1
    fi
    TEMP_FILES+=("$tmp_rc")

    if ! cp "$bashrc_source" "$tmp_rc"; then
        rm -f "$tmp_rc"
        echo "Error: failed to copy $bashrc_source to a temporary file" >&2
        return 1
    fi
    if ! chmod 644 "$tmp_rc"; then
        rm -f "$tmp_rc"
        echo "Error: failed to set permissions on $tmp_rc" >&2
        return 1
    fi
    if [ -n "$target_user" ]; then
        if ! chown "$target_user": "$tmp_rc"; then
            rm -f "$tmp_rc"
            echo "Error: failed to set ownership of $tmp_rc to $target_user" >&2
            return 1
        fi
    fi
    if ! mv -f "$tmp_rc" "$write_target"; then
        rm -f "$tmp_rc"
        echo "Error: failed to install $write_target" >&2
        return 1
    fi

    log "✓ Installed new .bashrc to $target_rc"

    # Apply the new configuration to this session so the aliases and tool
    # initializers take effect immediately. Each new shell sources it anyway.
    # shellcheck disable=SC1090
    if . "$target_rc"; then
        log "✓ Applied new .bashrc to the current session"
    else
        echo "Warning: .bashrc was installed but could not be applied to this session." >&2
    fi
    echo "Existing shells can pick up the changes with 'source ~/.bashrc'."
    return 0
}

generate_cheatsheet() {
    if ! resolve_target_account; then
        echo "Error: could not determine a valid home directory for the target user." >&2
        return 1
    fi
    local target_home="$TARGET_HOME" target_user="$TARGET_USER"
    local cheatsheet_path="$target_home/$CHEATSHEET_FILE"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would write command cheatsheet to $cheatsheet_path"
        return 0
    fi

    local script_dir bashrc_source
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    bashrc_source="$script_dir/bashrc"

    # Evaluate aliases against an empty HOME so the bundled bashrc cannot
    # source (and execute as root) the target user's ~/.bash_aliases.
    local safe_home=""
    if [ -f "$bashrc_source" ]; then
        if safe_home=$(mktemp -d "${TMPDIR:-/tmp}/cheatsheet_home.XXXXXX"); then
            TEMP_DIRS+=("$safe_home")
        else
            safe_home=""
        fi
    fi

    local tmp=""
    if ! tmp=$(mktemp "$target_home/.command_cheatsheet.XXXXXX"); then
        echo "Error: could not create a temporary file in $target_home" >&2
        return 1
    fi
    TEMP_FILES+=("$tmp")

    local aliases="" alias_fallback=false
    if [ -f "$bashrc_source" ] && [ -n "$safe_home" ]; then
        aliases=$(HOME="$safe_home" bash --noprofile --norc -c \
            'source "$1" >/dev/null 2>&1 || exit 1; alias' _ "$bashrc_source" 2>/dev/null || true)
    fi
    if [ -z "$aliases" ] && [ -f "$bashrc_source" ]; then
        aliases=$(grep -E "^[[:space:]]*alias [A-Za-z0-9_]+=" "$bashrc_source" 2>/dev/null | sed -E 's/^[[:space:]]*alias //' || true)
        [ -n "$aliases" ] && alias_fallback=true
    fi

    {
        printf '%s\n' "${C_TITLE} COMMAND CHEATSHEET ${C_RESET}"
        printf 'Generated %s by install_base_apps.sh\n' "$(date '+%Y-%m-%d')"
        printf '%s\n\n' "${C_DIM}View: cat ~/${CHEATSHEET_FILE}    or: less -R ~/${CHEATSHEET_FILE}${C_RESET}"

        printf '%s\n' "${C_SECTION}COMMANDS INSTALLED BY THIS SCRIPT${C_RESET}"
        printf '%s\n\n' "${C_DIM}Basic usage only; see each command's man page for the full reference.${C_RESET}"

        local entry label probe summary ex1 ex2 probe_first probe_second
        for entry in "${cheatsheet_entries[@]}"; do
            IFS='|' read -r label probe summary ex1 ex2 <<< "$entry"
            probe_first="${probe%%/*}"
            probe_second=""
            [ "$probe" != "$probe_first" ] && probe_second="${probe#*/}"

            printf '%s%s%s  %s\n' "$C_CMD" "$label" "$C_RESET" "$summary"
            if ! command -v "$probe_first" >/dev/null 2>&1 &&
               { [ -z "$probe_second" ] || ! command -v "$probe_second" >/dev/null 2>&1; }; then
                printf '   %s(not installed)%s\n' "$C_DIM" "$C_RESET"
            fi
            printf '   %s$%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_EXAMPLE" "$ex1" "$C_RESET"
            [ -n "$ex2" ] && printf '   %s$%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_EXAMPLE" "$ex2" "$C_RESET"

            case "$label" in
                fd)
                    if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
                        printf '   %sDebian/Ubuntu binary: fdfind (bashrc defines alias fd)%s\n' "$C_DIM" "$C_RESET"
                    fi
                    ;;
                bat)
                    if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
                        printf '   %sDebian/Ubuntu binary: batcat (bashrc defines alias bat)%s\n' "$C_DIM" "$C_RESET"
                    fi
                    ;;
                eza)
                    printf '   %sThe bashrc alias ls uses eza when it is installed.%s\n' "$C_DIM" "$C_RESET"
                    ;;
                mcfly)
                    printf '   %sPrimary use: press Ctrl-R in an interactive shell.%s\n' "$C_DIM" "$C_RESET"
                    ;;
                nala)
                    if [ "${PKG_MANAGER:-}" != "apt" ]; then
                        printf '   %sAPT-only; skipped on non-APT systems.%s\n' "$C_DIM" "$C_RESET"
                    fi
                    ;;
            esac
            printf '\n'
        done

        printf '%s\n' "${C_SECTION}SHELL ALIASES (from bashrc)${C_RESET}"
        printf '%s\n' "${C_DIM}Effective aliases for this system; conditional aliases appear only when their tool is installed.${C_RESET}"
        if [ -f "$bashrc_source" ] && ! cmp -s "$bashrc_source" "$target_home/.bashrc" 2>/dev/null; then
            printf '%s\n' "${C_DIM}Note: install the bundled .bashrc (sudo bash install_base_apps.sh --yes) for these to take effect.${C_RESET}"
        fi
        printf '\n'

        if [ -n "$aliases" ]; then
            local line name value
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                line="${line#alias }"
                name="${line%%=*}"
                value="${line#*=}"
                value="${value#\'}"
                value="${value%\'}"
                # Strip control characters that could corrupt terminal output.
                value=$(printf '%s' "$value" | tr -d '\000-\010\013\014\016-\037\177' 2>/dev/null || printf '%s' "$value")
                printf '  %s%-8s%s %s\n' "$C_ALIAS" "$name" "$C_RESET" "$value"
            done <<< "$aliases"
            if [ "$alias_fallback" = true ]; then
                printf '\n%sNote: conditional aliases are listed without checking whether their tools are installed.%s\n' "$C_DIM" "$C_RESET"
            fi
        else
            printf '  %sNo aliases could be read from the bundled bashrc.%s\n' "$C_DIM" "$C_RESET"
        fi

        printf '\n%sRegenerate: sudo bash install_base_apps.sh%s\n' "$C_DIM" "$C_RESET"
    } > "$tmp"

    if ! chmod 644 "$tmp"; then
        rm -f "$tmp"
        echo "Error: failed to set permissions on $tmp" >&2
        return 1
    fi
    if [ -n "$target_user" ]; then
        if ! chown "$target_user": "$tmp"; then
            rm -f "$tmp"
            echo "Error: failed to set ownership of the cheatsheet to $target_user" >&2
            return 1
        fi
    fi
    if ! mv -f "$tmp" "$cheatsheet_path"; then
        rm -f "$tmp"
        echo "Error: failed to write $cheatsheet_path" >&2
        return 1
    fi

    log "✓ Wrote command cheatsheet to $cheatsheet_path"
    return 0
}

usage() {
    cat <<'EOF'
Usage: install_base_apps.sh [OPTIONS]

Installs the base application set and optionally installs the bundled bashrc.

Options:
  -n, --dry-run          Show what would be done without changing the system
  -y, --yes              Apply the bundled .bashrc without prompting
      --ignore-failures  Exit 0 even if some installations fail
  -h, --help             Show this help and exit
EOF
}

# Main Execution

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n)
            DRY_RUN=true
            ;;
        --yes|-y)
            ASSUME_YES=true
            ;;
        --ignore-failures)
            IGNORE_FAILURES=true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done
if [ $# -gt 0 ]; then
    echo "Error: unexpected argument: $1" >&2
    usage >&2
    exit 2
fi

if [ "$DRY_RUN" = true ]; then
    echo "Running in DRY-RUN mode. No changes will be made."
fi

# Check Root
if [ "$DRY_RUN" = false ] && [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

acquire_lock
check_connectivity
detect_package_manager
check_package_manager_lock

if ! update_package_lists; then
    if [ "$CONNECTIVITY_OK" = false ]; then
        echo "Error: no network connectivity and package lists could not be updated. Aborting." >&2
        exit 1
    fi
    log "Warning: continuing with cached package metadata."
fi

# Define apps list based on manager
case "$PKG_MANAGER" in
    apt|dnf)
        apps=("nano" "git" "curl" "wget" "htop" "tmux" "fd-find" "zoxide" "duf" "tree" "neomutt" "bat" "eza")
        ;;
    *)
        apps=("nano" "git" "curl" "wget" "htop" "tmux" "fd" "zoxide" "duf" "tree" "neomutt" "bat" "eza")
        ;;
esac

# Install Standard Apps
for app in "${apps[@]}"; do
    install_app "$app"
done

# Install Manual Apps
install_mcfly
install_nala
install_gping

print_summary

# Offer to apply the bundled bashrc
exit_code=0
install_bashrc || exit_code=1
generate_cheatsheet || exit_code=1

if [ ${#failed_apps[@]} -gt 0 ]; then
    if [ "$IGNORE_FAILURES" = true ]; then
        log "Warning: ${#failed_apps[@]} step(s) failed; ignoring due to --ignore-failures."
    else
        exit_code=1
    fi
fi

if [ "$exit_code" -ne 0 ]; then
    echo -e "\nOne or more steps failed. See $LOG_FILE for details." >&2
fi

exit "$exit_code"
