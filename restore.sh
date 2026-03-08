#!/bin/bash
# Restaureaza clusterul K8s dintr-un snapshot
# Utilizare: ./restore.sh <tag>
# Exemplu:  ./restore.sh v1

TAG=$1

if [ -z "$TAG" ]; then
  echo "Utilizare: ./restore.sh <tag>"
  echo ""
  echo "Snapshots disponibile:"
  docker images "k8s-cluster/*" --format "table {{.Repository}}\t{{.Tag}}\t{{.CreatedAt}}" | head -20
  exit 1
fi

# Verifica daca snapshot-ul exista
MISSING=""
for container in controller-1 controller-2 controller-3 worker-1 worker-2 ansible; do
  if ! docker image inspect "k8s-cluster/$container:$TAG" > /dev/null 2>&1; then
    MISSING="$MISSING $container"
  fi
done

if [ -n "$MISSING" ]; then
  echo "EROARE: Lipsesc imagini pentru tag '$TAG':$MISSING"
  exit 1
fi

echo "=== Restaurez snapshot: $TAG ==="
echo "ATENTIE: Asta va opri clusterul curent si va sterge volumele!"
read -p "Continui? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
  echo "Anulat."
  exit 0
fi

# Actualizeaza docker-compose sa foloseasca tag-ul dorit
sed -i "s|image: k8s-cluster/controller-1:.*|image: k8s-cluster/controller-1:$TAG|" docker-compose.yml
sed -i "s|image: k8s-cluster/controller-2:.*|image: k8s-cluster/controller-2:$TAG|" docker-compose.yml
sed -i "s|image: k8s-cluster/controller-3:.*|image: k8s-cluster/controller-3:$TAG|" docker-compose.yml
sed -i "s|image: k8s-cluster/worker-1:.*|image: k8s-cluster/worker-1:$TAG|" docker-compose.yml
sed -i "s|image: k8s-cluster/worker-2:.*|image: k8s-cluster/worker-2:$TAG|" docker-compose.yml
sed -i "s|image: k8s-cluster/ansible:.*|image: k8s-cluster/ansible:$TAG|" docker-compose.yml

# Opreste si sterge totul (inclusiv volume)
echo "  Opresc containerele..."
docker compose down -v 2>/dev/null

# Porneste din snapshot
echo "  Pornesc din snapshot $TAG..."
docker compose up -d

# Asteapta sa porneasca
echo "  Astept 15s pentru boot..."
sleep 15

# Verifica
echo ""
echo "=== Cluster restaurat din snapshot $TAG ==="
docker exec controller-1 kubectl get nodes 2>/dev/null || echo "(Clusterul porneste, incearca din nou in cateva secunde)"
