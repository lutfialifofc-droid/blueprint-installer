#!/usr/bin/env bash
# ==============================================================================
# Blueprint Auto-Installer for Pterodactyl Panel
# Based on official documentation: https://blueprint.zip/guides/admin/install
# ==============================================================================

set -eo pipefail

# Text formatting & Colors
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${CYAN}${BOLD}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}${BOLD}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}${BOLD}[ERROR]${NC} $1" >&2
}

# ------------------------------------------------------------------------------
# 1. Pre-flight Checks (Root & Environment)
# ------------------------------------------------------------------------------
echo -e "${CYAN}${BOLD}"
cat << 'EOF'
 ____  _                             _       _   
| __ )| |_   _  ___ _ __  _ __ _ __ (_)_ __ | |_ 
|  _ \| | | | |/ _ \ '_ \| '__| '_ \| | '_ \| __|
| |_) | | |_| |  __/ |_) | |  | |_) | | | | | |_ 
|____/|_|\__,_|\___| .__/|_|  | .__/|_|_| |_|\__|
                   |_|        |_|                
        Pterodactyl Extension Framework Installer
EOF
echo -e "${NC}"

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root. Please run with 'sudo bash $0'"
    exit 1
fi

# Detect package manager
if ! command -v apt-get &>/dev/null; then
    log_error "This auto-installer currently supports Debian/Ubuntu systems with 'apt'. Please install manually on other distributions."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Determine Pterodactyl Directory (Step 1 in official guide)
# ------------------------------------------------------------------------------
PTERODACTYL_DIRECTORY="${PTERODACTYL_DIRECTORY:-/var/www/pterodactyl}"

if [ ! -d "$PTERODACTYL_DIRECTORY" ] || [ ! -f "$PTERODACTYL_DIRECTORY/artisan" ]; then
    log_warning "Pterodactyl panel was not found at default location: $PTERODACTYL_DIRECTORY"
    read -rp "Please enter your Pterodactyl installation path: " USER_INPUT_PATH
    PTERODACTYL_DIRECTORY="${USER_INPUT_PATH:-$PTERODACTYL_DIRECTORY}"

    if [ ! -d "$PTERODACTYL_DIRECTORY" ] || [ ! -f "$PTERODACTYL_DIRECTORY/artisan" ]; then
        log_error "Valid Pterodactyl installation (artisan file) not found in '$PTERODACTYL_DIRECTORY'. Aborting."
        exit 1
    fi
fi

log_info "Pterodactyl Directory: ${BOLD}$PTERODACTYL_DIRECTORY${NC}"

# Detect Web User and Group
if id "www-data" &>/dev/null; then
    WEBUSER="www-data"
    OWNERSHIP="www-data:www-data"
elif id "nginx" &>/dev/null; then
    WEBUSER="nginx"
    OWNERSHIP="nginx:nginx"
else
    WEBUSER="www-data"
    OWNERSHIP="www-data:www-data"
fi

USERSHELL="${USERSHELL:-/bin/bash}"
log_info "Detected Web User: ${BOLD}$WEBUSER${NC} (Ownership: $OWNERSHIP)"

# ------------------------------------------------------------------------------
# 3. Install System Dependencies (Step 2 & 3 in official guide)
# ------------------------------------------------------------------------------
log_info "Updating package lists and installing core dependencies..."
apt-get update -qq
apt-get install -y -qq \
    ca-certificates \
    curl \
    git \
    gnupg \
    unzip \
    wget \
    zip

log_success "Core system packages installed."

# ------------------------------------------------------------------------------
# 4. Set Up Node.js 22.x & Yarn (Step 3 in official guide)
# ------------------------------------------------------------------------------
NEED_NODE_INSTALL=true
if command -v node &>/dev/null; then
    CURRENT_NODE_VERSION=$(node -v | tr -d 'v' | cut -d'.' -f1)
    if [ "$CURRENT_NODE_VERSION" -ge 20 ]; then
        log_info "Node.js $(node -v) is already installed."
        NEED_NODE_INSTALL=false
    fi
fi

