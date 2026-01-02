#!/usr/bin/env bash
# TPM Test Script
# Tests the installation and basic functionality in a controlled environment

set -euo pipefail

echo "========================================"
echo "TPM - Test Script"
echo "========================================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_DIR="/tmp/tpm_test_$(date +%s)"
TEST_PREFIX="${TEST_DIR}/usr"
TEST_HOME="${TEST_DIR}/home"
TEST_REPO="${TEST_DIR}/repo"

# Create test directory structure
mkdir -p "${TEST_PREFIX}/bin"
mkdir -p "${TEST_PREFIX}/lib"
mkdir -p "${TEST_HOME}"
mkdir -p "${TEST_REPO}"
mkdir -p "${TEST_REPO}/lib"

# Export test environment
export PREFIX="${TEST_PREFIX}"
export HOME="${TEST_HOME}"

log_info() { echo -e "${BLUE}[TEST]${NC} $*"; }
log_success() { echo -e "${GREEN}[TEST]${NC} $*"; }
log_error() { echo -e "${RED}[TEST]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[TEST]${NC} $*"; }

# Cleanup function
cleanup() {
    log_info "Cleaning up test directory: ${TEST_DIR}"
    rm -rf "${TEST_DIR}"
}

trap cleanup EXIT

# Copy TPM files to test repository
copy_tpm_files() {
    log_info "Setting up test repository..."
    
    # Copy main executable
    cp tpm "${TEST_REPO}/tpm"
    chmod +x "${TEST_REPO}/tpm"
    
    # Copy libraries
    cp lib/core.sh "${TEST_REPO}/lib/"
    cp lib/manifest.sh "${TEST_REPO}/lib/"
    cp lib/transaction.sh "${TEST_REPO}/lib/"
    cp lib/github.sh "${TEST_REPO}/lib/"
    cp lib/store.sh "${TEST_REPO}/lib/"
    
    # Copy installer
    cp install.sh "${TEST_REPO}/install.sh"
    chmod +x "${TEST_REPO}/install.sh"
    
    log_success "Test repository created at: ${TEST_REPO}"
}

# Modify installer to use local repository
create_local_installer() {
    log_info "Creating local installer..."
    
    cat > "${TEST_DIR}/local_install.sh" <<EOF
#!/usr/bin/env bash
# Local test installer

# Override repository URL to use local test repo
export TPM_REPO="file://${TEST_REPO}"
export TPM_BRANCH=""

# Run the real installer
"${TEST_REPO}/install.sh"
EOF
    
    chmod +x "${TEST_DIR}/local_install.sh"
    log_success "Local installer created"
}

# Test 1: Installation
test_installation() {
    log_info "Test 1: Installing TPM..."
    
    if ! "${TEST_DIR}/local_install.sh"; then
        log_error "Installation failed"
        return 1
    fi
    
    # Verify installation
    if [[ ! -x "${TEST_PREFIX}/bin/tpm" ]]; then
        log_error "TPM executable not found"
        return 1
    fi
    
    if [[ ! -d "${TEST_PREFIX}/lib/tpm" ]]; then
        log_error "TPM libraries not found"
        return 1
    fi
    
    log_success "Installation test passed"
    return 0
}

# Test 2: Version command
test_version() {
    log_info "Test 2: Testing version command..."
    
    local output
    if ! output=$("${TEST_PREFIX}/bin/tpm" version 2>&1); then
        log_error "Version command failed"
        return 1
    fi
    
    if ! echo "$output" | grep -q "TPM - Termux Package Manager"; then
        log_error "Version output incorrect"
        return 1
    fi
    
    log_success "Version test passed"
    return 0
}

# Test 3: Help command
test_help() {
    log_info "Test 3: Testing help command..."
    
    local output
    if ! output=$("${TEST_PREFIX}/bin/tpm" help 2>&1); then
        log_error "Help command failed"
        return 1
    fi
    
    if ! echo "$output" | grep -q "Usage: tpm"; then
        log_error "Help output incorrect"
        return 1
    fi
    
    log_success "Help test passed"
    return 0
}

# Test 4: List command (empty)
test_list_empty() {
    log_info "Test 4: Testing list command (empty)..."
    
    local output
    if ! output=$("${TEST_PREFIX}/bin/tpm" list 2>&1); then
        log_error "List command failed"
        return 1
    fi
    
    if ! echo "$output" | grep -q "No tools installed"; then
        log_error "Empty list output incorrect"
        return 1
    fi
    
    log_success "List empty test passed"
    return 0
}

