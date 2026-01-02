#!/usr/bin/env bash
# TPM Manifest Management
# Version: 0.1.0

set -euo pipefail

# ------------------------------------------------------------------------------
# Manifest File Structure
# ------------------------------------------------------------------------------
# The manifest uses INI-style blocks separated by '---'
# Each block represents one installed tool:
#
# ---
# tool=sharkdp/bat
# version=v0.24.0
# binary=bat
# store_path=/data/data/com.termux/files/usr/tpm/store/bat/v0.24.0/bin/bat
# symlink_path=/data/data/com.termux/files/usr/bin/bat
# installed_at=2024-01-15T10:30:00Z
# checksum=sha256:abc123...
# files=/path1,/path2,/path3
# ---

# ------------------------------------------------------------------------------
# Global Manifest State
# ------------------------------------------------------------------------------

declare -A MANIFEST_TOOL_ID        # tool_id -> block index
declare -a MANIFEST_BLOCKS         # Array of block strings
declare MANIFEST_MODIFIED=false    # Track if manifest needs saving

# ------------------------------------------------------------------------------
# Block Parsing & Serialization
# ------------------------------------------------------------------------------

# Parse a block string into an associative array
# Usage: parse_block "$block_string" -> associative array (via nameref)
parse_block() {
    local block="$1"
    local -n result="$2"  # nameref for associative array
    
    # Clear the result array
    result=()
    
    # Split by newlines and process key=value pairs
    while IFS='=' read -r key value; do
        # Skip empty lines and comments
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        
        # Trim whitespace
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        
        # Store in associative array
        result["$key"]="$value"
    done <<< "$block"
}

# Serialize an associative array into a block string
# Usage: serialize_block associative_array -> block string
serialize_block() {
    local -n data="$1"  # nameref for associative array
    local block="---\n"
    
    # Define the order of fields for consistent output
    local fields=(
        "tool" "version" "binary" "store_path"
        "symlink_path" "installed_at" "checksum" "files"
    )
    
    for field in "${fields[@]}"; do
        if [[ -n "${data[$field]:-}" ]]; then
            block+="${field}=${data[$field]}\n"
        fi
    done
    
    block+="---"
    echo -e "$block"
}

# ------------------------------------------------------------------------------
# Manifest File Operations
# ------------------------------------------------------------------------------

# Load manifest from file into memory
load_manifest() {
    local manifest_file="${TPM_MANIFEST_FILE}"
    
    # Clear existing state
    MANIFEST_TOOL_ID=()
    MANIFEST_BLOCKS=()
    MANIFEST_MODIFIED=false
    
    # Create empty manifest file if it doesn't exist
    if [[ ! -f "$manifest_file" ]]; then
        touch "$manifest_file"
        log_debug "Created new manifest file: $manifest_file"
        return 0
    fi
    
    # Check if manifest file is readable
    if [[ ! -r "$manifest_file" ]]; then
        log_error "Cannot read manifest file: $manifest_file"
        return 1
    fi
    
    log_debug "Loading manifest from: $manifest_file"
    
    # Read the entire file
    local content
    content=$(cat "$manifest_file")
    
    # Split into blocks (separated by '---' on its own line)
    local block=""
    local in_block=false
    local block_index=0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Check for block delimiter
        if [[ "$line" == "---" ]]; then
            if [[ "$in_block" == true ]]; then
                # End of block
                if [[ -n "$block" ]]; then
                    # Parse the block to get tool_id
                    local -A block_data
                    parse_block "$block" block_data
                    
                    local tool_id="${block_data[tool]:-}"
                    if [[ -n "$tool_id" ]]; then
                        # Store block
                        MANIFEST_BLOCKS[$block_index]="$block"
                        MANIFEST_TOOL_ID["$tool_id"]=$block_index
                        ((block_index++))
                        log_debug "Loaded tool: $tool_id (v${block_data[version]:-unknown})"
                    else
                        log_warn "Skipping block without tool ID"
                    fi
                fi
                block=""
                in_block=false
            else
                # Start of block
                in_block=true
            fi
        elif [[ "$in_block" == true ]]; then
            # Inside a block, accumulate lines
            block+="$line\n"
        fi
    done <<< "$content"
    
    log_debug "Loaded $block_index tool(s) from manifest"
    return 0
}

