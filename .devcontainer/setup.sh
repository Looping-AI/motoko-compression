#!/usr/bin/env bash
set -euo pipefail

# Load version pins from repo root
REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=../versions.env
source "$REPO_ROOT/versions.env"

echo "=== motoko-compression devcontainer setup ==="

# 1. Install system dependencies
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y jq wget

# 2. Install ICP CLI tooling
npm install -g @icp-sdk/icp-cli@${ICP_CLI_VERSION} @icp-sdk/ic-wasm@${IC_WASM_VERSION}

# 3. Install didc (pinned release)
wget -q "https://github.com/dfinity/candid/releases/download/${DIDC_VERSION}/didc-linux64" -O /tmp/didc
sudo mv /tmp/didc /usr/local/bin/didc
sudo chmod +x /usr/local/bin/didc

# 4. Install Mops
npm install -g ic-mops

# 5. Install Mops packages
mops install

echo "=== Setup complete ==="
