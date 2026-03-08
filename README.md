# Kubernetes Cluster on Docker with Ansible

Cluster Kubernetes (v1.30.14) rulat pe containere Docker, provizionat cu Ansible.

## Arhitectura

```
┌─────────────────────────────────────────────────────┐
│                 Docker Network (172.20.0.0/24)       │
│                                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ │
│  │ controller-1 │ │ controller-2 │ │ controller-3 │ │
│  │ 172.20.0.11  │ │ 172.20.0.12  │ │ 172.20.0.13  │ │
│  │ control-plane│ │ control-plane│ │ control-plane│ │
│  └──────────────┘ └──────────────┘ └──────────────┘ │
│                                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ │
│  │   worker-1   │ │   worker-2   │ │   ansible    │ │
│  │ 172.20.0.21  │ │ 172.20.0.22  │ │ 172.20.0.100 │ │
│  └──────────────┘ └──────────────┘ └──────────────┘ │
└─────────────────────────────────────────────────────┘
         │
         │ port 6443
         ▼
    localhost:6443 (host kubectl)
```

## Structura proiectului

```
k8s/
├── keys/
│   ├── id_ed25519           # Cheie privata SSH
│   └── id_ed25519.pub       # Cheie publica SSH
├── node/
│   ├── Dockerfile           # Ubuntu 22.04 + systemd + SSH
│   └── authorized_keys      # Cheie publica (copiata din keys/)
├── ansible/
│   ├── Dockerfile           # Ubuntu 22.04 + Ansible + cheie privata
│   ├── id_ed25519           # Cheie privata (copiata din keys/)
│   └── playbooks/
│       ├── inventory.ini    # Inventar Ansible (5 noduri)
│       ├── site.yml         # Master playbook
│       ├── 00-test-connectivity.yml
│       ├── 01-prepare-nodes.yml
│       ├── 02-install-containerd.yml
│       ├── 03-install-k8s.yml
│       └── 04-init-cluster.yml
├── docker-compose.yml
├── snapshot.sh              # Creeaza un snapshot al clusterului
├── restore.sh               # Restaureaza din snapshot
├── snapshots-list.sh        # Listeaza snapshot-urile disponibile
└── README.md
```

## Cum se ruleaza

```bash
# 1. Porneste toate containerele
docker compose up -d --build

# 2. Testeaza conectivitatea SSH
docker exec ansible ansible -i inventory.ini all -m ping

# 3. Instaleaza K8s pe cluster
docker exec ansible ansible-playbook -i inventory.ini site.yml

# 4. Dupa instalare, aplica fix-urile post-instalare (vezi sectiunea de mai jos)

# 5. Copiaza kubeconfig pe host
docker cp controller-1:/etc/kubernetes/admin.conf ~/.kube/config
# Schimba IP-ul la localhost (pe Windows/Git Bash):
sed -i 's|https://172.20.0.11:6443|https://127.0.0.1:6443|' ~/.kube/config

# 6. Verifica
kubectl get nodes
kubectl get pods -A
```

## Probleme intampinate si rezolvari

### 1. `/etc/hosts` nu se poate modifica cu Ansible `blockinfile`

**Eroare:**
```
OSError: [Errno 16] Device or resource busy: '/etc/.ansible_tmp..hosts' -> '/etc/hosts'
```

**Cauza:** Docker monteaza `/etc/hosts` ca bind mount read-only la nivel de rename. Modulul `blockinfile` din Ansible incearca sa faca rename atomic, care esueaza.

**Rezolvare:** Inlocuit `blockinfile` cu `shell` si `>>` (append):
```yaml
- name: Add /etc/hosts entries
  shell: |
    grep -q 'controller-1' /etc/hosts || echo '172.20.0.11 controller-1
    172.20.0.12 controller-2
    ...' >> /etc/hosts
```

---

### 2. Containerd nu poate face pull la imagini (whiteout file error)

**Eroare:**
```
failed to convert whiteout file "usr/local/.wh..wh..opq": operation not supported
```

