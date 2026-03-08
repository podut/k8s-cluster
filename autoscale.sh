#!/bin/bash
# Kubernetes Worker Autoscaler for Docker-in-Docker cluster
# Scales workers from 2 to MAX_WORKERS based on resource pressure
# Usage: ./autoscale.sh [start|status|scale-up|scale-down|stop]

MIN_WORKERS=2
MAX_WORKERS=5
CPU_THRESHOLD=80        # Scale up when CPU requests exceed this % of allocatable
MEM_THRESHOLD=80        # Scale up when memory requests exceed this % of allocatable
SCALE_DOWN_CPU=30       # Scale down when below this %
SCALE_DOWN_MEM=30       # Scale down when below this %
CHECK_INTERVAL=30       # Seconds between checks
NETWORK="k8s_k8s-net"
BASE_IMAGE="k8s-cluster/worker-1:v1"
BASE_IP="172.20.0"      # Workers get .21, .22, .23, .24, .25
PID_FILE="/tmp/autoscale.pid"
LOG_FILE="/tmp/autoscale.log"

SCALE_DOWN_WAIT=4       # Number of consecutive checks with low usage before scaling down (4 * 30s = 2 min)
STABILIZATION_COUNT=0   # Counter for scale down stabilization

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

sync_clock() {
  local name=$1
  log "Syncing clock on $name..."
  docker exec "$name" date -s "$(date '+%Y-%m-%d %H:%M:%S')" > /dev/null 2>&1
}

get_worker_nodes() {
  kubectl get nodes --no-headers 2>/dev/null | grep -v control-plane | awk '{print $1}'
}

get_worker_count() {
  kubectl get nodes --no-headers 2>/dev/null | grep -v control-plane | wc -l
}

get_highest_worker_num() {
  local max=0
  for node in $(get_worker_nodes); do
    num=$(echo "$node" | grep -o '[0-9]*')
    if [ "$num" -gt "$max" ]; then
      max=$num
    fi
  done
  echo $max
}

has_pending_pods() {
  local pending
  pending=$(kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | grep -cv "Completed\|Succeeded" 2>/dev/null)
  echo "${pending:-0}"
}

get_resource_usage() {
  # Returns CPU% and MEM% of requests vs allocatable on worker nodes
  # Parses "cpu  800m (3%)  1 (4%)" and "memory  978Mi (2%)  2218Mi (4%)" from kubectl describe
  local total_cpu_pct=0 total_mem_pct=0 count=0

  for node in $(get_worker_nodes); do
    local cpu_pct mem_pct
    cpu_pct=$(kubectl describe node "$node" 2>/dev/null | grep -A6 "Allocated resources" | grep "cpu" | awk '{gsub(/[()%]/, "", $3); print $3}')
    mem_pct=$(kubectl describe node "$node" 2>/dev/null | grep -A6 "Allocated resources" | grep "memory" | awk '{gsub(/[()%]/, "", $3); print $3}')
    cpu_pct=${cpu_pct:-0}
    mem_pct=${mem_pct:-0}
    total_cpu_pct=$((total_cpu_pct + cpu_pct))
    total_mem_pct=$((total_mem_pct + mem_pct))
    count=$((count + 1))
  done

  if [ "$count" -gt 0 ]; then
    echo "$((total_cpu_pct / count)) $((total_mem_pct / count))"
  else
    echo "0 0"
  fi
}

prepare_worker() {
  local name=$1
  local ip=$2

  log "Preparing $name ($ip)..."

  # Wait for systemd to be ready
  local retries=0
  while ! docker exec "$name" systemctl is-system-running --wait 2>/dev/null | grep -qE "running|degraded"; do
    retries=$((retries + 1))
    if [ $retries -gt 30 ]; then
      log "ERROR: $name systemd not starting"
      return 1
    fi
    sleep 2
  done

  # Configure the node
  docker exec "$name" bash -c "
    set -e

    # Set hostname
    hostnamectl set-hostname $name

    # Add /etc/hosts entries (append, don't replace - Docker manages this file)
    grep -q 'controller-1' /etc/hosts || cat >> /etc/hosts <<'EOF'
172.20.0.11 controller-1
172.20.0.12 controller-2
172.20.0.13 controller-3
172.20.0.21 worker-1
172.20.0.22 worker-2
172.20.0.23 worker-3
172.20.0.24 worker-4
172.20.0.25 worker-5
EOF

    # Disable swap
    swapoff -a 2>/dev/null || true

    # Load kernel modules
    modprobe overlay 2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true

    # Sysctl params
    cat > /etc/sysctl.d/k8s.conf <<'EOF2'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF2
    sysctl --system > /dev/null 2>&1

    # Reset any previous kubeadm state
    kubeadm reset -f > /dev/null 2>&1 || true
    rm -rf /etc/kubernetes/pki /etc/kubernetes/manifests

    # Make sure containerd is running with correct config
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml 2>/dev/null
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sed -i 's/snapshotter = \"overlayfs\"/snapshotter = \"native\"/' /etc/containerd/config.toml
    systemctl restart containerd
    systemctl enable containerd kubelet
  " 2>&1

  return $?
}

