"""Fix ImagePullBackOff by reverting to a known-good image tag."""

import logging

log = logging.getLogger("cluster-agent")

# Known-good fallback tags per image
KNOWN_GOOD = {
    "nginx": "nginx:stable",
    "wordpress": "wordpress:6-php8.2-apache",
    "mariadb": "mariadb:11",
    "redis": "redis:7-alpine",
    "grafana": "grafana/grafana:latest",
    "prometheus": "prom/prometheus:latest",
}


def fix(namespace: str, deployment_images: list[str], manifest_path: str, manifest_content: str) -> dict | None:
    """Fix image pull errors by replacing bad tags with known-good ones.
    Returns {"file_path": ..., "content": ..., "summary": ...} or None."""

    fixed_content = manifest_content
    changes = []

    for image in deployment_images:
        # Extract image name without tag
        base = image.split(":")[0].split("/")[-1]

        if base in KNOWN_GOOD:
            good_image = KNOWN_GOOD[base]
            # Replace the exact image reference in manifest
            if image in fixed_content:
                fixed_content = fixed_content.replace(image, good_image)
                changes.append(f"{image} → {good_image}")

    if not changes:
        return None

    return {
        "file_path": manifest_path,
        "content": fixed_content,
        "summary": f"Fix image in {namespace}: {', '.join(changes)}",
    }
