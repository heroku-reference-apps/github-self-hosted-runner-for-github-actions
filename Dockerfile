# Use the same image that Heroku apps use.
# https://devcenter.heroku.com/articles/stack
FROM heroku/heroku:24

# Inform utilities that we are in non-interactive mode.
ARG TERM=linux
ARG DEBIAN_FRONTEND=noninteractive

# this ARG can be overridden changing the heroku.yml, it must be 'latest' or a dot-separated number (e.g. 2.320.1)
# https://devcenter.heroku.com/articles/build-docker-images-heroku-yml#set-build-time-environment-variables
ARG RUNNER_VERSION=latest

# this ARG can be overridden changing the heroku.yml, it must be 'x64' (or 'arm64' when supported along with Dockerfile)
# https://devcenter.heroku.com/articles/build-docker-images-heroku-yml#set-build-time-environment-variables
ARG RUNNER_ARCH=x64

USER root

# Switch to bash shell.
#
# This resolves an error when the ENTRYPOINT script is started:
#   "OCI runtime create failed: container_linux.go:380:
#    starting container process caused: exec: "/bin/sh":
#    stat /bin/sh: no such file or directory: unknown"
#
# Note, even though Docker supports a 'SHELL' setting, Heroku doesn't support it.
# https://devcenter.heroku.com/articles/container-registry-and-runtime#unsupported-dockerfile-commands
#
# Remove /bin/sh and link to bash shell.
# https://stackoverflow.com/a/46670119/470818
RUN rm /bin/sh && ln -s /bin/bash /bin/sh

# Creating Heroku Dyno-like Environment with Docker
# This makes it more consistent with how Heroku dynos run,
# which set $HOME to '/app' and run as a non-root user.
# https://github.com/heroku/stack-images/issues/56#issuecomment-323378577
# https://github.com/heroku/stack-images/issues/56#issuecomment-348246257
ARG HOME="/app"
ENV HOME=${HOME}
WORKDIR ${HOME}

# Paths where we'll install various tools.
ARG ACTIONS_DIR="${HOME}/actions-runner"

# Create a non-root user. Heroku will not run as root.
# This step creates a user named 'docker' and creates its home directory.
# The user could be named anything, 'docker' just seemed fitting.
# https://ss64.com/bash/useradd.html
RUN useradd -m -d ${HOME} docker \
 && mkdir -p ${ACTIONS_DIR}

# ------------------------------------------------------------------------------
# Install GitHub Actions Runner
#
# The following commands come from GitHub's instructions
# at the time you choose which kind of self-hosted runner to create.
# https://github.com/organizations/{org}/settings/actions/runners/new
#
# Some of the instructions are inspired by the tutorial at
# https://testdriven.io/blog/github-actions-docker
#
# Learn more about self-hosted runners at
# https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners
# ------------------------------------------------------------------------------

# Switch to the actions directory to download and install the package.
# Note, doing a `cd` command in a `RUN` operation won't work like in a terminal,
# you must use `WORKDIR` to change your working directory.
WORKDIR ${ACTIONS_DIR}

# Download the latest GitHub Actions runner package.
COPY install-actions-runner.sh /tmp/install-actions-runner.sh
RUN sh /tmp/install-actions-runner.sh "$RUNNER_VERSION" "$RUNNER_ARCH" && rm -f /tmp/install-actions-runner.sh

# ------------------------------------------------------------------------------
# Copy files and set permissions
# ------------------------------------------------------------------------------

# Copy over our start.sh script that's in our repository
# and store it in the docker user's home directory.
COPY start.sh ${HOME}/start.sh

# Make the script executable and
# Make our docker user owner of the files we've added to the image.
RUN chmod ug+x ${HOME}/start.sh \
 && chown -R docker:docker ${HOME}

# Clean up the apt cache (as ./bin/installdependencies.sh above may install apt packages) to reduce image size for faster starts.
RUN apt-get autoremove --yes \
 && apt-get clean --yes \
 && rm -rf /var/lib/apt/lists/*

# Security hardening - removes SUID and SGID bits from executable files:
# - Removes potentially dangerous elevated privileges
# - Reduces the attack surface
# - Follows the principle of least privilege
RUN find / -perm /6000 -type f -exec chmod a-s {} \; || true

# ------------------------------------------------------------------------------
# Create User
# ------------------------------------------------------------------------------

# Since the config and run scripts for actions are not allowed to be run by root,
# switch to a different user so all subsequent commands are run as that user.
USER docker

# Confirm actions is where it should be.
RUN ${ACTIONS_DIR}/config.sh --version \
 && ${ACTIONS_DIR}/config.sh --commit

# Set the script to execute when the image starts.
# Note, even though Docker supports a 'SHELL' setting, Heroku doesn't support it.
# https://devcenter.heroku.com/articles/container-registry-and-runtime#unsupported-dockerfile-commands
#ENTRYPOINT ["/bin/bash", "-c", "/app/start.sh"]
CMD ["/app/start.sh"]

