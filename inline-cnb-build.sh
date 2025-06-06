#!/usr/bin/env bash
set -euo pipefail

echo "---> Heroku-hosted runner for GitHub Actions buildpack (CNB style)"

# Set APP_DIR to current working directory (where application source is located during build)
APP_DIR="$(pwd)"

# remove all the files in the buildpack working directory that are not required for the build
# Only keep start.sh and install-actions-runner.sh files
find . -mindepth 1 ! -name "start.sh" ! -name "install-actions-runner.sh" -delete

chmod +x "${APP_DIR}/start.sh"

mkdir -p "${APP_DIR}/actions-runner"

# Use the version from env or default to 'latest'
RUNNER_VERSION="${RUNNER_VERSION:-latest}"

# Use the architecture from CNB_TARGET_ARCH that can be amd64=>x64 or arm64
if [[ "${CNB_TARGET_ARCH}" == "amd64" ]]; then
    RUNNER_ARCH="x64"
else
    RUNNER_ARCH="${CNB_TARGET_ARCH:-arm64}"
fi

# Run the install script
chmod +x "${APP_DIR}/install-actions-runner.sh"
cd "${APP_DIR}/actions-runner" && "${APP_DIR}/install-actions-runner.sh" "$RUNNER_VERSION" "$RUNNER_ARCH"
rm "${APP_DIR}/install-actions-runner.sh"

# Write launch.toml to define the default process
# The launch.toml must be created in CNB_LAYERS_DIR even when running from workspace
cat > "${CNB_LAYERS_DIR}/launch.toml" <<EOL
[[processes]]
type = "runner"
command = ["${APP_DIR}/start.sh"]
default = true
EOL