if [ "$NEED_NODE_INSTALL" = true ]; then
    log_info "Configuring NodeSource official repository (Node.js 22.x)..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
        gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg

    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | \
        tee /etc/apt/sources.list.d/nodesource.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq nodejs
    log_success "Node.js $(node -v) installed successfully."
fi

# Install Yarn globally
if ! command -v yarn &>/dev/null; then
    log_info "Installing Yarn globally via npm..."
    npm i -g yarn --silent
    log_success "Yarn $(yarn -v) installed."
else
    log_info "Yarn is already installed ($(yarn -v))."
fi

# ------------------------------------------------------------------------------
# 5. Download and Extract Latest Blueprint Release (Step 2 in official guide)
# ------------------------------------------------------------------------------
log_info "Navigating to $PTERODACTYL_DIRECTORY..."
cd "$PTERODACTYL_DIRECTORY"

LATEST_RELEASE_URL="https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip"
log_info "Downloading latest Blueprint release from GitHub..."
wget -q --show-progress "$LATEST_RELEASE_URL" -O "$PTERODACTYL_DIRECTORY/release.zip"

log_info "Extracting Blueprint files..."
unzip -q -o "$PTERODACTYL_DIRECTORY/release.zip" -d "$PTERODACTYL_DIRECTORY"
rm -f "$PTERODACTYL_DIRECTORY/release.zip"
log_success "Blueprint files extracted."

# ------------------------------------------------------------------------------
# 6. Install Project Dependencies with Yarn (Step 3 in official guide)
# ------------------------------------------------------------------------------
log_info "Running 'yarn install' in Pterodactyl directory (this may take a minute)..."
cd "$PTERODACTYL_DIRECTORY"
yarn install --production=false

log_success "Yarn dependencies installed."

# ------------------------------------------------------------------------------
# 7. Configure .blueprintrc (Step 4 in official guide)
# ------------------------------------------------------------------------------
log_info "Configuring .blueprintrc..."
cat << EOF > "$PTERODACTYL_DIRECTORY/.blueprintrc"
WEBUSER="${WEBUSER}";
OWNERSHIP="${OWNERSHIP}";
USERSHELL="${USERSHELL}";
EOF

log_success ".blueprintrc configuration created."

# ------------------------------------------------------------------------------
# 8. Set Permissions & Run Blueprint Initializer (Step 5 in official guide)
# ------------------------------------------------------------------------------
log_info "Setting script execution permissions..."
chmod +x "$PTERODACTYL_DIRECTORY/blueprint.sh"

# Ensure global symlink exists for running 'blueprint' directly from any folder
if [ ! -L /usr/local/bin/blueprint ] && [ ! -f /usr/local/bin/blueprint ]; then
    ln -s "$PTERODACTYL_DIRECTORY/blueprint.sh" /usr/local/bin/blueprint
    chmod +x /usr/local/bin/blueprint
fi

# Fix ownership before initializing
chown -R "$OWNERSHIP" "$PTERODACTYL_DIRECTORY"

log_info "Executing blueprint.sh to complete installation..."
cd "$PTERODACTYL_DIRECTORY"
bash "$PTERODACTYL_DIRECTORY/blueprint.sh"

# Fix ownership post-build
chown -R "$OWNERSHIP" "$PTERODACTYL_DIRECTORY"

# ------------------------------------------------------------------------------
# 9. Summary & Finish
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo -e "${GREEN}${BOLD}             Blueprint Framework Installed Successfully!                      ${NC}"
echo -e "${GREEN}${BOLD}==============================================================================${NC}"
echo ""
echo -e "Next steps:"
echo -e " 1. Access your Pterodactyl Panel at: ${CYAN}https://your-panel-domain/admin/extensions${NC}"
echo -e " 2. To install extensions in the future, upload the ${BOLD}.blueprint${NC} file to"
echo -e "    ${CYAN}$PTERODACTYL_DIRECTORY${NC} and run:"
echo -e "    ${BOLD}blueprint -install <extension-name>.blueprint${NC}"
echo -e " 3. You can run Blueprint commands from anywhere using: ${BOLD}blueprint --help${NC}"
echo ""
