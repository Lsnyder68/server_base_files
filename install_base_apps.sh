#!/bin/bash

# Arrays to store installation results
declare -a already_installed=()
declare -a newly_installed=()
declare -a failed_apps=()
declare -a failed_reasons=()

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
    SUDO="sudo"
elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
else
    echo "Error: Neither apt nor apk package manager found"
    exit 1
fi

# Check for root privileges, as they are needed for installations
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi
# Function to check if an application is already installed
is_installed() {
    local app_name=$1
    if command -v "$app_name" >/dev/null 2>&1; then
        return 0
    elif [ "$PKG_MANAGER" = "apt" ] && dpkg -l | grep -q "^ii.*$app_name "; then
        return 0
    elif [ "$PKG_MANAGER" = "apk" ] && apk info -e "$app_name" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Generic function to handle an installation command and report status
handle_installation() {
    local app_name="$1"
    local install_command="$2"

    echo "Installing $app_name..."
    # Create a temporary file for stderr
    local error_log
    error_log=$(mktemp)

    if eval "$install_command" > /dev/null 2> "$error_log"; then
        newly_installed+=("$app_name")
        echo "✓ Successfully installed $app_name"
    else
        failed_apps+=("$app_name")
        failed_reasons+=("$(head -n 1 "$error_log")")
        echo "✗ Failed to install $app_name"
    fi
    # Clean up the temp file
    rm -f "$error_log"
}

# Function to install an application and track its status
install_app() {
    local app_name=$1
    
    if is_installed "$app_name"; then
        echo "✓ $app_name is already installed"
        already_installed+=("$app_name")
        return
    fi
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        handle_installation "$app_name" "DEBIAN_FRONTEND=noninteractive apt-get install -y \"$app_name\""
    else
        handle_installation "$app_name" "apk add \"$app_name\""
    fi
}

# Update package lists
echo "Updating package lists..."
if [ "$PKG_MANAGER" = "apt" ]; then
    apt-get update
else
    apk update
fi

# List of applications to install
if [ "$PKG_MANAGER" = "apt" ]; then
    apps=(
        "nano"
        "git"
        "curl"
        "wget"
        "htop"
        "tmux"
        "fd-find"
        "zoxide"
        "duf"
        "tree"
        "neomutt"
        "bat"
    )
else
    apps=(
        "nano"
        "git"
        "curl"
        "wget"
        "htop"
        "tmux"
        "fd"
        "zoxide"
        "duf"
        "tree"
        "neomutt"
        "bat"
    )
fi

# Install each application
for app in "${apps[@]}"; do
    install_app "$app"
done

# Print installation summary
echo -e "\n=== Installation Summary ===\n"

echo "Already installed applications:"
if [ ${#already_installed[@]} -eq 0 ]; then
    echo "None"
else
    printf '%s\n' "${already_installed[@]}" | sed 's/^/✓ /'
fi

echo -e "\nNewly installed applications:"
if [ ${#newly_installed[@]} -eq 0 ]; then
    echo "None"
else
    printf '%s\n' "${newly_installed[@]}" | sed 's/^/✓ /'
fi

echo -e "\nFailed installations:"
if [ ${#failed_apps[@]} -eq 0 ]; then
    echo "None"
else
    for i in "${!failed_apps[@]}"; do
        echo "✗ ${failed_apps[$i]}: ${failed_reasons[$i]}"
    done
fi

# Install mcfly manually
echo "Checking mcfly installation..."
if is_installed "mcfly"; then
    echo "✓ mcfly is already installed"
    already_installed+=("mcfly")
else
    install_cmd="curl -LSfs https://raw.githubusercontent.com/cantino/mcfly/master/ci/install.sh | sh -s -- --git cantino/mcfly"
    handle_installation "mcfly" "$install_cmd"
fi

# Install nala manually for apt systems
if [ "$PKG_MANAGER" = "apt" ]; then
    echo "Checking nala installation..."
    if is_installed "nala"; then
        echo "✓ nala is already installed"
        already_installed+=("nala")
    else
        install_cmd="(echo 'deb [arch=amd64,arm64,armhf] http://deb.volian.org/volian/ scar main' | tee /etc/apt/sources.list.d/volian-archive-scar-unstable.list && wget -qO - https://deb.volian.org/volian/scar.key | tee /etc/apt/trusted.gpg.d/volian-archive-scar-unstable.gpg && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y nala)"
        handle_installation "nala" "$install_cmd"
    fi
fi

# Install gping manually
echo "Checking gping installation..."
if is_installed "gping"; then
    echo "✓ gping is already installed"
    already_installed+=("gping")
else
    if [ "$PKG_MANAGER" = "apt" ]; then
        install_cmd="(echo 'deb [signed-by=/usr/share/keyrings/azlux.gpg] https://packages.azlux.fr/debian/ bookworm main' | tee /etc/apt/sources.list.d/azlux.list && DEBIAN_FRONTEND=noninteractive apt-get install -y gpg && curl -s https://azlux.fr/repo.gpg.key | gpg --dearmor | tee /usr/share/keyrings/azlux.gpg > /dev/null && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y gping)"
        handle_installation "gping" "$install_cmd"
    else
        handle_installation "gping" "apk add gping"
    fi
fi