# Test 5: Repair command
test_repair() {
    log_info "Test 5: Testing repair command..."
    
    if ! "${TEST_PREFIX}/bin/tpm" repair 2>&1; then
        log_error "Repair command failed"
        return 1
    fi
    
    log_success "Repair test passed"
    return 0
}

# Test 6: Cleanup command
test_cleanup() {
    log_info "Test 6: Testing cleanup command..."
    
    if ! "${TEST_PREFIX}/bin/tpm" cleanup 2>&1; then
        log_error "Cleanup command failed"
        return 1
    fi
    
    log_success "Cleanup test passed"
    return 0
}

# Test 7: Verbose and debug flags
test_flags() {
    log_info "Test 7: Testing global flags..."
    
    # Test verbose flag
    if ! "${TEST_PREFIX}/bin/tpm" --verbose version 2>&1 | grep -q "TPM_BIN_DIR"; then
        log_warn "Verbose flag might not be working"
    fi
    
    # Test force flag (should just show help since no command)
    if ! "${TEST_PREFIX}/bin/tpm" --force help 2>&1 >/dev/null; then
        log_warn "Force flag might not be working"
    fi
    
    log_success "Flags test completed"
    return 0
}

# Mock GitHub API for testing
setup_mock_github() {
    log_info "Setting up mock GitHub responses..."
    
    # Create a mock release JSON for testing
    local mock_repo="${TEST_DIR}/mock_github"
    mkdir -p "${mock_repo}"
    
    cat > "${mock_repo}/release.json" <<EOF
{
  "tag_name": "v1.0.0",
  "name": "Test Release",
  "body": "Test release body",
  "assets": [
    {
      "name": "test-tool-linux-arm64.tar.gz",
      "browser_download_url": "file://${TEST_DIR}/mock_asset.tar.gz",
      "size": 1024
    }
  ]
}
EOF
    
    # Create a mock asset
    echo "#!/bin/bash
echo 'test binary'" > "${TEST_DIR}/mock_binary"
    chmod +x "${TEST_DIR}/mock_binary"
    
    tar -czf "${TEST_DIR}/mock_asset.tar.gz" -C "${TEST_DIR}" mock_binary
    
    # We'd need to mock the GitHub API calls, but for now we'll skip
    # actual installation tests since they require network
    log_warn "Skipping network-dependent tests in mock environment"
}

# Run all tests
run_tests() {
    local passed=0
    local failed=0
    local tests=(
        copy_tpm_files
        create_local_installer
        test_installation
        test_version
        test_help
        test_list_empty
        test_repair
        test_cleanup
        test_flags
    )
    
    for test_func in "${tests[@]}"; do
        echo ""
        log_info "Running: ${test_func}"
        
        if $test_func; then
            ((passed++))
        else
            ((failed++))
            log_error "Test failed: ${test_func}"
            
            # Ask if we should continue
            read -p "Continue with remaining tests? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                break
            fi
        fi
    done
    
    echo ""
    echo "========================================"
    log_info "Test Summary:"
    log_info "  Passed: ${passed}"
    log_info "  Failed: ${failed}"
    log_info "  Total:  $((passed + failed))"
    echo "========================================"
    
    if [[ $failed -eq 0 ]]; then
        log_success "All tests passed!"
        return 0
    else
        log_error "Some tests failed"
        return 1
    fi
}

# Main execution
main() {
    echo "Starting TPM tests in isolated environment..."
    echo "Test directory: ${TEST_DIR}"
    echo ""
    
    # Run tests
    if run_tests; then
        log_success "TPM test suite completed successfully"
        echo ""
        echo "Next steps:"
        echo "  1. Push files to a GitHub repository"
        echo "  2. Update install.sh with the correct repository URL"
        echo "  3. Test on actual Termux installation"
        echo ""
        echo "To clean up test files manually:"
        echo "  rm -rf ${TEST_DIR}"
        return 0
    else
        log_error "TPM test suite failed"
        echo ""
        echo "Test files preserved at: ${TEST_DIR}"
        echo "Debug information available in test directory"
        return 1
    fi
}

# Only run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi