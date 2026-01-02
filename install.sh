#!/usr/bin/env bash
# TPM - Termux Package Manager
# Bootstrap installer
# Version: 0.1.0

set -euo pipefail

# Colors for output (only if terminal supports it)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# Configuration
TPM_VERSION="0.1.0"
TPM_REPO="https://raw.githubusercontent.com/x49dev/tpm"
TPM_BRANCH="main"

# Default paths (Termux specific)
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TPM_BIN_DIR="${PREFIX}/bin"
TPM_LIB_DIR="${PREFIX}/lib/tpm"
TPM_STORE_DIR="${PREFIX}/tpm/store"
TPM_TMP_DIR="${PREFIX}/tpm/tmp"
TPM_MANIFEST_DIR="${HOME}/.tpm"
TPM_MANIFEST_FILE="${TPM_MANIFEST_DIR}/manifest"

# Installation tracking for rollback
INSTALL_LOG=""
ROLLBACK_STEPS=()

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Cleanup function for interrupted installation
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Installation failed. Rolling back..."
        # Execute rollback steps in reverse order
        for (( idx=${#ROLLBACK_STEPS[@]}-1 ; idx>=0 ; idx-- )); do
            eval "${ROLLBACK_STEPS[idx]}" 2>/dev/null || true
        done
        log_warn "Rollback completed. You can retry installation."
    fi
    exit $exit_code
}

# Register cleanup trap
trap cleanup EXIT INT TERM

# Add rollback step
add_rollback() {
    ROLLBACK_STEPS+=("$1")
}

# Validation functions
validate_termux() {
    if [[ ! -d "${PREFIX}" ]]; then
        log_error "Termux installation not detected."
        log_error "Expected PREFIX at: ${PREFIX}"
        log_error "Make sure Termux is properly installed."
        exit 1
    fi
    
    if [[ ! -w "${PREFIX}" ]]; then
        log_error "Cannot write to Termux directory: ${PREFIX}"
        log_error "Check permissions or run termux-setup-storage"
        exit 1
    fi
}

validate_bash_version() {
    local bash_version
    bash_version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    local major minor patch
    IFS='.' read -r major minor patch <<< "$bash_version"
    
    if [[ $major -lt 5 ]] || { [[ $major -eq 5 ]] && [[ $minor -lt 1 ]]; }; then
        log_error "Bash 5.1+ required. Found: ${bash_version}"
        log_error "Update Termux packages: pkg upgrade"
        exit 1
    fi
    log_info "Bash version: ${bash_version}"
}

validate_dependencies() {
    local deps=("curl" "grep" "sed" "awk" "tar" "gzip")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_error "Install with: pkg install ${missing[*]}"
        exit 1
    fi
    
    # Check for unzip (optional for .zip support)
    if ! command -v unzip >/dev/null 2>&1; then
        log_warn "unzip not found. .zip archives will not be supported."
        log_warn "Install with: pkg install unzip"
    fi
}

detect_architecture() {
    local arch
    if [[ -n "${TERMUX_ARCH:-}" ]]; then
        arch="${TERMUX_ARCH}"
    else
        arch=$(uname -m)
    fi
    
    # Map to standard architectures
    case "$arch" in
        aarch64|arm64)      echo "arm64" ;;
        armv7l|arm|armhf)   echo "arm" ;;
        i686|x86)           echo "i686" ;;
        x86_64)             echo "x86_64" ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            log_error "Supported: aarch64, arm, i686, x86_64"
            exit 1
            ;;
    esac
}