# Save manifest from memory to file
save_manifest() {
    local manifest_file="${TPM_MANIFEST_FILE}"
    
    if [[ "$MANIFEST_MODIFIED" != true ]]; then
        log_debug "Manifest not modified, skipping save"
        return 0
    fi
    
    log_debug "Saving manifest to: $manifest_file"
    
    # Create backup of current manifest
    local backup_file="${manifest_file}.backup.$(date +%s)"
    if [[ -f "$manifest_file" ]]; then
        cp "$manifest_file" "$backup_file"
        log_debug "Created backup: $backup_file"
    fi
    
    # Write header
    cat > "$manifest_file" <<EOF
# TPM Manifest
# Generated: $(date -Iseconds)
# Version: ${TPM_VERSION}
#
# Format: INI-style blocks separated by '---'
# Each block represents one installed tool.
# Do not edit manually unless you know what you're doing.

EOF
    
    # Write all blocks
    for block in "${MANIFEST_BLOCKS[@]}"; do
        echo -e "$block" >> "$manifest_file"
    done
    
    # Clear modified flag
    MANIFEST_MODIFIED=false
    
    # Remove backup if save was successful
    rm -f "$backup_file"
    
    log_debug "Manifest saved successfully"
    return 0
}

# ------------------------------------------------------------------------------
# Tool CRUD Operations
# ------------------------------------------------------------------------------

# Check if a tool is installed
tool_installed() {
    local tool_id="$1"
    [[ -n "${MANIFEST_TOOL_ID[$tool_id]:-}" ]]
}

# Get tool information as associative array
get_tool_info() {
    local tool_id="$1"
    local -n result="$2"  # nameref for output
    
    local block_index="${MANIFEST_TOOL_ID[$tool_id]:-}"
    if [[ -z "$block_index" ]]; then
        log_debug "Tool not found in manifest: $tool_id"
        return 1
    fi
    
    parse_block "${MANIFEST_BLOCKS[$block_index]}" result
    return 0
}

# Get all installed tools
get_all_tools() {
    echo "${!MANIFEST_TOOL_ID[@]}"
}