scale_up() {
  local current
  current=$(get_worker_count)

  if [ "$current" -ge "$MAX_WORKERS" ]; then
    log "Already at max workers ($MAX_WORKERS). Cannot scale up."
    return 1
  fi

  local next_num=$(($(get_highest_worker_num) + 1))
  local name="worker-${next_num}"
  local ip="${BASE_IP}.$((20 + next_num))"

  log "SCALE UP: Creating $name with IP $ip (current workers: $current)"

  # Create Docker volumes
  docker volume create "wrk${next_num}-kubernetes" > /dev/null 2>&1
  docker volume create "wrk${next_num}-kubelet" > /dev/null 2>&1
  docker volume create "wrk${next_num}-containerd" > /dev/null 2>&1
  docker volume create "wrk${next_num}-cni" > /dev/null 2>&1

  # Start the container (MSYS_NO_PATHCONV prevents Git Bash path mangling)
  MSYS_NO_PATHCONV=1 docker run -d \
    --name "$name" \
    --hostname "$name" \
    --privileged \
    --memory 4g \
    --cpus 0.5 \
    --network "$NETWORK" \
    --ip "$ip" \
    --tmpfs /run \
    --tmpfs /run/lock \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "wrk${next_num}-kubernetes:/etc/kubernetes" \
    -v "wrk${next_num}-kubelet:/var/lib/kubelet" \
    -v "wrk${next_num}-containerd:/var/lib/containerd" \
    -v "wrk${next_num}-cni:/etc/cni" \
    "$BASE_IMAGE" > /dev/null 2>&1

  if [ $? -ne 0 ]; then
    log "ERROR: Failed to create container $name"
    return 1
  fi

  # Prepare the node
  prepare_worker "$name" "$ip"
  if [ $? -ne 0 ]; then
    log "ERROR: Failed to prepare $name"
    docker rm -f "$name" > /dev/null 2>&1
    return 1
  fi

  # Generate fresh join token and join
  log "Joining $name to cluster..."
  local join_cmd
  join_cmd=$(docker exec controller-1 kubeadm token create --print-join-command 2>/dev/null)

  if [ -z "$join_cmd" ]; then
    log "ERROR: Failed to get join command"
    docker rm -f "$name" > /dev/null 2>&1
    return 1
  fi

  docker exec "$name" bash -c "$join_cmd --ignore-preflight-errors=all" 2>&1
  if [ $? -ne 0 ]; then
    log "ERROR: Failed to join $name to cluster"
    docker rm -f "$name" > /dev/null 2>&1
    return 1
  fi

  # Wait for node to be Ready
  local retries=0
  while ! kubectl get node "$name" --no-headers 2>/dev/null | grep -q "Ready"; do
    retries=$((retries + 1))
    if [ $retries -gt 60 ]; then
      log "ERROR: $name not becoming Ready"
      return 1
    fi
    sleep 5
  done

  sync_clock "$name"
  STABILIZATION_COUNT=0 # Reset stabilization after any scale-up
  log "SUCCESS: $name is Ready! Workers: $((current + 1))/$MAX_WORKERS"
}

scale_down() {
  local current
  current=$(get_worker_count)

  if [ "$current" -le "$MIN_WORKERS" ]; then
    log "Already at min workers ($MIN_WORKERS). Cannot scale down."
    return 1
  fi

  local last_num
  last_num=$(get_highest_worker_num)
  local name="worker-${last_num}"

  # Don't remove original workers (1 and 2)
  if [ "$last_num" -le "$MIN_WORKERS" ]; then
    log "Cannot remove $name (original worker)"
    return 1
  fi

  log "SCALE DOWN: Removing $name (current workers: $current)"

  # Drain the node
  kubectl drain "$name" --ignore-daemonsets --delete-emptydir-data --force --timeout=60s 2>&1 | tail -1
  kubectl delete node "$name" 2>/dev/null

  # Stop and remove the container
  docker stop "$name" > /dev/null 2>&1
  docker rm "$name" > /dev/null 2>&1

  # Remove volumes
  docker volume rm "wrk${last_num}-kubernetes" "wrk${last_num}-kubelet" "wrk${last_num}-containerd" "wrk${last_num}-cni" > /dev/null 2>&1

  STABILIZATION_COUNT=0 # Reset after scale-down
  log "SUCCESS: $name removed. Workers: $((current - 1))/$MAX_WORKERS"
}

