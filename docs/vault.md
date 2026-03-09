# HashiCorp Vault - Cluster Secret Management

Acest document descrie integrarea Vault pentru gestionarea centralizată a secretelor în clusterul Kubernetes.

## Arhitectură

- **Namespace:** `vault`
- **Nod:** Fixat pe Control Plane (`controller-*`) pentru stabilitate.
- **Endpoint Intern:** `http://vault.vault.svc:8200`
- **Endpoint Host (via port-forward):** `http://localhost:8200`

## Acces și Autentificare

Acesta rulează în mod **Persistent** (File Storage). Dacă clusterul se restartează, seiful trebuie descuiat manual.

- **Unseal Key:** `[SCRIE_AICI_CHEIA_GENERATA]`
- **Root Token:** `[SCRIE_AICI_TOKENUL_GENERAT]`

### Procedura de restart (Unseal)
Dacă interfața web arată "Sealed", rulează:
```bash
kubectl exec -n vault vault-0 -- vault operator unseal e3a73c51e6e1167e66b119b935a6e118a387f000e338dc6cd57d33ea24df34b7
```

### Acces din linia de comandă (Host)
```powershell
# 1. Start port-forward
kubectl port-forward svc/vault -n vault 8200:8200

# 2. Setează variabilele de mediu
$env:VAULT_ADDR="http://127.0.0.1:8200"
$env:VAULT_TOKEN="root"

# 3. Interoghează un secret
vault kv get secret/site1
```

## Secrete Stocate

Momentan, Vault centralizează următoarele parole:

| Path | Keys | Descriere |
| :--- | :--- | :--- |
| `secret/site1` | `root_password`, `db_password` | Parolele MariaDB și WordPress pentru Site 1 |
| `secret/site2` | `root_password`, `db_password` | Parolele MariaDB și WordPress pentru Site 2 |
| `secret/grafana` | `admin_password` | Parola de administrare a monitorizării |

## Cum se adaugă un secret nou

```bash
# Exemplu pentru un site nou (site3)
docker exec -it vault-0 sh
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='root'
vault kv put secret/site3 root_password='parola_root' db_password='parola_wp'
```

## Securitate (Next Steps)

1. **Network Policies:** Se recomandă restricționarea accesului la namespace-ul `vault` doar pentru ArgoCD și pod-urile WordPress.
2. **AppRole:** În producție, pod-urile nu trebuie să folosească token-ul `root`. Trebuie configurată autentificarea prin `AppRole` sau `Kubernetes Auth Method`.
3. **External Secrets Operator:** Pentru o integrare nativă K8s, se poate instala un operator care să creeze automat `Secrets` în namespace-urile WordPress, extrăgând datele din Vault.
