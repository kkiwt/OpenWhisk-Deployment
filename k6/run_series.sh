#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_EXP="$SCRIPT_DIR/run_exp.sh"
RESULTS_ROOT="${RESULTS_DIR:-$SCRIPT_DIR/results}"

usage() {
  cat <<EOF
Usage: $0 <series-name> <requests-per-second> [--yes]

Runs a 1-minute warm-up, then collects 3 valid 5-minute measurements by default,
with a 2-minute cooldown between measurement attempts. Invalid attempts are kept
but excluded from the median. Set WARMUP_DURATION, MEASURE_DURATION, REPEATS,
MAX_ATTEMPTS, COOLDOWN_SECONDS, or MAX_HOST_CPU to adjust the protocol.
The current target settings (TARGET_MODE, WSK_CONFIG_FILE, GATEWAY_URL, and
REMOTE_DOCKER_HOSTS) are passed through to run_exp.sh.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage >&2
  exit 2
fi

SERIES_NAME="$1"
RATE="$2"
ASSUME_YES=0
if [[ "${3:-}" == "--yes" ]]; then ASSUME_YES=1; fi
if [[ ! "$SERIES_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: series-name may contain only letters, numbers, dot, underscore, and hyphen." >&2
  exit 2
fi
if ! awk -v rate="$RATE" 'BEGIN { exit !(rate ~ /^[0-9]+([.][0-9]+)?$/ && rate > 0) }'; then
  echo "ERROR: requests-per-second must be a positive number." >&2
  exit 2
fi
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "ERROR: run_series.sh is for real measurements; unset DRY_RUN first." >&2
  exit 2
fi

WARMUP_DURATION="${WARMUP_DURATION:-1m}"
MEASURE_DURATION="${MEASURE_DURATION:-5m}"
REPEATS="${REPEATS:-3}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-5}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-120}"
MAX_HOST_CPU="${MAX_HOST_CPU:-70}"
for value in "$REPEATS" "$MAX_ATTEMPTS" "$COOLDOWN_SECONDS"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "ERROR: repeat/attempt/cooldown settings must be integers." >&2; exit 2; }
done
(( REPEATS > 0 && MAX_ATTEMPTS >= REPEATS )) || {
  echo "ERROR: MAX_ATTEMPTS must be at least REPEATS, and REPEATS must be positive." >&2
  exit 2
}

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "This will send real traffic at $RATE req/s (target mode: ${TARGET_MODE:-gateway}). Continue? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

STAMP="$(date -u +%Y%m%d_%H%M%S)"
SERIES_DIR="$RESULTS_ROOT/series_${SERIES_NAME}_${STAMP}"
RUNS_DIR="$SERIES_DIR/runs"
mkdir -p "$RUNS_DIR"
SUMMARY="$SERIES_DIR/series-summary.csv"
printf 'attempt,run_dir,req_rate,avg_ms,p50_ms,p95_ms,error_rate,dropped_iterations,host_cpu_max,valid,reason\n' > "$SUMMARY"

run_one() {
  local run_name="$1" duration="$2" log_path="$3"
  local runner_status
  LAST_RUN_DIR=""
  set +e
  RESULTS_DIR="$RUNS_DIR" DURATION="$duration" "$RUN_EXP" "$run_name" "$RATE" 2>&1 | tee "$log_path"
  runner_status=${PIPESTATUS[0]}
  set -e
  LAST_RUN_DIR="$(sed -n 's/^Output: //p' "$log_path" | tail -n 1)"
  if [[ -z "$LAST_RUN_DIR" || ! -d "$LAST_RUN_DIR" ]]; then
    echo "ERROR: Could not locate run output; see $log_path" >&2
    return 1
  fi
  return "$runner_status"
}

append_attempt() {
  python3 - "$SUMMARY" "$@" <<'PY'
import csv
import sys
with open(sys.argv[1], "a", newline="") as stream:
    csv.writer(stream).writerow(sys.argv[2:])
PY
}

printf 'Series: %s\nRate: %s req/s\nWarm-up: %s\nMeasurement: %s x %s valid runs\nOutput: %s\n' \
  "$SERIES_NAME" "$RATE" "$WARMUP_DURATION" "$MEASURE_DURATION" "$REPEATS" "$SERIES_DIR"

WARMUP_LOG="$SERIES_DIR/warmup.log"
run_one "${SERIES_NAME}_warmup" "$WARMUP_DURATION" "$WARMUP_LOG" || true

VALID_RUNS=0
ATTEMPT=0
while (( VALID_RUNS < REPEATS && ATTEMPT < MAX_ATTEMPTS )); do
  ATTEMPT=$((ATTEMPT + 1))
  RUN_NAME="${SERIES_NAME}_run${ATTEMPT}"
  RUN_LOG="$SERIES_DIR/${RUN_NAME}.log"
  run_one "$RUN_NAME" "$MEASURE_DURATION" "$RUN_LOG" || true
  RUN_DIR="$LAST_RUN_DIR"

  STATS="$(python3 - "$RUN_DIR" "$MAX_HOST_CPU" <<'PY'
import csv
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
max_cpu_limit = float(sys.argv[2])
summary = json.loads((run_dir / "k6.json").read_text())
metrics = summary.get("metrics", {})
def metric(name, key, default=0.0):
    return metrics.get(name, {}).get("values", {}).get(key, default)

http_rate = metric("http_reqs", "rate")
avg_ms = metric("http_req_duration", "avg")
p50_ms = metric("http_req_duration", "med")
p95_ms = metric("http_req_duration", "p(95)")
error_rate = metric("http_req_failed", "rate")
dropped = metric("dropped_iterations", "count")
cpus = []
try:
    with (run_dir / "host_cpu.csv").open(newline="") as stream:
        cpus = [float(row["cpu_percent"]) for row in csv.DictReader(stream) if row.get("cpu_percent")]
except (OSError, ValueError, KeyError):
    pass
cpu_max = max(cpus) if cpus else None
reasons = []
if dropped > 0:
    reasons.append("dropped_iterations")
if cpu_max is None:
    reasons.append("host_cpu_missing")
elif cpu_max > max_cpu_limit:
    reasons.append("host_cpu_over_limit")
valid = not reasons
fields = [http_rate, avg_ms, p50_ms, p95_ms, error_rate, dropped, "" if cpu_max is None else cpu_max,
          "yes" if valid else "no", ";".join(reasons)]
print("\t".join(str(value) for value in fields))
PY
)"
  IFS=$'\t' read -r HTTP_RATE AVG_MS P50_MS P95_MS ERROR_RATE DROPPED CPU_MAX IS_VALID REASON <<< "$STATS"
  append_attempt "$ATTEMPT" "$RUN_DIR" "$HTTP_RATE" "$AVG_MS" "$P50_MS" "$P95_MS" \
    "$ERROR_RATE" "$DROPPED" "$CPU_MAX" "$IS_VALID" "$REASON"
  echo "Attempt $ATTEMPT: valid=$IS_VALID, dropped=$DROPPED, host_cpu_max=${CPU_MAX:-missing}% ${REASON:+($REASON)}"
  [[ "$IS_VALID" == "yes" ]] && VALID_RUNS=$((VALID_RUNS + 1))
  if (( VALID_RUNS < REPEATS && ATTEMPT < MAX_ATTEMPTS )); then
    echo "⏳ Cooling down for ${COOLDOWN_SECONDS}s..."
    sleep "$COOLDOWN_SECONDS"
  fi
done

python3 - "$SUMMARY" "$REPEATS" <<'PY'
import csv
import statistics
import sys

path, required = sys.argv[1], int(sys.argv[2])
with open(path, newline="") as stream:
    rows = list(csv.DictReader(stream))
valid = [row for row in rows if row["valid"] == "yes"]
print(f"\nValid measurements: {len(valid)}/{required}")
if valid:
    medians = {}
    for key, label in (("req_rate", "HTTP req/s"), ("avg_ms", "Average ms"),
                       ("p50_ms", "P50 ms"), ("p95_ms", "P95 ms"),
                       ("error_rate", "Error rate"), ("host_cpu_max", "Host CPU max %")):
        values = [float(row[key]) for row in valid if row[key]]
        if values:
            medians[key] = statistics.median(values)
            print(f"Median {label}: {medians[key]:.3f}")
    with open(path, "a", newline="") as stream:
        csv.writer(stream).writerow([
            "MEDIAN_VALID", f"{len(valid)} valid runs", medians.get("req_rate", ""),
            medians.get("avg_ms", ""), medians.get("p50_ms", ""), medians.get("p95_ms", ""),
            medians.get("error_rate", ""), statistics.median(float(row["dropped_iterations"]) for row in valid),
            medians.get("host_cpu_max", ""), "yes", "",
        ])
print(f"Summary: {path}")
sys.exit(0 if len(valid) >= required else 1)
PY