**Cauza:** Containerd foloseste snapshotter-ul `overlayfs` implicit, care nu functioneaza corect in Docker-in-Docker deoarece filesystem-ul containerului nu suporta overlayfs nested.

**Rezolvare:** Schimbat snapshotter-ul la `native` in configuratia containerd:
```yaml
# In 02-install-containerd.yml
- name: Switch to native snapshotter (required for Docker-in-Docker)
  replace:
    path: /etc/containerd/config.toml
    regexp: 'snapshotter = "overlayfs"'
    replace: 'snapshotter = "native"'
```

---

### 3. Containerele nod nu aveau systemd (necesar pentru kubelet)

**Eroare:**
```
Failed to connect to bus: No such file or directory
```

**Cauza:** Imaginea initiala a nodurilor folosea `sshd -D` ca CMD, fara systemd. Kubelet necesita systemd ca init system.

**Rezolvare:** Refacut Dockerfile-ul nodurilor cu systemd ca PID 1:
```dockerfile
FROM ubuntu:22.04
ENV container=docker

RUN apt-get install -y systemd systemd-sysv ...

# Curatat servicii systemd inutile in container
RUN (cd /lib/systemd/system/sysinit.target.wants/ && \
    ls | grep -v systemd-tmpfiles-setup | xargs rm -f) && ...

# Activat SSH prin systemd
RUN systemctl enable ssh

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]
```

De asemenea, adaugat in `docker-compose.yml`:
```yaml
tmpfs:
  - /run
  - /run/lock
```

---

### 4. kube-proxy crapa cu `nf_conntrack_max: permission denied`

**Eroare:**
```
Error running ProxyServer: open /proc/sys/net/netfilter/nf_conntrack_max: permission denied
```

**Cauza:** kube-proxy incearca sa seteze `sysctl net.netfilter.nf_conntrack_max` dar containerele nested nu au permisiunea sa modifice acest parametru kernel chiar si in mod privileged.

**Rezolvare:** Recreat ConfigMap-ul kube-proxy cu `conntrack.maxPerCore: 0` care dezactiveaza setarea automata:
```bash
docker exec controller-1 bash -c '
cat > /tmp/kp-config.yaml << "EOF"
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
conntrack:
  maxPerCore: 0
  min: 0
mode: iptables
clusterCIDR: 10.244.0.0/16
...
EOF

kubectl -n kube-system delete cm kube-proxy
kubectl -n kube-system create cm kube-proxy \
  --from-file=config.conf=/tmp/kp-config.yaml \
  --from-file=kubeconfig.conf=<(kubectl -n kube-system get cm kube-proxy -o jsonpath="{.data.kubeconfig\.conf}")
kubectl delete pods -n kube-system -l k8s-app=kube-proxy
'
```

---

### 5. CoreDNS intra in CrashLoopBackOff (loop detection)

**Eroare:**
```
[FATAL] plugin/loop: Loop (127.0.0.1 -> :53) detected for zone "."
```

**Cauza:** `/etc/resolv.conf` din containere pointeaza la `127.0.0.1` (systemd-resolved), iar CoreDNS forwardeaza tot la `/etc/resolv.conf`, creand un loop DNS infinit.

**Rezolvare:** Schimbat forward-ul CoreDNS de la `/etc/resolv.conf` la DNS-uri publice:
```bash
kubectl -n kube-system get cm coredns -o yaml | \
  sed "s/forward . \/etc\/resolv.conf/forward . 8.8.8.8 8.8.4.4/" | \
  kubectl apply -f -
kubectl -n kube-system delete pods -l k8s-app=kube-dns
```

---

### 6. Recrearea unui container Docker pierde starea K8s

**Cauza:** Orice `docker compose up -d` care recreaza un container (ex: adaugare `ports`) sterge tot ce era instalat (kubeadm, etcd data, certificate).

**Rezolvare:** Adaugate volume persistente Docker pentru directoarele critice K8s si folosite imagini commituite (snapshot) in loc de build din Dockerfile:

Volume persistente per nod:
- `/etc/kubernetes` - certificate, kubeconfig, manifeste static pods
- `/var/lib/etcd` - baza de date etcd (doar controllere)
- `/var/lib/kubelet` - starea kubelet
- `/var/lib/containerd` - imagini si containere
- `/etc/cni` - configuratie retea CNI

