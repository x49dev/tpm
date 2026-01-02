#!/usr/bin/env bash
# TPM Transaction Management
# Version: 0.1.0

set -euo pipefail

# ------------------------------------------------------------------------------
# Transaction State
# ------------------------------------------------------------------------------

declare -a TRANSACTION_STEPS    # Rollback steps (commands to execute)
declare TRANSACTION_ACTIVE=false
declare TRANSACTION_TYPE=""     # install, update, remove, etc.
declare TRANSACTION_CONTEXT=""  # tool_id or other context
declare TRANSACTION_START_TIME=""

# ------------------------------------------------------------------------------
# Transaction Core Functions
# ------------------------------------------------------------------------------

# Begin a new transaction
tpm_begin() {
    local type="$1"
    local context="$2"
    
    if [[ "$TRANSACTION_ACTIVE" == true ]]; then
        log_error "Transaction already active: $TRANSACTION_TYPE ($TRANSACTION_CONTEXT)"
        log_error "Cannot begin new transaction: $type ($context)"
        return 1
    fi
    
    TRANSACTION_ACTIVE=true
    TRANSACTION_TYPE="$type"
    TRANSACTION_CONTEXT="$context"
    TRANSACTION_START_TIME=$(date +%s)
    TRANSACTION_STEPS=()
    
    log_debug "Transaction began: $type ($context)"
    return 0
}

# Record a rollback step
tpm_record() {
    local rollback_command="$1"
    
    if [[ "$TRANSACTION_ACTIVE" != true ]]; then
        log_warn "Transaction not active, ignoring rollback step: $rollback_command"
        return 1
    fi
    
    TRANSACTION_STEPS+=("$rollback_command")
    log_debug "Recorded rollback step [${#TRANSACTION_STEPS[@]}]: $rollback_command"
    return 0
}

# Commit the transaction (mark as successful)
tpm_commit() {
    if [[ "$TRANSACTION_ACTIVE" != true ]]; then
        log_warn "No active transaction to commit"
        return 1
    fi
    
    local duration=$(( $(date +%s) - TRANSACTION_START_TIME ))
    
    log_debug "Transaction committed: $TRANSACTION_TYPE ($TRANSACTION_CONTEXT)"
    log_debug "Duration: ${duration}s, Steps recorded: ${#TRANSACTION_STEPS[@]}"
    
    # Clear transaction state
    TRANSACTION_ACTIVE=false
    TRANSACTION_TYPE=""
    TRANSACTION_CONTEXT=""
    TRANSACTION_START_TIME=""
    TRANSACTION_STEPS=()
    
    return 0
}

