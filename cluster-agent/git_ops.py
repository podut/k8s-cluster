"""Git operations — dynamic multi-repo support using ArgoCD metadata."""

import base64
import hashlib
import logging
import os
import re
from dataclasses import dataclass
from pathlib import Path

import requests

log = logging.getLogger("cluster-agent")

GITHUB_API = "https://api.github.com"


@dataclass
class AppMapping:
    """Maps an ArgoCD app to its git source."""
    name: str
    namespace: str
    repo: str    # Format: 'user/repo'
    branch: str
    path: str


# Populated at startup from ArgoCD
_app_mappings: list[AppMapping] = []


def _headers() -> dict:
    return {
        "Authorization": f"token {os.getenv('GITHUB_TOKEN')}",
        "Accept": "application/vnd.github+json",
    }


def _parse_repo(url: str) -> str:
    """Convert git URL to 'user/repo' format."""
    if not url:
        return os.getenv("GITHUB_REPO", "podut/k8s-cluster")
    # Handle https://github.com/user/repo.git or git@github.com:user/repo.git
    match = re.search(r"github\.com[:/](.+?)(?:\.git)?$", url)
    if match:
        return match.group(1)
    return os.getenv("GITHUB_REPO", "podut/k8s-cluster")


def load_argocd_mappings():
    """Load namespace→repo/branch/path mappings from ArgoCD applications."""
    global _app_mappings
    try:
        from kubernetes import client
        api = client.CustomObjectsApi()
        apps = api.list_namespaced_custom_object(
            group="argoproj.io",
            version="v1alpha1",
            namespace="argocd",
            plural="applications",
        )
        _app_mappings = []
        for app in apps.get("items", []):
            name = app["metadata"]["name"]
            spec = app.get("spec", {})
            source = spec.get("source", {})
            dest = spec.get("destination", {})

            namespace = dest.get("namespace", name)
            repo_url = source.get("repoURL", "")
            repo = _parse_repo(repo_url)
            branch = source.get("targetRevision", "main")
            if branch == "HEAD" or not branch:
                branch = "main"
            path = source.get("path", "")

            mapping = AppMapping(
                name=name,
                namespace=namespace,
                repo=repo,
                branch=branch,
                path=path,
            )
            _app_mappings.append(mapping)
            log.info("ArgoCD app: %s → repo=%s ns=%s branch=%s path=%s", name, repo, namespace, branch, path)

    except Exception as e:
        log.error("Failed to load ArgoCD mappings: %s", e)


def get_mapping_for_namespace(namespace: str) -> AppMapping | None:
    """Find ArgoCD app mapping for a namespace."""
    for m in _app_mappings:
        if m.namespace == namespace:
            return m
    for m in _app_mappings:
        if m.name == namespace:
            return m
    return None


def get_file(repo: str, path: str, ref: str = "main") -> tuple[str, str]:
    """Get file content and SHA from specific repo."""
    url = f"{GITHUB_API}/repos/{repo}/contents/{path}"
    resp = requests.get(url, headers=_headers(), params={"ref": ref})
    resp.raise_for_status()
    data = resp.json()
    content = base64.b64decode(data["content"]).decode()
    return content, data["sha"]


def list_dir(repo: str, path: str, ref: str = "main") -> list[str]:
    """List files in a directory of a specific repo."""
    url = f"{GITHUB_API}/repos/{repo}/contents/{path}"
    resp = requests.get(url, headers=_headers(), params={"ref": ref})
    resp.raise_for_status()
    return [f["path"] for f in resp.json()]


