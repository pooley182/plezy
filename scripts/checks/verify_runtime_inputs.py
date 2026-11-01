#!/usr/bin/env python3
"""Offline verification for reviewed Linux native and vendored binding inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

HEX_256 = re.compile(r"^[0-9a-f]{64}$")
HEX_COMMIT = re.compile(r"^[0-9a-f]{40}$")
NATIVE_NAMES = {"simdutf"}
BINDING_ARTIFACTS = {
    "pigeons/messages.dart",
    "android/src/main/kotlin/dev/fluttercommunity/plus/wakelock/WakelockPlusMessages.g.kt",
    "ios/wakelock_plus/Sources/wakelock_plus/include/wakelock_plus/messages.g.h",
    "ios/wakelock_plus/Sources/wakelock_plus/messages.g.m",
}


def _load_json(path: Path, errors: list[str]) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        errors.append(f"{path}: cannot load JSON: {error}")
        return {}
    if not isinstance(value, dict):
        errors.append(f"{path}: top-level value must be an object")
        return {}
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_text(value: Any, label: str, errors: list[str]) -> str:
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{label}: must be non-empty text")
        return ""
    return value


def _locked_package(lock_text: str, name: str) -> tuple[str, str] | None:
    pattern = re.compile(
        rf"^  {re.escape(name)}:\n(?P<body>(?:    .*\n|      .*\n)+?)(?=^  [a-zA-Z0-9_]+:|\Z)",
        re.MULTILINE,
    )
    match = pattern.search(lock_text)
    if match is None:
        return None
    body = match.group("body")
    version = re.search(r'^    version: "([^\"]+)"$', body, re.MULTILINE)
    checksum = re.search(r'^      sha256: "?([0-9a-f]{64})"?$', body, re.MULTILINE)
    if version is None or checksum is None:
        return None
    return version.group(1), checksum.group(1)


def _validate_wakelock(root: Path, errors: list[str]) -> None:
    package = root / "packages/wakelock_plus"
    provenance_path = package / "provenance.json"
    provenance = _load_json(provenance_path, errors)
    if provenance.get("formatVersion") != 1:
        errors.append(f"{provenance_path}: formatVersion must be 1")

    upstream = provenance.get("upstream")
    if not isinstance(upstream, dict) or HEX_COMMIT.fullmatch(str(upstream.get("commit", ""))) is None:
        errors.append(f"{provenance_path}: upstream.commit must be a full Git commit")


    artifacts = provenance.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != BINDING_ARTIFACTS:
        errors.append(f"{provenance_path}: artifacts must be exactly the schema and three host outputs")
    else:
        for relative, expected in artifacts.items():
            path = package / relative
            if not isinstance(expected, str) or HEX_256.fullmatch(expected) is None:
                errors.append(f"{provenance_path}: invalid artifact SHA-256 for {relative}")
            elif not path.is_file():
                errors.append(f"{path}: required binding artifact is missing")
            else:
                actual = _sha256(path)
                if actual != expected:
                    errors.append(f"{path}: SHA-256 drift (expected {expected}, got {actual})")

    try:
        pubspec = (package / "pubspec.yaml").read_text(encoding="utf-8")
        lock = (package / "pubspec.lock").read_text(encoding="utf-8")
        schema = (package / "pigeons/messages.dart").read_text(encoding="utf-8")
        root_lock = (root / "pubspec.lock").read_text(encoding="utf-8")
    except OSError as error:
        errors.append(f"{package}: cannot read package provenance input: {error}")
        return

    generator = provenance.get("generator") if isinstance(provenance.get("generator"), dict) else {}
    client = provenance.get("externalDartClient") if isinstance(provenance.get("externalDartClient"), dict) else {}
    expected_pigeon = (str(generator.get("version", "")), str(generator.get("archiveSha256", "")))
    expected_client = (str(client.get("version", "")), str(client.get("archiveSha256", "")))
    if not re.search(rf"^  pigeon: {re.escape(expected_pigeon[0])}$", pubspec, re.MULTILINE):
        errors.append(f"{package / 'pubspec.yaml'}: Pigeon must be pinned exactly to {expected_pigeon[0]}")
    if not re.search(
        rf"^  wakelock_plus_platform_interface: {re.escape(expected_client[0])}$", pubspec, re.MULTILINE
    ):
        errors.append(
            f"{package / 'pubspec.yaml'}: wakelock_plus_platform_interface must be pinned exactly to {expected_client[0]}"
        )
    if _locked_package(lock, "pigeon") != expected_pigeon:
        errors.append(f"{package / 'pubspec.lock'}: Pigeon version/checksum differs from provenance.json")
    if _locked_package(lock, "wakelock_plus_platform_interface") != expected_client:
        errors.append(
            f"{package / 'pubspec.lock'}: platform-interface version/checksum differs from provenance.json"
        )
    if _locked_package(root_lock, "wakelock_plus_platform_interface") != expected_client:
        errors.append(
            f"{root / 'pubspec.lock'}: runtime platform-interface version/checksum differs from provenance.json"
        )

    if "dartPackageName: 'wakelock_plus_platform_interface'" not in schema:
        errors.append(f"{package / 'pigeons/messages.dart'}: external Dart package name is not explicit")
    if re.search(r"\bdart(?:Test)?Out\s*:", schema):
        errors.append(f"{package / 'pigeons/messages.dart'}: host-only schema must not generate Dart outputs")
    for relative in BINDING_ARTIFACTS - {"pigeons/messages.dart"}:
        if relative not in schema:
            errors.append(f"{package / 'pigeons/messages.dart'}: missing owned output {relative}")

    binding_sources = (
        ("Kotlin", package / "android/src/main/kotlin/dev/fluttercommunity/plus/wakelock/WakelockPlusMessages.g.kt"),
        ("Objective-C", package / "ios/wakelock_plus/Sources/wakelock_plus/messages.g.m"),
    )
    for generated_name, generated_path in binding_sources:
        try:
            generated = generated_path.read_text(encoding="utf-8")
        except OSError as error:
            errors.append(f"{generated_path}: cannot read generated binding: {error}")
            continue
        if "26.2.3" not in generated:
            errors.append(f"{generated_name} binding was not generated by Pigeon 26.2.3")
        for method in ("WakelockPlusApi.toggle", "WakelockPlusApi.isEnabled"):
            if method not in generated:
                errors.append(f"{generated_name} binding is missing channel suffix {method}")
        for tag in ("129", "130"):
            if tag not in generated:
                errors.append(f"{generated_name} binding is missing codec tag {tag}")


def validate(root: Path) -> list[str]:
    errors: list[str] = []
    _validate_wakelock(root, errors)
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    arguments = parser.parse_args()
    errors = validate(arguments.root.resolve())
    if errors:
        print("Runtime input provenance verification failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Runtime input provenance verified offline")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
