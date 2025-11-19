# Script Documentation: `install_base_apps.sh`

## Overview
This bash script is designed to automate the installation of a set of base applications on Linux systems. It supports systems using either `apt` (Debian/Ubuntu-based) or `apk` (Alpine-based) package managers. The script ensures necessary tools are available, handles installation errors gracefully, and provides a summary of actions taken.

## Prerequisites
- **Root Privileges**: The script must be run as root (e.g., using `sudo`). It checks for this at the beginning and exits if not running as root.
- **Supported Package Manager**: The system must have either `apt-get` or `apk` installed.

## Workflow

1.  **Initialization**:
    - Initializes arrays to track installation results: `already_installed`, `newly_installed`, `failed_apps`, and `failed_reasons`.
    - Detects the package manager (`apt` or `apk`) and sets the `PKG_MANAGER` variable.
    - Verifies root privileges.

2.  **Helper Functions**:
    - `is_installed`: Checks if an application is already present on the system using `command -v`, `dpkg`, or `apk info`.
    - `handle_installation`: Executes the installation command, captures stderr to a temporary log, and updates the status arrays based on success or failure.
    - `install_app`: High-level function that checks if an app is installed and, if not, calls `handle_installation` with the appropriate command for the detected package manager.

3.  **Package List Update**:
    - Runs `apt-get update` or `apk update` to ensure the package lists are current.

4.  **Standard Application Installation**:
    - Iterates through a predefined list of applications and installs them using `install_app`.
    - **Common Apps**: `nano`, `git`, `curl`, `wget`, `htop`, `tmux`, `zoxide`, `duf`, `tree`, `neomutt`, `bat`.
    - **Differences**: `fd-find` is used for `apt`, while `fd` is used for `apk`.

5.  **Manual Installations**:
    - **mcfly**: Installs via a curl script from GitHub.
    - **nala**: (Only for `apt` systems) Installs from the Volian repository.
    - **gping**: Installs from the Azlux repository for `apt` systems, or via `apk add` for Alpine.

6.  **Summary**:
    - Prints a detailed summary of:
        - Already installed applications.
        - Newly installed applications.
        - Failed installations (including error messages).

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
| **mcfly** | Shell history search replacement | Manual (Shell Script) |
| **nala** | Frontend for `apt` | Manual (Repo Add + Apt) |
| **gping** | Ping with a graph | Manual (Repo Add + Apt) / Apk |

## Error Handling
- The script captures standard error output for failed installations.
- It does not stop on individual package failures but continues to try installing others.
- A summary of failures and their reasons is displayed at the end.
