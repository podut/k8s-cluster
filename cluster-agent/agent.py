"""Cluster Agent — monitors k8s cluster, suggests fixes via PRs."""

import json
import logging
import os
import sys
import time
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("cluster-agent")


def load_from_vault():
    """Override environment variables with values from Vault if available."""
    token = os.getenv("VAULT_ROOT_TOKEN")
    addr = os.getenv("VAULT_ADDR", "http://vault.vault:8200")
    if not token:
        return

    log.info("VAULT DETECTED: Fetching secrets from %s", addr)
    try:
        import requests
        # Get Gemini secrets
        resp = requests.get(
            f"{addr}/v1/secret/data/gemini",
            headers={"X-Vault-Token": token},
            timeout=10,
        )
        if resp.status_code == 200:
            data = resp.json()["data"]["data"]
            for k, v in data.items():
                os.environ[k.upper()] = v
                log.info("Loaded %s from Vault", k.upper())

        # Get Docker secrets
        resp = requests.get(
            f"{addr}/v1/secret/data/docker",
            headers={"X-Vault-Token": token},
            timeout=10,
        )
        if resp.status_code == 200:
            data = resp.json()["data"]["data"]
            os.environ["DOCKER_USER"] = data.get("user", "")
            os.environ["DOCKER_PASS"] = data.get("pass", "")
            log.info("Loaded Docker credentials from Vault")

        # Get Dynamic Agent Config
        resp = requests.get(
            f"{addr}/v1/secret/data/cluster-agent/config",
            headers={"X-Vault-Token": token},
            timeout=10,
        )
        if resp.status_code == 200:
            data = resp.json()["data"]["data"]
            os.environ["GITHUB_REPO"] = data.get("repo", os.getenv("GITHUB_REPO"))
            os.environ["MANIFESTS_PATH"] = data.get("manifests_path", os.getenv("MANIFESTS_PATH"))
            log.info("Dynamic config loaded: REPO=%s", os.environ["GITHUB_REPO"])

    except Exception as e:
        log.error("Failed to load from Vault: %s", e)


# Run vault loader immediately
load_from_vault()

from kubernetes import client, config

import checks
import git_ops
import models
import router

_data_dir = Path(os.getenv("AGENT_DATA_DIR", "/tmp"))
STATE_FILE = _data_dir / "cluster-agent-state.json"
HANDLED_FILE = _data_dir / "cluster-agent-handled.json"


def load_k8s():
    """Load kubernetes config (in-cluster or local)."""
    try:
        config.load_incluster_config()
        log.info("Loaded in-cluster k8s config")
    except config.ConfigException:
        config.load_kube_config()
        log.info("Loaded local kubeconfig")

    # Load ArgoCD app mappings for namespace→branch resolution
    git_ops.load_argocd_mappings()

    return client.CoreV1Api(), client.AppsV1Api()


def load_last_hash() -> str:
    """Load last known state hash."""
    if STATE_FILE.exists():
        data = json.loads(STATE_FILE.read_text())
        return data.get("hash", "")
    return ""


def save_state(state_hash: str):
    """Save current state hash."""
    STATE_FILE.write_text(json.dumps({"hash": state_hash, "time": time.time()}))


def load_handled() -> set:
    """Load set of already-handled issue keys to avoid duplicate PRs."""
    if HANDLED_FILE.exists():
        return set(json.loads(HANDLED_FILE.read_text()))
    return set()


def save_handled(handled: set):
    """Save handled issue keys."""
    HANDLED_FILE.write_text(json.dumps(list(handled)))


def issue_key(issue: checks.Issue) -> str:
    return f"{issue.category}:{issue.namespace}/{issue.resource}"


def handle_script_fix(issue: checks.Issue, handler_name: str) -> bool:
    """Run a deterministic script fix."""
    log.info("Script fix [%s] for: %s", handler_name, issue.summary)

    # Get manifest for this namespace
    result = git_ops.get_manifest_for_namespace(issue.namespace)
    if not result:
        log.warning("No manifest found for namespace %s", issue.namespace)
        return False

    manifest_path, manifest_content = result

    if handler_name == "fix_image_pull":
        from scripts.fix_image_pull import fix
        # Get images from issue details or extract from manifest
        images = issue.details.get("images", [])
        if not images:
            # Try to extract image references from manifest content
            import re
            images = re.findall(r'image:\s*(\S+)', manifest_content)
        if not images:
            log.info("No images found, falling back to AI")
            return False
        fix_result = fix(issue.namespace, images, manifest_path, manifest_content)

    elif handler_name == "fix_oom":
        from scripts.fix_oom import fix
        pod_name = issue.resource.replace("pod/", "")
        fix_result = fix(issue.namespace, pod_name, manifest_path, manifest_content)

    else:
        log.warning("Unknown handler: %s", handler_name)
        return False

    if not fix_result:
        log.info("Script fix produced no changes, escalating to AI")
        return False

    pr = git_ops.push_fix(
        file_path=fix_result["file_path"],
        content=fix_result["content"],
        issue_summary=fix_result["summary"],
        namespace=issue.namespace,
    )
    return pr is not None


def save_generated_secrets(secrets: dict, namespace: str):
    """Log generated secrets for manual review — NOT auto-saved to Vault for safety."""
    if not secrets:
        return

    review_file = _data_dir / "SECRETS_REVIEW_REQUIRED.env"
    with open(review_file, "a") as f:
        f.write(f"\n# === {namespace} (generated by AI) ===\n")
        f.write(f"# REVIEW BEFORE APPLYING TO VAULT\n")
        for k, v in secrets.items():
            f.write(f"{k}={v}\n")

    log.warning("⚠ AI generated %d secrets for %s - MANUAL REVIEW REQUIRED at %s",
                len(secrets), namespace, review_file)


