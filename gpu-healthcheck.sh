#!/usr/bin/env bash
# GPU fleet health check: compile + run vector_add.cpp in a throwaway hw
# container on each host, in parallel. A hung or unreachable host is killed
# after TIMEOUT and reported as its own state instead of blocking the others.
set -uo pipefail

TIMEOUT=${TIMEOUT:-30}
SYNC_TIMEOUT=${SYNC_TIMEOUT:-60}
IMAGE=${IMAGE:-rocm/pytorch:rocm10.1.0_ubuntu24.04_py3.12_pytorch_release_2.14.0}
CONTAINER_PATH=${CONTAINER_PATH:-/work/gpu-remote-dev}
RSYNC_EXCLUDES=${RSYNC_EXCLUDES:-"--exclude build/ --exclude .rocprofv3/ --exclude .git/ --exclude .claude/ --exclude .codex/ --exclude .superpowers/"}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Fleet to check. Edit this list directly; pass hosts as args to override for
# a one-off run instead.
HOSTS=(
    chunylai@heliosr-1b114-b01-2.mnb.dcgpu
    chunylai@heliosp-1b114-c01-3.mnb.dcgpu
    chunylai@heliosr-1b114-b01-4.mnb.dcgpu
    chunylai@heliosr-1b114-e02-4.mnb.dcgpu
    chunylai@heliosr-1b114-d05-4.mnb.dcgpu
    chunylai@heliosr-1b114-b07-2.mnb.dcgpu
    chunylai@heliosr-1b114-b07-3.mnb.dcgpu
    chunylai@heliosr-2b805-b8-2.aus-b200.dcgpu
    chunylai@heliosr-2b805-b8-3.aus-b200.dcgpu
    chunylai@ctheliosr-rck-g02-e15-03.rck.dcgpu
    chunylai@ctheliosr-rck-g02-e15-13.rck.dcgpu
)

[ "$#" -eq 0 ] || HOSTS=("$@")

ssh_error_summary() {
    # Prefer the SSH diagnostic over login banners or rsync's trailing summary.
    printf '%s\n' "$1" | tr -d '\r' | awk '
        NF { last = $0 }
        /^(ssh:|ssh_exchange_identification:|kex_exchange_identification:|Connection |.*: Permission denied|Host key verification failed|No .*host key is known|REMOTE HOST IDENTIFICATION HAS CHANGED)/ { error = $0 }
        END { print (error != "" ? error : (last != "" ? last : "SSH exited without an error message")) }
    '
}

report() {
    # host and driver are local to the calling check_one function.
    if [ "$1" = PASS ]; then
        printf '%-45s PASS     driver=%s\n' "$host" "$driver"
    else
        printf '%-45s %-8s driver=%-*s %s\n' "$host" "$1" "${3:-30}" "$driver" "$2"
    fi
}

check_one() {
    local host="$1" driver=unknown out rc remote_dir sync_log

    # /work is the host's ~/work bind mount. Sync only if the source is missing.
    remote_dir="work${CONTAINER_PATH#/work}"
    out=$(timeout -k 5 15 ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" \
            "test -f \"\$HOME/$remote_dir/vector_add.cpp\"" 2>&1)
    rc=$?
    case "$rc" in
        0|1) ;;
        124|137) report SSHFAIL 'SSH connection/file check timed out after 15s'; return ;;
        *) report SSHFAIL "$(ssh_error_summary "$out")"; return ;;
    esac
    if [ "$rc" -eq 1 ]; then
        sync_log=$(mktemp)
        timeout -k 10 "$SYNC_TIMEOUT" rsync -az --delete $RSYNC_EXCLUDES \
                -e 'ssh -o ConnectTimeout=15 -o BatchMode=yes' \
                "$SCRIPT_DIR/" "$host:$remote_dir/" >"$sync_log" 2>&1
        rc=$?
        case "$rc" in
            0) ;;
            255) report SSHFAIL "during rsync: $(ssh_error_summary "$(cat "$sync_log")")" ;;
            *) report SYNCFAIL "rsync to $remote_dir failed: $(tail -1 "$sync_log")" 28 ;;
        esac
        rm -f "$sync_log"
        [ "$rc" -eq 0 ] || return 0
    fi

    out=$(timeout -k 10 "$TIMEOUT" ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" \
        bash -s -- "$IMAGE" "$CONTAINER_PATH" 2>&1 <<'REMOTE'
set -e
IMAGE="$1"
CONTAINER_PATH="$2"
echo "DRIVER:$(dpkg-query -W -f='${Version}' amdgpu-dkms 2>/dev/null || echo unknown)"
RENDER_GID=$(stat -c '%g' /dev/kfd)
docker run --rm --user "$(id -u):$(id -g)" \
    --device=/dev/kfd --device=/dev/dri --ipc=host \
    --group-add video --group-add "$RENDER_GID" \
    --cap-add=SYS_PTRACE -v "$HOME/work:/work" -w "$CONTAINER_PATH" "$IMAGE" \
    bash -lc 'hipcc -O2 vector_add.cpp -o /tmp/vector_add_healthcheck && /tmp/vector_add_healthcheck'
REMOTE
    )
    rc=$?

    driver=$(echo "$out" | grep '^DRIVER:' | head -1 | cut -d: -f2-)
    driver=${driver:-unknown}

    case "$rc" in
        124|137) report TIMEOUT "(no response within ${TIMEOUT}s)" ;;
        255) report SSHFAIL "$(ssh_error_summary "$out")" ;;
        *)
            if [ "$rc" -eq 0 ] && echo "$out" | grep -q 'vector_add PASSED'; then
                report PASS
            else
                report FAIL "$(echo "$out" | grep -v '^DRIVER:' | tail -1)"
            fi ;;
    esac
}

export -f check_one ssh_error_summary report
export TIMEOUT SYNC_TIMEOUT IMAGE CONTAINER_PATH RSYNC_EXCLUDES SCRIPT_DIR

printf '%s\n' "${HOSTS[@]}" | xargs -P "${#HOSTS[@]}" -I{} bash -c 'check_one "$@"' _ {}