# Create directory structure
create_directories() {
    log_info "Creating directory structure..."
    
    local dirs=(
        "${TPM_BIN_DIR}"
        "${TPM_LIB_DIR}"
        "${TPM_STORE_DIR}"
        "${TPM_TMP_DIR}"
        "${TPM_MANIFEST_DIR}"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            add_rollback "rmdir '$dir' 2>/dev/null || true"
            log_info "  Created: $dir"
        else
            log_info "  Exists: $dir"
        fi
    done
    
    # Create lock file directory
    mkdir -p "${TPM_TMP_DIR}/locks"
}

# Download TPM files
download_tpm() {
    local files=(
        "tpm"
        "lib/core.sh"
        "lib/manifest.sh"
        "lib/transaction.sh"
        "lib/github.sh"
        "lib/store.sh"
    )
    
    log_info "Downloading TPM files..."
    
    for file in "${files[@]}"; do
        local url="${TPM_REPO}/${TPM_BRANCH}/${file}"
        local dest_dir
        local dest_file
        
        if [[ "$file" == "tpm" ]]; then
            dest_dir="${TPM_BIN_DIR}"
            dest_file="${TPM_BIN_DIR}/tpm"
        else
            dest_dir="${TPM_LIB_DIR}/$(dirname "${file#lib/}")"
            dest_file="${TPM_LIB_DIR}/${file#lib/}"
            mkdir -p "$dest_dir"
        fi
        
        log_info "  Downloading: $file"
        
        if ! curl -sSfL --retry 2 --retry-delay 1 "$url" -o "$dest_file.tmp"; then
            log_error "Failed to download: $url"
            exit 1
        fi
        
        # Validate it's a bash script (basic check)
        if [[ "$file" == *.sh ]] || [[ "$file" == "tpm" ]]; then
            if ! head -n1 "$dest_file.tmp" | grep -q "^#\!/usr/bin/env bash"; then
                log_error "Invalid file format: $file"
                rm -f "$dest_file.tmp"
                exit 1
            fi
        fi
        
        # Move to final location
        mv "$dest_file.tmp" "$dest_file"
        chmod +x "$dest_file"
        
        add_rollback "rm -f '$dest_file'"
        
        # For main executable, also create rollback for symlink
        if [[ "$file" == "tpm" ]]; then
            add_rollback "rm -f '${TPM_BIN_DIR}/tpm'"
        fi
    done
}

# Create configuration file
create_config() {
    local config_file="${TPM_MANIFEST_DIR}/config"
    
    cat > "$config_file" <<EOF
# TPM Configuration
# Generated: $(date -Iseconds)
# Version: ${TPM_VERSION}

# Core paths (do not modify unless you know what you're doing)
TPM_VERSION="${TPM_VERSION}"
TPM_BIN_DIR="${TPM_BIN_DIR}"
TPM_LIB_DIR="${TPM_LIB_DIR}"
TPM_STORE_DIR="${TPM_STORE_DIR}"
TPM_TMP_DIR="${TPM_TMP_DIR}"
TPM_MANIFEST_FILE="${TPM_MANIFEST_FILE}"

# Environment overrides (uncomment and modify as needed)
# export TPM_STORE_DIR="\${PREFIX}/tpm/store"
# export TPM_TMP_DIR="\${PREFIX}/tpm/tmp"
# export TPM_MANIFEST_FILE="\${HOME}/.tpm/manifest"

# Network settings
TPM_CURL_TIMEOUT=30
TPM_MAX_RETRIES=2

# Display settings
TPM_COLOR=auto  # auto, always, never

# Architecture (auto-detected)
TPM_ARCH=$(detect_architecture)
EOF
    
    chmod 644 "$config_file"
    add_rollback "rm -f '$config_file'"
    log_info "Created configuration: $config_file"
}

# Create initial manifest file
create_manifest() {
    if [[ ! -f "${TPM_MANIFEST_FILE}" ]]; then
        cat > "${TPM_MANIFEST_FILE}" <<EOF
# TPM Manifest
# Format: tool_id|version|binary_name|store_path|symlink_path|installed_at|checksum|files
# Each tool is stored as a block separated by "---"
# Do not edit manually unless you know what you're doing

EOF
        chmod 600 "${TPM_MANIFEST_FILE}"
        log_info "Created manifest file: ${TPM_MANIFEST_FILE}"
    fi
}

# Create uninstall script
create_uninstaller() {
    local uninstaller="${TPM_MANIFEST_DIR}/uninstall.sh"
    
    cat > "$uninstaller" <<'EOF'
#!/usr/bin/env bash
# TPM Uninstaller

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TPM_BIN_DIR="${PREFIX}/bin"
TPM_LIB_DIR="${PREFIX}/lib/tpm"
TPM_STORE_DIR="${PREFIX}/tpm"
TPM_MANIFEST_DIR="${HOME}/.tpm"

echo "This will remove TPM and all installed tools."
read -p "Are you sure? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo "Removing TPM..."
rm -f "${TPM_BIN_DIR}/tpm"
rm -rf "${TPM_LIB_DIR}"
rm -rf "${TPM_STORE_DIR}"

echo "Remove configuration and manifest? (This will remove record of installed tools)"
read -p "[y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "${TPM_MANIFEST_DIR}"
    echo "Configuration removed."
else
    echo "Configuration preserved at: ${TPM_MANIFEST_DIR}"
fi

echo "TPM has been uninstalled."
EOF
    
    chmod +x "$uninstaller"
    add_rollback "rm -f '$uninstaller'"
    log_info "Created uninstaller: $uninstaller"
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Check main executable
    if [[ ! -x "${TPM_BIN_DIR}/tpm" ]]; then
        log_error "Main executable not found"
        return 1
    fi
    
    # Check libraries
    local libs=("core.sh" "manifest.sh" "transaction.sh" "github.sh" "store.sh")
    for lib in "${libs[@]}"; do
        if [[ ! -f "${TPM_LIB_DIR}/${lib}" ]]; then
            log_error "Missing library: ${lib}"
            return 1
        fi
    done
    
    # Test version command
    if "${TPM_BIN_DIR}/tpm" --version 2>&1 | grep -q "${TPM_VERSION}"; then
        log_success "TPM installed successfully"
    else
        log_error "Version check failed"
        return 1
    fi
}

# Main installation flow
main() {
    echo "========================================"
    echo "TPM - Termux Package Manager"
    echo "Version: ${TPM_VERSION}"
    echo "========================================"
    echo ""
    
    # Validation phase
    log_info "Validating environment..."
    validate_termux
    validate_bash_version
    validate_dependencies
    
    local arch
    arch=$(detect_architecture)
    log_info "Architecture: ${arch}"
    
    # Installation phase
    create_directories
    download_tpm
    create_config
    create_manifest
    create_uninstaller
    
    # Verification phase
    if verify_installation; then
        echo ""
        echo "========================================"
        log_success "Installation complete!"
        echo ""
        echo "Usage:"
        echo "  tpm --help              Show help"
        echo "  tpm --version           Show version"
        echo ""
        echo "Next steps:"
        echo "  tpm install sharkdp/bat  Install a tool"
        echo "  tpm list                 List installed tools"
        echo ""
        echo "Configuration:"
        echo "  Edit: ~/.tpm/config"
        echo "  Uninstall: ~/.tpm/uninstall.sh"
        echo "========================================"
    else
        log_error "Installation verification failed"
        exit 1
    fi
}

# Only run main if script is executed, not sourced
# Handle cases where BASH_SOURCE might not be available
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    main "$@"
fi