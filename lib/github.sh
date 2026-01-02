#!/usr/bin/env bash
# TPM GitHub Integration
# Version: 0.1.0

set -euo pipefail

# ------------------------------------------------------------------------------
# GitHub API Configuration
# ------------------------------------------------------------------------------

GITHUB_API_BASE="https://api.github.com"
GITHUB_RAW_BASE="https://raw.githubusercontent.com"
GITHUB_RELEASE_CACHE_DIR="${TPM_TMP_DIR}/github_cache"
GITHUB_CACHE_TTL=300  # 5 minutes in seconds

# Rate limiting tracking
declare -i GITHUB_RATE_LIMIT_REMAINING=60
declare -i GITHUB_RATE_LIMIT_RESET=0

# ------------------------------------------------------------------------------
# API Response Parsing (jq-free)
# ------------------------------------------------------------------------------

# Parse JSON field from GitHub API response
# Usage: json_field "$json_string" "field_name"
json_field() {
    local json="$1"
    local field="$2"
    
    # Simple grep approach for specific fields
    # This assumes the field is on its own line with format: "field": value
    echo "$json" | grep -o "\"$field\": *\"[^\"]*\"" | head -n1 | cut -d'"' -f4
}

# Parse JSON array field (like assets)
# Usage: json_array_field "$json_string" "array_field" index "subfield"
json_array_field() {
    local json="$1"
    local array_field="$2"
    local index="$3"
    local subfield="$4"
    
    # Extract the array block for the given index
    local array_block
    array_block=$(echo "$json" | sed -n "/\"$array_field\": \[/,/\]/p" | sed -n "/{/,/}/p" | sed -n "$((index + 1))p" 2>/dev/null)
    
    if [[ -n "$array_block" ]]; then
        json_field "$array_block" "$subfield"
    fi
}

# Count items in a JSON array
json_array_count() {
    local json="$1"
    local array_field="$2"
    
    # Count occurrences of the object pattern within the array
    echo "$json" | sed -n "/\"$array_field\": \[/,/\]/p" | grep -c "{"
}

# ------------------------------------------------------------------------------
# Rate Limit Handling
# ------------------------------------------------------------------------------

# Check and update rate limit from response headers
update_rate_limit() {
    local headers="$1"
    
    # Extract rate limit headers
    local remaining
    local reset
    
    remaining=$(echo "$headers" | grep -i "x-ratelimit-remaining:" | tail -n1 | awk '{print $2}' | tr -d '\r')
    reset=$(echo "$headers" | grep -i "x-ratelimit-reset:" | tail -n1 | awk '{print $2}' | tr -d '\r')
    
    if [[ -n "$remaining" ]] && [[ "$remaining" =~ ^[0-9]+$ ]]; then
        GITHUB_RATE_LIMIT_REMAINING=$remaining
    fi
    
    if [[ -n "$reset" ]] && [[ "$reset" =~ ^[0-9]+$ ]]; then
        GITHUB_RATE_LIMIT_RESET=$reset
    fi
    
    log_debug "GitHub rate limit: $GITHUB_RATE_LIMIT_REMAINING remaining, resets at $(date -d "@$GITHUB_RATE_LIMIT_RESET")"
}

