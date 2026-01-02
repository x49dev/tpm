#!/usr/bin/env bash
# TPM Store Management
# Version: 0.1.0

set -euo pipefail

# ------------------------------------------------------------------------------
# Store Structure Definition
# ------------------------------------------------------------------------------
# Store layout:
#   ${TPM_STORE_DIR}/
#   ├── <owner>/
#   │   ├── <repo>/
#   │   │   ├── <version>/
#   │   │   │   ├── bin/
#   │   │   │   │   └── <binary>
#   │   │   │   ├── lib/
#   │   │   │   ├── share/
#   │   │   │   └── manifest.json (metadata)
#   │   │   └── current -> <version> (symlink)
#   └── tmp/ (temporary extraction)

# ------------------------------------------------------------------------------
# Store Path Utilities
# ------------------------------------------------------------------------------

# Get the store path for a specific tool version
get_store_path() {
    local owner="$1"
    local repo="$2"
    local version="$3"
    
    # Sanitize version string (remove leading v, replace slashes)
    local sanitized_version="${version#v}"
    sanitized_version="${sanitized_version//\//_}"
    
    echo "${TPM_STORE_DIR}/${owner}/${repo}/${sanitized_version}"
}

# Get the current symlink path for a tool
get_current_symlink_path() {
    local owner="$1"
    local repo="$2"
    
    echo "${TPM_STORE_DIR}/${owner}/${repo}/current"
}

# Get the binary directory within a store path
get_store_bin_dir() {
    local store_path="$1"
    echo "${store_path}/bin"
}

# ------------------------------------------------------------------------------
# Archive Extraction
# ------------------------------------------------------------------------------