Iar imaginile din `docker-compose.yml` refera snapshot-uri (`k8s-cluster/controller-1:v1`) in loc de `build: ./node`, astfel incat starea completa a clusterului e preservata in imaginea Docker.

## Snapshots (backup / rollback)

Clusterul suporta snapshot si restore complet prin `docker commit`.

### Crearea unui snapshot
```bash
# Snapshot cu tag automat (timestamp)
./snapshot.sh

# Snapshot cu tag specific
./snapshot.sh v2
./snapshot.sh before-upgrade
./snapshot.sh working-state
```

### Listarea snapshot-urilor
```bash
./snapshots-list.sh
```

### Restaurarea dintr-un snapshot
```bash
# Restaureaza la versiunea dorita
./restore.sh v1
./restore.sh before-upgrade
```

**ATENTIE:** Restore-ul face `docker compose down -v` (sterge volumele curente) si recreeaza totul din snapshot. Asigurati-va ca aveti un snapshot al starii curente inainte de restore daca vreti sa o pastrati.

### Flux recomandat
```bash
# Inainte de orice schimbare majora
./snapshot.sh before-change

# Faceti schimbarile...
# Daca ceva nu merge:
./restore.sh before-change

# Daca totul e ok, salvati starea noua:
./snapshot.sh after-change
```

## Persistenta datelor (volume Docker)

Clusterul foloseste **23 volume Docker** pentru a pastra datele intre opriri/porniri.

### Ce persista si ce nu

| Comanda | Volume | Date K8s | Rezultat |
|---|---|---|---|
| `docker compose stop / start` | Pastrate | Pastrate | Cluster revine instant |
| `docker compose down / up` | **Pastrate** | **Pastrate** | Cluster revine (30s boot) |
| `docker compose down -v / up` | **STERSE** | **PIERDUTE** | Trebuie restore din snapshot |

### Volume per nod

**Controllere** (controller-1/2/3):
- `ctrlN-kubernetes` → `/etc/kubernetes` (certificate, kubeconfig, manifeste)
- `ctrlN-etcd` → `/var/lib/etcd` (baza de date etcd)
- `ctrlN-kubelet` → `/var/lib/kubelet` (starea kubelet)
- `ctrlN-containerd` → `/var/lib/containerd` (imagini container)
- `ctrlN-cni` → `/etc/cni` (configuratie retea)

**Workeri** (worker-1/2):
- `wrkN-kubernetes`, `wrkN-kubelet`, `wrkN-containerd`, `wrkN-cni` (la fel, fara etcd)

### Oprire si pornire cluster

```bash
# Oprire (datele raman in volume)
docker compose down

# Pornire (clusterul revine automat in ~30 secunde)
docker compose up -d

# Verificare
kubectl get nodes       # toate 5 noduri Ready
kubectl get pods -A     # toate 24 pod-uri Running
```

### IMPORTANT

- `docker compose down` = **SAFE** — volumele raman, clusterul revine la pornire
- `docker compose down -v` = **DISTRUCTIV** — sterge volumele, datele se pierd
- Folositi `down -v` doar cand restaurati dintr-un snapshot cu `./restore.sh`

## Componente

| Componenta | Versiune |
|---|---|
| Ubuntu | 22.04 |
| Kubernetes | v1.30.14 |
| Containerd | din repo Ubuntu (native snapshotter) |
| CNI | Flannel (latest) |
| Ansible | pip latest |

## Resurse per container

| Container | RAM | CPU |
|---|---|---|
| controller-1/2/3 | 4 GB | 0.5 core |
| worker-1/2 | 4 GB | 0.5 core |
| ansible | 4 GB | 0.25 core |
| **Total** | **24 GB** | **2.75 cores** |

## Acces

- **kubectl de pe host:** `kubectl get nodes` (prin localhost:6443)
- **SSH din Ansible:** `docker exec ansible ssh root@controller-1`
- **Direct in container:** `docker exec -it controller-1 bash`
