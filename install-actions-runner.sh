#!/bin/bash

# Function to validate version input
validate_version() {
    local input="$1"
    # Check if input is "latest" or a dot-separated number (e.g. 2.320.1)
    if [[ "$input" == "latest" ]] || [[ "$input" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "$input"
    else
        echo "Error: Version must be 'latest' or a dot-separated number (e.g. 2.320.1)"
        exit 1
    fi
}

# Function to validate architecture input
validate_arch() {
    local arch="$1"
    if [[ "$arch" == "x64" || "$arch" == "arm64" ]]; then
        echo "$arch"
    else
        echo "Error: Architecture must be 'x64' or 'arm64'"
        exit 1
    fi
}

# Check if version parameter is provided
if [ -z "$1" ]; then
    echo "Error: Please provide a version (e.g. 'latest' or '2.320.1')."
    echo "Usage: $0 <version> <arch>"
    exit 1
fi

# Check if architecture parameter is provided
if [ -z "$2" ]; then
    echo "Error: Please provide the runner architecture ('x64' or 'arm64')."
    echo "Usage: $0 <version> <arch>"
    exit 1
fi

# Validate the version and architecture input
VERSION_INPUT=$(validate_version "$1")
ARCH_INPUT=$(validate_arch "$2")

# Define the GitHub repository and API endpoint
if [ "$VERSION_INPUT" == "latest" ]; then
    API_URL="https://api.github.com/repos/actions/runner/releases/latest"
else
    API_URL="https://api.github.com/repos/actions/runner/releases/tags/v${VERSION_INPUT}"
fi

# Fetch the latest release information
echo "Fetching latest release information from ${API_URL}..."
RELEASE_JSON=$(curl --silent --show-error --location "${API_URL}")

# Extract the version number
# printf is used to parse RELEASE_JSON as it might contain unescaped control characters (like newlines, tabs, ...)
RUNNER_VERSION=$(printf '%s' "${RELEASE_JSON}" | jq -r '.tag_name' | sed 's/^v//')
if [ -z "$RUNNER_VERSION" ]; then
    echo "Error: Could not determine the latest version."
    exit 1
fi
echo "Latest version: ${RUNNER_VERSION}"

# Define the asset name (e.g., for Linux x64 / arm64)
RUNNER_OS="linux"
RUNNER_ARCH="$ARCH_INPUT"

ASSET_NAME="actions-runner-${RUNNER_OS}-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
# printf is used to parse RELEASE_JSON as it might contain unescaped control characters (like newlines, tabs, ...)
ASSET_URL=$(printf '%s' "${RELEASE_JSON}" | jq -r --arg name "$ASSET_NAME" '.assets[] | select(.name == $name) | .browser_download_url')

if [ -z "$ASSET_URL" ]; then
    echo "Error: Could not find asset ${ASSET_NAME} in the latest release."
    exit 1
fi
echo "Asset URL: ${ASSET_URL}"

# Download the asset
echo "Downloading ${ASSET_NAME}..."
curl -sL "${ASSET_URL}" -o "${ASSET_NAME}"

# Compute the SHA256 hash
echo "Computing SHA256 hash of ${ASSET_NAME}..."
COMPUTED_SHA256=$(sha256sum "${ASSET_NAME}" | awk '{print $1}')
echo "Computed SHA256: ${COMPUTED_SHA256}"

# Extract the SHA256 hash from the release notes
echo "Extracting SHA256 from release notes..."
# printf is used to parse RELEASE_JSON as it might contain unescaped control characters (like newlines, tabs, ...)
RELEASE_NOTES=$(printf '%s' "${RELEASE_JSON}" | jq -r '.body')
EXPECTED_SHA256=$(echo "${RELEASE_NOTES}" | grep -A 1 "SHA" | grep "${ASSET_NAME}" | awk -F' -->|<!-- END SHA ' '{print $2}')

if [ -z "$EXPECTED_SHA256" ]; then
    echo "Error: Could not find SHA256 for ${ASSET_NAME} in release notes."
    exit 1
else
    echo "Expected SHA256 from release notes: ${EXPECTED_SHA256}"

    # Compare the computed and expected SHA256 hashes
    if [ "$COMPUTED_SHA256" == "$EXPECTED_SHA256" ]; then
        echo "Verification successful: Computed SHA256 matches the release notes."
    else
        echo "Verification failed: Computed SHA256 does NOT match the release notes."
        echo "Computed: ${COMPUTED_SHA256}"
        echo "Expected: ${EXPECTED_SHA256}"
        exit 1
    fi
fi

# Extract the runner. The additional dependencies usually required are already included using Heroku stack.
# https://github.com/actions/runner/blob/main/docs/start/envlinux.md#install-net-core-3x-linux-dependencies
tar xvfz "${ASSET_NAME}"

# Clean up
rm -f "${ASSET_NAME}"
echo "Cleaned up downloaded file." 