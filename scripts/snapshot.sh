#!/bin/bash
# Creeaza un snapshot al clusterului K8s
# Utilizare: ./snapshot.sh [tag]
# Exemplu:  ./snapshot.sh v2

TAG=${1:-$(date +%Y%m%d-%H%M%S)}

echo "=== Creez snapshot cu tag: $TAG ==="

for container in controller-1 controller-2 controller-3 worker-1 worker-2 ansible; do
  echo -n "  Commit $container... "
  docker commit "$container" "k8s-cluster/$container:$TAG" > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    echo "OK"
  else
    echo "EROARE (containerul nu ruleaza?)"
  fi
done

echo ""
echo "=== Snapshot $TAG creat ==="
echo "Snapshots disponibile:"
docker images "k8s-cluster/*" --format "table {{.Repository}}\t{{.Tag}}\t{{.CreatedAt}}\t{{.Size}}"
echo ""
echo "Pentru a restaura: ./restore.sh $TAG"
