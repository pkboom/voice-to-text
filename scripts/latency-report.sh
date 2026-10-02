#!/usr/bin/env bash
# Summarize the app's latency log lines and gate AC13: total_ms p50 <= 1000 ms.
# Summary lines look like (see Core/Sources/VoiceToTextCore/Diagnostics/Latency.swift):
#   total_ms=812 stt_ms=540 clean_ms=0 paste_ms=35 capture_start_ms=60 audio_s=10.50 outcome=passthrough
#
# By default this reads from the unified log (process VoiceToText, subsystem
# com.keunbae.VoiceToText, category latency) via `log show`.
#
# Usage:
#   scripts/latency-report.sh [WINDOW]             # `log show --last WINDOW` (default: 1h)
#   scripts/latency-report.sh --from-file <path>   # read pre-formatted log lines from a file (testing)
#   scripts/latency-report.sh --from-file -        # read pre-formatted log lines from stdin
#
# n/p50/p90/max are reported for total_ms, stt_ms, paste_ms and capture_start_ms. The single
# pass/fail gate is total_ms p50 <= 1000 ms. The report is written to .omc/artifacts/latency-v1.txt
# (override with VTT_LATENCY_ARTIFACT) and also printed to stdout.
set -euo pipefail
cd "$(dirname "$0")/.."

PREDICATE='subsystem == "com.keunbae.VoiceToText" AND category == "latency" AND process == "VoiceToText"'
ARTIFACT="${VTT_LATENCY_ARTIFACT:-.omc/artifacts/latency-v1.txt}"

FROM_FILE=""
WINDOW="1h"
if [[ "${1:-}" == "--from-file" ]]; then
  [[ $# -ge 2 ]] || { echo "!! --from-file requires a path (or - for stdin)" >&2; exit 1; }
  FROM_FILE="$2"
elif [[ $# -ge 1 ]]; then
  WINDOW="$1"
fi

mkdir -p "$(dirname "$ARTIFACT")"

report_source() {
  if [[ -n "$FROM_FILE" ]]; then
    if [[ "$FROM_FILE" == "-" ]]; then cat; else cat "$FROM_FILE"; fi
  else
    log show --last "$WINDOW" --style compact --info --debug --predicate "$PREDICATE" 2>/dev/null
  fi
}

report_source | awk '
    function pct(arr, n, p,   idx) {
      idx = int((p / 100.0) * (n - 1) + 0.5) + 1
      return arr[idx]
    }
    function sortn(arr, n,   i, j, t) {
      for (i = 2; i <= n; i++) { t = arr[i]; j = i - 1
        while (j >= 1 && arr[j] > t) { arr[j + 1] = arr[j]; j-- }
        arr[j + 1] = t }
    }
    BEGIN { nf = split("total_ms stt_ms paste_ms capture_start_ms", fields, " ") }
    {
      for (i = 1; i <= NF; i++) {
        if (split($i, kv, "=") == 2 && kv[2] ~ /^[0-9]+(\.[0-9]+)?$/) {
          k = kv[1]; cnt[k]++; vals[k, cnt[k]] = kv[2] + 0
        }
      }
    }
    END {
      status = 0
      for (f = 1; f <= nf; f++) {
        k = fields[f]; n = cnt[k] + 0
        if (n == 0) { printf "%-17s n=0\n", k; continue }
        delete a
        for (i = 1; i <= n; i++) a[i] = vals[k, i]
        sortn(a, n)
        p50 = pct(a, n, 50)
        printf "%-17s n=%d p50=%g p90=%g max=%g\n", k, n, p50, pct(a, n, 90), a[n]
        if (k == "total_ms") total_p50 = p50
      }
      if (cnt["total_ms"] + 0 == 0) { print "RESULT: FAIL (no total_ms samples)"; exit 1 }
      if (total_p50 <= 1000) { printf "RESULT: PASS (total_ms p50=%g <= 1000)\n", total_p50 }
      else { printf "RESULT: FAIL (total_ms p50=%g > 1000)\n", total_p50; status = 1 }
      exit status
    }' | tee "$ARTIFACT"
