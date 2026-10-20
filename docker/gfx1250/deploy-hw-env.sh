#!/usr/bin/env bash
# Deploy the gfx1250 hw docker env to a remote GPU host: stage the build files
# in /tmp there, build the image, and create/start the persistent container.
#
# Usage: ./docker/gfx1250/deploy-hw-env.sh user@host
#
# Only the three files the hw build actually reads are copied, into a
# throwaway /tmp dir that is removed afterwards. The Dockerfile has no
# COPY/ADD, so the build context needs nothing else, and the hw branch of
# env.sh does not use the artitoken secret -- so that credential is never
# uploaded. Your ~/work tree on the remote is left completely alone; sync it
# the usual way (see AGENTS.md) when you want to build or test code there.
set -euo pipefail

REMOTE_HOST=${1:-}
if [ -z "$REMOTE_HOST" ]; then
    echo "Usage: $0 user@host" >&2
    exit 2
fi

REMOTE_CONTAINER=mi450_rocking_env
# Resolved from this script's location, not the caller's cwd.
SRC_DIR=$(dirname "$(readlink -f "$0")")
BUILD_FILES=(Dockerfile env.sh toGfx1250HwEnv.sh)

log() { echo "[deploy-hw-env] $*"; }

log "Connecting to $REMOTE_HOST ..."
ssh -o StrictHostKeyChecking=accept-new "$REMOTE_HOST" true

# The login banner goes to stderr, so stdout is just the path.
STAGE=$(ssh "$REMOTE_HOST" 'mktemp -d /tmp/gfx1250-deploy.XXXXXX' 2>/dev/null)
if [ -z "$STAGE" ]; then
    echo "Could not create a staging dir on $REMOTE_HOST" >&2
    exit 1
fi
# shellcheck disable=SC2064
trap "ssh '$REMOTE_HOST' 'rm -rf \"$STAGE\"' >/dev/null 2>&1 || true" EXIT

log "Staging ${BUILD_FILES[*]} in $STAGE ..."
( cd "$SRC_DIR" && scp -q "${BUILD_FILES[@]}" "$REMOTE_HOST:$STAGE/" )
ssh "$REMOTE_HOST" "chmod +x '$STAGE'/*.sh"

log "Checking docker buildx on $REMOTE_HOST ..."
if ! ssh "$REMOTE_HOST" "docker buildx version" >/dev/null 2>&1; then
    log "buildx missing, installing docker-buildx via apt (requires passwordless sudo) ..."
    ssh "$REMOTE_HOST" "sudo apt-get update -qq && sudo apt-get install -y docker-buildx"
fi

log "Building hw image ..."
ssh "$REMOTE_HOST" "cd '$STAGE' && ./toGfx1250HwEnv.sh build"

log "Creating/starting container $REMOTE_CONTAINER ..."
# `run` target attaches an interactive shell (-it); with no local tty that
# just creates/starts the container and then exits once the ssh session
# drops. Force a pty and cap the wait so this doesn't hang.
timeout 20 ssh -tt "$REMOTE_HOST" "cd '$STAGE' && ./toGfx1250HwEnv.sh run" < /dev/null || true

log "Making sure $REMOTE_CONTAINER is up ..."
ssh "$REMOTE_HOST" "docker start $REMOTE_CONTAINER"
ssh "$REMOTE_HOST" "docker exec $REMOTE_CONTAINER bash -lc 'echo container ready'"

log "Done. Container $REMOTE_CONTAINER running on $REMOTE_HOST."
log "To make this your active target, set REMOTE_HOST in .remote.env."