show_status() {
  echo "=== Autoscaler Status ==="
  echo "Workers: $(get_worker_count)/$MAX_WORKERS (min: $MIN_WORKERS)"
  echo "Pending pods: $(has_pending_pods)"
  echo "Scale-down stabilization: ${STABILIZATION_COUNT}/${SCALE_DOWN_WAIT}"

  local usage
  usage=$(get_resource_usage)
  local cpu_pct mem_pct
  cpu_pct=$(echo "$usage" | awk '{print $1}')
  mem_pct=$(echo "$usage" | awk '{print $2}')
  echo "Worker CPU requests: ${cpu_pct}% (scale up > ${CPU_THRESHOLD}%, scale down < ${SCALE_DOWN_CPU}%)"
  echo "Worker MEM requests: ${mem_pct}% (scale up > ${MEM_THRESHOLD}%, scale down < ${SCALE_DOWN_MEM}%)"
  echo ""
  echo "Worker nodes:"
  kubectl get nodes --no-headers 2>/dev/null | grep -v control-plane | while read -r line; do
    echo "  $line"
  done

  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo ""
    echo "Autoscaler daemon: RUNNING (PID $(cat "$PID_FILE"))"
  else
    echo ""
    echo "Autoscaler daemon: STOPPED"
  fi
}

daemon_loop() {
  log "Autoscaler daemon started (interval: ${CHECK_INTERVAL}s)"
  log "Config: workers $MIN_WORKERS-$MAX_WORKERS, CPU threshold ${CPU_THRESHOLD}%/${SCALE_DOWN_CPU}%, MEM threshold ${MEM_THRESHOLD}%/${SCALE_DOWN_MEM}%"
  log "Scale-down wait: $((SCALE_DOWN_WAIT * CHECK_INTERVAL))s"

  while true; do
    local pending current usage cpu_pct mem_pct
    current=$(get_worker_count)
    pending=$(has_pending_pods)
    usage=$(get_resource_usage)
    cpu_pct=$(echo "$usage" | awk '{print $1}')
    mem_pct=$(echo "$usage" | awk '{print $2}')

    # Scale up: pending pods OR high resource usage
    if [ "$pending" -gt 0 ] && [ "$current" -lt "$MAX_WORKERS" ]; then
      log "Trigger: $pending pending pods detected"
      STABILIZATION_COUNT=0
      scale_up
    elif [ "$cpu_pct" -gt "$CPU_THRESHOLD" ] || [ "$mem_pct" -gt "$MEM_THRESHOLD" ]; then
      if [ "$current" -lt "$MAX_WORKERS" ]; then
        log "Trigger: Resource pressure CPU=${cpu_pct}% MEM=${mem_pct}%"
        STABILIZATION_COUNT=0
        scale_up
      fi
    # Scale down candidate: low resource usage and no pending pods
    elif [ "$cpu_pct" -lt "$SCALE_DOWN_CPU" ] && [ "$mem_pct" -lt "$SCALE_DOWN_MEM" ] && [ "$pending" -eq 0 ]; then
      if [ "$current" -gt "$MIN_WORKERS" ]; then
        STABILIZATION_COUNT=$((STABILIZATION_COUNT + 1))
        if [ "$STABILIZATION_COUNT" -ge "$SCALE_DOWN_WAIT" ]; then
          log "Trigger: Low usage sustained for 2 minutes. CPU=${cpu_pct}% MEM=${mem_pct}%"
          scale_down
        else
          log "Waiting for stabilization: ${STABILIZATION_COUNT}/${SCALE_DOWN_WAIT} (CPU=${cpu_pct}%, MEM=${mem_pct}%)"
        fi
      fi
    else
      # Reset stabilization if conditions are neither scale-up nor scale-down
      STABILIZATION_COUNT=0
    fi

    sleep "$CHECK_INTERVAL"
  done
}

case "${1:-status}" in
  start)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "Autoscaler already running (PID $(cat "$PID_FILE"))"
      exit 1
    fi
    daemon_loop &
    echo $! > "$PID_FILE"
    echo "Autoscaler started (PID $!). Log: $LOG_FILE"
    ;;
  stop)
    if [ -f "$PID_FILE" ]; then
      kill "$(cat "$PID_FILE")" 2>/dev/null
      rm -f "$PID_FILE"
      echo "Autoscaler stopped"
    else
      echo "Autoscaler not running"
    fi
    ;;
  status)
    show_status
    ;;
  scale-up)
    scale_up
    ;;
  scale-down)
    scale_down
    ;;
  *)
    echo "Usage: $0 {start|stop|status|scale-up|scale-down}"
    exit 1
    ;;
esac