# Check if we're rate limited
check_rate_limit() {
    local now
    now=$(date +%s)
    
    if [[ $GITHUB_RATE_LIMIT_REMAINING -le 1 ]] && [[ $now -lt $GITHUB_RATE_LIMIT_RESET ]]; then
        local wait_seconds=$((GITHUB_RATE_LIMIT_RESET - now + 5))
        log_error "GitHub API rate limit exceeded"
        log_error "Please wait $wait_seconds seconds or use a GitHub token"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# GitHub API Client
# ------------------------------------------------------------------------------

# Make a GitHub API request with caching and rate limit handling
# Usage: github_api_request "endpoint" -> outputs response body, headers in variable GITHUB_LAST_HEADERS
github_api_request() {
    local endpoint="$1"
    local url="${GITHUB_API_BASE}${endpoint}"
    local cache_file="${GITHUB_RELEASE_CACHE_DIR}${endpoint//[^a-zA-Z0-9]/_}.json"
    local headers_file="${cache_file}.headers"
    
    # Check cache first
    if [[ -f "$cache_file" ]] && [[ -f "$headers_file" ]]; then
        local cache_age
        cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
        
        if [[ $cache_age -lt $GITHUB_CACHE_TTL ]]; then
            log_debug "Using cached response for: $endpoint"
            GITHUB_LAST_HEADERS=$(cat "$headers_file")
            cat "$cache_file"
            return 0
        fi
    fi
    
    # Check rate limit before making request
    if ! check_rate_limit; then
        return 1
    fi
    
    log_debug "Fetching from GitHub API: $endpoint"
    
    # Make the request, capturing headers and body separately
    local response
    local headers
    local temp_file
    
    temp_file=$(mktemp "${TPM_TMP_DIR}/github_response.XXXXXX")
    
    # Use curl to get headers and body
    if ! curl -sSfL \
        --retry 2 \
        --retry-delay 1 \
        --connect-timeout "$TPM_CURL_TIMEOUT" \
        --max-time "$((TPM_CURL_TIMEOUT * 3))" \
        -D "${temp_file}.headers" \
        -o "$temp_file" \
        "$url"; then
        rm -f "$temp_file" "${temp_file}.headers"
        log_error "Failed to fetch from GitHub API: $endpoint"
        return 1
    fi
    
    # Read headers and update rate limit
    headers=$(cat "${temp_file}.headers")
    update_rate_limit "$headers"
    GITHUB_LAST_HEADERS="$headers"
    
    # Read response
    response=$(cat "$temp_file")
    
    # Check for API errors
    if echo "$response" | grep -q "\"message\": \"API rate limit"; then
        log_error "GitHub API rate limit exceeded (in response)"
        rm -f "$temp_file" "${temp_file}.headers"
        return 1
    fi
    
    if echo "$response" | grep -q "\"message\": \""; then
        local error_msg
        error_msg=$(json_field "$response" "message")
        log_error "GitHub API error: $error_msg"
        rm -f "$temp_file" "${temp_file}.headers"
        return 1
    fi
    
    # Cache the response
    mkdir -p "$(dirname "$cache_file")"
    echo "$response" > "$cache_file"
    echo "$headers" > "$headers_file"
    
    # Cleanup and output
    rm -f "$temp_file" "${temp_file}.headers"
    echo "$response"
    return 0
}

# ------------------------------------------------------------------------------
# Release Information
# ------------------------------------------------------------------------------

# Get latest release information for a repository
# Returns JSON response as string
get_latest_release() {
    local owner="$1"
    local repo="$2"
    
    log_debug "Fetching latest release for: $owner/$repo"
    
    local response
    if ! response=$(github_api_request "/repos/$owner/$repo/releases/latest"); then
        log_error "Failed to get latest release for $owner/$repo"
        return 1
    fi
    
    # Validate response has basic structure
    if [[ -z "$response" ]] || ! echo "$response" | grep -q "\"tag_name\":"; then
        log_error "Invalid response from GitHub API for $owner/$repo"
        return 1
    fi
    
    echo "$response"
    return 0
}

# Get specific release by tag
get_release_by_tag() {
    local owner="$1"
    local repo="$2"
    local tag="$3"
    
    log_debug "Fetching release $tag for: $owner/$repo"
    
    local response
    if ! response=$(github_api_request "/repos/$owner/$repo/releases/tags/$tag"); then
        log_error "Failed to get release $tag for $owner/$repo"
        return 1
    fi
    
    echo "$response"
    return 0
}

# Get the latest version tag
get_latest_version() {
    local owner="$1"
    local repo="$2"
    
    local response
    if ! response=$(get_latest_release "$owner" "$repo"); then
        return 1
    fi
    
    local version
    version=$(json_field "$response" "tag_name")
    
    if [[ -z "$version" ]]; then
        log_error "No version found in release for $owner/$repo"
        return 1
    fi
    
    echo "$version"
    return 0
}

# ------------------------------------------------------------------------------
# Asset Selection & Scoring
# ------------------------------------------------------------------------------

# Score an asset based on filename and architecture
# Higher score = better match
score_asset() {
    local asset_name="$1"
    local asset_url="$2"  # Not used currently, but available for future expansion
    
    local score=0
    local name_lower
    name_lower=$(echo "$asset_name" | tr '[:upper:]' '[:lower:]')
    
    # Architecture scoring
    case "$TPM_ARCH" in
        arm64)
            if [[ "$name_lower" =~ arm64 ]] || [[ "$name_lower" =~ aarch64 ]]; then
                score=$((score + 50))
            fi
            ;;
        arm)
            if [[ "$name_lower" =~ arm ]] && ! [[ "$name_lower" =~ arm64 ]] && ! [[ "$name_lower" =~ aarch64 ]]; then
                score=$((score + 50))
            fi
            ;;
        i686)
            if [[ "$name_lower" =~ 386 ]] || [[ "$name_lower" =~ i686 ]] || [[ "$name_lower" =~ x86 ]] && ! [[ "$name_lower" =~ x86_64 ]]; then
                score=$((score + 50))
            fi
            ;;
        x86_64)
            if [[ "$name_lower" =~ x86_64 ]] || [[ "$name_lower" =~ amd64 ]]; then
                score=$((score + 50))
            fi
            ;;
    esac
    
    # Platform scoring
    if [[ "$name_lower" =~ linux ]]; then
        score=$((score + 30))
    fi
    
    if [[ "$name_lower" =~ musl ]]; then
        # Prefer non-musl for Termux
        score=$((score - 10))
    fi
    
    if [[ "$name_lower" =~ gnu ]]; then
        score=$((score + 5))
    fi
    
    # File type scoring
    if [[ "$name_lower" =~ \.tar\.gz$ ]] || [[ "$name_lower" =~ \.tgz$ ]]; then
        score=$((score + 20))
    elif [[ "$name_lower" =~ \.zip$ ]]; then
        score=$((score + 10))
    elif [[ "$name_lower" =~ \.tar\.xz$ ]] || [[ "$name_lower" =~ \.txz$ ]]; then
        score=$((score + 15))
    elif [[ "$name_lower" =~ \.tar\.bz2$ ]] || [[ "$name_lower" =~ \.tbz2$ ]]; then
        score=$((score + 15))
    fi
    
    # Negative scoring for unwanted platforms
    if [[ "$name_lower" =~ darwin ]] || [[ "$name_lower" =~ macos ]]; then
        score=$((score - 100))
    fi
    
    if [[ "$name_lower" =~ windows ]] || [[ "$name_lower" =~ win ]]; then
        score=$((score - 100))
    fi
    
    if [[ "$name_lower" =~ freebsd ]] || [[ "$name_lower" =~ openbsd ]] || [[ "$name_lower" =~ netbsd ]]; then
        score=$((score - 50))
    fi
    
    # Negative for source code
    if [[ "$name_lower" =~ source ]] || [[ "$name_lower" =~ src ]]; then
        score=$((score - 200))
    fi
    
    # Negative for debug symbols
    if [[ "$name_lower" =~ debug ]] || [[ "$name_lower" =~ dbg ]]; then
        score=$((score - 150))
    fi
    
    # Bonus for static binaries
    if [[ "$name_lower" =~ static ]]; then
        score=$((score + 10))
    fi
    
    # Bonus for minimal/no dependencies
    if [[ "$name_lower" =~ minimal ]] || [[ "$name_lower" =~ standalone ]]; then
        score=$((score + 5))
    fi
    
    log_debug "Asset '$asset_name' score: $score"
    echo "$score"
}

