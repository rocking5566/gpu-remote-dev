#!/usr/bin/env bash
# FFM/CSIM 模擬器環境。實際邏輯在 env.sh。
set -euo pipefail
MODE=sim exec "$(dirname "$(readlink -f "$0")")/env.sh" "$@"
