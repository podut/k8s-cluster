"""Model escalation with Gemini + DeepSeek."""

import json
import logging
import os

import requests

log = logging.getLogger("cluster-agent")

# Model tiers — cheapest first, escalate when needed
MODELS = {
    "triage": {"provider": "deepseek", "model": "deepseek-chat"},
    "simple": {"provider": "deepseek", "model": "deepseek-chat"},
    "complex": {"provider": "deepseek", "model": "deepseek-chat"},
    "critical": {"provider": "deepseek", "model": "deepseek-chat"},
}

ESCALATION_CHAIN = [
    {"provider": "deepseek", "model": "deepseek-chat"},
]


def _deepseek(model: str, system: str, user_msg: str, max_tokens: int = 2000) -> str:
    """Call DeepSeek API (OpenAI-compatible)."""
    resp = requests.post(
        "https://api.deepseek.com/chat/completions",
        headers={
            "Authorization": f"Bearer {os.getenv('DEEPSEEK_API_KEY')}",
            "Content-Type": "application/json",
        },
        json={
            "model": model,
            "max_tokens": max_tokens,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user_msg},
            ],
        },
        timeout=60,
    )
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]["content"]


def _gemini(model: str, system: str, user_msg: str, max_tokens: int = 4000) -> str:
    """Call Gemini API."""
    api_key = os.getenv("GEMINI_API_KEY")
    url = f"https://generativelanguage.googleapis.com/v1/models/{model}:generateContent?key={api_key}"
    
    # Simpler payload for better compatibility
    payload = {
        "contents": [
            {
                "role": "user",
                "parts": [{"text": f"System Instruction: {system}\n\nUser Request: {user_msg}"}]
            }
        ],
        "generationConfig": {
            "maxOutputTokens": max_tokens,
            "temperature": 0.1
        }
    }
    
    resp = requests.post(
        url,
        headers={"Content-Type": "application/json"},
        json=payload,
        timeout=90
    )
    
    if resp.status_code != 200:
        log.error("Gemini error %d: %s", resp.status_code, resp.text)
        resp.raise_for_status()
        
    data = resp.json()
    return data["candidates"][0]["content"]["parts"][0]["text"]


def _call(provider: str, model: str, system: str, user_msg: str, max_tokens: int = 2000) -> str:
    """Route to correct provider."""
    log.info("Calling %s/%s (%d max tokens)", provider, model, max_tokens)
    if provider == "deepseek":
        return _deepseek(model, system, user_msg, max_tokens)
    elif provider == "gemini":
        return _gemini(model, system, user_msg, max_tokens)
    else:
        raise ValueError(f"Unknown provider: {provider}")


def select_model(severity: int, is_retry: bool = False, prev_model: dict | None = None) -> dict:
    """Select model based on severity and retry state."""
    if is_retry and prev_model:
        for i, m in enumerate(ESCALATION_CHAIN):
            if m["model"] == prev_model["model"]:
                if i + 1 < len(ESCALATION_CHAIN):
                    return ESCALATION_CHAIN[i + 1]
                return ESCALATION_CHAIN[-1]
        return ESCALATION_CHAIN[-1]

    if severity <= 2:
        return MODELS["simple"]
    elif severity == 3:
        return MODELS["complex"]
    else:
        return MODELS["complex"]


def clean_json(raw: str) -> str:
    """Extract JSON from potential markdown blocks."""
    raw = raw.strip()
    if "```json" in raw:
        raw = raw.split("```json", 1)[1].rsplit("```", 1)[0]
    elif "```" in raw:
        raw = raw.split("```", 1)[1].rsplit("```", 1)[0]
    return raw.strip()


def triage(issues_text: str) -> dict:
    """Quick triage — is AI analysis needed?"""
    system = (
        "You are a Kubernetes cluster health triage system. "
        "Given a list of detected issues, determine which ones need AI analysis "
        "vs which have known deterministic fixes.\n"
        "Respond with JSON only, no markdown:\n"
        '{"issues": [{"summary": "...", "needs_ai": true/false, '
        '"script_fix": "fix_name or null", "severity": 1-4}]}'
    )
    raw = _call("deepseek", "deepseek-chat", system, issues_text, max_tokens=300)
    raw = clean_json(raw)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        log.warning("Failed to parse triage response: %s", raw[:200])
        return {"issues": []}


def analyze(model_info: dict, cluster_state: str, manifest_content: str, issue_summary: str, patterns: str = "") -> dict:
    """AI analysis — generate a fix for the issue using patterns if provided."""
    system = (
        "You are a Senior Kubernetes SRE. Your goal is to fix issues strictly within the provided context.\n\n"
        "GUIDELINES:\n"
        "1. If a required service (like MariaDB) needs passwords, generate strong ones.\n"
        "2. Do NOT put the actual password values in the 'fixed_manifest'. Instead, use placeholder values like 'VALUE_FROM_VAULT'.\n"
        "3. Provide the actual generated passwords in a separate 'generated_secrets' dictionary in the JSON response.\n"
        "4. Respond with JSON only, no markdown code fences.\n\n"
        'JSON Schema: {"diagnosis": "...", "fixed_manifest": "full YAML", "generated_secrets": {"KEY": "VALUE"}, "file_path": "...", "explanation": "...", "confidence": 0.0-1.0}'
    )
    user_msg = (
        f"## ISSUE\n{issue_summary}\n\n"
        f"## CURRENT MANIFEST\n```yaml\n{manifest_content}\n```\n\n"
        f"## PATTERNS FROM OTHER SUCCESSFUL PROJECTS\n{patterns}\n\n"
        f"## CLUSTER STATE (includes Logs & Services)\n```json\n{cluster_state}\n```"
    )

    raw = _call(
        model_info["provider"], model_info["model"],
        system, user_msg,
        max_tokens=4000,
    )
    raw = clean_json(raw)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        log.error("Failed to parse AI response: %s", raw[:300])
        return {}
