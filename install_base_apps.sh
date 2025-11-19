#!/bin/bash

# Constants & Globals
LOG_FILE="/var/log/install_base_apps_$(date +%F).log"
DRY_RUN=false
PKG_MANAGER=""
SUDO=""

# Arrays to store installation results
declare -a already_installed=()
declare -a newly_installed=()
declare -a failed_apps=()
declare -a failed_reasons=()

# Helper Functions

log() {
    local message="$1"
    echo "$message"
    # Only log to file if not dry run and we have permissions (simple check)
    if [ "$DRY_RUN" = false ] && [ -w "$(dirname "$LOG_FILE")" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
    fi
}

cleanup() {
    if [ -n "$error_log" ] && [ -f "$error_log" ]; then
        rm -f "$error_log"
    fi
}
trap cleanup EXIT

check_connectivity() {
    log "Checking network connectivity..."
    if ! ping -c 1 google.com >/dev/null 2>&1; then
        echo "Error: No internet connectivity." >&2
        exit 1
    fi
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        SUDO="sudo"
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

is_installed() {
    local app_name=$1
    if command -v "$app_name" >/dev/null 2>&1; then
        return 0
    elif [ "$PKG_MANAGER" = "apt" ] && dpkg -l | grep -q "^ii.*$app_name "; then
        return 0
    elif [ "$PKG_MANAGER" = "dnf" ] && dnf list installed "$app_name" >/dev/null 2>&1; then
        return 0
    elif [ "$PKG_MANAGER" = "pacman" ] && pacman -Qi "$app_name" >/dev/null 2>&1; then
        return 0
    elif [ "$PKG_MANAGER" = "zypper" ] && zypper search -i --match-exact "$app_name" >/dev/null 2>&1; then
        return 0
    elif [ "$PKG_MANAGER" = "apk" ] && apk info -e "$app_name" >/dev/null 2>&1; then
        return 0
    else
        return 1
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
    error_log=$(mktemp)

    if "${install_cmd[@]}" > /dev/null 2> "$error_log"; then
        newly_installed+=("$app_name")
        log "✓ Successfully installed $app_name"
    else
        failed_apps+=("$app_name")
        local reason
        reason=$(head -n 1 "$error_log")
        failed_reasons+=("$reason")
        log "✗ Failed to install $app_name: $reason"
    fi
    # Clean up the temp file (trap handles it too, but good to do it early)
    rm -f "$error_log"
}

install_app() {
    local app_name=$1
    
    if is_installed "$app_name"; then
        log "✓ $app_name is already installed"
        already_installed+=("$app_name")
        return
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
        return
    fi

    case "$PKG_MANAGER" in
        apt) apt-get update ;;
        dnf) dnf check-update ;;
        pacman) pacman -Sy ;;
        zypper) zypper refresh ;;
        apk) apk update ;;
    esac
}

install_mcfly() {
    log "Checking mcfly installation..."
    if is_installed "mcfly"; then
        log "✓ mcfly is already installed"
        already_installed+=("mcfly")
        return
    fi

    # McFly install script
    if [ "$DRY_RUN" = true ]; then
         echo "[DRY RUN] Would install mcfly via curl script"
         newly_installed+=("mcfly (dry-run)")
         return
    fi
    
    local install_cmd="curl -LSfs https://raw.githubusercontent.com/cantino/mcfly/master/ci/install.sh | sh -s -- --git cantino/mcfly"
    
    # handle_installation expects an array/command. Since this is a pipeline, we run it via sh -c
    handle_installation "mcfly" sh -c "$install_cmd"
}

install_nala() {
    [ "$PKG_MANAGER" != "apt" ] && return

    log "Checking nala installation..."
    if is_installed "nala"; then
        log "✓ nala is already installed"
        already_installed+=("nala")
        return
    fi

    local install_cmd="(echo 'deb [arch=amd64,arm64,armhf] http://deb.volian.org/volian/ scar main' | tee /etc/apt/sources.list.d/volian-archive-scar-unstable.list && wget -qO - https://deb.volian.org/volian/scar.key | tee /etc/apt/trusted.gpg.d/volian-archive-scar-unstable.gpg && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nala)"
    
    handle_installation "nala" sh -c "$install_cmd"
}

install_gping() {
    log "Checking gping installation..."
    if is_installed "gping"; then
        log "✓ gping is already installed"
        already_installed+=("gping")
        return
    fi

    if [ "$PKG_MANAGER" = "apt" ]; then
        local install_cmd="(echo 'deb [signed-by=/usr/share/keyrings/azlux.gpg] https://packages.azlux.fr/debian/ bookworm main' | tee /etc/apt/sources.list.d/azlux.list && DEBIAN_FRONTEND=noninteractive apt-get install -y gpg && curl -s https://azlux.fr/repo.gpg.key | gpg --dearmor | tee /usr/share/keyrings/azlux.gpg > /dev/null && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y gping)"
        handle_installation "gping" sh -c "$install_cmd"
    else
        # For others, it's just a package
        install_app "gping"
    fi
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

# Main Execution

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            echo "Running in DRY-RUN mode. No changes will be made."
            ;;
    esac
done

# Check Root
if [ "$DRY_RUN" = false ] && [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

check_connectivity
detect_package_manager
update_package_lists

# Define apps list based on manager
case "$PKG_MANAGER" in
    apt|dnf)
        apps=("nano" "git" "curl" "wget" "htop" "tmux" "fd-find" "zoxide" "duf" "tree" "neomutt" "bat")
        ;;
    *)
        apps=("nano" "git" "curl" "wget" "htop" "tmux" "fd" "zoxide" "duf" "tree" "neomutt" "bat")
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