#!/usr/bin/env bash
# TPM Core Utilities
# Version: 0.1.0

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration Loading
# ------------------------------------------------------------------------------

# Load TPM configuration
load_config() {
    local config_file="${TPM_MANIFEST_DIR}/config"
    
    if [[ -f "$config_file" ]]; then
        # Source the config file
        source "$config_file"
    else
        # Default configuration if config file doesn't exist
        PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
        TPM_VERSION="0.1.0"
        TPM_BIN_DIR="${PREFIX}/bin"
        TPM_LIB_DIR="${PREFIX}/lib/tpm"
        TPM_STORE_DIR="${PREFIX}/tpm/store"
        TPM_TMP_DIR="${PREFIX}/tpm/tmp"
        TPM_MANIFEST_DIR="${HOME}/.tpm"
        TPM_MANIFEST_FILE="${TPM_MANIFEST_DIR}/manifest"
        TPM_CURL_TIMEOUT=30
        TPM_MAX_RETRIES=2
        TPM_COLOR="auto"
    fi
    
    # Set architecture
    TPM_ARCH="${TPM_ARCH:-$(detect_architecture)}"
    
    # Export for child processes
    export TPM_VERSION TPM_BIN_DIR TPM_LIB_DIR TPM_STORE_DIR TPM_TMP_DIR
    export TPM_MANIFEST_DIR TPM_MANIFEST_FILE TPM_CURL_TIMEOUT TPM_MAX_RETRIES
    export TPM_COLOR TPM_ARCH
}

# ------------------------------------------------------------------------------
# Logging System
# ------------------------------------------------------------------------------

# Initialize colors based on TPM_COLOR setting
init_colors() {
    case "${TPM_COLOR:-auto}" in
        always)
            RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
            BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
            BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
            ;;
        never)
            RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''
            BOLD=''; DIM=''; NC=''
            ;;
        auto|*)
            if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
                RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
                BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
                BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
            else
                RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''
                BOLD=''; DIM=''; NC=''
            fi
            ;;
    esac
}

log() {
    local level="$1"
    local message="$2"
    local color=""
    
    case "$level" in
        ERROR) color="$RED" ;;
        WARN) color="$YELLOW" ;;
        INFO) color="$BLUE" ;;
        SUCCESS) color="$GREEN" ;;
        DEBUG) color="$MAGENTA" ;;
        *) color="$NC" ;;
    esac
    
    echo -e "${color}[${level}]${NC} ${message}" >&2
}

log_error() { log "ERROR" "$1"; }
log_warn() { log "WARN" "$1"; }
log_info() { log "INFO" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_debug() { 
    if [[ "${TPM_DEBUG:-0}" -eq 1 ]]; then
        log "DEBUG" "$1"
    fi
}

# ------------------------------------------------------------------------------
# Architecture Detection
# ------------------------------------------------------------------------------

detect_architecture() {
    local arch
    
    # Prefer TERMUX_ARCH if set
    if [[ -n "${TERMUX_ARCH:-}" ]]; then
        arch="${TERMUX_ARCH}"
    else
        arch=$(uname -m)
    fi
    
    # Map to standardized architecture names
    case "$arch" in
        aarch64|arm64)          echo "arm64" ;;
        armv7l|arm|armhf|armv8) echo "arm" ;;
        i686|x86|i386)          echo "i686" ;;
        x86_64|amd64)           echo "x86_64" ;;
        *)
            log_error "Unsupported architecture: $arch"
            log_error "Please report this issue with your device information"
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Version Comparison
# ------------------------------------------------------------------------------

# Normalize version string: remove leading 'v', handle pre-releases
normalize_version() {
    local version="$1"
    
    # Remove leading 'v' if present
    version="${version#v}"
    
    # Convert to format: MAJOR.MINOR.PATCH-PRERELEASE
    # This handles semver-ish strings
    echo "$version" | sed -E 's/^([0-9]+)\.([0-9]+)\.([0-9]+)(-[a-zA-Z0-9\.]+)?$/\1.\2.\3\4/'
}

