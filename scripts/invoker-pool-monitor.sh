#!/bin/bash

NAMESPACE="openwhisk"
STATEFULSET="owdev-invoker"
INTERVAL=30

echo "Starting Invoker ContainerPool Monitor (MONITOR ONLY)..."

while true; do
    total=0

    for pod in $(kubectl get pods -n "$NAMESPACE" \
        -l app=owdev-invoker -o name 2>/dev/null); do

        count=$(kubectl logs -n "$NAMESPACE" "$pod" \
            --since="${INTERVAL}s" 2>/dev/null \
            | grep -c 'Rescheduling Run message')

        echo "$pod: $count rescheduling"
        total=$((total + count))
    done

    replicas=$(kubectl get statefulset "$STATEFULSET" \
        -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')

    echo "$(date '+%H:%M:%S') | Total=$total | Replicas=$replicas"

    if [ "$total" -ge 10 ]; then
        echo "[PRESSURE] ContainerPool đang có dấu hiệu quá tải!"
    else
        echo "[NORMAL] ContainerPool pressure thấp."
    fi

    sleep "$INTERVAL"
done
