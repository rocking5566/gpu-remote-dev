#!/usr/bin/env bash
# 實體 MI450 環境。實際邏輯在 env.sh。
set -euo pipefail
MODE=hw exec "$(dirname "$(readlink -f "$0")")/env.sh" "$@"
