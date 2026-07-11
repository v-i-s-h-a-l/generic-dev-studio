#!/usr/bin/env python3
"""Shared helpers for SDL client git hooks and CI validation.

This module is imported by the thin ``.stibdedlom/bin/validate-*.py`` scripts.
It is intentionally self-contained and depends only on the Python standard
library plus ``pyyaml`` when available.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import yaml
except Exception:  # pragma: no cover - client may not have pyyaml installed yet
    yaml = None

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    from cryptography.exceptions import InvalidSignature
except Exception:  # pragma: no cover - client may not have cryptography installed yet
    Ed25519PublicKey = None  # type: ignore[misc, assignment]
    InvalidSignature = Exception  # type: ignore[misc, assignment]


EXEMPT_PATTERNS = [
    r"^\.stibdedlom/routing/",
    r"^\.stibdedlom/bin/",
    r"^\.stibdedlom/lib/",
    r"^\.stibdedlom/trust/",
    r"^\.github/",
    r"^\.githooks/",
    r"^AGENTS\.md$",
    r"^\.cursorrules$",
    r"^CLAUDE\.md$",
    r"^GEMINI\.md$",
]

PROTECTED_BRANCHES = ["main", "master", "release/*"]

ROUTING_ATTESTATION_SCHEMA_VERSION = "sdl-routing-attestation@2"
# Attestation schema versions accepted by the client hooks. New attestations are
# @2 (kernel-enforced, ADR-080); @1 is grandfathered so existing client repos
# that have not re-onboarded keep validating.
SUPPORTED_ROUTING_ATTESTATION_VERSIONS = frozenset(
    {"sdl-routing-attestation@1", "sdl-routing-attestation@2"}
)
CLIENT_MANIFEST_SCHEMA_VERSION = "stibdedlom-client-manifest@1"
INVOCATION_POLICY_SCHEMA_VERSION = "0.1.0"


def _real(path: Path) -> Path:
    """Return the real, symlink-resolved path."""
    return Path(os.path.realpath(path))


def _run_git(repo_root: Path, *args: str, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=str(repo_root),
        capture_output=True,
        text=True,
        check=check,
    )


def current_branch(repo_root: Path) -> str | None:
    result = _run_git(repo_root, "rev-parse", "--abbrev-ref", "HEAD")
    branch = result.stdout.strip()
    return branch if branch and branch != "HEAD" else None


def is_protected_branch(branch: str) -> bool:
    for pattern in PROTECTED_BRANCHES:
        if pattern.endswith("*"):
            if branch.startswith(pattern[:-1]):
                return True
        elif branch == pattern:
            return True
    return False


def list_changed_files(
    repo_root: Path,
    *,
    staged: bool = False,
    base: str | None = None,
    head: str | None = None,
    commit_sha: str | None = None,
) -> list[str]:
    """Return repo-relative changed file paths.

    Args:
        staged: Use the staged diff (pre-commit).
        base/head: Use ``git diff --name-only base..head`` (CI / push).
        commit_sha: Use ``git show`` to list files touched by a single commit.
    """
    if commit_sha:
        result = _run_git(repo_root, "show", "--name-only", "--format=", commit_sha)
    elif base and head:
        result = _run_git(repo_root, "diff", "--name-only", f"{base}..{head}")
    elif staged:
        result = _run_git(repo_root, "diff", "--cached", "--name-only", "--diff-filter=ACMRT")
    else:
        # Default CI re-run: changes in the current HEAD commit.
        result = _run_git(repo_root, "diff", "--name-only", "HEAD~1..HEAD")
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def is_exempt(path: str) -> bool:
    return any(re.search(pattern, path) for pattern in EXEMPT_PATTERNS)


def is_under_allowed_path(rel_path: str, allowed_paths: list[str], repo_root: Path) -> bool:
    """Return True if ``rel_path`` is contained within at least one allowed path.

    Uses ``realpath`` to reject symlink escapes and ``Path.relative_to`` for
    containment.
    """
    root = _real(repo_root)
    child = _real(root / rel_path)
    try:
        child.relative_to(root)
    except ValueError:
        return False

    for allowed in allowed_paths:
        base = _real(root / allowed)
        try:
            base.relative_to(root)
        except ValueError:
            continue
        try:
            child.relative_to(base)
            return True
        except ValueError:
            continue
    return False


def parse_attestation_trailer(value: str) -> list[tuple[int, str | None]]:
    """Parse ``SDL-Routing-Attestation`` trailer values.

    Supported forms:
        42
        42:sha256:...
        42,99:sha256:...
    """
    refs: list[tuple[int, str | None]] = []
    for part in [item.strip() for item in value.split(",") if item.strip()]:
        if ":" in part:
            issue_part, envelope = part.split(":", 1)
        else:
            issue_part, envelope = part, None
        try:
            issue = int(issue_part)
        except ValueError as exc:
            raise ValueError(f"invalid issue number in '{part}'") from exc
        refs.append((issue, envelope))
    return refs


def load_manifest(repo_root: Path) -> dict[str, Any] | None:
    path = repo_root / ".stibdedlom" / "manifest.yaml"
    if not path.exists():
        return None
    if yaml is None:
        return None
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def load_attestation(repo_root: Path, issue: int) -> dict[str, Any] | None:
    path = repo_root / ".stibdedlom" / "routing" / f"{issue}.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def load_routing_attestation_key(repo_root: Path) -> tuple[bytes | None, list[str]]:
    """Load the project HMAC key from environment or the out-of-band memory root.

    Returns ``(key_bytes, reason_codes)``. If no key is found, returns
    ``(None, ["sdl.hook.signature_skipped"])`` so callers can emit a warning
    without blocking validation.
    """
    env_key = os.environ.get("SDL_ROUTING_ATTESTATION_KEY")
    if env_key:
        return env_key.encode("utf-8"), []

    manifest = load_manifest(repo_root)
    if manifest and manifest.get("memory_root"):
        key_path = (
            Path(manifest["memory_root"]).expanduser().resolve()
            / ".stibdedlom"
            / "trust"
            / "routing-attestation.key"
        )
        if key_path.exists():
            return key_path.read_bytes(), []

    return None, ["sdl.hook.signature_skipped"]


def _company_registry_root(repo_root: Path) -> Path | None:
    """Locate the checkout that holds the company capability registry.

    Order of preference:
      1. ``STIBDEDLOM_INFRA_ROOT`` environment variable.
      2. The current repo if it already contains ``registry/index.yaml``.
      3. ``company_registry_root`` from the client manifest.
    """
    env_root = os.environ.get("STIBDEDLOM_INFRA_ROOT")
    if env_root:
        return Path(env_root).expanduser().resolve()

    if (repo_root / "registry" / "index.yaml").exists():
        return repo_root

    manifest = load_manifest(repo_root)
    if manifest and manifest.get("company_registry_root"):
        return Path(manifest["company_registry_root"]).expanduser().resolve()

    return None


def _detect_domains_direct(
    changed_paths: list[str], registry_root: Path
) -> dict[str, Any] | None:
    try:
        original_path = sys.path.copy()
        if str(registry_root) not in sys.path:
            sys.path.insert(0, str(registry_root))
        try:
            from sdl_orchestrator.domain_detector import detect_domains

            return detect_domains(changed_paths, repo_root=registry_root)
        finally:
            sys.path[:] = original_path
    except Exception:  # noqa: BLE001
        return None


def _detect_domains_subprocess(
    changed_paths: list[str], registry_root: Path
) -> dict[str, Any] | None:
    try:
        proc = subprocess.run(
            [
                sys.executable,
                "-m",
                "sdl_orchestrator.domain_detector",
                "--repo-root",
                str(registry_root),
                "--paths-file",
                "-",
            ],
            input="\n".join(changed_paths),
            capture_output=True,
            text=True,
            cwd=str(registry_root),
            check=False,
        )
        if proc.returncode != 0:
            return None
        return json.loads(proc.stdout)
    except Exception:  # noqa: BLE001
        return None


def detect_domain_paths(
    changed_paths: list[str], repo_root: Path
) -> dict[str, Any]:
    """Return domain matches for ``changed_paths`` using the company registry.

    The result has the same shape as ``sdl_orchestrator.domain_detector.detect_domains``
    plus a ``reason_codes`` list explaining any skip/fallback conditions.
    """
    registry_root = _company_registry_root(repo_root)
    if registry_root is None:
        return {
            "matches": [],
            "review_gate": "none",
            "domains": [],
            "capabilities": [],
            "reason_codes": ["sdl.hook.domain_detection_skipped"],
        }

    result = _detect_domains_direct(changed_paths, registry_root)
    if result is None:
        result = _detect_domains_subprocess(changed_paths, registry_root)
    if result is None:
        return {
            "matches": [],
            "review_gate": "none",
            "domains": [],
            "capabilities": [],
            "reason_codes": ["sdl.hook.domain_detector_unavailable"],
        }

    result.setdefault("reason_codes", [])
    return result


def require_domain_review(
    changed_paths: list[str],
    lifecycle_record: dict[str, Any] | None,
    repo_root: Path,
) -> dict[str, Any]:
    """Block ``changed_paths`` if a matched domain requires an unmet review gate.

    A non-``none`` review gate requires ``lifecycle_record`` to carry an
    approved ``links.sibling_review_artifact`` (per ADR-077).
    """
    detection = detect_domain_paths(changed_paths, repo_root)
    review_gate = detection.get("review_gate", "none")

    if review_gate == "none":
        return {
            "ok": True,
            "reason": "no domain review required",
            "reason_codes": ["sdl.hook.domain_review_none"],
            "review_gate": "none",
            "domains": detection.get("domains", []),
        }

    if lifecycle_record is None:
        return {
            "ok": False,
            "reason": f"domain review gate '{review_gate}' requires a lifecycle record",
            "reason_codes": ["sdl.hook.domain_review_required"],
            "review_gate": review_gate,
            "domains": detection.get("domains", []),
            "matches": detection.get("matches", []),
        }

    sra = lifecycle_record.get("links", {}).get("sibling_review_artifact")
    if not sra:
        return {
            "ok": False,
            "reason": f"review_gate '{review_gate}' requires links.sibling_review_artifact",
            "reason_codes": ["sdl.hook.sibling_review_artifact_missing"],
            "review_gate": review_gate,
            "domains": detection.get("domains", []),
            "matches": detection.get("matches", []),
        }

    sra_path = repo_root / sra
    if not sra_path.exists():
        return {
            "ok": False,
            "reason": f"sibling-review artifact not found: {sra}",
            "reason_codes": ["sdl.hook.sibling_review_artifact_missing"],
            "review_gate": review_gate,
            "domains": detection.get("domains", []),
            "matches": detection.get("matches", []),
        }

    try:
        artifact = json.loads(sra_path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {
            "ok": False,
            "reason": f"sibling-review artifact is not valid JSON: {exc}",
            "reason_codes": ["sdl.hook.sibling_review_artifact_invalid"],
            "review_gate": review_gate,
            "domains": detection.get("domains", []),
            "matches": detection.get("matches", []),
        }

    verdict = artifact.get("merged", {}).get("verdict")
    if verdict != "approved":
        return {
            "ok": False,
            "reason": f"sibling-review artifact verdict is '{verdict}' (expected 'approved')",
            "reason_codes": ["sdl.hook.sibling_review_not_approved"],
            "review_gate": review_gate,
            "domains": detection.get("domains", []),
            "matches": detection.get("matches", []),
        }

    return {
        "ok": True,
        "reason": f"domain review satisfied ({review_gate})",
        "reason_codes": ["sdl.hook.domain_review_satisfied"],
        "review_gate": review_gate,
        "domains": detection.get("domains", []),
        "matches": detection.get("matches", []),
    }


def _load_lifecycle_record_for_attestation(
    repo_root: Path,
    attestation: dict[str, Any],
) -> dict[str, Any] | None:
    """Load the out-of-band lifecycle record referenced by an attestation."""
    manifest = load_manifest(repo_root)
    memory_root_value = manifest.get("memory_root") if manifest else None
    if not memory_root_value:
        return None
    memory_root = Path(memory_root_value).expanduser().resolve()
    record_path = find_lifecycle_record(
        memory_root,
        attestation.get("issue", 0),
        attestation.get("lifecycle_record_id"),
    )
    if record_path is None:
        return None
    try:
        return json.loads(record_path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return None


def find_lifecycle_record(memory_root: Path, issue: int, record_id: str | None = None) -> Path | None:
    """Return the first matching lifecycle record in the out-of-band memory root."""
    records_dir = memory_root.expanduser().resolve() / ".workflow"
    if not records_dir.exists():
        return None
    if record_id:
        candidate = records_dir / f"{record_id}.json"
        if candidate.exists():
            return candidate
    # Fallback to deterministic issue-based filename(s).
    for candidate in records_dir.glob(f"{issue}*.json"):
        return candidate
    return None


def _read_commit_message(
    repo_root: Path,
    commit_msg_file: Path | None = None,
    commit_msg_text: str | None = None,
    commit_sha: str | None = None,
) -> str:
    if commit_msg_text is not None:
        return commit_msg_text
    if commit_msg_file and commit_msg_file.exists():
        return commit_msg_file.read_text(encoding="utf-8")
    if commit_sha:
        return _run_git(repo_root, "log", "-1", "--format=%B", commit_sha).stdout
    return ""


def _commit_author_timestamp(repo_root: Path, sha: str) -> int:
    """Return the Unix author timestamp for a commit."""
    result = _run_git(repo_root, "show", "-s", "--format=%at", sha)
    return int(result.stdout.strip())


def _parse_iso_timestamp(value: str) -> Any:
    """Parse an ISO 8601 timestamp, tolerating trailing 'Z'."""
    value = value.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)


def validate_commit(
    repo_root: Path,
    *,
    staged: bool = False,
    commit_msg_file: Path | None = None,
    commit_msg_text: str | None = None,
    commit_sha: str | None = None,
) -> dict[str, Any]:
    """Validate a single commit / staged change set against routing attestations."""
    repo_root = _real(repo_root)

    branch = current_branch(repo_root)
    if branch and is_protected_branch(branch):
        return {
            "ok": False,
            "reason": f"direct commits to protected branch '{branch}' are not allowed",
            "reason_codes": ["sdl.hook.protected_branch"],
            "branch": branch,
        }

    anchor_ok, anchor_code = verify_pubkey_anchor_consistency(repo_root)
    if not anchor_ok:
        return {
            "ok": False,
            "reason": "trust anchor verification failed",
            "reason_codes": [anchor_code],
            "branch": branch,
        }

    changed = list_changed_files(repo_root, staged=staged, commit_sha=commit_sha)
    non_exempt = [path for path in changed if not is_exempt(path)]
    if not non_exempt:
        return {
            "ok": True,
            "reason": "only governance-only files changed",
            "reason_codes": ["sdl.hook.governance_only"],
            "changed_paths": changed,
        }

    message = _read_commit_message(repo_root, commit_msg_file, commit_msg_text, commit_sha)
    author_match = re.search(r"^SDL-Commit-Author:\s*(.+)$", message, re.MULTILINE)
    attestation_match = re.search(r"^SDL-Routing-Attestation:\s*(.+)$", message, re.MULTILINE)

    if not attestation_match:
        return {
            "ok": False,
            "reason": "missing SDL-Routing-Attestation trailer",
            "reason_codes": ["sdl.hook.missing_commit_trailers"],
            "changed_paths": non_exempt,
        }

    author = author_match.group(1).strip() if author_match else None
    try:
        refs = parse_attestation_trailer(attestation_match.group(1).strip())
    except ValueError as exc:
        return {
            "ok": False,
            "reason": f"invalid SDL-Routing-Attestation trailer: {exc}",
            "reason_codes": ["sdl.hook.invalid_attestation_trailer"],
            "changed_paths": non_exempt,
        }

    if not refs:
        return {
            "ok": False,
            "reason": "empty SDL-Routing-Attestation trailer",
            "reason_codes": ["sdl.hook.missing_commit_trailers"],
            "changed_paths": non_exempt,
        }

    key, key_reason_codes = load_routing_attestation_key(repo_root)

    attestations: list[dict[str, Any]] = []
    for issue, envelope in refs:
        attestation = load_attestation(repo_root, issue)
        if not attestation:
            return {
                "ok": False,
                "reason": f"routing attestation not found for issue #{issue}",
                "reason_codes": ["sdl.hook.missing_routing_attestation"],
                "changed_paths": non_exempt,
            }
        if attestation.get("schema_version") not in SUPPORTED_ROUTING_ATTESTATION_VERSIONS:
            return {
                "ok": False,
                "reason": f"attestation for issue #{issue} has invalid schema version",
                "reason_codes": ["sdl.hook.invalid_attestation_schema"],
                "changed_paths": non_exempt,
            }
        if envelope:
            full = attestation.get("envelope_hash", "")
            if full != envelope and not full.endswith(envelope):
                return {
                    "ok": False,
                    "reason": f"envelope hash mismatch for issue #{issue}",
                    "reason_codes": ["sdl.hook.envelope_hash_mismatch"],
                    "changed_paths": non_exempt,
                }
        if attestation.get("signature"):
            if not verify_attestation_signature(attestation, key=key, repo_root=repo_root):
                return {
                    "ok": False,
                    "reason": f"invalid attestation signature for issue #{issue}",
                    "reason_codes": ["sdl.hook.invalid_attestation_signature"],
                    "changed_paths": non_exempt,
                }
        attestations.append(attestation)

    if author:
        author_ok = any(
            (attestation.get("capability") and author == attestation["capability"])
            or (attestation.get("role") and author == attestation["role"])
            for attestation in attestations
        )
        if not author_ok:
            return {
                "ok": False,
                "reason": f"SDL-Commit-Author '{author}' does not match attestation capability/role",
                "reason_codes": ["sdl.hook.commit_author_mismatch"],
                "changed_paths": non_exempt,
            }

    blocked: list[str] = []
    for path in non_exempt:
        if any(
            is_under_allowed_path(path, attestation.get("allowed_paths", []), repo_root)
            for attestation in attestations
        ):
            continue
        blocked.append(path)

    if blocked:
        return {
            "ok": False,
            "reason": f"staged files outside allowed_paths: {blocked}",
            "reason_codes": ["sdl.hook.allowed_paths_violation"],
            "changed_paths": non_exempt,
            "blocked_paths": blocked,
        }

    # Domain-aware review gate. If any changed path maps to a capability domain
    # with a non-none review gate, the attestation's lifecycle record must link
    # an approved sibling-review artifact.
    lifecycle_record: dict[str, Any] | None = None
    for attestation in attestations:
        lifecycle_record = _load_lifecycle_record_for_attestation(
            repo_root, attestation
        )
        if lifecycle_record is not None:
            break

    domain_review = require_domain_review(non_exempt, lifecycle_record, repo_root)
    if not domain_review["ok"]:
        return {
            "ok": False,
            "reason": domain_review["reason"],
            "reason_codes": domain_review["reason_codes"],
            "changed_paths": non_exempt,
            "review_gate": domain_review.get("review_gate"),
            "domains": domain_review.get("domains"),
        }

    reason_codes = ["sdl.hook.validated"]
    if key_reason_codes:
        reason_codes.extend(key_reason_codes)
    domain_reason_codes = domain_review.get("reason_codes", [])
    for code in domain_reason_codes:
        if code not in reason_codes:
            reason_codes.append(code)

    return {
        "ok": True,
        "reason": "commit validated",
        "reason_codes": reason_codes,
        "changed_paths": non_exempt,
        "attestations": [attestation.get("issue") for attestation in attestations],
    }


def validate_push(
    repo_root: Path,
    base: str,
    head: str,
    *,
    remote_ref: str | None = None,
    require_lifecycle_records: bool = False,
) -> dict[str, Any]:
    """Validate all commits in a push range."""
    repo_root = _real(repo_root)

    if remote_ref:
        branch = remote_ref.replace("refs/heads/", "")
        if is_protected_branch(branch):
            return {
                "ok": False,
                "reason": f"direct pushes to protected branch '{branch}' are not allowed",
                "reason_codes": ["sdl.hook.protected_branch"],
                "branch": branch,
            }

    if head == "0000000000000000000000000000000000000000":
        return {
            "ok": True,
            "reason": "deletion push; nothing to validate",
            "reason_codes": ["sdl.hook.deletion_push"],
        }

    if base == "0000000000000000000000000000000000000000":
        rev_list = _run_git(repo_root, "rev-list", head).stdout.splitlines()
    else:
        rev_list = _run_git(repo_root, "rev-list", f"{base}..{head}").stdout.splitlines()

    if not rev_list:
        return {
            "ok": True,
            "reason": "no commits to validate",
            "reason_codes": ["sdl.hook.no_commits"],
        }

    manifest = load_manifest(repo_root)
    memory_root: Path | None = None
    if manifest and manifest.get("memory_root"):
        memory_root = Path(manifest["memory_root"]).expanduser().resolve()

    anchor_ok, anchor_code = verify_pubkey_anchor_consistency(repo_root)
    if not anchor_ok:
        return {
            "ok": False,
            "reason": "trust anchor verification failed",
            "reason_codes": [anchor_code],
        }

    failures: list[dict[str, Any]] = []
    for sha in rev_list:
        files = list_changed_files(repo_root, commit_sha=sha)
        non_exempt = [path for path in files if not is_exempt(path)]
        if not non_exempt:
            continue

        try:
            commit_timestamp = _commit_author_timestamp(repo_root, sha)
        except ValueError:
            commit_timestamp = None

        message = _run_git(repo_root, "log", "-1", "--format=%B", sha).stdout
        author_match = re.search(r"^SDL-Commit-Author:\s*(.+)$", message, re.MULTILINE)
        attestation_match = re.search(r"^SDL-Routing-Attestation:\s*(.+)$", message, re.MULTILINE)

        if not attestation_match:
            failures.append(
                {
                    "sha": sha,
                    "reason": "missing SDL-Routing-Attestation trailer",
                    "reason_codes": ["sdl.hook.missing_commit_trailers"],
                    "changed_paths": non_exempt,
                }
            )
            continue

        try:
            refs = parse_attestation_trailer(attestation_match.group(1).strip())
        except ValueError as exc:
            failures.append(
                {
                    "sha": sha,
                    "reason": f"invalid attestation trailer: {exc}",
                    "reason_codes": ["sdl.hook.invalid_attestation_trailer"],
                    "changed_paths": non_exempt,
                }
            )
            continue

        attestations: list[dict[str, Any]] = []
        ok = True
        for issue, envelope in refs:
            attestation = load_attestation(repo_root, issue)
            if not attestation:
                failures.append(
                    {
                        "sha": sha,
                        "reason": f"routing attestation not found for issue #{issue}",
                        "reason_codes": ["sdl.hook.missing_routing_attestation"],
                        "changed_paths": non_exempt,
                    }
                )
                ok = False
                break
            if envelope:
                full = attestation.get("envelope_hash", "")
                if full != envelope and not full.endswith(envelope):
                    failures.append(
                        {
                            "sha": sha,
                            "reason": f"envelope hash mismatch for issue #{issue}",
                            "reason_codes": ["sdl.hook.envelope_hash_mismatch"],
                            "changed_paths": non_exempt,
                        }
                    )
                    ok = False
                    break
            if commit_timestamp is not None:
                try:
                    attestation_time = _parse_iso_timestamp(attestation["created_at"])
                    # Git author timestamps have whole-second precision, while
                    # attestation created_at may carry microseconds. Compare at
                    # second granularity to avoid false positives when the two
                    # events occur within the same second.
                    if int(attestation_time.timestamp()) > commit_timestamp:
                        failures.append(
                            {
                                "sha": sha,
                                "reason": f"attestation for issue #{issue} created after commit",
                                "reason_codes": ["sdl.hook.attestation_after_commit"],
                                "changed_paths": non_exempt,
                            }
                        )
                        ok = False
                        break
                except (ValueError, KeyError, TypeError):
                    failures.append(
                        {
                            "sha": sha,
                            "reason": f"attestation for issue #{issue} has invalid created_at",
                            "reason_codes": ["sdl.hook.invalid_attestation_schema"],
                            "changed_paths": non_exempt,
                        }
                    )
                    ok = False
                    break
            if attestation.get("signature") and not verify_attestation_signature(
                attestation, repo_root=repo_root
            ):
                failures.append(
                    {
                        "sha": sha,
                        "reason": f"invalid attestation signature for issue #{issue}",
                        "reason_codes": ["sdl.hook.invalid_attestation_signature"],
                        "changed_paths": non_exempt,
                    }
                )
                ok = False
                break
            attestations.append(attestation)

        if not ok:
            continue

        if author_match:
            author = author_match.group(1).strip()
            author_ok = any(
                (attestation.get("capability") and author == attestation["capability"])
                or (attestation.get("role") and author == attestation["role"])
                for attestation in attestations
            )
            if not author_ok:
                failures.append(
                    {
                        "sha": sha,
                        "reason": f"SDL-Commit-Author '{author}' does not match attestation capability/role",
                        "reason_codes": ["sdl.hook.commit_author_mismatch"],
                        "changed_paths": non_exempt,
                    }
                )
                continue

        if require_lifecycle_records and memory_root:
            for attestation in attestations:
                record = find_lifecycle_record(
                    memory_root,
                    attestation["issue"],
                    attestation.get("lifecycle_record_id"),
                )
                if not record:
                    failures.append(
                        {
                            "sha": sha,
                            "reason": f"missing lifecycle record for issue #{attestation['issue']}",
                            "reason_codes": ["sdl.hook.missing_lifecycle_record"],
                            "changed_paths": non_exempt,
                        }
                    )
                    ok = False
                    break

        if not ok:
            continue

        blocked = [
            path
            for path in non_exempt
            if not any(
                is_under_allowed_path(path, attestation.get("allowed_paths", []), repo_root)
                for attestation in attestations
            )
        ]
        if blocked:
            failures.append(
                {
                    "sha": sha,
                    "reason": f"files outside allowed_paths: {blocked}",
                    "reason_codes": ["sdl.hook.allowed_paths_violation"],
                    "changed_paths": non_exempt,
                    "blocked_paths": blocked,
                }
            )
            continue

        # Domain-aware review gate per commit.
        lifecycle_record: dict[str, Any] | None = None
        for attestation in attestations:
            lifecycle_record = _load_lifecycle_record_for_attestation(
                repo_root, attestation
            )
            if lifecycle_record is not None:
                break

        domain_review = require_domain_review(non_exempt, lifecycle_record, repo_root)
        if not domain_review["ok"]:
            failures.append(
                {
                    "sha": sha,
                    "reason": domain_review["reason"],
                    "reason_codes": domain_review["reason_codes"],
                    "changed_paths": non_exempt,
                    "review_gate": domain_review.get("review_gate"),
                    "domains": domain_review.get("domains"),
                }
            )

    if failures:
        return {
            "ok": False,
            "reason": "push validation failed",
            "reason_codes": ["sdl.hook.push_validation_failed"],
            "failures": failures,
        }

    return {
        "ok": True,
        "reason": "push validated",
        "reason_codes": ["sdl.hook.validated"],
        "commit_count": len(rev_list),
    }


def _canonical_json_without_signature(data: dict[str, Any]) -> bytes:
    payload = {k: v for k, v in data.items() if k != "signature"}
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sign_attestation(data: dict[str, Any], key: bytes) -> str:
    """Return the HMAC-SHA256 signature string for an attestation."""
    payload = _canonical_json_without_signature(data)
    digest = hmac.new(key, payload, hashlib.sha256).hexdigest()
    return f"hmac-sha256:{digest}"


def _parse_signature(value: str) -> tuple[str, str]:
    if not value or ":" not in value:
        raise ValueError("malformed signature")
    algorithm, _, encoded = value.partition(":")
    return algorithm, encoded


def _parse_iso_timestamp(value: str) -> Any:
    """Parse an ISO 8601 timestamp, tolerating trailing 'Z'."""
    value = value.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)


def _load_public_key_records(repo_root: Path) -> list[dict[str, Any]]:
    """Load Ed25519 public keys and optional meta files from the repo trust anchor."""
    records: list[dict[str, Any]] = []
    if Ed25519PublicKey is None:
        return records
    pubkeys_dir = repo_root / ".stibdedlom" / "trust" / "pubkeys"
    if not pubkeys_dir.exists():
        return records
    for pub_file in sorted(pubkeys_dir.glob("*.pub")):
        public_bytes = pub_file.read_bytes()
        kid = pub_file.stem
        meta_file = pub_file.with_suffix(".pub.meta")
        meta: dict[str, Any] = {}
        if meta_file.exists():
            try:
                meta = json.loads(meta_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError):
                meta = {}
        records.append(
            {
                "kid": kid,
                "algorithm": meta.get("algorithm", "ed25519"),
                "public_key_bytes": public_bytes,
                "key_usage": meta.get("key_usage", "attestation"),
                "created_at": meta.get("created_at", ""),
                "rotated_at": meta.get("rotated_at"),
                "expires_at": meta.get("expires_at"),
                "revoked_at": meta.get("revoked_at"),
                "source": meta.get("source", "onboarding"),
            }
        )
    return records


def verify_pubkey_anchor_consistency(repo_root: Path) -> tuple[bool, str]:
    """Fail-closed check that repo-committed pubkeys are a subset of the out-of-band anchor.

    The anchor location is sourced from a **trusted, non-repo** location only — the
    ``SDL_/Users/vishalsingh/.stibdedlom/project-memory/v-i-s-h-a-l/generic-dev-studio`` environment variable — never from the committed
    ``manifest.yaml`` (a forged commit could redirect ``memory_root`` into the repo and
    self-authorize; review B1). When no anchor is configured we return
    ``(True, "no_anchor")`` so legacy/no-anchor repos behave exactly as before (the
    deterministic gate is server-side/CI; see ADR-082 residual risks). An anchor that
    resolves inside ``repo_root`` is a misconfiguration and is refused. With an anchor,
    every ``<repo>/.stibdedlom/trust/pubkeys/*.pub`` must be present (by sha256) in the
    anchor set; any extra repo pubkey is treated as a forged in-repo key.
    """
    repo_root = _real(repo_root)
    raw = os.environ.get("SDL_/Users/vishalsingh/.stibdedlom/project-memory/v-i-s-h-a-l/generic-dev-studio", "").strip()
    if not raw:
        return True, "no_anchor"
    anchor_root = Path(raw).expanduser().resolve()
    try:
        anchor_root.relative_to(repo_root)
        # The anchor resolves inside the repo: a manifest-redirect style attack (or a
        # misconfiguration). Refuse rather than trust a repo-controlled anchor.
        return False, "sdl.hook.anchor_inside_repo"
    except ValueError:
        pass  # anchor is outside the repo (expected)
    anchor_pubkeys = anchor_root / ".stibdedlom" / "trust" / "pubkeys"
    if not anchor_pubkeys.exists():
        return True, "no_anchor"  # anchor not provisioned -> legacy posture
    repo_pubkeys = repo_root / ".stibdedlom" / "trust" / "pubkeys"
    if not repo_pubkeys.exists():
        return True, "no_repo_keys"  # nothing to subset-check; kernel governs (intentional)
    try:
        anchor_hashes = {
            hashlib.sha256(p.read_bytes()).hexdigest()
            for p in anchor_pubkeys.glob("*.pub")
        }
        for pub in sorted(repo_pubkeys.glob("*.pub")):
            digest = hashlib.sha256(pub.read_bytes()).hexdigest()
            if digest not in anchor_hashes:
                return False, "sdl.hook.trust_anchor_mismatch"
    except OSError:
        # Fail closed: if we cannot read the anchor, do not trust repo keys.
        return False, "sdl.hook.trust_anchor_mismatch"
    return True, "anchor_ok"


def _is_key_valid_for_attestation(
    key_record: dict[str, Any],
    attestation_created_at: str,
) -> tuple[bool, str]:
    """Check expiry and revocation semantics for a key relative to an attestation."""
    now = datetime.now(timezone.utc)
    expires_at = key_record.get("expires_at")
    if expires_at:
        try:
            expires = _parse_iso_timestamp(expires_at)
            if now > expires:
                return False, "key_expired"
        except ValueError:
            return False, "invalid_expires_at"
    revoked_at = key_record.get("revoked_at")
    if revoked_at:
        try:
            revoked = _parse_iso_timestamp(revoked_at)
            created = _parse_iso_timestamp(attestation_created_at)
            if created >= revoked:
                return False, "key_revoked"
        except ValueError:
            return False, "invalid_revoked_at"
    return True, ""


def verify_attestation_signature(
    data: dict[str, Any],
    key: bytes | None = None,
    repo_root: Path | None = None,
) -> bool:
    """Verify the ``signature`` field of an attestation.

    Supports ``hmac-sha256`` (legacy) when ``key`` is provided and
    ``ed25519`` when public keys are available in the repo trust anchor.
    Rejects signatures created with revoked keys.
    """
    signature = data.get("signature", "")
    try:
        algorithm, encoded = _parse_signature(signature)
    except ValueError:
        return False

    if algorithm == "hmac-sha256" and key is not None:
        expected = sign_attestation(data, key)
        return hmac.compare_digest(signature, expected)

    if algorithm == "ed25519" and Ed25519PublicKey is not None and repo_root is not None:
        kid = data.get("kid", "")
        created_at = data.get("created_at", "")
        for key_record in _load_public_key_records(repo_root):
            if key_record["kid"] != kid:
                continue
            ok, _reason = _is_key_valid_for_attestation(key_record, created_at)
            if not ok:
                return False
            try:
                public_key = Ed25519PublicKey.from_public_bytes(
                    key_record["public_key_bytes"]
                )
                payload = _canonical_json_without_signature(data)
                signature_bytes = base64.b64decode(encoded)
                public_key.verify(signature_bytes, payload)
                return True
            except Exception:
                return False
        return False

    return False


def _build_routing_index(attestations: list[dict[str, Any]]) -> dict[str, Any]:
    """Return the normalized routing/index.json payload."""
    return {
        "schema_version": "sdl-routing-index@1",
        "count": len(attestations),
        "attestations": [
            {
                "issue": data["issue"],
                "envelope_hash": data["envelope_hash"],
                "lifecycle_record_id": data.get("lifecycle_record_id", ""),
                "created_at": data["created_at"],
            }
            for data in attestations
        ],
    }


def _validate_routing_index(
    existing: dict[str, Any], attestations: list[dict[str, Any]]
) -> list[str]:
    """Return a list of inconsistency reasons, or empty if consistent."""
    reasons: list[str] = []
    if existing.get("schema_version") != "sdl-routing-index@1":
        reasons.append("index schema version mismatch")
        return reasons
    if existing.get("count") != len(attestations):
        reasons.append(f"index count mismatch: {existing.get('count')} vs {len(attestations)}")
    indexed = {entry.get("issue"): entry for entry in existing.get("attestations", [])}
    for data in attestations:
        issue = data["issue"]
        entry = indexed.get(issue)
        if not entry:
            reasons.append(f"index missing issue #{issue}")
            continue
        if entry.get("envelope_hash") != data.get("envelope_hash"):
            reasons.append(f"index envelope_hash mismatch for issue #{issue}")
    return reasons


def validate_attestations(
    repo_root: Path,
    *,
    signature_key: bytes | None = None,
) -> dict[str, Any]:
    """Validate all routing attestations in the repo and maintain routing/index.json."""
    repo_root = _real(repo_root)
    routing_dir = repo_root / ".stibdedlom" / "routing"
    base_required_fields = [
        "schema_version",
        "issue",
        "goal",
        "envelope_hash",
        "created_at",
        "kid",
        "algorithm",
        "runtime_binding",
    ]
    errors: list[dict[str, Any]] = []
    count = 0
    attestations: list[dict[str, Any]] = []

    if not routing_dir.exists():
        return {
            "ok": True,
            "reason": "no routing attestations directory",
            "reason_codes": ["sdl.ci.no_routing_directory"],
            "count": 0,
        }

    for path in sorted(routing_dir.glob("*.json")):
        if path.name == "index.json":
            continue
        count += 1
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            errors.append({"path": path.name, "reason": f"invalid JSON: {exc}"})
            continue

        if data.get("schema_version") == "sdl-routing-attestation@2":
            # @2 moves the lifecycle linkage onto the record and the drift
            # budget into runtime_binding; it adds chain_id/node_id instead.
            required_fields = base_required_fields + ["chain_id", "node_id"]
        else:
            required_fields = base_required_fields + [
                "lifecycle_record_id",
                "max_commits_ahead",
            ]
        missing = [field for field in required_fields if field not in data]
        if missing:
            errors.append({"path": path.name, "reason": f"missing fields: {missing}"})
            continue

        if data.get("schema_version") not in SUPPORTED_ROUTING_ATTESTATION_VERSIONS:
            errors.append(
                {
                    "path": path.name,
                    "reason": f"unsupported schema version {data.get('schema_version')}",
                }
            )
            continue

        if not isinstance(data.get("issue"), int) or data["issue"] < 1:
            errors.append({"path": path.name, "reason": "issue must be a positive integer"})
            continue

        if not re.fullmatch(r"sha256:[a-f0-9]{64}", str(data.get("envelope_hash", ""))):
            errors.append({"path": path.name, "reason": "envelope_hash must match sha256:<64 hex chars>"})
            continue

        if not data.get("capability") and not data.get("role"):
            errors.append({"path": path.name, "reason": "attestation must specify capability or role"})
            continue

        if data.get("signature"):
            if not verify_attestation_signature(
                data, key=signature_key, repo_root=repo_root
            ):
                errors.append({"path": path.name, "reason": "signature verification failed"})
                continue

        attestations.append(data)

    index_path = routing_dir / "index.json"
    if not errors:
        if index_path.exists():
            try:
                existing_index = json.loads(index_path.read_text(encoding="utf-8"))
            except Exception as exc:
                errors.append({"path": "index.json", "reason": f"invalid JSON: {exc}"})
            else:
                index_errors = _validate_routing_index(existing_index, attestations)
                for reason in index_errors:
                    errors.append({"path": "index.json", "reason": reason})

        if not errors:
            new_index = _build_routing_index(attestations)
            index_path.write_text(json.dumps(new_index, indent=2) + "\n", encoding="utf-8")

    if errors:
        return {
            "ok": False,
            "reason": f"{len(errors)} attestation(s) invalid",
            "reason_codes": ["sdl.ci.attestation_validation_failed"],
            "count": count,
            "errors": errors,
        }

    return {
        "ok": True,
        "reason": "all attestations valid",
        "reason_codes": ["sdl.ci.attestations_valid"],
        "count": count,
    }


def validate_schemas(repo_root: Path) -> dict[str, Any]:
    """Validate that manifest and invocation-policy files are present and well-formed."""
    repo_root = _real(repo_root)
    errors: list[dict[str, Any]] = []

    manifest = load_manifest(repo_root)
    manifest_path = repo_root / ".stibdedlom" / "manifest.yaml"
    if not manifest_path.exists():
        errors.append({"path": str(manifest_path.relative_to(repo_root)), "reason": "missing manifest"})
    elif manifest is None:
        errors.append({"path": ".stibdedlom/manifest.yaml", "reason": "manifest is not valid YAML"})
    else:
        required = [
            "schema_version",
            "project_ref",
            "memory_root",
            "strategy_posture",
            "autonomy_default",
            "invocation_policy_ref",
            "registered_at",
        ]
        missing = [field for field in required if field not in manifest]
        if missing:
            errors.append({"path": ".stibdedlom/manifest.yaml", "reason": f"missing fields: {missing}"})
        if manifest.get("schema_version") != CLIENT_MANIFEST_SCHEMA_VERSION:
            errors.append(
                {
                    "path": ".stibdedlom/manifest.yaml",
                    "reason": f"unsupported schema version {manifest.get('schema_version')}",
                }
            )

    policy_path = repo_root / ".stibdedlom" / "invocation-policy.yaml"
    if not policy_path.exists():
        errors.append({"path": str(policy_path.relative_to(repo_root)), "reason": "missing invocation policy"})
    elif yaml is None:
        errors.append({"path": ".stibdedlom/invocation-policy.yaml", "reason": "pyyaml is not installed"})
    else:
        try:
            policy = yaml.safe_load(policy_path.read_text(encoding="utf-8"))
        except Exception as exc:
            errors.append({"path": ".stibdedlom/invocation-policy.yaml", "reason": f"invalid YAML: {exc}"})
            policy = None
        if isinstance(policy, dict):
            if policy.get("schema_version") != INVOCATION_POLICY_SCHEMA_VERSION:
                errors.append(
                    {
                        "path": ".stibdedlom/invocation-policy.yaml",
                        "reason": f"unsupported schema version {policy.get('schema_version')}",
                    }
                )
            if not isinstance(policy.get("defaults"), dict):
                errors.append({"path": ".stibdedlom/invocation-policy.yaml", "reason": "missing defaults"})
            if "triggers" not in policy or not isinstance(policy.get("triggers"), list):
                errors.append({"path": ".stibdedlom/invocation-policy.yaml", "reason": "missing triggers"})

    if errors:
        return {
            "ok": False,
            "reason": f"{len(errors)} schema validation error(s)",
            "reason_codes": ["sdl.ci.schema_validation_failed"],
            "errors": errors,
        }

    return {
        "ok": True,
        "reason": "schemas valid",
        "reason_codes": ["sdl.ci.schemas_valid"],
    }


def validate_trust_anchor(
    repo_root: Path,
    trust_anchor: Path | None = None,
) -> dict[str, Any]:
    """Validate manifest/policy schemas and optional trust-anchor hashes.

    ``trust_anchor`` is the out-of-band memory root that contains
    ``.stibdedlom/trust/manifest.sha256`` and
    ``.stibdedlom/trust/invocation-policy.sha256``.
    """
    repo_root = _real(repo_root)
    result = validate_schemas(repo_root)
    if not result["ok"]:
        return result

    if trust_anchor is None:
        return {
            "ok": True,
            "reason": "schemas valid; trust-anchor hash verification skipped",
            "reason_codes": ["sdl.trust_anchor.schemas_valid", "sdl.trust_anchor.hash_verification_skipped"],
        }

    trust_dir = trust_anchor.expanduser().resolve() / ".stibdedlom" / "trust"
    checks = {
        ".stibdedlom/manifest.yaml": trust_dir / "manifest.sha256",
        ".stibdedlom/invocation-policy.yaml": trust_dir / "invocation-policy.sha256",
    }
    mismatched: list[str] = []
    missing: list[str] = []

    for relpath, expected_path in checks.items():
        file_path = repo_root / relpath
        if not file_path.exists():
            missing.append(relpath)
            continue
        if not expected_path.exists():
            missing.append(str(expected_path.relative_to(trust_anchor)))
            continue
        expected = expected_path.read_text(encoding="utf-8").strip().split()[0]
        actual = hashlib.sha256(file_path.read_bytes()).hexdigest()
        if actual != expected:
            mismatched.append(relpath)

    # Public-key hash verification.
    repo_pubkeys_dir = repo_root / ".stibdedlom" / "trust" / "pubkeys"
    if repo_pubkeys_dir.exists():
        for pub_file in sorted(repo_pubkeys_dir.glob("*.pub")):
            expected_path = trust_dir / "pubkeys" / f"{pub_file.stem}.pub.sha256"
            if not expected_path.exists():
                missing.append(str(expected_path.relative_to(trust_anchor)))
                continue
            expected = expected_path.read_text(encoding="utf-8").strip().split()[0]
            actual = hashlib.sha256(pub_file.read_bytes()).hexdigest()
            if actual != expected:
                mismatched.append(str(pub_file.relative_to(repo_root)))

    # Governance-executable manifest hash verification.
    gem_path = trust_dir / "governance-executable-manifest.json"
    gem_hash_path = trust_dir / "governance-executable-manifest.sha256"
    if gem_path.exists() or gem_hash_path.exists():
        if not gem_path.exists() or not gem_hash_path.exists():
            missing.append("governance-executable-manifest files incomplete")
        else:
            expected = gem_hash_path.read_text(encoding="utf-8").strip().split()[0]
            actual = hashlib.sha256(gem_path.read_bytes()).hexdigest()
            if actual != expected:
                mismatched.append("governance-executable-manifest.json")

    if missing or mismatched:
        errors: list[dict[str, Any]] = []
        for relpath in missing:
            errors.append({"path": relpath, "reason": "missing trust hash or target file"})
        for relpath in mismatched:
            errors.append({"path": relpath, "reason": "SHA-256 hash mismatch"})
        return {
            "ok": False,
            "reason": "trust-anchor verification failed",
            "reason_codes": ["sdl.trust_anchor.verification_failed"],
            "errors": errors,
        }

    return {
        "ok": True,
        "reason": "schemas and trust-anchor hashes valid",
        "reason_codes": ["sdl.trust_anchor.valid"],
    }


# ---------------------------------------------------------------------------
# CLI entry points used by the thin wrapper scripts in .stibdedlom/bin
# ---------------------------------------------------------------------------


def _json_out(result: dict[str, Any], output: Path | None) -> None:
    print(json.dumps(result, indent=2))
    if output:
        output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


def commit_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate a commit against SDL routing attestations.")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--staged", action="store_true", help="validate staged changes")
    parser.add_argument("--commit-msg-file", type=Path, default=None)
    parser.add_argument("--commit-msg-text", default=None)
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args(argv)

    result = validate_commit(
        args.repo_root.resolve(),
        staged=args.staged,
        commit_msg_file=args.commit_msg_file,
        commit_msg_text=args.commit_msg_text,
    )
    _json_out(result, args.output)
    return 0 if result["ok"] else 1


def push_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate a push range against SDL routing attestations.")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--base", required=True, help="base SHA (remote SHA)")
    parser.add_argument("--head", required=True, help="head SHA (local SHA)")
    parser.add_argument("--remote-ref", default=None, help="remote ref for protected-branch checks")
    parser.add_argument("--require-lifecycle-records", action="store_true")
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args(argv)

    result = validate_push(
        args.repo_root.resolve(),
        args.base,
        args.head,
        remote_ref=args.remote_ref,
        require_lifecycle_records=args.require_lifecycle_records,
    )
    _json_out(result, args.output)
    return 0 if result["ok"] else 1


def attestations_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate SDL routing attestations.")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--trust-anchor",
        default=None,
        help="HMAC key (raw string) or path to a key file; if omitted signatures are skipped",
    )
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args(argv)

    key: bytes | None = None
    if args.trust_anchor:
        candidate = Path(args.trust_anchor)
        if candidate.exists():
            key = candidate.read_bytes()
        else:
            key = args.trust_anchor.encode("utf-8")

    result = validate_attestations(args.repo_root.resolve(), signature_key=key)
    _json_out(result, args.output)
    return 0 if result["ok"] else 1


def schemas_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate SDL manifest and invocation-policy schemas.")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args(argv)

    result = validate_schemas(args.repo_root.resolve())
    _json_out(result, args.output)
    return 0 if result["ok"] else 1


def trust_anchor_cli(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate SDL manifest, policy, and trust-anchor hashes.")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--trust-anchor",
        type=Path,
        default=None,
        help="Path to the out-of-band memory root containing .stibdedlom/trust/",
    )
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args(argv)

    result = validate_trust_anchor(
        args.repo_root.resolve(),
        trust_anchor=args.trust_anchor.expanduser().resolve() if args.trust_anchor else None,
    )
    _json_out(result, args.output)
    return 0 if result["ok"] else 1
