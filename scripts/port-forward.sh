#!/bin/bash
# Port-forward dinamic pentru Grafana, ArgoCD si Vault
# Detecteaza automat serviciile dupa nume din cluster
# Utilizare: ./scripts/port-forward.sh [start|stop|restart|status]

KUBECTL="docker exec controller-1 kubectl"
PID_DIR="/tmp/k8s-forwards"
mkdir -p "$PID_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Gaseste serviciul in cluster dupa keyword (returneaza "namespace svcname port")
find_service() {
  local KEYWORD=$1
  $KUBECTL get svc -A --no-headers 2>/dev/null \
    | grep -i "$KEYWORD" \
    | awk '{print $1, $2, $6}' \
    | head -1
}

# Extrage primul port numeric dintr-un string de tipul "443/TCP" sau "3000:30300/TCP"
parse_port() {
  echo "$1" | grep -oE '^[0-9]+' | head -1
}

# Porneste port-forward in background prin controller-1
start_forward() {
  local NAME=$1
  local NS=$2
  local SVC=$3
  local REMOTE_PORT=$4
  local LOCAL_PORT=$5
  local PID_FILE="$PID_DIR/$NAME.pid"

  if [ -f "$PID_FILE" ] && kill -0 "$(cat $PID_FILE)" 2>/dev/null; then
    echo -e "  ${YELLOW}⚠${NC}  $NAME deja ruleaza pe localhost:$LOCAL_PORT"
    return
  fi

  docker exec -d controller-1 kubectl port-forward \
    -n "$NS" "svc/$SVC" "${LOCAL_PORT}:${REMOTE_PORT}" --address=0.0.0.0
  echo $! > "$PID_FILE"
  sleep 1
  echo -e "  ${GREEN}✅${NC} $NAME  svc/$SVC -n $NS  →  http://172.20.0.11:$LOCAL_PORT"
}

stop_forward() {
  local NAME=$1
  local PID_FILE="$PID_DIR/$NAME.pid"
  if [ -f "$PID_FILE" ]; then
    kill "$(cat $PID_FILE)" 2>/dev/null
    rm -f "$PID_FILE"
    echo -e "  ${RED}⛔${NC} $NAME oprit"
  fi
}

cmd_start() {
  echo ""
  echo -e "${CYAN}========================================${NC}"
  echo -e "${CYAN}  Port-Forward  |  Grafana ArgoCD Vault ${NC}"
  echo -e "${CYAN}========================================${NC}"
  echo ""

  # --- GRAFANA ---
  echo -e "${YELLOW}[ Grafana ]${NC}"
  INFO=$(find_service "grafana")
  if [ -n "$INFO" ]; then
    NS=$(echo "$INFO" | awk '{print $1}')
    SVC=$(echo "$INFO" | awk '{print $2}')
    PORT=$(parse_port "$(echo "$INFO" | awk '{print $3}')")
    start_forward "grafana" "$NS" "$SVC" "$PORT" "3000"
    PASS=$($KUBECTL get deployment "$SVC" -n "$NS" \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="GF_SECURITY_ADMIN_PASSWORD")].value}' 2>/dev/null)
    echo -e "       user: admin  |  pass: ${PASS:-admin123}"
  else
    echo -e "  ${RED}✗${NC} Grafana nu a fost gasit in cluster"
  fi

  # --- ARGOCD ---
  echo ""
  echo -e "${YELLOW}[ ArgoCD ]${NC}"
  INFO=$(find_service "argocd-server")
  if [ -n "$INFO" ]; then
    NS=$(echo "$INFO" | awk '{print $1}')
    SVC=$(echo "$INFO" | awk '{print $2}')
    start_forward "argocd" "$NS" "$SVC" "443" "8080"
    PASS=$($KUBECTL get secret argocd-initial-admin-secret \
      -n "$NS" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
    echo -e "       user: admin  |  pass: ${PASS:-N/A}"
    echo -e "       ${YELLOW}nota: ignora SSL warning (self-signed cert)${NC}"
  else
    echo -e "  ${RED}✗${NC} ArgoCD nu a fost gasit in cluster"
  fi

  # --- VAULT ---
  echo ""
  echo -e "${YELLOW}[ Vault ]${NC}"
  INFO=$(find_service "vault")
  if [ -n "$INFO" ]; then
    NS=$(echo "$INFO" | awk '{print $1}')
    SVC=$(echo "$INFO" | awk '{print $2}')
    PORT=$(parse_port "$(echo "$INFO" | awk '{print $3}')")
    start_forward "vault" "$NS" "$SVC" "$PORT" "8200"
    echo -e "       token: vezi keys/vault.env"
  else
    echo -e "  ${RED}✗${NC} Vault nu a fost gasit in cluster"
  fi

  echo ""
  echo -e "${CYAN}========================================${NC}"
  echo -e "  Grafana  →  ${GREEN}http://172.20.0.11:3000${NC}"
  echo -e "  ArgoCD   →  ${GREEN}https://172.20.0.11:8080${NC}"
  echo -e "  Vault    →  ${GREEN}http://172.20.0.11:8200${NC}"
  echo -e "${CYAN}========================================${NC}"
  echo -e "  Opreste cu: ${YELLOW}./scripts/port-forward.sh stop${NC}"
  echo ""
}

cmd_stop() {
  echo ""
  echo -e "${CYAN}[ Opresc port-forwards ]${NC}"
  stop_forward "grafana"
  stop_forward "argocd"
  stop_forward "vault"
  docker exec controller-1 bash -c "pkill -f 'kubectl port-forward' 2>/dev/null || true"
  echo ""
}

cmd_status() {
  echo ""
  echo -e "${CYAN}[ Status port-forwards ]${NC}"
  local found=0
  for PID_FILE in "$PID_DIR"/*.pid; do
    [ -f "$PID_FILE" ] || continue
    found=1
    NAME=$(basename "$PID_FILE" .pid)
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      echo -e "  ${GREEN}●${NC} $NAME activ (PID $PID)"
    else
      echo -e "  ${RED}●${NC} $NAME oprit"
      rm -f "$PID_FILE"
    fi
  done
  [ $found -eq 0 ] && echo -e "  ${YELLOW}Niciun port-forward activ${NC}"
  echo ""
}

case "${1:-start}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_stop; sleep 1; cmd_start ;;
  status)  cmd_status ;;
  *)
    echo "Utilizare: $0 [start|stop|restart|status]"
    exit 1
    ;;
esac
