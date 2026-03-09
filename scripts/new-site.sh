#!/bin/bash
# Creeaza un nou site WordPress in cluster via ArgoCD
# Utilizare: ./scripts/new-site.sh <nume-site>
# Exemplu:  ./scripts/new-site.sh site5

SITE_NAME=$1

if [ -z "$SITE_NAME" ]; then
  echo "Utilizare: ./scripts/new-site.sh <nume-site>"
  echo "Exemplu:  ./scripts/new-site.sh site5"
  exit 1
fi

NAMESPACE="wp-$SITE_NAME"
OVERLAY_DIR="manifests/apps/wordpress/overlays/$SITE_NAME"
DB_PASS="$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)"
ROOT_PASS="$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)"

echo "=== Creez site WordPress: $SITE_NAME ==="
echo "  Namespace: $NAMESPACE"
echo "  DB Password: $DB_PASS"

# 1. Creez overlay Kustomize
mkdir -p "$OVERLAY_DIR"
cat > "$OVERLAY_DIR/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $NAMESPACE

resources:
  - ../../base

patches:
  - target:
      kind: Secret
      name: wp-secrets
    patch: |
      - op: replace
        path: /stringData/MYSQL_ROOT_PASSWORD
        value: $ROOT_PASS
      - op: replace
        path: /stringData/MYSQL_PASSWORD
        value: $DB_PASS
      - op: replace
        path: /stringData/WORDPRESS_DB_PASSWORD
        value: $DB_PASS
EOF

# 2. Creez ArgoCD Application
ARGOCD_APP="manifests/argocd/app-wordpress-$SITE_NAME.yaml"
cat > "$ARGOCD_APP" << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: wp-$SITE_NAME
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/podut/k8s-cluster.git
    targetRevision: main
    path: manifests/apps/wordpress/overlays/$SITE_NAME
  destination:
    server: https://kubernetes.default.svc
    namespace: $NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

echo ""
echo "=== Fisiere create pentru $SITE_NAME ==="
echo "  Overlay: $OVERLAY_DIR/kustomization.yaml"
echo "  ArgoCD:  $ARGOCD_APP"
echo ""
echo "Urmatorul pas: adauga app-ul in manifests/argocd/kustomization.yaml"
echo "  apoi commit + push la git pentru ca ArgoCD sa deploieze automat."
echo ""
echo "Dupa deploy (~2 minute):"
echo "  kubectl port-forward svc/wordpress -n $NAMESPACE 80"
echo "  kubectl port-forward svc/phpmyadmin -n $NAMESPACE 8080:80"
