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


class CatcherBase(unittest.TestCase):
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


class CatcherTests(CatcherBase):
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


class CliOutputTests(CatcherBase):
    """OCI CLI output handling, mocked at the subprocess boundary."""

    LIST = ["compute", "instance", "list", "--compartment-id", "ocid1.compartment.oc1..test", "--all"]
    LAUNCH = ["compute", "instance", "launch", "--compartment-id", "ocid1.compartment.oc1..test"]
    GET = ["compute", "instance", "get", "--instance-id", "ocid1.instance.oc1.test"]
    WARNING = "WARNING: Permissions on /tmp/oci/config are too open.\n"

    @staticmethod
    def proc(returncode=0, stdout="", stderr=""):
        return mock.Mock(returncode=returncode, stdout=stdout, stderr=stderr)

    def call(self, args, **result):
        with mock.patch.object(catcher.subprocess, "run", return_value=self.proc(**result)):
            return catcher.cli(args)

    def test_successful_empty_list_is_zero_instances(self):
        for stdout in ("", "\n", "  \n"):
            with self.subTest(stdout=stdout):
                self.assertEqual(self.call(self.LIST, stdout=stdout), (0, {"data": []}, ""))

    def test_successful_empty_list_with_stderr_warning_is_zero_instances(self):
        self.assertEqual(self.call(self.LIST, stderr=self.WARNING), (0, {"data": []}, ""))
        with mock.patch.object(catcher.subprocess, "run", return_value=self.proc(stderr=self.WARNING)):
            self.assertEqual(catcher.list_instances(self.config), ([], ""))

    def test_non_empty_list_still_parsed(self):
        listed = {"data": [{"id": "ocid1.instance.oc1.test"}]}
        self.assertEqual(self.call(self.LIST, stdout=json.dumps(listed)), (0, listed, ""))

    def test_empty_launch_or_get_output_stays_unknown(self):
        for args in (self.LAUNCH, self.GET):
            with self.subTest(command=args[2]):
                rc, data, err = self.call(args, stderr=self.WARNING)
                self.assertEqual(rc, 99)
                self.assertIsNone(data)
                self.assertIn("UnknownOutcome", err)

    def test_invalid_list_json_stays_unknown(self):
        for stdout in ("not json", "{\"data\": [", "WARNING: something"):
            with self.subTest(stdout=stdout):
                rc, data, err = self.call(self.LIST, stdout=stdout)
                self.assertEqual(rc, 99)
                self.assertIsNone(data)
                self.assertIn("UnknownOutcome", err)

    def test_failed_list_with_empty_stdout_is_not_normalized(self):
        for stderr in ("", self.WARNING, "ServiceError: connection timed out"):
            with self.subTest(stderr=stderr):
                rc, data, err = self.call(self.LIST, returncode=1, stderr=stderr)
                self.assertEqual(rc, 1)
                self.assertIsNone(data)
                self.assertEqual(catcher.classify(err), "halt")
                with mock.patch.object(catcher.subprocess, "run", return_value=self.proc(returncode=1, stderr=stderr)):
                    self.assertEqual(catcher.list_instances(self.config)[0], None)

    def test_list_timeout_is_unknown(self):
        with mock.patch.object(catcher.subprocess, "run", side_effect=catcher.subprocess.TimeoutExpired("oci", 130)):
            self.assertEqual(catcher.cli(self.LIST), (99, None, "UnknownOutcome: TimeoutExpired"))

    def test_preflight_empty_list_proceeds_to_single_launch(self):
        def fake(command, **kwargs):
            if "list" in command:
                return self.proc(stderr=self.WARNING)
            return self.proc(stdout=json.dumps({"data": {"id": "ocid1.instance.oc1.test"}}))

        with mock.patch.object(catcher.subprocess, "run", side_effect=fake) as proc:
            self.assertEqual(catcher.run(self.config, self.state), 0)
        launched = [c for c in proc.call_args_list if "launch" in c.args[0]]
        self.assertEqual(len(launched), 1)
        self.assertEqual(json.loads(self.state.read_text())["status"], "pending")

    def test_empty_launch_output_reconciles_instead_of_succeeding(self):
        with mock.patch.object(catcher.subprocess, "run", return_value=self.proc(stderr=self.WARNING)) as proc:
            self.assertEqual(catcher.run(self.config, self.state), 0)
        launched = [c for c in proc.call_args_list if "launch" in c.args[0]]
        self.assertEqual(len(launched), 1)
        self.assertEqual(json.loads(self.state.read_text())["status"], "launching")

    def test_empty_get_output_halts_pending_verification(self):
        catcher.save(self.state, {"status": "pending", "instance_id": "ocid1.instance.oc1.test"})
        with mock.patch.object(catcher.subprocess, "run", return_value=self.proc()), \
                mock.patch.object(catcher, "notify"):
            self.assertEqual(catcher.run(self.config, self.state), 1)
        self.assertEqual(json.loads(self.state.read_text())["status"], "halt")


