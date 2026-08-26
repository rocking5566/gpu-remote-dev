#!/usr/bin/env bash
# gfx1250 開發環境驅動腳本。由 toGfx1250Env.sh (MODE=sim) 與
# toGfx1250HwEnv.sh (MODE=hw) 呼叫，不建議直接執行。
#
#   sim  FFM/CSIM 模擬器，額外裝 rocdtif，不碰 /dev/kfd
#   hw   實體 MI450，不裝 rocdtif，掛 kfd/dri 與 render group
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

MODE=${MODE:-sim}

USERNAME=${USERNAME:-$(id -un)}
USER_UID=${USER_UID:-$(id -u)}
USER_GID=${USER_GID:-$(id -g)}

case "${MODE}" in
    sim)
        TAG=${TAG:-rocm7.15.0a20260712}
        IMAGE_NAME=mi450-sim:${TAG}
        CONTAINER_NAME=mi450_rocking_sim_env
        BUILD_EXTRA=(--secret "id=artitoken,src=./artitoken"
                     --build-arg "WITH_ROCDTIF=1")
        # 模擬器沒有裝置可掛，沿用既有的 --privileged。
        RUN_EXTRA=(--privileged)
        ;;
    hw)
        TAG=${TAG:-rocm7.15.0a20260728}
        IMAGE_NAME=mi450:${TAG}
        CONTAINER_NAME=mi450_rocking_env
        # 明確掛裝置即可，不用 --privileged。RENDER_GID 放在這裡求值，
        # 沒有 GPU 的機器跑 sim 模式才不會被 set -e 打死。
        RENDER_GID=$(stat -c '%g' /dev/kfd)
        BUILD_EXTRA=(--build-arg "WITH_ROCDTIF=0" --build-arg "RENDER_GID=${RENDER_GID}")
        RUN_EXTRA=(--device=/dev/kfd --device=/dev/dri
                   --ipc=host
                   --group-add video --group-add "${RENDER_GID}"
                   --cap-add=SYS_PTRACE)
        ;;
    *)
        echo "Unknown MODE: ${MODE} (expected 'sim' or 'hw')" >&2
        exit 2
        ;;
esac

VOLUMES=(-v "${HOME}/work:/work")
USER_PARAM=(--user "${USER_UID}:${USER_GID}"
            -v "/home/${USERNAME}:/home/${USERNAME}"
            -e "HOME=/home/${USERNAME}")

help() {
    cat <<EOF
Usage: $(basename "$0") [target] [TAG=... via environment]

Targets:
  build   Build image from Dockerfile
  run     Start/attach to persistent container
  bash    One-off ephemeral shell (--rm)
  clean   Remove persistent container
  help    Show this message

No target runs: build + bash

Variables:
  MODE    sim | hw (current: ${MODE})
  TAG     Base image tag (default: ${TAG})

Image: ${IMAGE_NAME}   Container: ${CONTAINER_NAME}
EOF
}

build() {
    DOCKER_BUILDKIT=1 docker build \
        --build-arg "USERNAME=${USERNAME}" \
        --build-arg "USER_UID=${USER_UID}" \
        --build-arg "USER_GID=${USER_GID}" \
        --build-arg "THEROCK_VER=${TAG}" \
        --build-arg "THEROCK_TAR=therock-dist-linux-gfx125X-dcgpu-${TAG#rocm}.tar.gz" \
        "${BUILD_EXTRA[@]}" \
        -t "${IMAGE_NAME}" -f Dockerfile .
}

run_bash() {
    docker run -it -w /work --rm \
        "${USER_PARAM[@]}" "${VOLUMES[@]}" "${RUN_EXTRA[@]}" --net=host "${IMAGE_NAME}" bash
}

create_container() {
    docker run -it -w /work --name "${CONTAINER_NAME}" \
        "${USER_PARAM[@]}" "${VOLUMES[@]}" "${RUN_EXTRA[@]}" --net=host "${IMAGE_NAME}" bash
}

run() {
    if [ -n "$(docker ps -aq -f "name=${CONTAINER_NAME}")" ]; then
        STATUS=$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null)
        case "${STATUS}" in
            running)
                echo "Container ${CONTAINER_NAME} is running, attaching..."
                docker exec -it "${CONTAINER_NAME}" bash
                ;;
            exited)
                echo "Container ${CONTAINER_NAME} is stopped, starting..."
                docker start -ai "${CONTAINER_NAME}"
                ;;
            paused)
                echo "Container ${CONTAINER_NAME} is paused, unpausing and attaching..."
                docker unpause "${CONTAINER_NAME}"
                docker exec -it "${CONTAINER_NAME}" bash
                ;;
            *)
                echo "Container ${CONTAINER_NAME} is in '${STATUS}' state, removing and recreating..."
                docker rm -f "${CONTAINER_NAME}"
                create_container
                ;;
        esac
    else
        echo "Creating new container ${CONTAINER_NAME}..."
        create_container
    fi
}

clean() {
    if [ -n "$(docker ps -aq -f "name=${CONTAINER_NAME}")" ]; then
        echo "Removing container ${CONTAINER_NAME}..."
        docker rm -f "${CONTAINER_NAME}"
    else
        echo "Container ${CONTAINER_NAME} does not exist."
    fi
}

case "${1:-}" in
    build) build ;;
    bash)  run_bash ;;
    run)   run ;;
    clean) clean ;;
    help|-h|--help) help ;;
    "")    build; run_bash ;;
    *)     echo "Unknown target: $1" >&2; echo ""; help; exit 2 ;;
esac
