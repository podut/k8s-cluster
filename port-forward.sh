#!/bin/bash
# Porneste port-forward pentru toate serviciile
# Utilizare: ./port-forward.sh [serviciu]
# Servicii: all, argocd, grafana, prometheus, site1, site2...

SERVICE=${1:-all}

start_forward() {
  local name=$1 namespace=$2 svc=$3 local_port=$4 remote_port=$5
  echo "  $name -> localhost:$local_port"
  kubectl port-forward "svc/$svc" -n "$namespace" "$local_port:$remote_port" --address 0.0.0.0 > /dev/null 2>&1 &
}

echo "=== Port Forward ==="

case $SERVICE in
  argocd)
    start_forward "ArgoCD" argocd argocd-server 8080 443
    ;;
  grafana)
    start_forward "Grafana" monitoring grafana 3000 3000
    ;;
  prometheus)
    start_forward "Prometheus" monitoring prometheus 9090 9090
    ;;
  site*)
    NS="wp-$SERVICE"
    # Calculeaza portul bazat pe numarul site-ului
    NUM=$(echo $SERVICE | grep -o '[0-9]*')
    WP_PORT=$((8080 + NUM))
    PMA_PORT=$((8180 + NUM))
    start_forward "WordPress $SERVICE" "$NS" wordpress "$WP_PORT" 80
    start_forward "phpMyAdmin $SERVICE" "$NS" phpmyadmin "$PMA_PORT" 80
    ;;
  all)
    start_forward "ArgoCD" argocd argocd-server 8080 443
    start_forward "Grafana" monitoring grafana 3000 3000
    start_forward "Prometheus" monitoring prometheus 9090 9090

    # Forward all WordPress sites
    for ns in $(kubectl get ns --no-headers | awk '{print $1}' | grep '^wp-'); do
      SITE=$(echo $ns | sed 's/wp-//')
      NUM=$(echo $SITE | grep -o '[0-9]*')
      WP_PORT=$((8080 + NUM))
      PMA_PORT=$((8180 + NUM))
      start_forward "WordPress $SITE" "$ns" wordpress "$WP_PORT" 80
      start_forward "phpMyAdmin $SITE" "$ns" phpmyadmin "$PMA_PORT" 80
    done
    ;;
  *)
    echo "Serviciu necunoscut: $SERVICE"
    echo "Optiuni: all, argocd, grafana, prometheus, site1, site2..."
    exit 1
    ;;
esac

echo ""
echo "=== Servicii disponibile ==="
echo "  ArgoCD:     http://localhost:8080  (user: admin)"
echo "  Grafana:    http://localhost:3000  (user: admin / pass: admin123)"
echo "  Prometheus: http://localhost:9090"

for ns in $(kubectl get ns --no-headers 2>/dev/null | awk '{print $1}' | grep '^wp-'); do
  SITE=$(echo $ns | sed 's/wp-//')
  NUM=$(echo $SITE | grep -o '[0-9]*')
  echo "  WordPress $SITE:  http://localhost:$((8080 + NUM))"
  echo "  phpMyAdmin $SITE: http://localhost:$((8180 + NUM))"
done

echo ""
echo "Apasa Ctrl+C pentru a opri toate port-forward-urile"
wait
