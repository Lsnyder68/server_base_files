#!/bin/bash

# Arrays to store installation results
declare -a already_installed=()
declare -a newly_installed=()
declare -a failed_apps=()
declare -a failed_reasons=()

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
else
    echo "Error: Neither apt nor apk package manager found"
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

# Function to install an application and track its status
install_app() {
    local app_name=$1
    
    if is_installed "$app_name"; then
        echo "✓ $app_name is already installed"
        already_installed+=("$app_name")
        return
    fi
    
    echo "Installing $app_name..."
    
    # Try to install the package
    if [ "$PKG_MANAGER" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$app_name" > /dev/null 2> /tmp/install_error.log
    else
        apk add "$app_name" > /dev/null 2> /tmp/install_error.log
    fi
    
    if [ $? -eq 0 ]; then
        newly_installed+=("$app_name")
        echo "✓ Successfully installed $app_name"
    else
        failed_apps+=("$app_name")
        failed_reasons+=("$(cat /tmp/install_error.log | head -n 1)")
        echo "✗ Failed to install $app_name"
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
        "nala"
        "fd-find"
        "zoxide"
        "duf"
        "tree"
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
    echo "Installing mcfly..."
    if curl -LSfs https://raw.githubusercontent.com/cantino/mcfly/master/ci/install.sh | sh -s -- --git cantino/mcfly > /dev/null 2> /tmp/install_error.log; then
        newly_installed+=("mcfly")
        echo "✓ Successfully installed mcfly"
    else
        failed_apps+=("mcfly")
        failed_reasons+=("$(cat /tmp/install_error.log | head -n 1)")
        echo "✗ Failed to install mcfly"
    fi
fi

# Install gping manually
echo "Checking gping installation..."
if is_installed "gping"; then
    echo "✓ gping is already installed"
    already_installed+=("gping")
else
    echo "Installing gping..."
    if [ "$PKG_MANAGER" = "apt" ]; then
        # Install gping for Debian/Ubuntu
        if (echo 'deb [signed-by=/usr/share/keyrings/azlux.gpg] https://packages.azlux.fr/debian/ bookworm main' | sudo tee /etc/apt/sources.list.d/azlux.list && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y gpg && \
            curl -s https://azlux.fr/repo.gpg.key | gpg --dearmor | sudo tee /usr/share/keyrings/azlux.gpg > /dev/null && \
            apt-get update && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y gping) > /dev/null 2> /tmp/install_error.log; then
            newly_installed+=("gping")
            echo "✓ Successfully installed gping"
        else
            failed_apps+=("gping")
            failed_reasons+=("$(cat /tmp/install_error.log | head -n 1)")
            echo "✗ Failed to install gping"
        fi
    else
        # Install gping for Alpine
        if apk add gping > /dev/null 2> /tmp/install_error.log; then
            newly_installed+=("gping")
            echo "✓ Successfully installed gping"
        else
            failed_apps+=("gping")
            failed_reasons+=("$(cat /tmp/install_error.log | head -n 1)")
            echo "✗ Failed to install gping"
        fi
    fi
fi

# Cleanup
rm -f /tmp/install_error.log