# Select the best asset from a release
select_best_asset() {
    local release_json="$1"
    
    local asset_count
    asset_count=$(json_array_count "$release_json" "assets")
    
    if [[ $asset_count -eq 0 ]]; then
        log_error "No assets found in release"
        return 1
    fi
    
    local best_score=-9999
    local best_asset_name=""
    local best_asset_url=""
    local best_asset_size=""
    
    log_debug "Evaluating $asset_count assets for architecture: $TPM_ARCH"
    
    for (( i=0; i < asset_count; i++ )); do
        local asset_name
        local asset_url
        local asset_size
        
        asset_name=$(json_array_field "$release_json" "assets" "$i" "name")
        asset_url=$(json_array_field "$release_json" "assets" "$i" "browser_download_url")
        asset_size=$(json_array_field "$release_json" "assets" "$i" "size")
        
        if [[ -z "$asset_name" ]] || [[ -z "$asset_url" ]]; then
            continue
        fi
        
        local score
        score=$(score_asset "$asset_name" "$asset_url")
        
        if [[ $score -gt $best_score ]]; then
            best_score=$score
            best_asset_name="$asset_name"
            best_asset_url="$asset_url"
            best_asset_size="$asset_size"
        fi
    done
    
    if [[ -z "$best_asset_url" ]]; then
        log_error "No suitable asset found for architecture: $TPM_ARCH"
        log_error "Available assets:"
        for (( i=0; i < asset_count; i++ )); do
            local asset_name
            asset_name=$(json_array_field "$release_json" "assets" "$i" "name")
            echo "  - $asset_name"
        done
        return 1
    fi
    
    if [[ $best_score -lt 0 ]]; then
        log_warn "Best asset has negative score ($best_score): $best_asset_name"
        log_warn "This might not be the correct binary for your system"
    fi
    
    log_debug "Selected asset: $best_asset_name (score: $best_score, size: ${best_asset_size} bytes)"
    
    # Return as space-separated string: name url size
    echo "$best_asset_name $best_asset_url $best_asset_size"
    return 0
}

