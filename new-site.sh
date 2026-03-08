#!/bin/bash
# Creeaza un nou site WordPress in cluster via ArgoCD
# Utilizare: ./new-site.sh <nume-site>
# Exemplu:  ./new-site.sh site2

SITE_NAME=$1

if [ -z "$SITE_NAME" ]; then
  echo "Utilizare: ./new-site.sh <nume-site>"
  echo "Exemplu:  ./new-site.sh site2"
  exit 1
fi

NAMESPACE="wp-$SITE_NAME"
MANIFESTS_DIR="manifests/sites/$SITE_NAME"
DB_PASS="$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)"
ROOT_PASS="$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)"

echo "=== Creez site WordPress: $SITE_NAME ==="
echo "  Namespace: $NAMESPACE"
echo "  DB Password: $DB_PASS"

# 1. Creez overlay Kustomize
mkdir -p "$MANIFESTS_DIR"
cat > "$MANIFESTS_DIR/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $NAMESPACE

resources:
  - ../../wordpress-base

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

# 2. Push la Gitea
GITEA_IP=$(docker exec controller-1 kubectl get svc gitea -n gitea -o jsonpath='{.spec.clusterIP}')
docker cp "$MANIFESTS_DIR/kustomization.yaml" "controller-1:/tmp/k8s-apps/sites/$SITE_NAME/kustomization.yaml"

# Creez directorul si copiez
docker exec controller-1 bash -c "
cd /tmp/k8s-apps
mkdir -p sites/$SITE_NAME
git add -A
git commit -m 'Add WordPress site: $SITE_NAME'
git push origin main
" 2>&1

# 3. Creez ArgoCD Application
cat > "/tmp/argocd-app-$SITE_NAME.yml" << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: wp-$SITE_NAME
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://gitea.gitea.svc:3000/argocd/k8s-apps.git
    targetRevision: main
    path: sites/$SITE_NAME
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

kubectl apply -f "/tmp/argocd-app-$SITE_NAME.yml"

echo ""
echo "=== Site $SITE_NAME creat! ==="
echo ""
echo "Asteapta ~2 minute pentru deploy, apoi:"
echo "  kubectl port-forward svc/wordpress -n $NAMESPACE 80"
echo "  kubectl port-forward svc/phpmyadmin -n $NAMESPACE 8080:80"