# Rollback the transaction (execute all recorded steps in reverse)
tpm_rollback() {
    if [[ "$TRANSACTION_ACTIVE" != true ]]; then
        log_warn "No active transaction to rollback"
        return 1
    fi
    
    local total_steps="${#TRANSACTION_STEPS[@]}"
    
    if [[ $total_steps -eq 0 ]]; then
        log_debug "No rollback steps recorded for transaction: $TRANSACTION_TYPE ($TRANSACTION_CONTEXT)"
        TRANSACTION_ACTIVE=false
        return 0
    fi
    
    log_warn "Rolling back transaction: $TRANSACTION_TYPE ($TRANSACTION_CONTEXT)"
    log_warn "Executing $total_steps rollback step(s) in reverse order"
    
    local failed_steps=0
    
    # Execute steps in reverse order (LIFO)
    for (( idx=total_steps-1; idx>=0; idx-- )); do
        local step="${TRANSACTION_STEPS[idx]}"
        local step_number=$(( total_steps - idx ))
        
        log_debug "Rollback step $step_number/$total_steps: $step"
        
        if eval "$step" 2>/dev/null; then
            log_debug "  ✓ Step executed successfully"
        else
            log_warn "  ✗ Step failed (continuing rollback): $step"
            ((failed_steps++))
        fi
    done
    
    # Clear transaction state even if some rollback steps failed
    TRANSACTION_ACTIVE=false
    local original_type="$TRANSACTION_TYPE"
    local original_context="$TRANSACTION_CONTEXT"
    
    TRANSACTION_TYPE=""
    TRANSACTION_CONTEXT=""
    TRANSACTION_START_TIME=""
    TRANSACTION_STEPS=()
    
    if [[ $failed_steps -eq 0 ]]; then
        log_debug "Rollback completed successfully: $original_type ($original_context)"
        return 0
    else
        log_warn "Rollback completed with $failed_steps failed step(s): $original_type ($original_context)"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Transaction Utilities
# ------------------------------------------------------------------------------

# Check if a transaction is active
tpm_in_transaction() {
    [[ "$TRANSACTION_ACTIVE" == true ]]
}

# Get current transaction info
tpm_transaction_info() {
    if [[ "$TRANSACTION_ACTIVE" != true ]]; then
        echo "No active transaction"
        return 1
    fi
    
    local duration=$(( $(date +%s) - TRANSACTION_START_TIME ))
    
    cat <<EOF
Type:       $TRANSACTION_TYPE
Context:    $TRANSACTION_CONTEXT
Duration:   ${duration}s
Steps:      ${#TRANSACTION_STEPS[@]}
EOF
    
    if [[ ${#TRANSACTION_STEPS[@]} -gt 0 ]]; then
        echo "Rollback steps:"
        for i in "${!TRANSACTION_STEPS[@]}"; do
            echo "  [$((i+1))] ${TRANSACTION_STEPS[i]}"
        done
    fi
}

# ------------------------------------------------------------------------------
# Predefined Rollback Actions
# ------------------------------------------------------------------------------

# Record file/directory removal (if it exists at transaction start)
record_remove() {
    local path="$1"
    
    if [[ -e "$path" ]]; then
        if [[ -d "$path" ]]; then
            # For directories, we need to preserve their contents
            local backup_dir="${TPM_TMP_DIR}/backup/$(date +%s)/$(basename "$path")"
            mkdir -p "$(dirname "$backup_dir")"
            
            if cp -r "$path" "$backup_dir" 2>/dev/null; then
                tpm_record "rm -rf '$path' 2>/dev/null || true"
                tpm_record "mkdir -p '$(dirname "$path")' && cp -r '$backup_dir' '$path' 2>/dev/null || true"
                log_debug "Recorded directory removal with backup: $path"
            else
                # Fallback: just record removal
                tpm_record "rm -rf '$path' 2>/dev/null || true"
                log_debug "Recorded directory removal: $path"
            fi
        else
            # For files, back up the content
            local backup_file="${TPM_TMP_DIR}/backup/$(date +%s)/$(basename "$path")"
            mkdir -p "$(dirname "$backup_file")"
            
            if cp "$path" "$backup_file" 2>/dev/null; then
                tpm_record "rm -f '$path' 2>/dev/null || true"
                tpm_record "mkdir -p '$(dirname "$path")' && cp '$backup_file' '$path' 2>/dev/null || true"
                log_debug "Recorded file removal with backup: $path"
            else
                # Fallback: just record removal
                tpm_record "rm -f '$path' 2>/dev/null || true"
                log_debug "Recorded file removal: $path"
            fi
        fi
    else
        log_debug "Path does not exist, skipping removal record: $path"
    fi
}

# Record symlink creation
record_symlink() {
    local target="$1"
    local link_path="$2"
    
    # Check if symlink already exists
    if [[ -L "$link_path" ]]; then
        local existing_target
        existing_target=$(readlink -f "$link_path" 2>/dev/null || true)
        
        tpm_record "rm -f '$link_path' 2>/dev/null || true"
        tpm_record "ln -sf '$existing_target' '$link_path' 2>/dev/null || true"
        log_debug "Recorded symlink replacement: $link_path -> $target (was -> $existing_target)"
    elif [[ -e "$link_path" ]]; then
        # It's not a symlink but exists - back it up
        local backup_path="${TPM_TMP_DIR}/backup/$(date +%s)/$(basename "$link_path")"
        mkdir -p "$(dirname "$backup_path")"
        
        if cp -r "$link_path" "$backup_path" 2>/dev/null; then
            tpm_record "rm -rf '$link_path' 2>/dev/null || true"
            tpm_record "cp -r '$backup_path' '$link_path' 2>/dev/null || true"
            tpm_record "ln -sf '$target' '$link_path' 2>/dev/null || true"
            log_debug "Recorded symlink with backup: $link_path -> $target"
        else
            # Fallback
            tpm_record "rm -rf '$link_path' 2>/dev/null || true"
            tpm_record "ln -sf '$target' '$link_path' 2>/dev/null || true"
            log_debug "Recorded symlink: $link_path -> $target"
        fi
    else
        # Simple symlink creation
        tpm_record "rm -f '$link_path' 2>/dev/null || true"
        log_debug "Recorded symlink creation: $link_path -> $target"
    fi
}

# Record directory creation
record_mkdir() {
    local dir_path="$1"
    
    if [[ ! -d "$dir_path" ]]; then
        tpm_record "rmdir '$dir_path' 2>/dev/null || true"
        log_debug "Recorded directory creation: $dir_path"
    else
        log_debug "Directory already exists: $dir_path"
    fi
}

# Record manifest addition (for rollback: remove the tool)
record_manifest_add() {
    local tool_id="$1"
    
    tpm_record "if [[ -f '$TPM_MANIFEST_FILE' ]]; then \
        grep -B1 -A7 \"^tool=$tool_id\$\" '$TPM_MANIFEST_FILE' >/dev/null && \
        sed -i '/^---\$/,/^---\$/ { /^tool=$tool_id\$/d; }' '$TPM_MANIFEST_FILE' 2>/dev/null || true; \
    fi"
    log_debug "Recorded manifest addition rollback for: $tool_id"
}

# Record manifest update (for rollback: restore previous version)
record_manifest_update() {
    local tool_id="$1"
    
    # Save current manifest entry to a temporary file
    local backup_file="${TPM_TMP_DIR}/manifest_backup_${tool_id//\//_}_$(date +%s)"
    
    if [[ -f "$TPM_MANIFEST_FILE" ]]; then
        # Extract the current block for this tool
        awk '/^---$/ { block=!block; if(block) { current="" } else { if(current ~ /^tool='"${tool_id//\//\\/}"'$/) print_block=1 } } \
             block { current=current $0 RS } \
             !block && print_block { print "---"; printf "%s", current; print "---"; print_block=0 }' \
             "$TPM_MANIFEST_FILE" > "$backup_file" 2>/dev/null || true
        
        if [[ -s "$backup_file" ]]; then
            tpm_record "if [[ -f '$TPM_MANIFEST_FILE' ]] && [[ -f '$backup_file' ]]; then \
                sed -i '/^---\$/,/^---\$/ { /^tool=$tool_id\$/d; }' '$TPM_MANIFEST_FILE' 2>/dev/null || true; \
                cat '$backup_file' >> '$TPM_MANIFEST_FILE'; \
            fi"
            log_debug "Recorded manifest update rollback with backup: $tool_id"
        else
            # Fallback: just remove the entry
            record_manifest_add "$tool_id"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Transaction Safety Wrappers
# ------------------------------------------------------------------------------

# Safe file move with transaction recording
safe_move() {
    local source="$1"
    local destination="$2"
    
    if [[ ! -e "$source" ]]; then
        log_error "Source does not exist: $source"
        return 1
    fi
    
    # Record rollback: move back if destination exists, otherwise remove
    if [[ -e "$destination" ]]; then
        if [[ -d "$destination" ]]; then
            local backup_dir="${TPM_TMP_DIR}/backup/$(date +%s)/$(basename "$destination")"
            mkdir -p "$(dirname "$backup_dir")"
            
            if cp -r "$destination" "$backup_dir" 2>/dev/null; then
                tpm_record "rm -rf '$destination' 2>/dev/null || true; cp -r '$backup_dir' '$destination' 2>/dev/null || true"
            fi
        else
            local backup_file="${TPM_TMP_DIR}/backup/$(date +%s)/$(basename "$destination")"
            mkdir -p "$(dirname "$backup_file")"
            
            if cp "$destination" "$backup_file" 2>/dev/null; then
                tpm_record "rm -f '$destination' 2>/dev/null || true; cp '$backup_file' '$destination' 2>/dev/null || true"
            fi
        fi
    else
        tpm_record "rm -rf '$destination' 2>/dev/null || true"
    fi
    
    # Perform the move
    if mv "$source" "$destination"; then
        log_debug "Moved: $source -> $destination"
        return 0
    else
        log_error "Failed to move: $source -> $destination"
        return 1
    fi
}

# Safe copy with transaction recording
safe_copy() {
    local source="$1"
    local destination="$2"
    
    if [[ ! -e "$source" ]]; then
        log_error "Source does not exist: $source"
        return 1
    fi
    
    # Record rollback: remove the copy
    tpm_record "rm -rf '$destination' 2>/dev/null || true"
    
    # Perform the copy
    if cp -r "$source" "$destination"; then
        log_debug "Copied: $source -> $destination"
        return 0
    else
        log_error "Failed to copy: $source -> $destination"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Error Handling Integration
# ------------------------------------------------------------------------------

# Set up transaction-aware error handling
setup_transaction_trap() {
    # If we're in a transaction and get an error, rollback
    trap 'if tpm_in_transaction; then log_error "Script error detected, rolling back transaction"; tpm_rollback; fi' ERR
}

# Cleanup function for transaction system
cleanup_transaction() {
    if tpm_in_transaction; then
        log_warn "Cleaning up uncommitted transaction: $TRANSACTION_TYPE ($TRANSACTION_CONTEXT)"
        tpm_rollback
    fi
    
    # Clean up transaction backups (older than 1 hour)
    local backup_dir="${TPM_TMP_DIR}/backup"
    if [[ -d "$backup_dir" ]]; then
        find "$backup_dir" -type f -mmin +60 -delete 2>/dev/null || true
        find "$backup_dir" -type d -empty -delete 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------

# Initialize transaction module
init_transaction() {
    log_debug "Initializing transaction module"
    
    # Set up error trap
    setup_transaction_trap
    
    # Register cleanup on exit
    trap cleanup_transaction EXIT
    
    log_debug "Transaction module initialized"
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
    init_transaction
fi