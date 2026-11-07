import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
IMAGE = "123456789012.dkr.ecr.eu-central-1.amazonaws.com/demo:build-7-0123456789ab"


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory()
        self.addCleanup(self.sandbox.cleanup)
        self.work = Path(self.sandbox.name)
        shutil.copy(ROOT / "deployment.yml", self.work)
        self.env = {
            **os.environ,
            "PATH": f"{Path(sys.executable).parent}:{os.environ['PATH']}",
            "IMAGE_URI": IMAGE,
            "REPOSITORY_URI": IMAGE.split(":")[0],
            "EKS_CLUSTER_NAME": "eksctl-demo",
            "EKS_KUBECTL_ROLE_ARN": "arn:aws:iam::123456789012:role/deploy",
            "AWS_DEFAULT_REGION": "eu-central-1",
            "CODEBUILD_BUILD_NUMBER": "7",
            "CODEBUILD_RESOLVED_SOURCE_VERSION": "0123456789abcdef",
            "CODEBUILD_BUILD_SUCCEEDING": "1",
            "CALL_LOG": str(self.work / "calls.jsonl"),
        }

    def run_phase(self, phase):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/pipeline.sh"), phase],
            cwd=self.work, env=self.env, text=True, capture_output=True,
        )

    def fake_cloud_commands(self):
        # Exercise the actual phase orchestration without accessing AWS or Kubernetes.
        executable = self.work / "fake-command"
        executable.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "name = Path(sys.argv[0]).name\n"
            "with open(os.environ['CALL_LOG'], 'a') as stream:\n"
            "    stream.write(json.dumps([name, *sys.argv[1:]]) + '\\n')\n"
            "if name == 'docker' and os.environ.get('FAIL_PUSH') == '1':\n"
            "    sys.exit(7)\n"
            "if name == 'kubectl' and 'rollout' in sys.argv and os.environ.get('FAIL_ROLLOUT') == '1':\n"
            "    sys.exit(8)\n"
            "if name == 'kubectl' and any(arg.startswith('jsonpath=') for arg in sys.argv):\n"
            "    print(os.environ['IMAGE_URI'])\n"
        )
        executable.chmod(0o755)
        for name in ("docker", "aws", "kubectl"):
            (self.work / name).symlink_to(executable)
        self.env["PATH"] = f"{self.work}:{self.env['PATH']}"

    def calls(self):
        log = self.work / "calls.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def test_render_uses_this_build_image_and_preserves_source(self):
        source = (self.work / "deployment.yml").read_text()
        result = self.run_phase("render")
        self.assertEqual(result.returncode, 0, result.stderr)
        rendered = (self.work / "deployment.rendered.yml").read_text()
        self.assertIn(f"image: {IMAGE}", rendered)
        self.assertNotIn("CONTAINER_IMAGE", rendered)
        self.assertEqual((self.work / "deployment.yml").read_text(), source)

    def test_render_rejects_missing_or_duplicate_placeholders(self):
        for source in ("image: old/image", "image: CONTAINER_IMAGE\n# CONTAINER_IMAGE"):
            with self.subTest(source=source):
                (self.work / "deployment.yml").write_text(source)
                self.assertNotEqual(self.run_phase("render").returncode, 0)

    def test_failed_earlier_phase_never_pushes_or_deploys(self):
        self.fake_cloud_commands()
        self.env["CODEBUILD_BUILD_SUCCEEDING"] = "0"
        self.assertNotEqual(self.run_phase("deploy").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_failed_push_never_changes_cluster(self):
        self.fake_cloud_commands()
        self.env["FAIL_PUSH"] = "1"
        self.assertNotEqual(self.run_phase("deploy").returncode, 0)
        self.assertEqual([call[0] for call in self.calls()], ["docker"])

    def test_rollout_failure_fails_build_without_success_artifact(self):
        self.fake_cloud_commands()
        self.env["FAIL_ROLLOUT"] = "1"
        self.assertNotEqual(self.run_phase("deploy").returncode, 0)
        self.assertFalse((self.work / "build.json").exists())
        self.assertTrue(any("events" in call for call in self.calls()))

    def test_success_waits_for_rollout_and_records_deployed_image(self):
        self.fake_cloud_commands()
        result = self.run_phase("deploy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads((self.work / "build.json").read_text()),
                         [{"name": "simple-flask", "imageUri": IMAGE}])
        calls = self.calls()
        self.assertIn(["docker", "push", IMAGE], calls)
        self.assertTrue(any("--region" in call and "eu-central-1" in call for call in calls))
        self.assertTrue(any("rollout" in call and "--timeout=180s" in call for call in calls))
        self.assertTrue(any("apply" in call and "deployment-tests" in call for call in calls))


if __name__ == "__main__":
    unittest.main()
