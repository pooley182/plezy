#!/usr/bin/env python3
"""Behavior tests for the privileged build-workflow guard."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/checks/check_build_workflow.py"
WORKFLOW = ROOT / ".github/workflows/build.yml"


class BuildWorkflowGuardTest(unittest.TestCase):
    def _run(self, workflow: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="plezy-build-workflow-test-") as directory:
            fixture = Path(directory) / ".github/workflows/build.yml"
            fixture.parent.mkdir(parents=True)
            fixture.write_text(workflow, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(CHECKER), str(fixture)],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

    def _workflow(self) -> str:
        return WORKFLOW.read_text(encoding="utf-8")

    def test_current_workflow_passes(self) -> None:
        result = self._run(self._workflow())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build workflow checks passed", result.stdout)

    def test_draft_release_without_explicit_tag_is_rejected(self) -> None:
        workflow = self._workflow().replace(
            " && inputs.release_tag != '' }}",
            " }}",
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches workflow")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must require an explicit release tag", result.stderr)

    def test_release_run_without_tagged_name_is_rejected(self) -> None:
        workflow = self._workflow().replace(
            "run-name: ${{ inputs.release_tag != '' && format('Release {0}', inputs.release_tag) "
            "|| format('Build {0}', github.sha) }}\n",
            "",
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches workflow")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must expose their tag in the run name", result.stderr)

    def test_release_tag_without_exact_target_is_rejected(self) -> None:
        workflow = self._workflow().replace(
            "          target_commitish: ${{ github.sha }}\n",
            "",
            1,
        )
        self.assertNotEqual(workflow, self._workflow(), "fixture mutation no longer matches workflow")

        result = self._run(workflow)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must target the exact build commit", result.stderr)



if __name__ == "__main__":
    unittest.main()
