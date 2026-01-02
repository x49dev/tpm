# TPM - Termux Package Manager

A lightweight, dependency-free package manager for Termux that enables safe, version-tracked installation of third-party CLI tools directly from GitHub releases.

## Features

- **Atomic Operations**: Install, update, and remove tools with full rollback on failure
- **Version Tracking**: Keep track of installed versions and available updates
- **Architecture Detection**: Automatically selects the correct binary for your Termux device
- **No Dependencies**: Pure Bash with coreutils only
- **Safe Storage**: Versioned store with automatic cleanup of old versions
- **Manifest System**: Track all installations in a human-readable format

## Quick Start

### Installation

```bash
curl -fsSL https://raw.githubusercontent.com/termux-pm/tpm/main/install.sh | bash
```

Basic Usage

```bash
# Install a tool
tpm install sharkdp/bat

# List installed tools
tpm list

# Update a tool
tpm update sharkdp/bat

# Update all tools
tpm update --all

# Remove a tool
tpm remove sharkdp/bat

# Get tool information
tpm info sharkdp/bat

# Repair TPM installation
tpm repair

# Clean up old versions
tpm cleanup
```

Commands

· tpm install <owner/repo> - Install a tool from GitHub
· tpm list - List installed tools (use --verbose for details)
· tpm update <tool> - Update a specific tool
· tpm update --all - Update all installed tools
· tpm remove <tool> - Remove an installed tool
· tpm info <tool> - Show information about a tool
· tpm repair - Repair TPM installation (fix symlinks, validate)
· tpm cleanup - Clean up old versions (keeps last 3)
· tpm version - Show TPM version and info
· tpm help - Show help message

Global Options

· --force - Force operation (install/remove)
· --verbose - Show verbose output
· --debug - Show debug information (includes set -x)

How It Works

TPM manages tools in a versioned store:

```
~/.tpm/
├── manifest          # Installation records
└── config           # Configuration

${PREFIX}/tpm/store/
├── <owner>/
│   ├── <repo>/
│   │   ├── <version>/
│   │   │   ├── bin/      # Executable
│   │   │   ├── lib/      # Libraries (if any)
│   │   │   └── share/    # Shared files (if any)
│   │   └── current -> <version>  # Symlink to current version
└── tmp/             # Temporary files
```

Supported Platforms

· Termux on Android 8+
· Architectures: aarch64 (arm64), arm, i686, x86_64
· Bash 5.1+ with coreutils (curl, grep, sed, awk, tar, gzip)

GitHub Rate Limits

TPM uses GitHub's public API which has rate limits (60 requests per hour). If you hit limits:

1. Wait an hour for the limit to reset
2. Use --verbose to see remaining rate limit
3. Consider using a GitHub token (future feature)

Examples

Install popular tools:

```bash
tpm install sharkdp/bat          # Bat - cat clone with syntax highlighting
tpm install sharkdp/fd           # fd - find alternative
tpm install BurntSushi/ripgrep   # ripgrep - grep replacement
tpm install jgm/pandoc          # Pandoc - document converter
```

Update workflow:

```bash
# Check what's installed
tpm list

# Update everything
tpm update --all

# Or update specific tools
tpm update sharkdp/bat
tpm update sharkdp/fd
```

Configuration

Edit ~/.tpm/config to customize:

```bash
# Network settings
TPM_CURL_TIMEOUT=30
TPM_MAX_RETRIES=2

# Display settings
TPM_COLOR=auto  # auto, always, never

# Path overrides (uncomment to change)
# export TPM_STORE_DIR="${PREFIX}/tpm/store"
# export TPM_TMP_DIR="${PREFIX}/tpm/tmp"
```

Uninstallation

```bash
~/.tpm/uninstall.sh
```

Or manually:

```bash
rm -f ${PREFIX}/bin/tpm
rm -rf ${PREFIX}/lib/tpm
rm -rf ${PREFIX}/tpm
rm -rf ~/.tpm
```

Limitations

· Only supports GitHub releases
· Always installs latest release (no version pinning in MVP)
· No signature verification (trusts GitHub release integrity)
· No dependency management between tools
· No custom install scripts or post-install hooks

Contributing

TPM is under active development. Please report issues and feature requests on GitHub.

License

MIT License - see LICENSE file for details.