# Get asset checksum if available in release body
get_asset_checksum() {
    local release_json="$1"
    local asset_name="$2"
    
    local release_body
    release_body=$(json_field "$release_json" "body")
    
    if [[ -z "$release_body" ]]; then
        return 0  # No checksum available
    fi
    
    # Look for checksum lines in the format: checksum filename
    # Common patterns: SHA256, sha256, md5, SHA1
    local checksum_patterns=("sha256" "sha1" "md5")
    
    for pattern in "${checksum_patterns[@]}"; do
        local checksum_line
        checksum_line=$(echo "$release_body" | grep -i "^$pattern.*$asset_name" | head -n1)
        
        if [[ -n "$checksum_line" ]]; then
            # Extract the checksum (first field after the pattern)
            local checksum
            checksum=$(echo "$checksum_line" | awk '{print $2}')
            
            if [[ -n "$checksum" ]] && [[ "$checksum" =~ ^[a-fA-F0-9]{32,128}$ ]]; then
                echo "${pattern}:${checksum}"
                return 0
            fi
        fi
    done
    
    # Also check for checksum files in assets
    local asset_count
    asset_count=$(json_array_count "$release_json" "assets")
    
    for (( i=0; i < asset_count; i++ )); do
        local check_asset_name
        check_asset_name=$(json_array_field "$release_json" "assets" "$i" "name")
        
        if [[ "$check_asset_name" =~ ^.*(sha256|sha1|md5|checksums)\.(txt|sum)$ ]]; then
            local checksum_file_url
            checksum_file_url=$(json_array_field "$release_json" "assets" "$i" "browser_download_url")
            
            log_debug "Found checksum file: $check_asset_name"
            # Note: We could download and parse this, but for MVP we'll skip
            # This is a future enhancement
        fi
    done
    
    return 0
}

# ------------------------------------------------------------------------------
# Asset Download & Verification
# ------------------------------------------------------------------------------

# Download an asset with progress indicator
download_asset() {
    local asset_url="$1"
    local output_path="$2"
    local expected_checksum="${3:-}"
    
    log_info "Downloading: $(basename "$output_path")"
    
    # Create temporary download file
    local temp_file
    temp_file=$(mktemp "${TPM_TMP_DIR}/download.XXXXXX")
    
    # Record rollback for cleanup
    tpm_record "rm -f '$temp_file' 2>/dev/null || true"
    
    # Download with progress
    local curl_cmd=(curl -sSfL --retry 2 --retry-delay 1 --connect-timeout "$TPM_CURL_TIMEOUT")
    
    # Add progress indicator if terminal
    if [[ -t 1 ]] && [[ "$TPM_COLOR" != "never" ]]; then
        curl_cmd+=("-#")
    else
        curl_cmd+=("--silent" "--show-error")
    fi
    
    curl_cmd+=("-o" "$temp_file" "$asset_url")
    
    if ! "${curl_cmd[@]}"; then
        rm -f "$temp_file"
        log_error "Download failed: $asset_url"
        return 1
    fi
    
    # Verify checksum if provided
    if [[ -n "$expected_checksum" ]]; then
        local checksum_type="${expected_checksum%%:*}"
        local expected_hash="${expected_checksum#*:}"
        local actual_hash
        
        case "$checksum_type" in
            sha256)
                if ! command -v sha256sum >/dev/null 2>&1; then
                    log_warn "sha256sum not available, skipping checksum verification"
                else
                    actual_hash=$(sha256sum "$temp_file" | awk '{print $1}')
                    if [[ "$actual_hash" != "$expected_hash" ]]; then
                        rm -f "$temp_file"
                        log_error "Checksum verification failed for $(basename "$output_path")"
                        log_error "Expected: $expected_hash"
                        log_error "Got: $actual_hash"
                        return 1
                    fi
                    log_debug "Checksum verified: $actual_hash"
                fi
                ;;
            sha1)
                if ! command -v sha1sum >/dev/null 2>&1; then
                    log_warn "sha1sum not available, skipping checksum verification"
                else
                    actual_hash=$(sha1sum "$temp_file" | awk '{print $1}')
                    if [[ "$actual_hash" != "$expected_hash" ]]; then
                        rm -f "$temp_file"
                        log_error "Checksum verification failed"
                        return 1
                    fi
                fi
                ;;
            md5)
                if ! command -v md5sum >/dev/null 2>&1; then
                    log_warn "md5sum not available, skipping checksum verification"
                else
                    actual_hash=$(md5sum "$temp_file" | awk '{print $1}')
                    if [[ "$actual_hash" != "$expected_hash" ]]; then
                        rm -f "$temp_file"
                        log_error "Checksum verification failed"
                        return 1
                    fi
                fi
                ;;
            *)
                log_warn "Unknown checksum type: $checksum_type, skipping verification"
                ;;
        esac
    fi
    
    # Move to final location
    if ! safe_move "$temp_file" "$output_path"; then
        rm -f "$temp_file"
        return 1
    fi
    
    log_success "Download completed: $(basename "$output_path")"
    return 0
}

# ------------------------------------------------------------------------------
# Repository Validation
# ------------------------------------------------------------------------------

# Check if a GitHub repository exists and has releases
validate_repository() {
    local owner="$1"
    local repo="$2"
    
    log_debug "Validating repository: $owner/$repo"
    
    # First check if repo exists
    local repo_info
    if ! repo_info=$(github_api_request "/repos/$owner/$repo"); then
        log_error "Repository not found or inaccessible: $owner/$repo"
        return 1
    fi
    
    # Check if it's a fork (sometimes forks have different release patterns)
    local is_fork
    is_fork=$(json_field "$repo_info" "fork")
    if [[ "$is_fork" == "true" ]]; then
        log_warn "Repository $owner/$repo is a fork"
    fi
    
    # Check if it has releases
    local releases_response
    if ! releases_response=$(github_api_request "/repos/$owner/$repo/releases"); then
        log_error "Failed to check releases for $owner/$repo"
        return 1
    fi
    
    local release_count
    release_count=$(json_array_count "$releases_response" "")
    
    if [[ $release_count -eq 0 ]]; then
        log_error "Repository $owner/$repo has no releases"
        return 1
    fi
    
    log_debug "Repository validated: $owner/$repo ($release_count releases)"
    return 0
}

# ------------------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------------------

# Initialize GitHub module
init_github() {
    log_debug "Initializing GitHub module"
    
    # Create cache directory
    mkdir -p "$GITHUB_RELEASE_CACHE_DIR"
    
    # Set default User-Agent for GitHub API
    export GITHUB_USER_AGENT="TPM/$TPM_VERSION (https://github.com/x49dev/tpm)"
    
    log_debug "GitHub module initialized"
    return 0
}

# Cleanup GitHub cache
cleanup_github_cache() {
    if [[ -d "$GITHUB_RELEASE_CACHE_DIR" ]]; then
        # Remove files older than 1 hour
        find "$GITHUB_RELEASE_CACHE_DIR" -type f -mmin +60 -delete 2>/dev/null || true
    fi
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
    init_github
    
    # Register cache cleanup on exit
    trap cleanup_github_cache EXIT
fi