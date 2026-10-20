#!/usr/bin/env bash
# Deploy the prebuilt ROCm PyTorch image and its container to a remote GPU host.
#
# Usage: ./docker/gfx1250/deploy-torch-env.sh user@host
#
# Same shape as deploy-hw-env.sh, except the image is pulled rather than built.
# Deliberately touches nothing else: no repo sync, no .remote.env edits.
#
# Afterwards:  ssh user@host "docker exec -it rocking_torch_env bash"
set -euo pipefail

REMOTE_HOST=${1:-}
if [ -z "$REMOTE_HOST" ]; then
    echo "Usage: $0 user@host" >&2
    exit 2
fi

# Tags on rocm/pytorch rotate, so allow an override without editing this file.
IMAGE=${IMAGE:-rocm/pytorch:rocm10.1.0_ubuntu24.04_py3.12_pytorch_release_2.14.0}
# Distinct from the gfx1250 image's mi450_rocking_env so both can coexist.
CONTAINER=${CONTAINER:-rocking_torch_env}

log() { echo "[deploy-torch-env] $*"; }

log "Connecting to $REMOTE_HOST ..."
ssh -o StrictHostKeyChecking=accept-new "$REMOTE_HOST" true

log "Pulling $IMAGE ..."
log "(multi-GB image; the first pull on a host takes a while)"
ssh "$REMOTE_HOST" bash -s -- "$IMAGE" <<'REMOTE'
set -e
docker pull "$1"
REMOTE

log "Creating/starting container $CONTAINER ..."
ssh "$REMOTE_HOST" bash -s -- "$IMAGE" "$CONTAINER" <<'REMOTE'
set -e
IMAGE="$1"
CONTAINER="$2"
RENDER_GID=$(stat -c '%g' /dev/kfd)
USERNAME=$(id -un)
USER_UID=$(id -u)
USER_GID=$(id -g)
mkdir -p "$HOME/work"

create() {
    # -dit, not -it: leaves the container running without needing a tty on the
    # ssh side. --ipc=host also covers PyTorch dataloaders' shared-memory use.
    # --user mirrors docker/gfx1250/env.sh so files written to /work stay owned
    # by you rather than root.
    docker run -dit --name "$CONTAINER" \
        --user "$USER_UID:$USER_GID" \
        -v "/home/$USERNAME:/home/$USERNAME" \
        -e "HOME=/home/$USERNAME" \
        --device=/dev/kfd --device=/dev/dri \
        --ipc=host \
        --group-add video --group-add "$RENDER_GID" \
        --cap-add=SYS_PTRACE \
        --net=host \
        -v "$HOME/work:/work" -w /work \
        "$IMAGE" bash
}

if [ -n "$(docker ps -aq -f "name=^/${CONTAINER}$")" ] &&
   [ "$(docker inspect -f '{{.Config.User}}' "$CONTAINER")" != "$USER_UID:$USER_GID" ]; then
    # --user is fixed at creation, so a container built with a different user
    # has to be replaced for the setting to take effect. Anything written
    # outside /work and /home is lost; both are host mounts, so that is scratch.
    echo "Container $CONTAINER does not run as $USER_UID:$USER_GID; recreating ..."
    docker rm -f "$CONTAINER"
    create
elif [ -n "$(docker ps -aq -f "name=^/${CONTAINER}$")" ]; then
    STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER")
    case "$STATUS" in
        running) echo "Container $CONTAINER is already running." ;;
        exited|created) echo "Starting $CONTAINER ..."; docker start "$CONTAINER" ;;
        paused) echo "Unpausing $CONTAINER ..."; docker unpause "$CONTAINER" ;;
        *) echo "Container $CONTAINER is '$STATUS'; recreating ..."
           docker rm -f "$CONTAINER"
           create ;;
    esac
else
    echo "Creating container $CONTAINER ..."
    create
fi
REMOTE

log "Smoke-testing PyTorch (version / gpu_available / device_count) ..."
if ssh "$REMOTE_HOST" bash -s -- "$CONTAINER" <<'REMOTE'
set -e
docker exec "$1" bash -lc 'python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.device_count())" 2>/dev/null || python3 -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.device_count())"'
REMOTE
then
    log "PyTorch OK."
else
    log "WARNING: PyTorch smoke test failed. The container is up anyway; debug with:"
    log "  ssh $REMOTE_HOST \"docker exec -it $CONTAINER bash\""
fi

log "Done. $CONTAINER is running on $REMOTE_HOST."
log "Attach with: ssh $REMOTE_HOST \"docker exec -it $CONTAINER bash\""
