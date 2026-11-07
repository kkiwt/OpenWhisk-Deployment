#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_SCRIPT="$SCRIPT_DIR/load.js"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/results}"
K6_BIN="${K6_BIN:-k6}"

usage() {
  cat <<EOF
Usage: $0 <run-name> <requests-per-second>

Environment:
  GATEWAY_URL   Gateway base URL (default: http://localhost:8080)
  DURATION      K6 duration (default: 5m)
  PRE_VUS       Pre-allocated K6 VUs (default: 100)
  MAX_VUS       Maximum K6 VUs (default: 300)
  TASKSET_CPUS  Optional CPU list for K6, e.g. 0,1
  TARGET_MODE   gateway (default) or direct
  DIRECT_PROPS  WSK properties file for direct mode, e.g. ~/.wskprops.c2
  DIRECT_API_URL, DIRECT_AUTH, DIRECT_CLUSTER
                Optional direct-mode overrides; auth is never written to results
  REMOTE_DOCKER_HOSTS
                Optional SSH targets, e.g. "c2=user@100.x.2 c3=user@100.x.3"
  RESULTS_DIR   Results root (default: $SCRIPT_DIR/results)
  K6_BIN        K6 executable (default: k6)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

RUN_NAME="$1"
RATE="$2"
if [[ ! "$RUN_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: run-name may contain only letters, numbers, dot, underscore, and hyphen." >&2
  exit 2
fi
if ! awk -v rate="$RATE" 'BEGIN { exit !(rate ~ /^[0-9]+([.][0-9]+)?$/ && rate > 0) }'; then
  echo "ERROR: requests-per-second must be a positive number." >&2
  exit 2
fi

command -v "$K6_BIN" >/dev/null 2>&1 || { echo "ERROR: K6 executable not found: $K6_BIN" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: Docker CLI is required to collect docker.csv." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is unavailable to this user." >&2; exit 1; }
[[ -f "$LOAD_SCRIPT" ]] || { echo "ERROR: K6 script not found: $LOAD_SCRIPT" >&2; exit 1; }

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
DURATION="${DURATION:-5m}"
PRE_VUS="${PRE_VUS:-100}"
MAX_VUS="${MAX_VUS:-300}"
TARGET_MODE="${TARGET_MODE:-gateway}"
DIRECT_NAMESPACE="${DIRECT_NAMESPACE:-_}"
DRY_RUN="${DRY_RUN:-0}"
REMOTE_DOCKER_HOSTS="${REMOTE_DOCKER_HOSTS:-}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-3}"

if [[ "$TARGET_MODE" != "gateway" && "$TARGET_MODE" != "direct" ]]; then
  echo "ERROR: TARGET_MODE must be gateway or direct." >&2
  exit 2
fi
if [[ "$TARGET_MODE" == "direct" ]]; then
  DIRECT_PROPS="${DIRECT_PROPS:-${WSK_CONFIG_FILE:-}}"
  if [[ -n "$DIRECT_PROPS" && -r "$DIRECT_PROPS" ]]; then
    DIRECT_API_URL="${DIRECT_API_URL:-$(sed -n 's/^APIHOST=//p' "$DIRECT_PROPS" | head -n 1)}"
    DIRECT_AUTH="${DIRECT_AUTH:-$(sed -n 's/^AUTH=//p' "$DIRECT_PROPS" | head -n 1)}"
    DIRECT_CLUSTER="${DIRECT_CLUSTER:-${DIRECT_PROPS##*.wskprops.}}"
  fi
  if [[ "${DIRECT_API_URL:-}" != https://* || -z "${DIRECT_AUTH:-}" ]]; then
    echo "ERROR: Direct mode requires HTTPS DIRECT_API_URL and guest auth (set DIRECT_PROPS to ~/.wskprops.cX)." >&2
    exit 2
  fi
  export DIRECT_API_URL DIRECT_AUTH DIRECT_CLUSTER DIRECT_NAMESPACE
fi

read -r -a REMOTE_HOST_ENTRIES <<< "$REMOTE_DOCKER_HOSTS"
for entry in "${REMOTE_HOST_ENTRIES[@]}"; do
  if [[ ! "$entry" =~ ^c[1-3]=[^=[:space:]]+$ ]]; then
    echo "ERROR: Each REMOTE_DOCKER_HOSTS entry must look like c2=user@host." >&2
    exit 2
  fi
done

STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT_DIR="$RESULTS_DIR/${RUN_NAME}_${STAMP}"
if [[ -e "$OUT_DIR" ]]; then
  OUT_DIR="${OUT_DIR}_$$"
fi
mkdir -p "$OUT_DIR"
TARGET_URL="$GATEWAY_URL"
if [[ "$TARGET_MODE" == "direct" ]]; then
  TARGET_URL="$DIRECT_API_URL"
fi

cat > "$OUT_DIR/run-info.txt" <<EOF
run_name=$RUN_NAME
rate=$RATE
duration=$DURATION
target_mode=$TARGET_MODE
target_url=$TARGET_URL
pre_vus=$PRE_VUS
max_vus=$MAX_VUS
remote_docker_hosts=${REMOTE_DOCKER_HOSTS:-none}
started_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

LOCAL_DOCKER_HOST="$(hostname -s)"
sample_host_cpu() {
  local timestamp user nice system idle iowait irq softirq steal total busy previous_total previous_idle
  printf 'timestamp_utc,cpu_percent\n'
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  previous_idle=$((idle + iowait))
  previous_total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  while true; do
    sleep 1
    read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    busy=$((total - previous_total - (idle + iowait - previous_idle)))
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    awk -v ts="$timestamp" -v b="$busy" -v t="$((total - previous_total))" \
      'BEGIN { if (t > 0) printf "%s,%.2f\n", ts, 100*b/t }'
    previous_idle=$((idle + iowait))
    previous_total="$total"
  done
}

sample_docker_stats() {
  local timestamp stats container cpu memory entry cluster ssh_host
  printf 'timestamp_utc,host,container,cpu_percent,mem_usage\n'
  while true; do
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if stats="$(docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' 2>>"$OUT_DIR/docker-stats.log")"; then
      while IFS=, read -r container cpu memory; do
        [[ -n "$container" ]] || continue
        printf '%s,%s,%s,%s,"%s"\n' "$timestamp" "$LOCAL_DOCKER_HOST" "$container" "$cpu" "$memory"
      done <<< "$stats"
    fi
    for entry in "${REMOTE_HOST_ENTRIES[@]}"; do
      [[ -n "$entry" ]] || continue
      cluster="${entry%%=*}"
      ssh_host="${entry#*=}"
      if stats="$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" "$ssh_host" \
          "docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}'" \
          2>>"$OUT_DIR/docker-stats.log")"; then
        while IFS=, read -r container cpu memory; do
          [[ -n "$container" ]] || continue
          printf '%s,%s,%s,%s,"%s"\n' "$timestamp" "$cluster" "$container" "$cpu" "$memory"
        done <<< "$stats"
      fi
    done
    sleep 1
  done
}

sample_docker_stats > "$OUT_DIR/docker.csv" &
STATS_PID=$!
sample_host_cpu > "$OUT_DIR/host_cpu.csv" &
CPU_STATS_PID=$!
cleanup() {
  if [[ -n "${K6_PID:-}" ]] && kill -0 "$K6_PID" 2>/dev/null; then
    kill "$K6_PID" 2>/dev/null || true
    wait "$K6_PID" 2>/dev/null || true
  fi
  if [[ -n "${STATS_PID:-}" ]] && kill -0 "$STATS_PID" 2>/dev/null; then
    kill "$STATS_PID" 2>/dev/null || true
    wait "$STATS_PID" 2>/dev/null || true
  fi
  if [[ -n "${CPU_STATS_PID:-}" ]] && kill -0 "$CPU_STATS_PID" 2>/dev/null; then
    kill "$CPU_STATS_PID" 2>/dev/null || true
    wait "$CPU_STATS_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

K6_ARGS=(run
  -e "RATE=$RATE"
  -e "GATEWAY_URL=$GATEWAY_URL"
  -e "TARGET_MODE=$TARGET_MODE"
  -e "DRY_RUN=$DRY_RUN"
  -e "DIRECT_API_URL=${DIRECT_API_URL:-}"
  -e "DIRECT_CLUSTER=${DIRECT_CLUSTER:-unknown}"
  -e "DIRECT_NAMESPACE=$DIRECT_NAMESPACE"
  -e "DURATION=$DURATION"
  -e "PRE_VUS=$PRE_VUS"
  -e "MAX_VUS=$MAX_VUS"
  --summary-export="$OUT_DIR/k6.json"
  "$LOAD_SCRIPT")

printf 'Run: %s\nMode: %s\nRate: %s req/s for %s\nTarget: %s\nOutput: %s\n' \
  "$RUN_NAME" "$TARGET_MODE" "$RATE" "$DURATION" "$TARGET_URL" "$OUT_DIR"

if [[ -n "${TASKSET_CPUS:-}" ]]; then
  command -v taskset >/dev/null 2>&1 || { echo "ERROR: TASKSET_CPUS is set but taskset is unavailable." >&2; exit 1; }
  taskset -c "$TASKSET_CPUS" "$K6_BIN" "${K6_ARGS[@]}" &
else
  "$K6_BIN" "${K6_ARGS[@]}" &
fi
K6_PID=$!
set +e
wait "$K6_PID"
K6_STATUS=$?
set -e
K6_PID=""

cleanup
trap - EXIT INT TERM
printf 'Finished. K6 summary: %s/k6.json\nDocker samples: %s/docker.csv\n' "$OUT_DIR" "$OUT_DIR"
exit "$K6_STATUS"
