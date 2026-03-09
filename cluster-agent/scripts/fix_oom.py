"""Fix OOMKilled by bumping memory limits."""

import logging
import re

log = logging.getLogger("cluster-agent")


def fix(namespace: str, pod_name: str, manifest_path: str, manifest_content: str) -> dict | None:
    """Bump memory limits by 50% for OOMKilled pods.
    Returns {"file_path": ..., "content": ..., "summary": ...} or None."""

    # Find memory limits in manifest and bump them
    def bump_memory(match):
        value = match.group(1)
        unit = match.group(2)
        new_value = int(int(value) * 1.5)
        return f"memory: {new_value}{unit}"

    fixed = re.sub(
        r'memory:\s*(\d+)(Mi|Gi)',
        bump_memory,
        manifest_content,
    )

    if fixed == manifest_content:
        return None

    return {
        "file_path": manifest_path,
        "content": fixed,
        "summary": f"Bump memory limits +50% for {pod_name} in {namespace}",
    }