def get_manifest_for_namespace(namespace: str) -> tuple[str, str] | None:
    """Find manifest using dynamic mapping."""
    mapping = get_mapping_for_namespace(namespace)
    if not mapping or not mapping.path:
        log.warning("No mapping/path for namespace %s", namespace)
        return None

    try:
        files = list_dir(mapping.repo, mapping.path, ref=mapping.branch)
        all_content = []
        first_path = None
        for f in files:
            if f.endswith((".yaml", ".yml")):
                content, _ = get_file(mapping.repo, f, ref=mapping.branch)
                if first_path is None:
                    first_path = f
                all_content.append(f"# --- {f} ---\n{content}")
        if all_content:
            return first_path, "\n".join(all_content)
    except Exception as e:
        log.error("Failed to get manifests for %s: %s", namespace, e)

    return None


def get_patterns(namespace_hint: str) -> str:
    """Find other projects in the repo that might serve as patterns."""
    patterns = []
    prefix = namespace_hint.split('-')[0] if '-' in namespace_hint else namespace_hint[:3]
    
    for mapping in _app_mappings:
        if mapping.namespace != namespace_hint and mapping.namespace.startswith(prefix):
            res = get_manifest_for_namespace(mapping.namespace)
            if res:
                path, content = res
                patterns.append(f"### PATTERN FROM {mapping.namespace} (Repo: {mapping.repo}, Path: {path})\n{content}")
    
    return "\n\n".join(patterns)


def create_branch(repo: str, branch_name: str, from_ref: str = "main") -> bool:
    """Create a new branch from ref."""
    url = f"{GITHUB_API}/repos/{repo}/git/ref/heads/{from_ref}"
    resp = requests.get(url, headers=_headers())
    resp.raise_for_status()
    sha = resp.json()["object"]["sha"]

    url = f"{GITHUB_API}/repos/{repo}/git/refs"
    resp = requests.post(url, headers=_headers(), json={
        "ref": f"refs/heads/{branch_name}",
        "sha": sha,
    })
    return resp.status_code in [201, 422]


def update_file(repo: str, path: str, content: str, branch: str, message: str) -> bool:
    """Update file in specific repo."""
    url = f"{GITHUB_API}/repos/{repo}/contents/{path}"
    sha = None
    try:
        resp = requests.get(url, headers=_headers(), params={"ref": branch})
        if resp.status_code == 200:
            sha = resp.json()["sha"]
    except: pass

    payload = {
        "message": message,
        "content": base64.b64encode(content.encode()).decode(),
        "branch": branch,
    }
    if sha: payload["sha"] = sha

    resp = requests.put(url, headers=_headers(), json=payload)
    resp.raise_for_status()
    return True


def create_pr(repo: str, branch: str, title: str, body: str, base: str = "main") -> int | None:
    """Create a PR in specific repo."""
    url = f"{GITHUB_API}/repos/{repo}/pulls"
    resp = requests.post(url, headers=_headers(), json={
        "title": title, "body": body, "head": branch, "base": base,
    })
    if resp.status_code == 201:
        return resp.json()["number"]
    return None


def push_fix(file_path: str, content: str, issue_summary: str, namespace: str = "") -> int | None:
    """Full flow using dynamic repo and branch."""
    mapping = get_mapping_for_namespace(namespace)
    repo = mapping.repo if mapping else os.getenv("GITHUB_REPO", "podut/k8s-cluster")
    target_branch = mapping.branch if mapping else "main"
    
    autonomous = os.getenv("AUTONOMOUS_MODE", "false").lower() == "true"

    try:
        if autonomous:
            log.info("AUTONOMOUS: Pushing direct fix to repo=%s branch=%s", repo, target_branch)
            update_file(repo, file_path, content, target_branch, f"🤖 Auto-Fix: {issue_summary}")
            return 1

        slug = re.sub(r'[^a-z0-9]+', '-', issue_summary.lower())[:40].strip('-')
        branch = f"agent/fix-{slug}"
        if create_branch(repo, branch, from_ref=target_branch):
            update_file(repo, file_path, content, branch, f"fix: {issue_summary}")
            return create_pr(repo, branch, f"🤖 Fix: {issue_summary[:60]}", "Auto-fix", base=target_branch)
    except Exception as e:
        log.error("Failed to push fix to %s: %s", repo, e)
    return None
