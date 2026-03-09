"""Route issues to script fixes or AI analysis based on severity."""

import logging

from checks import Issue

log = logging.getLogger("cluster-agent")

# Categories that have deterministic script fixes
SCRIPT_FIXES = {
    "ImagePullBackOff": "fix_image_pull",
    # CrashLoopBackOff -> AI (prea multe cauze posibile: bad config, missing secret, OOM, etc.)
}

# Categories that always need AI
AI_REQUIRED = {
    "NodeNotReady",
    "DeploymentUnavailable",
    "PodFailed",
}


def route(issue: Issue) -> dict:
    """Decide how to handle an issue.

    Returns:
        {"type": "script", "handler": "fix_name"} or
        {"type": "ai", "severity": int} or
        {"type": "skip", "reason": "..."}
    """
    cat = issue.category

    # Severity 1: just log, don't act
    if issue.severity <= 1:
        return {"type": "skip", "reason": "Low severity, monitoring only"}

    # Known script fixes for severity 2
    if issue.severity <= 2 and cat in SCRIPT_FIXES:
        return {"type": "script", "handler": SCRIPT_FIXES[cat]}

    # Everything else goes to AI with appropriate model selection
    return {"type": "ai", "severity": issue.severity}
