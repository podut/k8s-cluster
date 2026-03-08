#!/bin/bash
# Listeaza toate snapshot-urile disponibile
echo "=== Snapshots K8s disponibile ==="
echo ""
docker images "k8s-cluster/controller-1" --format "table {{.Tag}}\t{{.CreatedAt}}\t{{.Size}}" | head -1
docker images "k8s-cluster/controller-1" --format "table {{.Tag}}\t{{.CreatedAt}}\t{{.Size}}" | tail -n +2 | sort -r
echo ""

# Tag-ul curent din docker-compose
CURRENT=$(grep "image: k8s-cluster/controller-1:" docker-compose.yml | sed 's/.*://')
echo "Tag curent in docker-compose: $CURRENT"