# Add a new tool to the manifest
add_tool() {
    local -n tool_data="$1"  # nameref for associative array with tool data
    
    local tool_id="${tool_data[tool]}"
    
    # Validate required fields
    local required_fields=("tool" "version" "binary" "store_path" "symlink_path")
    for field in "${required_fields[@]}"; do
        if [[ -z "${tool_data[$field]:-}" ]]; then
            log_error "Missing required field for tool $tool_id: $field"
            return 1
        fi
    done
    
    # Check if tool already exists
    if tool_installed "$tool_id"; then
        log_error "Tool already installed: $tool_id"
        log_error "Use update_tool instead"
        return 1
    fi
    
    # Set installed_at if not provided
    if [[ -z "${tool_data[installed_at]:-}" ]]; then
        tool_data[installed_at]=$(date -Iseconds)
    fi
    
    # Generate files list if not provided
    if [[ -z "${tool_data[files]:-}" ]]; then
        local store_path="${tool_data[store_path]}"
        local binary_name="${tool_data[binary]}"
        
        # Find all files in the store directory for this version
        local store_dir
        store_dir=$(dirname "$store_path")
        
        if [[ -d "$store_dir" ]]; then
            local files_list=""
            while IFS= read -r -d '' file; do
                if [[ -n "$files_list" ]]; then
                    files_list+=","
                fi
                files_list+="$file"
            done < <(find "$store_dir" -type f -print0)
            
            tool_data[files]="$files_list"
        fi
    fi
    
    # Serialize and add to manifest
    local block
    block=$(serialize_block tool_data)
    
    local block_index=${#MANIFEST_BLOCKS[@]}
    MANIFEST_BLOCKS[$block_index]="$block"
    MANIFEST_TOOL_ID["$tool_id"]=$block_index
    MANIFEST_MODIFIED=true
    
    log_debug "Added tool to manifest: $tool_id (v${tool_data[version]})"
    return 0
}

# Update an existing tool in the manifest
update_tool() {
    local tool_id="$1"
    local -n new_data="$2"  # nameref for associative array with updated data
    
    local block_index="${MANIFEST_TOOL_ID[$tool_id]:-}"
    if [[ -z "$block_index" ]]; then
        log_error "Cannot update non-existent tool: $tool_id"
        return 1
    fi
    
    # Parse existing block to preserve fields not being updated
    local -A existing_data
    parse_block "${MANIFEST_BLOCKS[$block_index]}" existing_data
    
    # Update fields from new_data
    for key in "${!new_data[@]}"; do
        existing_data["$key"]="${new_data[$key]}"
    done
    
    # Ensure tool ID doesn't change
    if [[ "${existing_data[tool]}" != "$tool_id" ]]; then
        log_error "Cannot change tool ID from $tool_id to ${existing_data[tool]}"
        return 1
    fi
    
    # Serialize and update manifest
    local block
    block=$(serialize_block existing_data)
    
    MANIFEST_BLOCKS[$block_index]="$block"
    MANIFEST_MODIFIED=true
    
    log_debug "Updated tool in manifest: $tool_id (v${existing_data[version]})"
    return 0
}

# Remove a tool from the manifest
remove_tool() {
    local tool_id="$1"
    
    local block_index="${MANIFEST_TOOL_ID[$tool_id]:-}"
    if [[ -z "$block_index" ]]; then
        log_error "Cannot remove non-existent tool: $tool_id"
        return 1
    fi
    
    # Get tool info for cleanup
    local -A tool_info
    get_tool_info "$tool_id" tool_info
    
    # Remove from arrays
    unset MANIFEST_TOOL_ID["$tool_id"]
    
    # Shift remaining blocks to fill the gap
    for (( i=block_index; i < ${#MANIFEST_BLOCKS[@]} - 1; i++ )); do
        MANIFEST_BLOCKS[$i]="${MANIFEST_BLOCKS[$((i + 1))]}"
        
        # Update tool_id index for the moved block
        local -A moved_data
        parse_block "${MANIFEST_BLOCKS[$i]}" moved_data
        local moved_tool_id="${moved_data[tool]}"
        MANIFEST_TOOL_ID["$moved_tool_id"]=$i
    done
    
    # Remove last element
    unset "MANIFEST_BLOCKS[${#MANIFEST_BLOCKS[@]}-1]"
    MANIFEST_MODIFIED=true
    
    log_debug "Removed tool from manifest: $tool_id (v${tool_info[version]})"
    return 0
}

# ------------------------------------------------------------------------------
# Query Operations
# ------------------------------------------------------------------------------

# Get tool version
get_tool_version() {
    local tool_id="$1"
    
    local -A tool_info
    if get_tool_info "$tool_id" tool_info; then
        echo "${tool_info[version]}"
        return 0
    fi
    return 1
}

# Get tool store path
get_tool_store_path() {
    local tool_id="$1"
    
    local -A tool_info
    if get_tool_info "$tool_id" tool_info; then
        echo "${tool_info[store_path]}"
        return 0
    fi
    return 1
}

# Get tool symlink path
get_tool_symlink_path() {
    local tool_id="$1"
    
    local -A tool_info
    if get_tool_info "$tool_id" tool_info; then
        echo "${tool_info[symlink_path]}"
        return 0
    fi
    return 1
}

# List all installed tools with basic info
list_tools_basic() {
    local output=""
    
    for tool_id in "${!MANIFEST_TOOL_ID[@]}"; do
        local -A tool_info
        get_tool_info "$tool_id" tool_info
        
        local version="${tool_info[version]:-unknown}"
        local binary="${tool_info[binary]:-unknown}"
        local installed_at="${tool_info[installed_at]:-unknown}"
        
        output+="$tool_id|$version|$binary|$installed_at\n"
    done
    
    echo -e "$output" | sort
}

# ------------------------------------------------------------------------------
# Validation & Repair
# ------------------------------------------------------------------------------

# Validate manifest structure
validate_manifest() {
    local errors=0
    
    for tool_id in "${!MANIFEST_TOOL_ID[@]}"; do
        local -A tool_info
        if ! get_tool_info "$tool_id" tool_info; then
            log_warn "Failed to parse block for tool: $tool_id"
            ((errors++))
            continue
        fi
        
        # Check required fields
        local required_fields=("tool" "version" "store_path" "symlink_path")
        for field in "${required_fields[@]}"; do
            if [[ -z "${tool_info[$field]:-}" ]]; then
                log_warn "Tool $tool_id missing required field: $field"
                ((errors++))
            fi
        done
        
        # Check if store path exists
        local store_path="${tool_info[store_path]:-}"
        if [[ -n "$store_path" ]] && [[ ! -f "$store_path" ]]; then
            log_warn "Tool $tool_id store path does not exist: $store_path"
            ((errors++))
        fi
        
        # Check if symlink exists and points to store path
        local symlink_path="${tool_info[symlink_path]:-}"
        if [[ -n "$symlink_path" ]]; then
            if [[ ! -L "$symlink_path" ]]; then
                log_warn "Tool $tool_id symlink is not a symlink: $symlink_path"
                ((errors++))
            elif [[ "$(readlink -f "$symlink_path")" != "$(readlink -f "$store_path")" ]]; then
                log_warn "Tool $tool_id symlink points to wrong location"
                ((errors++))
            fi
        fi
    done
    
    if [[ $errors -eq 0 ]]; then
        log_debug "Manifest validation passed"
        return 0
    else
        log_warn "Manifest validation found $errors issue(s)"
        return 1
    fi
}

# Repair broken symlinks in manifest
repair_symlinks() {
    local repaired=0
    
    for tool_id in "${!MANIFEST_TOOL_ID[@]}"; do
        local -A tool_info
        get_tool_info "$tool_id" tool_info
        
        local store_path="${tool_info[store_path]}"
        local symlink_path="${tool_info[symlink_path]}"
        
        # Check if symlink is broken
        if [[ -n "$symlink_path" ]] && [[ -n "$store_path" ]]; then
            if [[ ! -L "$symlink_path" ]] || [[ "$(readlink -f "$symlink_path")" != "$(readlink -f "$store_path")" ]]; then
                log_info "Repairing symlink for $tool_id"
                
                # Remove broken symlink if it exists
                [[ -e "$symlink_path" ]] && rm -f "$symlink_path"
                
                # Create new symlink
                if ln -sf "$store_path" "$symlink_path"; then
                    log_debug "Created symlink: $symlink_path -> $store_path"
                    ((repaired++))
                else
                    log_warn "Failed to create symlink for $tool_id"
                fi
            fi
        fi
    done
    
    log_debug "Repaired $repaired symlink(s)"
    return $((repaired > 0 ? 0 : 1))
}

# ------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------

# Initialize manifest module
init_manifest() {
    log_debug "Initializing manifest module"
    
    # Ensure manifest directory exists
    ensure_directory "${TPM_MANIFEST_DIR}"
    
    # Load manifest from file
    if ! load_manifest; then
        log_error "Failed to load manifest"
        return 1
    fi
    
    log_debug "Manifest module initialized with ${#MANIFEST_BLOCKS[@]} tool(s)"
    return 0
}

# Auto-save on exit
save_on_exit() {
    if [[ "$MANIFEST_MODIFIED" == true ]]; then
        log_debug "Auto-saving manifest before exit"
        save_manifest
    fi
}

# Register exit handler
trap save_on_exit EXIT

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
    init_manifest
fi