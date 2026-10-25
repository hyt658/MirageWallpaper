#!/bin/bash
#
#  Mirage Wallpaper
#
#  Copyright © 2026 王孝慈. All rights reserved.
#

set -euo pipefail

if [[ "$#" -ne 2 || ( "$1" != staple && "$1" != validate ) ]]; then
    echo "Usage / 用法: bash stapler_with_retry.sh <staple|validate> <path>" >&2
    exit 64
fi

operation="$1"
target="$2"
log="$(mktemp -t mirage-stapler)"
trap 'rm -f "$log"' EXIT
delay=5

for attempt in 1 2 3 4; do
    if xcrun stapler "$operation" "$target" > "$log" 2>&1; then
        cat "$log"
        exit 0
    else
        status=$?
    fi
    cat "$log" >&2

    # EX_NOHOST (68) also covers a missing notarization or an unexpected server
    # response. Retry only explicit transport failures, never ticket errors.
    if [[ "$status" -ne 68 ]] || ! LC_ALL=C grep -Eq \
        'Error Domain=NSURLErrorDomain Code=-(1001|1005)([^0-9]|$)' "$log"; then
        exit "$status"
    fi
    if [[ "$attempt" -eq 4 ]]; then
        echo "[stapler] Network retries exhausted / 网络重试次数已用尽 ($operation)." >&2
        exit "$status"
    fi

    echo "[stapler] Network failure / 网络故障 ($operation, $attempt/4); retry in / 重试等待 ${delay}s." >&2
    sleep "$delay"
    delay=$((delay * 2))
done
