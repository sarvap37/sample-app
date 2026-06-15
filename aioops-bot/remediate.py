"""
Auto-remediation actions for the AIOps triage bot.

Decision tree:
  scenario pod (crash/oom)  →  delete the scenario deployment (clean rollback)
  main app OOMKilled         →  increase memory limit in deployment.yaml → git push → ArgoCD syncs
  main app CrashLooping      →  kubectl rollout restart
  main app AppDown           →  kubectl rollout restart
  anything else              →  log only (requires human)
"""

import os
import subprocess
from pathlib import Path

REPO_ROOT = os.getenv("REPO_ROOT", str(Path(__file__).parent.parent))
MAIN_DEPLOYMENT = "hello-world-app"
MAIN_NAMESPACE = "default"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def _is_scenario_pod(pod: str) -> bool:
    return f"{MAIN_DEPLOYMENT}-crash-" in pod or f"{MAIN_DEPLOYMENT}-oom-" in pod


def _scenario_deployment(pod: str) -> str | None:
    if f"{MAIN_DEPLOYMENT}-crash-" in pod:
        return f"{MAIN_DEPLOYMENT}-crash"
    if f"{MAIN_DEPLOYMENT}-oom-" in pod:
        return f"{MAIN_DEPLOYMENT}-oom"
    return None


# ---------------------------------------------------------------------------
# Remediation actions
# ---------------------------------------------------------------------------

def delete_scenario_deployment(pod: str, namespace: str) -> str:
    dep = _scenario_deployment(pod)
    if not dep:
        return f"Could not determine scenario deployment from pod '{pod}'"
    result = _run(
        ["kubectl", "delete", "deployment", dep, "-n", namespace, "--ignore-not-found"],
        check=False,
    )
    output = result.stdout.strip() or result.stderr.strip() or "done"
    return f"Deleted scenario deployment '{dep}': {output}"


def rollout_restart(namespace: str) -> str:
    result = _run(
        ["kubectl", "rollout", "restart", f"deployment/{MAIN_DEPLOYMENT}", "-n", namespace],
        check=False,
    )
    if result.returncode == 0:
        return f"Triggered rollout restart for {MAIN_DEPLOYMENT}"
    return f"Rollout restart failed: {result.stderr.strip()}"


def increase_memory_limit(factor: float = 1.5, max_mb: int = 512) -> str:
    """
    Read the current memory limit from the live deployment, increase it,
    update k8s/deployment.yaml, and push via GitOps so ArgoCD picks it up.
    """
    # Get live limit so we don't rely on file parsing
    r = _run(
        [
            "kubectl", "get", "deployment", MAIN_DEPLOYMENT,
            "-n", MAIN_NAMESPACE,
            "-o", "jsonpath={.spec.template.spec.containers[0].resources.limits.memory}",
        ],
        check=False,
    )
    if r.returncode != 0 or not r.stdout.strip():
        return "Could not read current memory limit from cluster"

    current_limit = r.stdout.strip()  # e.g. "128Mi"
    if not current_limit.endswith("Mi"):
        return f"Unexpected memory limit format: {current_limit}"

    old_mb = int(current_limit[:-2])
    new_mb = min(int(old_mb * factor), max_mb)
    if new_mb <= old_mb:
        return f"Memory limit already at cap ({max_mb}Mi) — manual review needed"

    # Patch the YAML file (requests and limits have different values so this is unambiguous)
    deployment_path = Path(REPO_ROOT) / "k8s" / "deployment.yaml"
    old_str = f'memory: "{old_mb}Mi"'
    new_str = f'memory: "{new_mb}Mi"'

    content = deployment_path.read_text()
    if old_str not in content:
        return f"Could not find '{old_str}' in deployment.yaml — manual fix needed"

    # Only replace the limits entry (requests has a different value)
    # Find limits: block and replace only within it
    limits_idx = content.rfind("limits:")
    if limits_idx == -1:
        return "Could not find 'limits:' block in deployment.yaml"
    patched = content[:limits_idx] + content[limits_idx:].replace(old_str, new_str, 1)
    deployment_path.write_text(patched)

    # Git commit and push
    try:
        _run(["git", "-C", REPO_ROOT, "add", "k8s/deployment.yaml"])
        _run(
            [
                "git", "-C", REPO_ROOT, "commit", "-m",
                f"fix(auto-remediation): memory limit {old_mb}Mi → {new_mb}Mi after OOMKill",
            ]
        )
        _run(["git", "-C", REPO_ROOT, "push"])
        return (
            f"Memory limit bumped {old_mb}Mi → {new_mb}Mi. "
            f"Committed & pushed — ArgoCD will auto-sync."
        )
    except subprocess.CalledProcessError as exc:
        # Undo file change so repo stays clean
        _run(["git", "-C", REPO_ROOT, "checkout", "k8s/deployment.yaml"], check=False)
        return f"Git operation failed (file reverted): {exc.stderr}"


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def remediate(alert_name: str, pod: str, namespace: str) -> str:
    """Return a human-readable description of the action taken."""

    if _is_scenario_pod(pod):
        # Scenario pods are intentionally broken — deleting them is the fix
        return delete_scenario_deployment(pod, namespace)

    if alert_name == "HelloWorldPodOOMKilled":
        return increase_memory_limit()

    if alert_name in ("HelloWorldPodCrashLooping", "HelloWorldAppDown"):
        return rollout_restart(namespace)

    if alert_name in ("HelloWorldHighRestartRate", "HelloWorldHighMemoryUsage"):
        return "⚠ No automated fix — restart rate/memory alerts require human investigation."

    return f"No remediation configured for alert '{alert_name}'"