# Compare two version strings
# Returns: 0 if version1 == version2, 1 if version1 > version2, 2 if version1 < version2
version_compare() {
    local v1 v2
    v1=$(normalize_version "$1")
    v2=$(normalize_version "$2")
    
    # If versions are identical
    if [[ "$v1" == "$v2" ]]; then
        echo 0
        return 0
    fi
    
    # Split into components
    IFS='.-' read -ra v1_parts <<< "$v1"
    IFS='.-' read -ra v2_parts <<< "$v2"
    
    # Compare each component
    local max_len=$(( ${#v1_parts[@]} > ${#v2_parts[@]} ? ${#v1_parts[@]} : ${#v2_parts[@]} ))
    
    for (( i=0; i < max_len; i++ )); do
        local part1="${v1_parts[i]:-0}"
        local part2="${v2_parts[i]:-0}"
        
        # Check if parts are numeric
        if [[ "$part1" =~ ^[0-9]+$ ]] && [[ "$part2" =~ ^[0-9]+$ ]]; then
            # Numeric comparison
            if (( part1 > part2 )); then
                echo 1
                return 0
            elif (( part1 < part2 )); then
                echo 2
                return 0
            fi
        else
            # String comparison (for pre-release identifiers)
            if [[ "$part1" > "$part2" ]]; then
                echo 1
                return 0
            elif [[ "$part1" < "$part2" ]]; then
                echo 2
                return 0
            fi
        fi
    done
    
    # Should not reach here if versions are different
    echo 0
}

# Check if version1 is greater than version2
version_gt() {
    local result
    result=$(version_compare "$1" "$2")
    [[ "$result" -eq 1 ]]
}

# Check if version1 is less than version2
version_lt() {
    local result
    result=$(version_compare "$1" "$2")
    [[ "$result" -eq 2 ]]
}

# Check if version1 equals version2
version_eq() {
    local result
    result=$(version_compare "$1" "$2")
    [[ "$result" -eq 0 ]]
}

# ------------------------------------------------------------------------------
# Validation Utilities
# ------------------------------------------------------------------------------

validate_tool_id() {
    local tool_id="$1"
    
    # Format: owner/repo
    if [[ ! "$tool_id" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
        log_error "Invalid tool ID format: $tool_id"
        log_error "Expected format: owner/repo (e.g., sharkdp/bat)"
        return 1
    fi
    return 0
}

validate_version() {
    local version="$1"
    
    # Basic validation: should not be empty
    if [[ -z "$version" ]]; then
        log_error "Version cannot be empty"
        return 1
    fi
    
    # Should not contain path separators or other dangerous characters
    if [[ "$version" =~ [/\\\|\;\&\$\`] ]]; then
        log_error "Invalid characters in version: $version"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# File System Utilities
# ------------------------------------------------------------------------------

ensure_directory() {
    local dir="$1"
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        log_debug "Created directory: $dir"
    fi
}

safe_rm() {
    local path="$1"
    
    if [[ -e "$path" ]]; then
        if [[ -d "$path" ]]; then
            rm -rf "$path"
            log_debug "Removed directory: $path"
        else
            rm -f "$path"
            log_debug "Removed file: $path"
        fi
    fi
}

# Get file size in human-readable format
human_size() {
    local bytes="$1"
    local units=('B' 'KB' 'MB' 'GB' 'TB')
    local unit=0
    
    while (( bytes > 1024 )) && (( unit < 4 )); do
        bytes=$(( bytes / 1024 ))
        (( unit++ ))
    done
    
    echo "${bytes}${units[unit]}"
}

# ------------------------------------------------------------------------------
# Network Utilities
# ------------------------------------------------------------------------------

# Wrapper for curl with timeout and retries
curl_with_retry() {
    local url="$1"
    local output_file="${2:-}"
    local max_retries="${3:-${TPM_MAX_RETRIES}}"
    local timeout="${4:-${TPM_CURL_TIMEOUT}}"
    
    local curl_cmd=("curl" "-sSfL" "--retry" "$max_retries" "--retry-delay" "1")
    
    if [[ -n "$output_file" ]]; then
        curl_cmd+=("-o" "$output_file")
    fi
    
    curl_cmd+=("--connect-timeout" "$timeout" "--max-time" "$((timeout * 3))")
    
    if log_debug "Fetching: $url"; then
        curl_cmd+=("--verbose")
    else
        curl_cmd+=("--silent" "--show-error")
    fi
    
    # Execute curl
    if ! "${curl_cmd[@]}" "$url"; then
        log_error "Failed to fetch: $url"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Error Handling
# ------------------------------------------------------------------------------

# Die with error message
die() {
    log_error "$1"
    exit 1
}

# Check if command exists
require_command() {
    local cmd="$1"
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "Required command not found: $cmd"
    fi
}

# ------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------

# Initialize core module
init_core() {
    load_config
    init_colors
    require_command "curl"
    require_command "grep"
    require_command "sed"
    require_command "awk"
    require_command "tar"
    require_command "gzip"
    
    # Ensure essential directories exist
    ensure_directory "${TPM_TMP_DIR}"
    ensure_directory "${TPM_STORE_DIR}"
    ensure_directory "${TPM_MANIFEST_DIR}"
    
    log_debug "Core module initialized"
    log_debug "Architecture: ${TPM_ARCH}"
    log_debug "Store directory: ${TPM_STORE_DIR}"
}

# Run initialization when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This file is a library and should be sourced, not executed." >&2
    exit 1
else
    init_core
fi