def handle_ai_fix(issue: checks.Issue, cluster_state: dict, severity: int) -> bool:
    """Use AI to analyze and fix the issue."""
    model_info = models.select_model(severity)
    log.info("AI analysis [%s/%s] for: %s", model_info["provider"], model_info["model"], issue.summary)

    # Get manifest
    result = git_ops.get_manifest_for_namespace(issue.namespace)
    manifest_content = ""
    if result:
        _, manifest_content = result

    # Get patterns from other similar projects (e.g. other wp-sites)
    patterns = git_ops.get_patterns(issue.namespace)

    # Prepare compact state (only relevant namespace + nodes + all services)
    compact_state = {
        "nodes": cluster_state.get("nodes", []),
        "services": [
            {"name": s["name"], "namespace": s["namespace"]}
            for s in cluster_state.get("services", [])
        ],
        "pods": [
            {
                "name": p["name"],
                "namespace": p["namespace"],
                "phase": p["phase"],
                "containers": p["containers"],
                "logs": p.get("logs", "(no logs available)")
            }
            for p in cluster_state.get("pods", [])
            if p["namespace"] == issue.namespace
        ],
        "deployments": [d for d in cluster_state.get("deployments", [])
                        if d["namespace"] == issue.namespace],
        "warning_events": [e for e in cluster_state.get("warning_events", [])
                           if e["namespace"] == issue.namespace],
    }

    analysis = models.analyze(
        model_info=model_info,
        cluster_state=json.dumps(compact_state, indent=2),
        manifest_content=manifest_content or "(no manifest found)",
        issue_summary=issue.summary,
        patterns=patterns
    )

    if not analysis or not analysis.get("fixed_manifest"):
        log.warning("AI analysis returned no fix")
        if severity < 4:
            log.info("Escalating to higher model...")
            return handle_ai_fix(issue, cluster_state, severity + 1)
        return False

    confidence = analysis.get("confidence", 0)
    file_path = analysis.get("file_path") or ""
    diagnosis = analysis.get("diagnosis", "")

    log.info("AI diagnosis: %s", diagnosis)
    log.info("AI confidence: %.0f%%", confidence * 100)

    # Save any new secrets to .env file
    save_generated_secrets(analysis.get("generated_secrets", {}), issue.namespace)

    # If AI says it can't fix via manifest, log and skip
    if confidence < 0.3 or not file_path:
        log.warning("AI says issue is not fixable via manifest: %s", diagnosis)
        return False

    pr = git_ops.push_fix(
        file_path=file_path,
        content=analysis["fixed_manifest"],
        issue_summary=issue.summary,
        namespace=issue.namespace,
    )
    return pr is not None


def run_check(v1: client.CoreV1Api, apps: client.AppsV1Api):
    """Run one check cycle."""
    log.info("=== Running cluster check ===")

    # Step 0: Gather state
    state = checks.get_cluster_state(v1, apps)
    current_hash = checks.state_hash(state)
    last_hash = load_last_hash()

    if current_hash == last_hash:
        log.info("State unchanged (hash: %s), skipping", current_hash[:8])
        return

    log.info("State changed: %s → %s", last_hash[:8] or "none", current_hash[:8])
    save_state(current_hash)

    # Step 1: Detect issues
    issues = checks.detect_issues(state)
    if not issues:
        log.info("No issues detected")
        return

    log.info("Found %d issue(s):", len(issues))
    for i in issues:
        log.info("  [sev%d] %s: %s", i.severity, i.category, i.summary)

    # Step 2: Filter already-handled
    handled = load_handled()
    new_issues = [i for i in issues if issue_key(i) not in handled]

    if not new_issues:
        log.info("All issues already handled, waiting for resolution")
        return

    # Step 3: Route and handle each issue
    for issue in new_issues:
        try:
            route_result = router.route(issue)
            log.info("Route %s → %s", issue.category, route_result["type"])

            success = False
            if route_result["type"] == "skip":
                log.info("Skipping: %s", route_result["reason"])
                continue
            elif route_result["type"] == "script":
                success = handle_script_fix(issue, route_result["handler"])
                if not success:
                    # Fallback to AI
                    success = handle_ai_fix(issue, state, issue.severity)
            elif route_result["type"] == "ai":
                success = handle_ai_fix(issue, state, route_result["severity"])

            if success:
                handled.add(issue_key(issue))
                log.info("✓ PR created for: %s", issue.summary)
            else:
                log.warning("✗ Could not fix: %s", issue.summary)
        except Exception as e:
            log.error("Error handling issue %s: %s", issue.summary, e)
            continue

    save_handled(handled)


def main():
    interval = int(os.getenv("CHECK_INTERVAL", "60"))
    v1, apps = load_k8s()

    # First run immediately
    log.info("Cluster Agent started (interval: %ds)", interval)

    if "--once" in sys.argv:
        run_check(v1, apps)
        return

    while True:
        try:
            run_check(v1, apps)
        except Exception as e:
            log.error("Check failed: %s", e, exc_info=True)
        log.info("Next check in %ds...", interval)
        time.sleep(interval)


if __name__ == "__main__":
    main()
