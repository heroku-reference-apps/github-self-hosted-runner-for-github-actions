#!/usr/bin/env bash

# This file inspired by tutorial at
# https://testdriven.io/blog/github-actions-docker/
# It selects the runner directory based on the packaging method (Dockerfile or CNB buildpack)

# Requests a temporary token to register a GitHub runner.
# https://docs.github.com/en/rest/reference/actions#create-a-registration-token-for-an-organization

# Validating used environment variables to validate values and avoid code injection

# GitHub organization names can contain alphanumeric characters (a-z, A-Z, 0-9), hyphens (-), underscores (_), periods (.) and must be at least 1 character long and not exceed 60 characters in length
[[ "${GITHUB_ORGANIZATION}" ]] || { echo "GITHUB_ORGANIZATION is required"; exit 1; }
[[ "${GITHUB_ORGANIZATION}" =~ ^[A-Za-z0-9_.-]{1,60}$ ]] || { echo "GITHUB_ORGANIZATION contains invalid characters or is longer than 60 characters"; exit 1; }

# GitHub access tokens can contain alphanumeric characters (a-z, A-Z, 0-9), underscores (_)
[[ "${GITHUB_ACCESS_TOKEN}" ]] || { echo "GITHUB_ACCESS_TOKEN is required"; exit 1; }
[[ "${GITHUB_ACCESS_TOKEN}" =~ ^[a-zA-Z0-9_]+$ ]] || { echo "GITHUB_ACCESS_TOKEN contains invalid characters"; exit 1; }
# saving it locally before removing the env var (see unset_vars)
LOCAL_GITHUB_ACCESS_TOKEN="${GITHUB_ACCESS_TOKEN}"

# HIDDEN_ENV_VARS must only contain a list of space separated Heroku env vars. Those can contain uppercase letters (A-Z), numbers (0-9), underscores (_)
# spaces are allowed in the regexpr as those are used as separator for Heroku env vars
if [[ -n "${HIDDEN_ENV_VARS}" ]]; then
  [[ "${HIDDEN_ENV_VARS}" =~ ^[A-Z][A-Z0-9_\ ]*$ ]] || { echo "HIDDEN_ENV_VARS contains invalid characters"; exit 1; }
fi

# Holds short-lived registration token for attaching/detaching self-hosted runners with GitHub Actions framework.
# This variable is populated at runtime as needed because it does expire after an hour.
GITHUB_REG_TOKEN=""
GITHUB_REG_TOKEN_URL="https://api.github.com/orgs/${GITHUB_ORGANIZATION}/actions/runners/registration-token"

# -------------------------------------------------------------------

unset_vars() {
    # List of space separated env vars that has to be hidden to the runner (and workflows) to avoid being logged (leaked) to the GitHub logs
    # GITHUB_ACCESS_TOKEN is always unset even if GitHub already prevents from being logged in clear text
    if [[ -n "${HIDDEN_ENV_VARS}" ]]; then
        for var in ${HIDDEN_ENV_VARS}; do
          echo "Unsetting $var"
          unset "$var"
        done
        unset "GITHUB_ACCESS_TOKEN"
    fi
}

# Use access token to obtain a short-lived registration token for adding and removing runners.
# For example, when this container starts up then we need to attach this runner
# to our GitHub organization. Likewise, when this container shuts down then
# we need to remove this runner from our GitHub organization.
# Runners that are inactive for 30 days are automatically removed by GitHub.
getRegistrationToken() {
  GITHUB_REG_TOKEN=$(curl --silent -X POST -H "Authorization: token ${LOCAL_GITHUB_ACCESS_TOKEN}" "${GITHUB_REG_TOKEN_URL}" | jq .token --raw-output)
}

# software update is managed via schedule or manually that's the reason --disableupdate is used. 
# If you use ephemeral runners in containers then this can lead to repeated software updates when a new runner version is released. 
# Turning off automatic updates allows you to update the runner version on the container image directly on your own schedule.
# see https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners#controlling-runner-software-updates-on-self-hosted-runners
attachRunner() {
  echo "[self-hosted runner] Attaching runner ..."
  getRegistrationToken
  ./config.sh \
    --unattended \
    --token "${GITHUB_REG_TOKEN}" \
    --url "https://github.com/${GITHUB_ORGANIZATION}" \
    --replace \
    --disableupdate \
    --ephemeral \
    ${GITHUB_RUNNER_LABELS:+--labels "${GITHUB_RUNNER_LABELS}"} \
    ${GITHUB_RUNNER_GROUP:+--runnergroup "${GITHUB_RUNNER_GROUP}"}

  # using the default runner name (--name option is not used) that on Linux defaults to hostname 
  echo "[self-hosted runner] registered runner name $(hostname)"
}

detachRunner() {
  echo "[self-hosted runner] Removing runner ..."
  getRegistrationToken
  ./config.sh remove \
    --token "${GITHUB_REG_TOKEN}"
}

# Directory selection logic
# If the installation was done in the Dockerfile, use the Dockerfile path
# Otherwise, default to CNB path that is in the current working directory
if [[ -d "${HOME}/actions-runner" ]]; then
  RUNNER_DIR="${HOME}/actions-runner"
elif [[ -d "${PWD}/actions-runner" ]]; then
  RUNNER_DIR="${PWD}/actions-runner"
else
  echo "Could not determine runner directory. Neither CNB nor Dockerfile path exists." >&2
  exit 1
fi

cd "$RUNNER_DIR" || { echo "error while changing directory to $RUNNER_DIR"; exit 1; }

attachRunner

# In case of error or the dyno shutting down,
# detach this runner from the GitHub Actions framework.
#
# In bash, the way to "catch" an exception is with `trap` command.
# Syntax is `trap {command to run} {error code to handle}`
# https://sodocumentation.net/bash/topic/363/using--trap--to-react-to-signals-and-system-events
#
# `INT` refers to SIGINT status code, the process interrupted at the terminal (Ctrl+C)
# `TERM` refers to SIGTERM status code, the process was told to shutdown.
#
# POSIX systems return a status code as a number, which is 128 + N
# where N is the value of the actual error.
#
# SIGINT has a value of 2, so the exit code is 130 (128+2).
# SIGTERM has a value of 15, so the exit code is 143 (128+15).
# https://en.wikipedia.org/wiki/Signal_(IPC)#Default_action
trap 'echo \[self-hosted runner\] received SIGINT; detachRunner; wait $PID' INT
trap 'echo \[self-hosted runner\] received SIGTERM; detachRunner; wait $PID' TERM

# Normally, bash will ignore any signals while a child process is executing.
# Starting the server with & (single ampersand) will background it into the
# shell's job control system, with `$!` holding the server's PID.
#
# Calling `wait` will then wait for the job with the specified PID (the server)
# to finish, or for any signals to be fired.
#
# For more on shell signal handling along with `wait`, review this Stack Exchange answer
# https://unix.stackexchange.com/questions/146756/forward-sigterm-to-child-in-bash/146770#146770
#
# Also note that we are invoking runsvc.sh and not run.sh because the runner
# program self-updates (no way to disable it) and according to online discussions
# the service script should handle the update and keep the processing running
# rather than shutting down and becoming a zombie runner that won't run jobs.
# https://github.com/actions/runner/issues/485
# https://github.com/actions/runner/issues/484
# https://github.com/actions/runner/issues/246

# hiding sensitive env vars to the runner
unset_vars

./bin/runsvc.sh &
PID=$!
wait $PID

echo "[self-hosted runner] Exiting ..." 