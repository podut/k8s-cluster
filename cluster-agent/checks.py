"""Kubernetes cluster health checks and state diffing."""

import hashlib
import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone

from kubernetes import client

log = logging.getLogger("cluster-agent")


@dataclass
class Issue:
    severity: int  # 1=low, 2=medium, 3=high, 4=critical
    category: str
    namespace: str
    resource: str
    summary: str
    details: dict = field(default_factory=dict)


SKIP_NAMESPACES = {"kube-public", "kube-node-lease", "kube-system", "argocd", "cluster-agent"}


def get_cluster_state(v1: client.CoreV1Api, apps: client.AppsV1Api) -> dict:
    """Gather full cluster state snapshot."""
    state = {"timestamp": datetime.now(timezone.utc).isoformat()}

    # Nodes
    nodes = v1.list_node()
    state["nodes"] = []
    for n in nodes.items:
        conditions = {c.type: c.status for c in (n.status.conditions or [])}
        state["nodes"].append({
            "name": n.metadata.name,
            "ready": conditions.get("Ready", "Unknown"),
            "roles": [
                k.replace("node-role.kubernetes.io/", "")
                for k in (n.metadata.labels or {})
                if k.startswith("node-role.kubernetes.io/")
            ] or ["worker"],
            "conditions": conditions,
        })

    # Pods (skip system namespaces that are noisy)
    pods = v1.list_pod_for_all_namespaces()
    state["pods"] = []
    for p in pods.items:
        ns = p.metadata.namespace
        if ns in SKIP_NAMESPACES:
            continue
        container_statuses = []
        for cs in (p.status.container_statuses or []):
            s = {"name": cs.name, "ready": cs.ready, "restarts": cs.restart_count}
            if cs.state.waiting:
                s["waiting"] = cs.state.waiting.reason
            if cs.last_state and cs.last_state.terminated:
                s["last_terminated_reason"] = cs.last_state.terminated.reason
            container_statuses.append(s)

        pod_state = {
            "name": p.metadata.name,
            "namespace": ns,
            "phase": p.status.phase,
            "containers": container_statuses,
        }

        # Collect logs if pod is failing
        if p.status.phase != "Running" or any(not cs["ready"] for cs in container_statuses):
            try:
                # Get logs from the first container
                container_name = p.spec.containers[0].name
                logs = v1.read_namespaced_pod_log(
                    name=p.metadata.name,
                    namespace=ns,
                    container=container_name,
                    tail_lines=20
                )
                pod_state["logs"] = logs
            except Exception:
                pod_state["logs"] = "(could not fetch logs)"

        state["pods"].append(pod_state)

    # Deployments
    deps = apps.list_deployment_for_all_namespaces()
    state["deployments"] = []
    for d in deps.items:
        ns = d.metadata.namespace
        if ns in SKIP_NAMESPACES:
            continue
        state["deployments"].append({
            "name": d.metadata.name,
            "namespace": ns,
            "replicas": d.spec.replicas or 0,
            "ready": d.status.ready_replicas or 0,
            "available": d.status.available_replicas or 0,
            "images": [
                c.image for c in (d.spec.template.spec.containers or [])
            ],
        })

    # Services (for discovery)
    svcs = v1.list_service_for_all_namespaces()
    state["services"] = []
    for s in svcs.items:
        ns = s.metadata.namespace
        if ns in SKIP_NAMESPACES:
            continue
        state["services"].append({
            "name": s.metadata.name,
            "namespace": ns,
            "type": s.spec.type,
        })

    # Recent warning events (last hour)
    events = v1.list_event_for_all_namespaces(
        field_selector="type=Warning",
    )
    state["warning_events"] = []
    for e in events.items:
        ns = e.metadata.namespace
        if ns in SKIP_NAMESPACES:
            continue
        state["warning_events"].append({
            "namespace": ns,
            "reason": e.reason,
            "message": e.message,
            "object": f"{e.involved_object.kind}/{e.involved_object.name}",
            "count": e.count or 1,
        })

    return state


def state_hash(state: dict) -> str:
    """Hash relevant parts of state to detect changes."""
    relevant = {
        "nodes": state.get("nodes", []),
        "pods": [
            {k: v for k, v in p.items() if k != "name"}
            for p in state.get("pods", [])
        ],
        "deployments": state.get("deployments", []),
    }
    raw = json.dumps(relevant, sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def detect_issues(state: dict) -> list[Issue]:
    """Analyze state and return list of issues found."""
    issues = []

    # Check nodes
    for node in state.get("nodes", []):
        if node["ready"] != "True":
            issues.append(Issue(
                severity=4,
                category="NodeNotReady",
                namespace="",
                resource=f"node/{node['name']}",
                summary=f"Node {node['name']} is NotReady",
                details={"conditions": node["conditions"]},
            ))

    # Check pods
    for pod in state.get("pods", []):
        ns = pod["namespace"]
        name = pod["name"]

        if pod["phase"] == "Failed":
            issues.append(Issue(
                severity=3,
                category="PodFailed",
                namespace=ns,
                resource=f"pod/{name}",
                summary=f"Pod {name} in {ns} is Failed",
            ))

        for cs in pod.get("containers", []):
            waiting = cs.get("waiting", "")
            last_terminated = cs.get("last_terminated_reason", "")

            if waiting == "ImagePullBackOff" or waiting == "ErrImagePull":
                issues.append(Issue(
                    severity=2,
                    category="ImagePullBackOff",
                    namespace=ns,
                    resource=f"pod/{name}",
                    summary=f"Pod {name} in {ns}: {waiting}",
                    details={"container": cs["name"]},
                ))

            elif waiting == "CrashLoopBackOff" or last_terminated == "OOMKilled":
                category = "OOMKilled" if last_terminated == "OOMKilled" else "CrashLoopBackOff"
                issues.append(Issue(
                    severity=3,
                    category=category,
                    namespace=ns,
                    resource=f"pod/{name}",
                    summary=f"Pod {name} in {ns}: {category} (restarts: {cs['restarts']})",
                    details={"restarts": cs["restarts"], "reason": last_terminated},
                ))

            elif cs.get("restarts", 0) > 10:
                issues.append(Issue(
                    severity=2,
                    category="HighRestarts",
                    namespace=ns,
                    resource=f"pod/{name}",
                    summary=f"Pod {name} in {ns}: {cs['restarts']} restarts",
                    details={"restarts": cs["restarts"]},
                ))

    # Check deployments
    for dep in state.get("deployments", []):
        expected = dep["replicas"]
        ready = dep["ready"]
        if expected > 0 and ready == 0:
            issues.append(Issue(
                severity=3,
                category="DeploymentUnavailable",
                namespace=dep["namespace"],
                resource=f"deployment/{dep['name']}",
                summary=f"Deployment {dep['name']} in {dep['namespace']}: 0/{expected} ready",
                details={"images": dep["images"]},
            ))
        elif expected > 0 and ready < expected:
            issues.append(Issue(
                severity=2,
                category="DeploymentDegraded",
                namespace=dep["namespace"],
                resource=f"deployment/{dep['name']}",
                summary=f"Deployment {dep['name']} in {dep['namespace']}: {ready}/{expected} ready",
            ))

    # Deduplicate by resource
    seen = set()
    unique = []
    for issue in issues:
        key = f"{issue.category}:{issue.namespace}/{issue.resource}"
        if key not in seen:
            seen.add(key)
            unique.append(issue)

    return sorted(unique, key=lambda i: -i.severity)
