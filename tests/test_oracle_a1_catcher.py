"""Hermetic OCI catcher regression tests; never connects to Oracle."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "oracle" / "a1_catcher.py"
spec = importlib.util.spec_from_file_location("a1_catcher", MODULE)
catcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catcher)


class CatcherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        key = self.folder / "key.pub"
        key.write_text("ssh-ed25519 AAAATEST placeholder\n", encoding="utf-8")
        self.env = {
            "OCI_REGION": "ap-hyderabad-1", "OCI_OCPUS": "2", "OCI_MEMORY_GB": "12",
            "OCI_COMPARTMENT_ID": "ocid1.compartment.oc1..test",
            "OCI_SUBNET_ID": "ocid1.subnet.oc1.ap-hyderabad-1.test",
            "OCI_IMAGE_ID": "ocid1.image.oc1.ap-hyderabad-1.test",
            "OCI_AVAILABILITY_DOMAIN": "XXXX:AP-HYDERABAD-1-AD-1",
            "OCI_SSH_PUBLIC_KEY_FILE": str(key), "OCI_ENABLE_LAUNCH": "true",
            "OCI_ACK_ACCOUNT_QUOTA": "true", "OCI_DISPLAY_NAME": "oracle-a1-free-catcher",
        }
        patcher = mock.patch.dict(os.environ, self.env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.config = catcher.configure()
        self.state = self.folder / "state.json"

    def test_reject_paid_size_or_region(self):
        with mock.patch.dict(os.environ, {"OCI_OCPUS": "3"}):
            with self.assertRaises(ValueError):
                catcher.configure()
        with mock.patch.dict(os.environ, {"OCI_REGION": "ap-mumbai-1"}):
            with self.assertRaises(ValueError):
                catcher.configure()

    def test_disabled_is_noop(self):
        with mock.patch.dict(os.environ, {"OCI_ENABLE_LAUNCH": "false"}):
            with mock.patch.object(catcher, "cli") as mocked:
                self.assertEqual(catcher.run(self.config, self.state), 0)
                mocked.assert_not_called()

    def test_capacity_retries_without_state_or_second_calls(self):
        calls = [(0, {"data": []}, ""), (1, None, "Out of host capacity")]
        with mock.patch.object(catcher, "cli", side_effect=calls) as mocked:
            self.assertEqual(catcher.run(self.config, self.state), 0)
            self.assertEqual(mocked.call_count, 2)
            self.assertFalse(self.state.exists())

    def test_limit_exceeded_halts(self):
        calls = [(0, {"data": []}, ""), (1, None, "LimitExceeded")]
        with mock.patch.object(catcher, "cli", side_effect=calls), mock.patch.object(catcher, "notify"):
            self.assertEqual(catcher.run(self.config, self.state), 1)
            self.assertEqual(json.loads(self.state.read_text())["status"], "halt")

    def test_rate_limit_cools_down(self):
        calls = [(0, {"data": []}, ""), (1, None, "TooManyRequests")]
        with mock.patch.object(catcher, "cli", side_effect=calls):
            self.assertEqual(catcher.run(self.config, self.state), 0)
            self.assertEqual(json.loads(self.state.read_text())["status"], "cooldown")

    def test_existing_target_prevents_duplicate(self):
        instance = {"id": "ocid1.instance.oc1.test", "display-name": self.config["name"],
                    "lifecycle-state": "RUNNING", "shape": catcher.SHAPE}
        with mock.patch.object(catcher, "cli", return_value=(0, {"data": [instance]}, "")) as mocked:
            self.assertEqual(catcher.run(self.config, self.state), 0)
            self.assertEqual(mocked.call_count, 1)
            self.assertEqual(json.loads(self.state.read_text())["status"], "pending")

    def test_pending_verifies_running_without_launch(self):
        catcher.save(self.state, {"status": "pending", "instance_id": "ocid1.instance.oc1.test"})
        with mock.patch.object(catcher, "cli", return_value=(0, {"data": {"lifecycle-state": "RUNNING"}}, "")) as mocked, mock.patch.object(catcher, "notify"):
            self.assertEqual(catcher.run(self.config, self.state), 0)
            self.assertEqual(mocked.call_count, 1)
            self.assertEqual(json.loads(self.state.read_text())["status"], "done")

    def test_ambiguous_cli_timeout_never_retried(self):
        result = mock.Mock(returncode=1, stderr="ServiceError: connection timed out", stdout="")
        with mock.patch.object(catcher.subprocess, "run", return_value=result):
            rc, data, err = catcher.cli(["compute", "instance", "launch"])
            self.assertNotEqual(rc, 0)
            self.assertIsNone(data)
            self.assertEqual(catcher.classify(err), "halt")

    def test_done_and_halt_are_terminal(self):
        with mock.patch.object(catcher, "cli") as mocked:
            for status in ("done", "halt"):
                catcher.save(self.state, {"status": status})
                self.assertEqual(catcher.run(self.config, self.state), 0)
            mocked.assert_not_called()


if __name__ == "__main__":
    unittest.main()
