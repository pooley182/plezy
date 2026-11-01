#!/usr/bin/env python3
"""Guard the trust gate and release contract in build.yml."""

from pathlib import Path
import re
import sys

from workflow_yaml import iter_uses_references, job_block


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_WORKFLOW = ROOT / ".github/workflows/build.yml"
FLUTTER_VERSION = "3.47.1"
if len(sys.argv) > 2:
    raise SystemExit(f"Usage: {Path(sys.argv[0]).name} [workflow-path]")
WORKFLOW = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else DEFAULT_WORKFLOW
text = WORKFLOW.read_text(encoding="utf-8")
errors: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def job(name: str) -> str:
    block = job_block(text, name)
    require(bool(block), f"missing {name} job")
    return block



require(
    "run-name: ${{ inputs.release_tag != '' && format('Release {0}', inputs.release_tag)"
    in text,
    "release workflow runs must expose their tag in the run name",
)

release = job("create-release")
require(
    "needs: [validate-trusted-ref, build-android]"
    in release,
    "release dependencies must include the trust gate and the Android build",
)
require("name: android-apk" in release, "release download lost android-apk")

release_if = re.search(r"(?m)^    if: (.+)$", release)
require(release_if is not None, "release job must have an explicit condition")
release_condition = release_if.group(1) if release_if else ""
require("&& inputs.build_android" in release_condition, "release publication must require build_android")
require(
    "&& inputs.release_tag != ''" in release_condition,
    "draft release creation must require an explicit release tag",
)


require("draft: true" in release, "build output must remain a draft release")
require(
    "tag_name: ${{ inputs.release_tag }}" in release,
    "release builds must bind the requested tag",
)
require(
    "target_commitish: ${{ github.sha }}" in release,
    "release tags must target the exact build commit",
)
require(
    "if: ${{ inputs.release_tag != '' }}" in release
    and '"$RELEASE_TAG" != "$VERSION"' in release,
    "release tags must be validated against the pubspec version",
)
require(
    "generate_release_notes:" not in release,
    "draft releases must not generate notes before deploy.py attaches channel notes",
)

trusted_ref = job("validate-trusted-ref")
require("permissions: {}" in trusted_ref, "trusted-ref validation must have no token permissions")
require(
    '"$GITHUB_REF" != "refs/heads/main"' in trusted_ref,
    "trusted-ref validation must reject non-main refs",
)
require(
    "needs: validate-trusted-ref" in job("build-android"),
    "build-android must depend on trusted-ref validation",
)

require(
    text.count(FLUTTER_VERSION) == 1 and f'FLUTTER_VERSION: "{FLUTTER_VERSION}"' in text,
    "the Flutter SDK version must be written once, as the workflow FLUTTER_VERSION env",
)
require(
    "TRUSTED_BUILD_CACHE_VERSION: trusted-build-v1" in text,
    "build caches must use a dedicated trusted namespace",
)
require("restore-keys:" not in text, "privileged build caches must not use prefix fallback")
cache_keys = re.findall(r"(?m)^          key: (.+)$", text)
require(bool(cache_keys), "build workflow must define cache keys")
for cache_key in cache_keys:
    require(
        "TRUSTED_BUILD_CACHE_VERSION" in cache_key,
        f"cache key is outside the trusted build namespace: {cache_key}",
    )
require(
    text.count("cache-key:") == text.count("cache: true"),
    "every Flutter SDK cache must define its trusted cache key",
)

# Action-pin checks run elsewhere; this guard adds the checkout credential
# invariant for the workflow-dispatch-only build.
remote_actions = [
    reference.rpartition("@")[0]
    for _, reference in iter_uses_references(text)
    if not reference.startswith("./")
]
require(bool(remote_actions), "build workflow must use pinned actions")
require(
    text.count("persist-credentials: false") == remote_actions.count("actions/checkout"),
    "every build checkout must discard GitHub credentials",
)

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    sys.exit(1)

print("build workflow checks passed")
