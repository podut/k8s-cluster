#!/bin/bash
# Aplica secretele din Vault in Kubernetes
# Utilizare: ./scripts/apply-secrets-from-vault.sh
# Rulat dupa restart cluster sau dupa adaugarea unui site nou

set -e

VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
VAULT_TOKEN_FILE="keys/vault.env"

# --- Load Vault token ---
if [ ! -f "$VAULT_TOKEN_FILE" ]; then
  echo "ERROR: $VAULT_TOKEN_FILE nu exista!"
  exit 1
fi

source "$VAULT_TOKEN_FILE"

if [ -z "$VAULT_ROOT_TOKEN" ]; then
  echo "ERROR: VAULT_ROOT_TOKEN nu e setat in $VAULT_TOKEN_FILE"
  exit 1
fi

TOKEN="$VAULT_ROOT_TOKEN"

# --- Helper: get secret from Vault ---
vault_get() {
  docker exec controller-1 kubectl exec -n $VAULT_NAMESPACE $VAULT_POD -- \
    sh -c "VAULT_TOKEN=$TOKEN vault kv get -field=$2 secret/$1 2>/dev/null"
}

# --- Helper: apply wp-secrets in namespace ---
apply_wp_secrets() {
  local SITE=$1
  local NS="wp-$SITE"

  echo "  Citesc $SITE din Vault..."
  ROOT=$(vault_get "$SITE" "root_password")
  DB=$(vault_get "$SITE" "db_password")

  if [ -z "$ROOT" ] || [ -z "$DB" ]; then
    echo "  WARN: secret/$SITE nu exista in Vault, sar peste $NS"
    return
  fi

  docker exec controller-1 kubectl create secret generic wp-secrets -n "$NS" \
    --from-literal=MYSQL_ROOT_PASSWORD="$ROOT" \
    --from-literal=MYSQL_PASSWORD="$DB" \
    --from-literal=MYSQL_DATABASE=wordpress \
    --from-literal=MYSQL_USER=wpuser \
    --from-literal=WORDPRESS_DB_HOST=mariadb \
    --from-literal=WORDPRESS_DB_USER=wpuser \
    --from-literal=WORDPRESS_DB_PASSWORD="$DB" \
    --from-literal=WORDPRESS_DB_NAME=wordpress \
    --dry-run=client -o yaml | docker exec -i controller-1 kubectl apply -f - 2>/dev/null

  echo "  ✅ $NS/wp-secrets aplicat"
}

# --- Helper: apply generic secret ---
apply_generic_secret() {
  local NS=$1
  local SECRET_NAME=$2
  local VAULT_PATH=$3
  shift 3
  local FIELDS=("$@")

  echo "  Citesc $VAULT_PATH din Vault..."

  ARGS=""
  for FIELD in "${FIELDS[@]}"; do
    VAL=$(vault_get "$VAULT_PATH" "$FIELD")
    if [ -z "$VAL" ]; then
      echo "  WARN: field $FIELD nu exista in $VAULT_PATH"
      continue
    fi
    ARGS="$ARGS --from-literal=$FIELD=$VAL"
  done

  if [ -z "$ARGS" ]; then
    echo "  WARN: niciun field gasit pentru $SECRET_NAME in $NS"
    return
  fi

  docker exec controller-1 kubectl create secret generic "$SECRET_NAME" -n "$NS" \
    $ARGS \
    --dry-run=client -o yaml | docker exec -i controller-1 kubectl apply -f - 2>/dev/null

  echo "  ✅ $NS/$SECRET_NAME aplicat"
}

echo "========================================"
echo "  Apply Secrets din Vault -> Kubernetes"
echo "========================================"
echo ""

# --- WordPress sites ---
echo "[ WordPress Sites ]"
for SITE in site1 site2 site3 site4; do
  apply_wp_secrets "$SITE"
done

# --- Cluster Agent ---
echo ""
echo "[ Cluster Agent ]"
echo "  WARN: API keys (GEMINI, DEEPSEEK, GITHUB) nu sunt in Vault."
echo "  Adauga-le manual:"
echo "    vault kv put secret/cluster-agent/keys GEMINI_API_KEY=... DEEPSEEK_API_KEY=... GITHUB_TOKEN=..."
echo "  Apoi re-ruleaza acest script."

# --- Grafana (daca parola e schimbata) ---
echo ""
echo "[ Grafana ]"
GRAFANA_PASS=$(vault_get "grafana" "admin_password")
if [ -n "$GRAFANA_PASS" ]; then
  docker exec controller-1 kubectl set env deployment/grafana \
    GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_PASS" \
    -n monitoring 2>/dev/null && echo "  ✅ grafana admin password actualizat"
fi

echo ""
echo "========================================"
echo "  Done! Restart pods daca e nevoie:"
echo "  kubectl rollout restart deployment -n wp-site1"
echo "  kubectl rollout restart deployment -n wp-site2"
echo "========================================"
