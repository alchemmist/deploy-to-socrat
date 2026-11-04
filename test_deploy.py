#!/usr/bin/env python3
"""Unit tests for homelab values updates."""

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("deploy", ROOT / "deploy.py")
deploy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deploy)

SHA = "b0bb95f85d3903357162079c0d12827a6e6976b8"
DIGEST = "sha256:fa4dba61583f116da5300594a334ba8f0d40141728a121777ee64f691ffd2b5c"

VALUES = """\
image:
  repository: ghcr.io/alchemmist/lms
  tag: old
  digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
front:
  tag: old-front
  digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
"""


class UpdateImageTest(unittest.TestCase):
    def test_digest_sets_tag_to_commit(self):
        updated = deploy.update_image(VALUES, digest=DIGEST, tag=SHA, component="image")
        self.assertIn(f"digest: {DIGEST}", updated)
        self.assertIn(f"tag: {SHA}", updated)
        self.assertIn("tag: old-front", updated)

    def test_tag_clears_digest(self):
        updated = deploy.update_image(VALUES, digest='""', tag="release", component="image")
        self.assertIn('digest: ""', updated)
        self.assertIn("tag: release", updated)

    def test_component_keeps_top_level_image(self):
        updated = deploy.update_image(VALUES, digest=DIGEST, tag=SHA, component="front")
        self.assertIn("tag: old", updated)
        self.assertIn(f"tag: {SHA}", updated)
        self.assertIn(f"digest: {DIGEST}", updated)

    def test_nested_image_is_not_the_top_level_block(self):
        text = "service:\n  image:\n    tag: old\n    digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
        with self.assertRaises(SystemExit):
            deploy.update_image(text, digest=DIGEST, tag=SHA, component="image")

    def test_missing_field_is_refused(self):
        with self.assertRaises(SystemExit):
            deploy.update_image("image:\n  tag: only\n", digest=DIGEST, tag=SHA, component="image")


class CliTest(unittest.TestCase):
    def write_tree(self, root: Path, digest: str, tag: str) -> None:
        for folder in ("deploy", "charts"):
            path = root / folder / "lms" / "values.yaml"
            path.parent.mkdir(parents=True)
            path.write_text(
                "image:\n"
                "  repository: ghcr.io/alchemmist/lms\n"
                f"  tag: {tag}\n"
                f"  digest: {digest}\n"
            )

    def run_cli(self, root: Path, version: str, component: str = "") -> subprocess.CompletedProcess[str]:
        command = [sys.executable, str(ROOT / "deploy.py"), str(root), "lms", version, SHA]
        if component:
            command.append(component)
        return subprocess.run(command, text=True, capture_output=True, check=False)

    def test_updates_deploy_and_chart(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_tree(root, "sha256:" + "a" * 64, "old")
            result = self.run_cli(root, DIGEST)
            self.assertEqual(result.returncode, 0, result.stderr)
            for folder in ("deploy", "charts"):
                text = (root / folder / "lms" / "values.yaml").read_text()
                self.assertIn(f"digest: {DIGEST}", text)
                self.assertIn(f"tag: {SHA}", text)

    def test_component_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "deploy" / "lms" / "values.yaml"
            path.parent.mkdir(parents=True)
            path.write_text(VALUES)
            result = self.run_cli(root, DIGEST, "front")
            self.assertEqual(result.returncode, 0, result.stderr)
            text = path.read_text()
            self.assertIn("tag: old\n", text)
            self.assertIn(f"tag: {SHA}", text)

    def test_refuses_bad_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_tree(root, "sha256:" + "a" * 64, "old")
            bad_app = subprocess.run(
                [sys.executable, str(ROOT / "deploy.py"), str(root), "../lms", DIGEST, SHA],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(bad_app.returncode, 0)
            bad_component = self.run_cli(root, DIGEST, "Front")
            self.assertNotEqual(bad_component.returncode, 0)


if __name__ == "__main__":
    unittest.main()