class Crash(BaseException):
    """Stands in for SIGKILL/power loss mid-request; bypasses except clauses."""


class LaunchIntentTests(CatcherBase):
    """Write-ahead launch intent and crash-recovery reconciliation."""

    INTENT = "0123456789abcdef0123456789abcdef"

    def read(self):
        return json.loads(self.state.read_text())

    def launching(self, minutes_ago=0):
        started = catcher.now() - catcher.dt.timedelta(minutes=minutes_ago)
        catcher.save(self.state, {"status": "launching", "intent_id": self.INTENT,
                                  "started": started.isoformat()})

    def instance(self, state="PROVISIONING", tagged=True, **extra):
        item = {"id": "ocid1.instance.oc1.ap-hyderabad-1.test", "display-name": self.config["name"],
                "lifecycle-state": state, "shape": catcher.SHAPE,
                "freeform-tags": {catcher.INTENT_TAG: self.INTENT} if tagged else {}}
        item.update(extra)
        return item

    @staticmethod
    def launches(mocked):
        return [c for c in mocked.call_args_list if c.args[0][:3] == ["compute", "instance", "launch"]]

    def test_intent_persisted_before_launch_request(self):
        seen = {}

        def fake(args):
            if args[2] == "list":
                return 0, {"data": []}, ""
            seen["state"] = self.read()
            seen["tags"] = json.loads(args[args.index("--freeform-tags") + 1])
            return 0, {"data": {"id": "ocid1.instance.oc1.test"}}, ""

        with mock.patch.object(catcher, "cli", side_effect=fake):
            self.assertEqual(catcher.run(self.config, self.state), 0)
        self.assertEqual(seen["state"]["status"], "launching")
        intent = seen["state"]["intent_id"]
        self.assertEqual(seen["tags"], {catcher.INTENT_TAG: intent})
        final = self.read()
        self.assertEqual((final["status"], final["instance_id"], final["intent_id"]),
                         ("pending", "ocid1.instance.oc1.test", intent))

    def test_intent_save_failure_never_launches(self):
        with mock.patch.object(catcher, "cli", return_value=(0, {"data": []}, "")) as mocked, \
                mock.patch.object(catcher, "save", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                catcher.run(self.config, self.state)
        self.assertEqual(self.launches(mocked), [])

    def test_crash_during_launch_then_restart_adopts_tagged_instance(self):
        def crashing(args):
            if args[2] == "list":
                return 0, {"data": []}, ""
            raise Crash()

        with mock.patch.object(catcher, "cli", side_effect=crashing):
            with self.assertRaises(Crash):
                catcher.run(self.config, self.state)
        recorded = self.read()
        self.assertEqual(recorded["status"], "launching")

        # Restart: OCI did accept the request. The tag ties it to the intent.
        tagged = self.instance()
        tagged["freeform-tags"] = {catcher.INTENT_TAG: recorded["intent_id"]}
        with mock.patch.object(catcher, "cli", return_value=(0, {"data": [tagged]}, "")) as mocked:
            self.assertEqual(catcher.run(self.config, self.state), 0)
        self.assertEqual(self.launches(mocked), [])
        self.assertEqual(self.read()["status"], "pending")
        self.assertEqual(self.read()["instance_id"], tagged["id"])
        self.assertEqual(self.read()["intent_id"], recorded["intent_id"])

    def test_crash_after_accept_before_record_never_duplicates(self):
        # Simulates a crash between OCI accepting the launch and saving pending.
        self.launching()

        def fake(args):
            if args[2] == "get":
                return 0, {"data": {"lifecycle-state": "RUNNING"}}, ""
            return 0, {"data": [self.instance(state="RUNNING")]}, ""

        with mock.patch.object(catcher, "cli", side_effect=fake) as mocked, mock.patch.object(catcher, "notify"):
            catcher.run(self.config, self.state)
            self.assertEqual(self.read()["status"], "pending")
            for _ in range(3):  # repeated restarts: verify, then terminal
                self.assertEqual(catcher.run(self.config, self.state), 0)
        self.assertEqual(self.launches(mocked), [])
        self.assertEqual(self.read()["status"], "done")

    def test_unresolved_intent_waits_within_grace_without_launch(self):
        self.launching(minutes_ago=1)
        before = self.read()
        with mock.patch.object(catcher, "cli", return_value=(0, {"data": []}, "")) as mocked:
            self.assertEqual(catcher.run(self.config, self.state), 0)
        self.assertEqual(self.launches(mocked), [])
        self.assertEqual(self.read(), before)

    def test_unresolved_intent_halts_after_grace(self):
        self.launching(minutes_ago=catcher.RECONCILE_GRACE.total_seconds() / 60 + 1)
        with mock.patch.object(catcher, "cli", return_value=(0, {"data": []}, "")) as mocked, \
                mock.patch.object(catcher, "notify") as notified:
            self.assertEqual(catcher.run(self.config, self.state), 1)
        self.assertEqual(self.launches(mocked), [])
        self.assertEqual(self.read()["status"], "halt")
        self.assertEqual(self.read()["intent_id"], self.INTENT)
        self.assertIn("manual reconciliation", self.read()["reason"])
        notified.assert_called_once()

    def test_reconcile_list_failure_waits_then_halts(self):
        failure = (1, None, "ServiceError: connection timed out")
        self.launching(minutes_ago=1)
        with mock.patch.object(catcher, "cli", return_value=failure) as mocked:
            self.assertEqual(catcher.run(self.config, self.state), 0)
        self.assertEqual(self.read()["status"], "launching")
        self.launching(minutes_ago=60)
        with mock.patch.object(catcher, "cli", return_value=failure) as mocked2, mock.patch.object(catcher, "notify"):
            self.assertEqual(catcher.run(self.config, self.state), 1)
        self.assertEqual(self.launches(mocked) + self.launches(mocked2), [])
        self.assertEqual(self.read()["status"], "halt")

    def test_reconcile_halts_on_terminated_multiple_or_untagged(self):
        cases = {
            "terminated": [self.instance(state="TERMINATED")],
            "multiple": [self.instance(), self.instance(id="ocid1.instance.oc1.ap-hyderabad-1.other")],
            "untagged-name": [self.instance(tagged=False)],
            "untagged-a1": [self.instance(tagged=False, **{"display-name": "something-else"})],
        }
        for name, listed in cases.items():
            with self.subTest(name):
                self.launching()
                with mock.patch.object(catcher, "cli", return_value=(0, {"data": listed}, "")) as mocked, \
                        mock.patch.object(catcher, "notify"):
                    self.assertEqual(catcher.run(self.config, self.state), 1)
                self.assertEqual(self.launches(mocked), [])
                self.assertEqual(self.read()["status"], "halt")
                self.assertEqual(self.read()["intent_id"], self.INTENT)

    def test_ambiguous_launch_error_keeps_intent_and_reconciles(self):
        calls = [(0, {"data": []}, ""), (99, None, "UnknownOutcome: TimeoutExpired"), (0, {"data": []}, "")]
        with mock.patch.object(catcher, "cli", side_effect=calls) as mocked:
            self.assertEqual(catcher.run(self.config, self.state), 0)
        self.assertEqual(len(self.launches(mocked)), 1)
        self.assertEqual(self.read()["status"], "launching")
        # Next timer cycle: still nothing, still no launch.
        with mock.patch.object(catcher, "cli", return_value=(0, {"data": []}, "")) as mocked:
            self.assertEqual(catcher.run(self.config, self.state), 0)
        self.assertEqual(self.launches(mocked), [])

    def test_accepted_launch_without_id_reconciles_by_tag(self):
        def fake(args):
            if args[2] == "list" and self.state.exists() and self.read()["status"] == "launching":
                item = self.instance()
                item["freeform-tags"] = {catcher.INTENT_TAG: self.read()["intent_id"]}
                return 0, {"data": [item]}, ""
            if args[2] == "list":
                return 0, {"data": []}, ""
            return 0, {"data": {}}, ""

        with mock.patch.object(catcher, "cli", side_effect=fake) as mocked:
            self.assertEqual(catcher.run(self.config, self.state), 0)
        self.assertEqual(len(self.launches(mocked)), 1)
        self.assertEqual(self.read()["status"], "pending")

    def test_definitive_rejections_clear_intent(self):
        calls = [(0, {"data": []}, ""), (1, None, "Out of host capacity")]
        with mock.patch.object(catcher, "cli", side_effect=calls):
            self.assertEqual(catcher.run(self.config, self.state), 0)
        self.assertFalse(self.state.exists())
        calls = [(0, {"data": []}, ""), (1, None, "TooManyRequests")]
        with mock.patch.object(catcher, "cli", side_effect=calls):
            self.assertEqual(catcher.run(self.config, self.state), 0)
        self.assertEqual(self.read()["status"], "cooldown")

    def test_corrupt_or_unknown_state_never_launches(self):
        for record in ({"status": "launching"}, {"status": "launching", "intent_id": "bad"}, {"status": "mystery"}, {}):
            with self.subTest(record=record):
                catcher.save(self.state, record)
                with mock.patch.object(catcher, "cli", return_value=(0, {"data": []}, "")) as mocked, \
                        mock.patch.object(catcher, "notify"):
                    try:
                        catcher.run(self.config, self.state)
                    except ValueError:
                        pass
                self.assertEqual(self.launches(mocked), [])

    def test_disabled_guard_leaves_intent_untouched(self):
        self.launching()
        before = self.read()
        with mock.patch.dict(os.environ, {"OCI_ACK_ACCOUNT_QUOTA": "false"}), \
                mock.patch.object(catcher, "cli") as mocked:
            self.assertEqual(catcher.run(self.config, self.state), 0)
        mocked.assert_not_called()
        self.assertEqual(self.read(), before)

    def test_dry_run_makes_no_calls_or_state(self):
        state_dir = self.folder / "state"
        with mock.patch.dict(os.environ, {"OCI_STATE_DIR": str(state_dir)}), \
                mock.patch.object(catcher.sys, "argv", ["a1_catcher.py"]), \
                mock.patch.object(catcher, "cli") as mocked, mock.patch.object(catcher.subprocess, "run") as proc:
            self.assertEqual(catcher.main(), 0)
        mocked.assert_not_called()
        proc.assert_not_called()
        self.assertFalse(state_dir.exists())


if __name__ == "__main__":
    unittest.main()
