# Cluster Resource Overview

## Infrastructure

| Component | Details |
|-----------|---------|
| Platform | Docker-in-Docker (DinD) on Windows 11 / WSL2 |
| Kubernetes | v1.30.14 (kubeadm) |
| Container Runtime | containerd 1.7.28 (native snapshotter) |
| CNI | Flannel |
| OS | Ubuntu 22.04.5 LTS |
| Kernel | 6.6.87.2-microsoft-standard-WSL2 |

## Nodes

| Node | Role | IP | RAM | CPU |
|------|------|----|-----|-----|
| controller-1 | control-plane | 172.20.0.11 | 4 GB | 0.5 |
| controller-2 | control-plane | 172.20.0.12 | 4 GB | 0.5 |
| controller-3 | control-plane | 172.20.0.13 | 4 GB | 0.5 |
| worker-1 | worker | 172.20.0.21 | 4 GB | 0.5 |
| worker-2 | worker | 172.20.0.22 | 4 GB | 0.5 |
| ansible | provisioning | 172.20.0.100 | 512 MB | 0.25 |

## Namespaces

| Namespace | Purpose |
|-----------|---------|
| kube-system | Core K8s components |
| kube-flannel | Flannel CNI |
| argocd | ArgoCD GitOps |
| gitea | Internal Git server |
| metallb-system | MetalLB load balancer |
| ingress-nginx | Nginx Ingress Controller |
| monitoring | Prometheus + Grafana |
| wp-site1 | WordPress Site 1 |
| wp-site2 | WordPress Site 2 |
| local-path-storage | Local Path Provisioner |

## Load Balancer (MetalLB)

- **Type**: L2 mode
- **IP Pool**: 172.20.0.200 - 172.20.0.250
- **Speakers**: Running on all 5 nodes
- **Config**: `manifests/metallb-config.yml`

## Ingress (Nginx)

| Host | Namespace | Backend Service | Rate Limit |
|------|-----------|----------------|------------|
| site1.local | wp-site1 | wordpress:80 | 50 rps |
| pma-site1.local | wp-site1 | phpmyadmin:80 | 10 rps |
| site2.local | wp-site2 | wordpress:80 | 50 rps |
| pma-site2.local | wp-site2 | phpmyadmin:80 | 10 rps |

- **External IP**: 172.20.0.200
- **Max Upload Size**: 64 MB (WordPress)
- **Max Connections**: 20 (WordPress)

## WordPress Sites

### Per-Site Stack

Each site runs in its own namespace with isolated resources:

| Component | Image | PVC | Service Port |
|-----------|-------|-----|-------------|
| WordPress | wordpress:6-php8.2-apache | wordpress-data (2Gi) | 80 |
| MariaDB | mariadb:10.11 | mariadb-data (2Gi) | 3306 |
| Redis | redis:7-alpine (64MB max) | - | 6379 |
| phpMyAdmin | phpmyadmin:5 | - | 80 |

### Site 1 (wp-site1)

- **Hostname**: site1.local / pma-site1.local
- **DB Passwords**: site1root123 / site1pass123
- **Status**: Healthy, Synced

### Site 2 (wp-site2)

- **Hostname**: site2.local / pma-site2.local
- **DB Passwords**: site2root456 / site2pass456
- **Status**: Healthy, Synced

## Resource Limits (Per Site Namespace)

### ResourceQuota (wp-quota)

| Resource | Request | Limit |
|----------|---------|-------|
| CPU | 2 cores | 4 cores |
| Memory | 2 Gi | 4 Gi |
| Pods | 10 | - |
| PVCs | 5 | - |

### LimitRange (wp-limits)

| | CPU | Memory |
|--|-----|--------|
| Default | 500m | 512Mi |
| Default Request | 100m | 128Mi |
| Max (Container) | 2 | 2Gi |
| Min (Container) | 50m | 64Mi |
| Max (Pod) | 3 | 3Gi |

### Bandwidth Limits (per-pod annotations)

| Deployment | Ingress | Egress |
|------------|---------|--------|
| WordPress | 50 Mbps | 50 Mbps |
| MariaDB | 20 Mbps | 20 Mbps |

