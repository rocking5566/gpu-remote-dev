#!/usr/bin/env bash
# GPU fleet health check: compile + run vector_add.cpp in a throwaway hw
# container on each host, in parallel. A hung or unreachable host is killed
# after TIMEOUT and reported as its own state instead of blocking the others.
set -uo pipefail

TIMEOUT=${TIMEOUT:-15}
IMAGE=${IMAGE:-mi450:rocm7.15.0a20260728}
CONTAINER_PATH=${CONTAINER_PATH:-/work/gpu-remote-dev}

# Fleet to check. Edit this list directly; pass hosts as args to override for
# a one-off run instead.
HOSTS=(
    chunylai@heliosr-1b114-b07-3.mnb.dcgpu
    chunylai@heliosr-1b114-b01-2.mnb.dcgpu
    chunylai@ct-heliosr-2b805-c3-2.aus-b200.dcgpu
    chunylai@ctheliosr-1b112-a31-1.mnb.dcgpu
    chunylai@ctheliosr-1b112-a31-2.mnb.dcgpu
    chunylai@heliosr-2b805-b8-2.aus-b200.dcgpu
)

if [ "$#" -gt 0 ]; then
    HOSTS=("$@")
fi

check_one() {
    local host="$1" out rc driver
    out=$(timeout -k 10 "$TIMEOUT" ssh -o ConnectTimeout=15 -o BatchMode=yes "$host" \
        bash -s -- "$IMAGE" "$CONTAINER_PATH" 2>&1 <<'REMOTE'
set -e
IMAGE="$1"
CONTAINER_PATH="$2"
echo "DRIVER:$(dpkg-query -W -f='${Version}' amdgpu-dkms 2>/dev/null || echo unknown)"
RENDER_GID=$(stat -c '%g' /dev/kfd)
docker run --rm \
    --device=/dev/kfd --device=/dev/dri \
    --ipc=host \
    --group-add video --group-add "$RENDER_GID" \
    --cap-add=SYS_PTRACE \
    -v "$HOME/work:/work" \
    -w "$CONTAINER_PATH" \
    "$IMAGE" \
    bash -lc 'hipcc -O2 vector_add.cpp -o /tmp/vector_add_healthcheck && /tmp/vector_add_healthcheck'
REMOTE
    )
    rc=$?

    driver=$(echo "$out" | grep '^DRIVER:' | head -1 | cut -d: -f2-)
    driver=${driver:-unknown}

    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        printf '%-45s TIMEOUT  driver=%-30s (no response within %ss)\n' "$host" "$driver" "$TIMEOUT"
    elif [ "$rc" -ne 0 ]; then
        printf '%-45s FAIL     driver=%-30s %s\n' "$host" "$driver" "$(echo "$out" | grep -v '^DRIVER:' | tail -1)"
    elif echo "$out" | grep -q "vector_add PASSED"; then
        printf '%-45s PASS     driver=%s\n' "$host" "$driver"
    else
        printf '%-45s FAIL     driver=%-30s %s\n' "$host" "$driver" "$(echo "$out" | grep -v '^DRIVER:' | tail -1)"
    fi
}

export -f check_one
export TIMEOUT IMAGE CONTAINER_PATH

printf '%s\n' "${HOSTS[@]}" | xargs -P "${#HOSTS[@]}" -I{} bash -c 'check_one "$@"' _ {}