# Extract an archive based on its extension
extract_archive() {
    local archive_path="$1"
    local extract_dir="$2"
    
    if [[ ! -f "$archive_path" ]]; then
        log_error "Archive not found: $archive_path"
        return 1
    fi
    
    log_debug "Extracting: $(basename "$archive_path") to $extract_dir"
    
    # Create extraction directory
    mkdir -p "$extract_dir"
    record_mkdir "$extract_dir"
    
    # Get file extension
    local filename
    filename=$(basename "$archive_path")
    local extension="${filename##*.}"
    
    # Handle different archive types
    case "$filename" in
        *.tar.gz|*.tgz)
            if ! tar -xzf "$archive_path" -C "$extract_dir" --strip-components=1 2>/dev/null; then
                # Try without strip-components
                if ! tar -xzf "$archive_path" -C "$extract_dir"; then
                    log_error "Failed to extract tar.gz archive: $archive_path"
                    return 1
                fi
            fi
            ;;
        *.tar.bz2|*.tbz2)
            if ! tar -xjf "$archive_path" -C "$extract_dir" --strip-components=1 2>/dev/null; then
                if ! tar -xjf "$archive_path" -C "$extract_dir"; then
                    log_error "Failed to extract tar.bz2 archive: $archive_path"
                    return 1
                fi
            fi
            ;;
        *.tar.xz|*.txz)
            if ! tar -xJf "$archive_path" -C "$extract_dir" --strip-components=1 2>/dev/null; then
                if ! tar -xJf "$archive_path" -C "$extract_dir"; then
                    log_error "Failed to extract tar.xz archive: $archive_path"
                    return 1
                fi
            fi
            ;;
        *.zip)
            if ! command -v unzip >/dev/null 2>&1; then
                log_error "unzip command not found. Cannot extract zip archive."
                log_error "Install with: pkg install unzip"
                return 1
            fi
            
            if ! unzip -q "$archive_path" -d "$extract_dir"; then
                log_error "Failed to extract zip archive: $archive_path"
                return 1
            fi
            
            # Try to strip top-level directory if there's only one
            local top_dirs
            top_dirs=$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d | wc -l)
            if [[ $top_dirs -eq 1 ]]; then
                local top_dir
                top_dir=$(find "$extract_dir" -maxdepth 1 -mindepth 1 -type d)
                mv "$top_dir"/* "$extract_dir"/ 2>/dev/null || true
                rmdir "$top_dir" 2>/dev/null || true
            fi
            ;;
        *.tar)
            if ! tar -xf "$archive_path" -C "$extract_dir" --strip-components=1 2>/dev/null; then
                if ! tar -xf "$archive_path" -C "$extract_dir"; then
                    log_error "Failed to extract tar archive: $archive_path"
                    return 1
                fi
            fi
            ;;
        *)
            # Assume it's a single binary file
            if [[ -x "$archive_path" ]] || [[ "$archive_path" =~ \.(so|dylib|dll)$ ]]; then
                log_debug "Treating as single binary file"
                cp "$archive_path" "$extract_dir/"
                chmod +x "$extract_dir/$(basename "$archive_path")" 2>/dev/null || true
            else
                log_error "Unsupported archive format: $filename"
                log_error "Supported: .tar.gz, .tgz, .tar.bz2, .tbz2, .tar.xz, .txz, .zip, .tar"
                return 1
            fi
            ;;
    esac
    
    log_debug "Extraction completed: $extract_dir"
    return 0
}

# ------------------------------------------------------------------------------
# Binary Detection
# ------------------------------------------------------------------------------

# Find the main binary in an extracted directory
find_main_binary() {
    local extract_dir="$1"
    local tool_name="$2"  # Optional: expected binary name
    
    log_debug "Looking for binary in: $extract_dir"
    
    # Files to exclude
    local exclude_patterns=(
        "*.so" "*.so.*" "*.dylib" "*.dll" "*.a" "*.la"
        "*.py" "*.sh" "*.pl" "*.rb" "*.js"
        "README*" "LICENSE*" "COPYING*" "AUTHORS*" "CHANGELOG*"
        "*.md" "*.txt" "*.json" "*.yml" "*.yaml" "*.xml"
        "*.html" "*.css" "*.png" "*.jpg" "*.jpeg" "*.gif" "*.svg"
    )
    
    # Build find command with exclusions
    local find_cmd="find \"$extract_dir\" -type f -perm /u+x,g+x,o+x"
    
    for pattern in "${exclude_patterns[@]}"; do
        find_cmd+=" ! -name \"$pattern\""
    done
    
    # Also exclude hidden files and backup files
    find_cmd+=" ! -name '.*' ! -name '*~' ! -name '#*#'"
    
    # Execute find command
    local candidates
    candidates=$(eval "$find_cmd 2>/dev/null" | head -20)
    
    if [[ -z "$candidates" ]]; then
        # No executable files found, look for any file that might be a binary
        candidates=$(find "$extract_dir" -type f ! -name ".*" ! -name "*~" 2>/dev/null | head -20)
    fi
    
    local candidate_count
    candidate_count=$(echo "$candidates" | wc -l)
    
    if [[ $candidate_count -eq 0 ]]; then
        log_error "No files found in extracted archive"
        return 1
    fi
    
    # If we have an expected tool name, try to match it
    if [[ -n "$tool_name" ]]; then
        local exact_match
        exact_match=$(echo "$candidates" | grep -E "/$tool_name\$" | head -n1)
        
        if [[ -n "$exact_match" ]]; then
            echo "$exact_match"
            log_debug "Found exact binary match: $exact_match"
            return 0
        fi
        
        # Try case-insensitive match
        local case_insensitive_match
        case_insensitive_match=$(echo "$candidates" | grep -i "$tool_name" | head -n1)
        
        if [[ -n "$case_insensitive_match" ]]; then
            echo "$case_insensitive_match"
            log_debug "Found case-insensitive binary match: $case_insensitive_match"
            return 0
        fi
    fi
    
    # Score candidates based on various heuristics
    local best_score=-1
    local best_candidate=""
    
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        
        local score=0
        local filename
        filename=$(basename "$candidate")
        
        # Heuristic scoring
        if [[ "$filename" == "$tool_name" ]]; then
            score=$((score + 100))
        fi
        
        if [[ "$filename" =~ ^[a-z]+$ ]]; then
            score=$((score + 20))  # Lowercase names are often binaries
        fi
        
        if [[ ! "$filename" =~ \. ]]; then
            score=$((score + 15))  # No extension often means binary
        fi
        
        if [[ "$filename" =~ ^[[:alnum:]]+$ ]]; then
            score=$((score + 10))  # Alphanumeric names
        fi
        
        if file "$candidate" 2>/dev/null | grep -q "ELF.*executable"; then
            score=$((score + 50))  # ELF executable
        fi
        
        if file "$candidate" 2>/dev/null | grep -q "Mach-O.*executable"; then
            score=$((score + 50))  # Mach-O executable
        fi
        
        if file "$candidate" 2>/dev/null | grep -q "script.*executable"; then
            score=$((score - 30))  # Script files (less likely to be main binary)
        fi
        
        if [[ "$candidate" =~ /bin/ ]]; then
            score=$((score + 25))  # In a bin/ directory
        fi
        
        if [[ "$candidate" =~ /s?bin/ ]]; then
            score=$((score + 20))  # In sbin/ directory
        fi
        
        if [[ "$candidate" =~ /usr/ ]]; then
            score=$((score - 10))  # Deep in usr/ might be library
        fi
        
        # Check file size (reasonable binary size: 10KB - 50MB)
        local size
        size=$(stat -c %s "$candidate" 2>/dev/null || stat -f %z "$candidate" 2>/dev/null || echo 0)
        
        if [[ $size -gt 10000 ]] && [[ $size -lt 50000000 ]]; then
            score=$((score + 15))
        fi
        
        log_debug "Candidate: $filename (score: $score)"
        
        if [[ $score -gt $best_score ]]; then
            best_score=$score
            best_candidate="$candidate"
        fi
    done <<< "$candidates"
    
    if [[ -z "$best_candidate" ]]; then
        log_error "Could not identify main binary in extracted files"
        return 1
    fi
    
    log_debug "Selected binary: $best_candidate (score: $best_score)"
    echo "$best_candidate"
    return 0
}

# ------------------------------------------------------------------------------
# Store Operations
# ------------------------------------------------------------------------------

# Prepare store directory for a new version
prepare_store() {
    local owner="$1"
    local repo="$2"
    local version="$3"
    
    local store_path
    store_path=$(get_store_path "$owner" "$repo" "$version")
    
    log_debug "Preparing store: $store_path"
    
    # Clean up existing directory if it exists (for reinstall/force)
    if [[ -d "$store_path" ]]; then
        log_warn "Store path already exists, cleaning: $store_path"
        safe_rm "$store_path"
    fi
    
    # Create directory structure
    mkdir -p "${store_path}/bin"
    record_mkdir "$store_path"
    
    # Create metadata file
    local metadata_file="${store_path}/manifest.json"
    cat > "$metadata_file" <<EOF
{
    "tool": "${owner}/${repo}",
    "version": "${version}",
    "architecture": "${TPM_ARCH}",
    "installed_at": "$(date -Iseconds)",
    "store_path": "${store_path}"
}
EOF
    
    echo "$store_path"
    return 0
}

# Install a downloaded asset to the store
install_to_store() {
    local owner="$1"
    local repo="$2"
    local version="$3"
    local asset_path="$4"
    local expected_binary="${5:-}"  # Optional: expected binary name
    
    log_debug "Installing to store: $owner/$repo $version"
    
    # Prepare store directory
    local store_path
    store_path=$(prepare_store "$owner" "$repo" "$version")
    
    # Create temporary extraction directory
    local extract_dir
    extract_dir=$(mktemp -d "${TPM_TMP_DIR}/extract.XXXXXX")
    tpm_record "rm -rf '$extract_dir' 2>/dev/null || true"
    
    # Extract archive
    if ! extract_archive "$asset_path" "$extract_dir"; then
        rm -rf "$extract_dir"
        return 1
    fi
    
    # Find the main binary
    local binary_path
    if ! binary_path=$(find_main_binary "$extract_dir" "$expected_binary"); then
        log_error "Failed to identify binary in extracted files"
        log_error "Contents of extraction:"
        find "$extract_dir" -type f | head -10 | while read -r f; do
            log_error "  - $(basename "$f")"
        done
        rm -rf "$extract_dir"
        return 1
    fi
    
    local binary_name
    binary_name=$(basename "$binary_path")
    
    # Create bin directory in store
    local store_bin_dir
    store_bin_dir=$(get_store_bin_dir "$store_path")
    mkdir -p "$store_bin_dir"
    
    # Move binary to store
    local store_binary_path="${store_bin_dir}/${binary_name}"
    
    if ! safe_move "$binary_path" "$store_binary_path"; then
        log_error "Failed to move binary to store"
        rm -rf "$extract_dir"
        return 1
    fi
    
    # Make binary executable
    chmod +x "$store_binary_path"
    
    # Copy other files (optional - for completeness)
    log_debug "Copying additional files to store..."
    
    # Create lib and share directories if they have content
    local has_lib=false
    local has_share=false
    
    if [[ -d "${extract_dir}/lib" ]]; then
        mkdir -p "${store_path}/lib"
        cp -r "${extract_dir}/lib"/* "${store_path}/lib/" 2>/dev/null || true
        has_lib=true
    fi
    
    if [[ -d "${extract_dir}/share" ]]; then
        mkdir -p "${store_path}/share"
        cp -r "${extract_dir}/share"/* "${store_path}/share/" 2>/dev/null || true
        has_share=true
    fi
    
    # Copy other top-level directories (except bin, lib, share)
    for dir in "$extract_dir"/*/; do
        [[ ! -d "$dir" ]] && continue
        
        local dir_name
        dir_name=$(basename "$dir")
        
        case "$dir_name" in
            bin|lib|share)
                continue
                ;;
            *)
                mkdir -p "${store_path}/${dir_name}"
                cp -r "$dir"/* "${store_path}/${dir_name}/" 2>/dev/null || true
                ;;
        esac
    done
    
    # Cleanup extraction directory
    rm -rf "$extract_dir"
    
    # Update metadata with binary info
    local metadata_file="${store_path}/manifest.json"
    local file_list
    file_list=$(find "$store_path" -type f | sed "s|^$store_path/||" | tr '\n' ',' | sed 's/,$//')
    
    cat > "$metadata_file" <<EOF
{
    "tool": "${owner}/${repo}",
    "version": "${version}",
    "architecture": "${TPM_ARCH}",
    "installed_at": "$(date -Iseconds)",
    "store_path": "${store_path}",
    "binary": "${binary_name}",
    "binary_path": "${store_binary_path}",
    "files": "${file_list}"
}
EOF
    
    log_debug "Installation complete: $store_binary_path"
    echo "$store_binary_path $binary_name"
    return 0
}

# Create symlink to binary in PATH
create_symlink() {
    local store_binary_path="$1"
    local binary_name="$2"
    local symlink_name="${3:-}"  # Optional: custom symlink name
    
    local link_name="${symlink_name:-$binary_name}"
    local symlink_path="${TPM_BIN_DIR}/${link_name}"
    
    log_debug "Creating symlink: $symlink_path -> $store_binary_path"
    
    # Check if symlink already exists
    if [[ -L "$symlink_path" ]]; then
        local existing_target
        existing_target=$(readlink -f "$symlink_path" 2>/dev/null || true)
        
        if [[ "$existing_target" == "$(readlink -f "$store_binary_path")" ]]; then
            log_debug "Symlink already points to correct location"
            return 0
        fi
        
        log_warn "Symlink already exists, replacing: $symlink_path"
        record_symlink "$store_binary_path" "$symlink_path"
        rm -f "$symlink_path"
    elif [[ -e "$symlink_path" ]]; then
        log_warn "File exists at symlink location, backing up: $symlink_path"
        local backup_path="${symlink_path}.tpm_backup.$(date +%s)"
        mv "$symlink_path" "$backup_path"
        tpm_record "mv '$backup_path' '$symlink_path' 2>/dev/null || true"
    fi
    
    # Create symlink
    if ln -sf "$store_binary_path" "$symlink_path"; then
        log_debug "Symlink created: $symlink_path -> $store_binary_path"
        return 0
    else
        log_error "Failed to create symlink: $symlink_path"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Version Management
# ------------------------------------------------------------------------------

# Get all installed versions of a tool
get_installed_versions() {
    local owner="$1"
    local repo="$2"
    
    local tool_dir="${TPM_STORE_DIR}/${owner}/${repo}"
    
    if [[ ! -d "$tool_dir" ]]; then
        return 0
    fi
    
    find "$tool_dir" -maxdepth 1 -mindepth 1 -type d ! -name "current" | \
        sort -V | \
        while read -r version_dir; do
            basename "$version_dir"
        done
}

# Get current installed version
get_current_version() {
    local owner="$1"
    local repo="$2"
    
    local current_link
    current_link=$(get_current_symlink_path "$owner" "$repo")
    
    if [[ -L "$current_link" ]]; then
        local target
        target=$(readlink -f "$current_link" 2>/dev/null || true)
        
        if [[ -n "$target" ]]; then
            basename "$target"
            return 0
        fi
    fi
    
    # Fallback: check manifest
    local tool_id="${owner}/${repo}"
    if tool_installed "$tool_id"; then
        get_tool_version "$tool_id"
        return 0
    fi
    
    return 1
}

# Set current version symlink
set_current_version() {
    local owner="$1"
    local repo="$2"
    local version="$3"
    
    local store_path
    store_path=$(get_store_path "$owner" "$repo" "$version")
    
    if [[ ! -d "$store_path" ]]; then
        log_error "Version not found in store: $version"
        return 1
    fi
    
    local current_link
    current_link=$(get_current_symlink_path "$owner" "$repo")
    
    # Create parent directory if needed
    mkdir -p "$(dirname "$current_link")"
    
    # Update or create symlink
    if [[ -L "$current_link" ]]; then
        record_symlink "$store_path" "$current_link"
    else
        tpm_record "rm -f '$current_link' 2>/dev/null || true"
    fi
    
    if ln -sfn "$store_path" "$current_link"; then
        log_debug "Set current version: $owner/$repo -> $version"
        return 0
    else
        log_error "Failed to set current version"
        return 1
    fi
}

# Clean up old versions (keep last N versions)
cleanup_old_versions() {
    local owner="$1"
    local repo="$2"
    local keep_versions="${3:-3}"  # Default: keep 3 versions
    
    log_debug "Cleaning up old versions for $owner/$repo (keeping $keep_versions)"
    
    local versions
    versions=($(get_installed_versions "$owner" "$repo"))
    
    local version_count=${#versions[@]}
    
    if [[ $version_count -le $keep_versions ]]; then
        log_debug "Only $version_count version(s) installed, nothing to clean"
        return 0
    fi
    
    local versions_to_remove=$((version_count - keep_versions))
    local removed=0
    
    # Sort versions (oldest first)
    local sorted_versions
    sorted_versions=($(printf "%s\n" "${versions[@]}" | sort -V))
    
    for (( i=0; i < versions_to_remove; i++ )); do
        local version_to_remove="${sorted_versions[i]}"
        local store_path
        store_path=$(get_store_path "$owner" "$repo" "$version_to_remove")
        
        # Skip if this is the current version
        local current_version
        current_version=$(get_current_version "$owner" "$repo" 2>/dev/null || true)
        
        if [[ "$version_to_remove" == "$current_version" ]]; then
            log_debug "Skipping current version: $version_to_remove"
            continue
        fi
        
        log_debug "Removing old version: $version_to_remove"
        
        if safe_rm "$store_path"; then
            ((removed++))
            log_debug "Removed: $store_path"
        else
            log_warn "Failed to remove: $store_path"
        fi
    done
    
    log_debug "Cleanup removed $removed old version(s)"
    return 0
}

# ------------------------------------------------------------------------------
# Validation & Repair
# ------------------------------------------------------------------------------

# Validate store structure
validate_store() {
    local errors=0
    
    log_debug "Validating store structure..."
    
    if [[ ! -d "$TPM_STORE_DIR" ]]; then
        log_error "Store directory does not exist: $TPM_STORE_DIR"
        return 1
    fi
    
    # Check each tool directory
    for owner_dir in "$TPM_STORE_DIR"/*/; do
        [[ ! -d "$owner_dir" ]] && continue
        
        local owner
        owner=$(basename "$owner_dir")
        
        for repo_dir in "$owner_dir"/*/; do
            [[ ! -d "$repo_dir" ]] && continue
            
            local repo
            repo=$(basename "$repo_dir")
            local tool_id="${owner}/${repo}"
            
            log_debug "Checking tool: $tool_id"
            
            # Check current symlink
            local current_link="${repo_dir}/current"
            if [[ -L "$current_link" ]]; then
                local target
                target=$(readlink -f "$current_link" 2>/dev/null || true)
                
                if [[ -z "$target" ]] || [[ ! -d "$target" ]]; then
                    log_warn "Broken current symlink for $tool_id"
                    ((errors++))
                fi
            fi
            
            # Check each version directory
            for version_dir in "$repo_dir"/*/; do
                [[ ! -d "$version_dir" ]] && continue
                [[ "$(basename "$version_dir")" == "current" ]] && continue
                
                local version
                version=$(basename "$version_dir")
                
                # Check for binary
                local bin_dir="${version_dir}/bin"
                if [[ ! -d "$bin_dir" ]]; then
                    log_warn "Missing bin directory for $tool_id $version"
                    ((errors++))
                    continue
                fi
                
                # Check for at least one executable
                local executables
                executables=$(find "$bin_dir" -type f -perm /u+x,g+x,o+x 2>/dev/null | head -5)
                
                if [[ -z "$executables" ]]; then
                    log_warn "No executable files in bin directory for $tool_id $version"
                    ((errors++))
                fi
            done
        done
    done
    
    if [[ $errors -eq 0 ]]; then
        log_debug "Store validation passed"
        return 0
    else
        log_warn "Store validation found $errors issue(s)"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------

# Initialize store module
init_store() {
    log_debug "Initializing store module"
    
    # Ensure store directory exists
    ensure_directory "$TPM_STORE_DIR"
    
    # Ensure tmp directory exists
    ensure_directory "$TPM_TMP_DIR"
    
    log_debug "Store module initialized"
    return 0
}

# Run initialization when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This file is a library and should be sourced, not executed." >&2
    exit 1
else
    # Source core utilities first
    source "${TPM_LIB_DIR}/core.sh" 2>/dev/null || {
        echo "Failed to source core utilities" >&2
        exit 1
    }
    
    # Source transaction module for record_* functions
    source "${TPM_LIB_DIR}/transaction.sh" 2>/dev/null || {
        echo "Failed to source transaction module" >&2
        exit 1
    }
    
    init_store
fi