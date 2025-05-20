#!/bin/bash

# Arrays to store installation results
declare -a installed_apps=()
declare -a failed_apps=()
declare -a failed_reasons=()

# Function to check if an application is already installed
is_installed() {
    local app_name=$1
    if command -v "$app_name" >/dev/null 2>&1; then
        return 0
    elif dpkg -l | grep -q "^ii.*$app_name "; then
        return 0
    else
        return 1
    fi
}

# Function to install an application and track its status
install_app() {
    local app_name=$1
    
    if is_installed "$app_name"; then
        echo "✓ $app_name is already installed"
        installed_apps+=("$app_name")
        return
    fi
    
    echo "Installing $app_name..."
    
    # Try to install the package
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$app_name" > /dev/null 2> /tmp/install_error.log; then
        installed_apps+=("$app_name")
        echo "✓ Successfully installed $app_name"
    else
        failed_apps+=("$app_name")
        failed_reasons+=("$(cat /tmp/install_error.log | head -n 1)")
        echo "✗ Failed to install $app_name"
    fi
}

# Update package lists
echo "Updating package lists..."
apt-get update

# List of applications to install
apps=(
    "nano"
    "git"
    "curl"
    "wget"
    "htop"
    "tmux"
    "nala"
    "fd-find"
    "zoxide"
    "duf"
    "tree"
    "gping"    
)

# Install each application
for app in "${apps[@]}"; do
    install_app "$app"
done

# Print installation summary
echo -e "\n=== Installation Summary ===\n"

echo "Successfully installed applications:"
if [ ${#installed_apps[@]} -eq 0 ]; then
    echo "None"
else
    printf '%s\n' "${installed_apps[@]}" | sed 's/^/✓ /'
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
    installed_apps+=("mcfly")
else
    echo "Installing mcfly..."
    if curl -LSfs https://raw.githubusercontent.com/cantino/mcfly/master/ci/install.sh | sh -s -- --git cantino/mcfly > /dev/null 2> /tmp/install_error.log; then
        installed_apps+=("mcfly")
        echo "✓ Successfully installed mcfly"
    else
        failed_apps+=("mcfly")
        failed_reasons+=("$(cat /tmp/install_error.log | head -n 1)")
        echo "✗ Failed to install mcfly"
    fi
fi

# Cleanup
rm -f /tmp/install_error.log