## GitOps (ArgoCD)

- **URL**: https://localhost:8080
- **Credentials**: admin / wQouQbcfprzuWFUR
- **Git Source**: http://gitea.gitea.svc:3000/argocd/k8s-apps.git
- **Sync Policy**: Automated (prune + self-heal)
- **Apps**: wp-site1, wp-site2

### Repository Structure (Gitea)

```
k8s-apps/
  wordpress-base/
    kustomization.yaml    # Base Kustomization with bandwidth patches
    secrets.yaml          # Default DB credentials
    mariadb.yaml          # MariaDB 10.11 deployment + PVC
    redis.yaml            # Redis 7 deployment
    wordpress.yaml        # WordPress 6 deployment + PVC
    phpmyadmin.yaml       # phpMyAdmin 5 deployment
    resource-limits.yaml  # ResourceQuota + LimitRange
    ingress.yaml          # Nginx Ingress rules
  sites/
    site1/
      kustomization.yaml  # Overlay: namespace, passwords, hostnames
    site2/
      kustomization.yaml  # Overlay: namespace, passwords, hostnames
```

## Monitoring

### Prometheus

- **URL**: http://localhost:9090
- **Namespace**: monitoring
- **Scrape Targets**: cadvisor, kube-state-metrics, node metrics via API proxy
- **Metrics**: 644+ container metrics, 40+ pod info series

### Grafana

- **URL**: http://localhost:3000
- **Credentials**: admin / admin123
- **Datasource**: Prometheus (auto-configured)

#### Dashboards

1. **Cluster Overview** (uid: cluster-overview)
   - CPU/memory per node
   - Pods running, nodes ready
   - Namespaces, deployments, PVCs count
   - Container restarts
   - CPU/memory per namespace
   - Network I/O

2. **Pod Resources** (uid: pod-resources)
   - Namespace filter
   - CPU/memory per pod
   - Top 15 containers by resource usage
   - Pod status table
   - Restart counts
   - Network per pod

## Persistent Volumes (Docker)

Each node has named Docker volumes for state persistence:

```
{node}-etc-kubernetes    /etc/kubernetes
{node}-var-lib-etcd      /var/lib/etcd        (controllers only)
{node}-var-lib-kubelet   /var/lib/kubelet
{node}-var-lib-containerd /var/lib/containerd
{node}-etc-cni           /etc/cni
```

**Total**: 23 named volumes. Cluster survives `docker compose down && docker compose up`.

## Snapshots

- **Create**: `./snapshot.sh <tag>` (docker commit all containers)
- **Restore**: `./restore.sh <tag>` (updates docker-compose.yml images)
- **List**: `./snapshots-list.sh`

## Port Forwards

| Service | Local Port | Target |
|---------|-----------|--------|
| ArgoCD | 8080 | argocd-server:443 |
| Grafana | 3000 | grafana:3000 |
| Prometheus | 9090 | prometheus:9090 |
| WordPress Site1 | 8081 | wordpress:80 (wp-site1) |
| phpMyAdmin Site1 | 8181 | phpmyadmin:80 (wp-site1) |
| WordPress Site2 | 8082 | wordpress:80 (wp-site2) |
| phpMyAdmin Site2 | 8182 | phpmyadmin:80 (wp-site2) |

Start all: `./port-forward.sh`

## Adding a New Site

```bash
./new-site.sh site3 site3root789 site3pass789
```

This creates the Kustomize overlay, ArgoCD Application, and pushes to Gitea.

## Network Architecture

```
Internet / Host
      |
  [Docker Network: 172.20.0.0/24]
      |
  [MetalLB L2: 172.20.0.200-250]
      |
  [Nginx Ingress: 172.20.0.200]
      |
  +-----------+-----------+
  |                       |
  site1.local         site2.local
  pma-site1.local     pma-site2.local
  [wp-site1 ns]       [wp-site2 ns]
  |                       |
  WP ─ MariaDB ─ Redis   WP ─ MariaDB ─ Redis
  phpMyAdmin              phpMyAdmin
```
