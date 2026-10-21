#!/usr/bin/env python3
"""Fail-closed Oracle Always Free A1 capacity catcher (stdlib + OCI CLI)."""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse
import urllib.request
import uuid

REGION = "ap-hyderabad-1"
SHAPE = "VM.Standard.A1.Flex"
UTC = dt.timezone.utc
# Freeform tag written on every launch so an unrecorded outcome can be matched
# back to the intent that issued it.
INTENT_TAG = "a1-catcher-intent"
# How long an unresolved intent may wait for ListInstances to show the
# instance before the catcher halts for manual reconciliation.
RECONCILE_GRACE = dt.timedelta(minutes=15)
GONE = ("TERMINATED", "TERMINATING")


def now() -> dt.datetime:
    return dt.datetime.now(UTC)


def stamp() -> str:
    return now().isoformat()


def fail(message: str) -> None:
    raise ValueError(message)


def need(key: str) -> str:
    value = os.environ.get(key, "").strip()
    if not value:
        fail(f"Missing {key}")
    return value


def configure() -> dict:
    region = os.environ.get("OCI_REGION", REGION)
    if region != REGION:
        fail(f"Only {REGION} is permitted, got {region!r}")
    ocpus = int(os.environ.get("OCI_OCPUS", "2"))
    memory = int(os.environ.get("OCI_MEMORY_GB", "12"))
    if not (1 <= ocpus <= 2 and 1 <= memory <= 12):
        fail("Requested size exceeds conservative 2-OCPU / 12-GB Always Free ceiling")
    comp, subnet, image = need("OCI_COMPARTMENT_ID"), need("OCI_SUBNET_ID"), need("OCI_IMAGE_ID")
    for field, value, prefix in (("compartment", comp, ("ocid1.compartment.", "ocid1.tenancy.")),
                                  ("subnet", subnet, ("ocid1.subnet.",)),
                                  ("image", image, ("ocid1.image.",))):
        if not value.startswith(prefix):
            fail(f"Invalid {field} OCID")
    if f".{REGION}." not in subnet or f".{REGION}." not in image:
        fail("Image and subnet OCIDs must belong to Hyderabad")
    ad = need("OCI_AVAILABILITY_DOMAIN")
    if "AD-" not in ad:
        fail("Set OCI_AVAILABILITY_DOMAIN to a returned OCI availability domain name")
    name = os.environ.get("OCI_DISPLAY_NAME", "oracle-a1-free-catcher")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{2,62}", name):
        fail("OCI_DISPLAY_NAME must be 3-63 alphanumeric/hyphen characters")
    key = Path(need("OCI_SSH_PUBLIC_KEY_FILE")).expanduser()
    if not key.is_file() or not key.read_text(encoding="utf-8").strip().startswith(("ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-")):
        fail("Provide an existing SSH PUBLIC key file, not a private key")
    public_ip = os.environ.get("OCI_ASSIGN_PUBLIC_IP", "false").lower()
    if public_ip not in ("true", "false"):
        fail("OCI_ASSIGN_PUBLIC_IP must be true or false")
    return dict(region=region, ocpus=ocpus, memory=memory, compartment=comp, subnet=subnet,
                image=image, ad=ad, name=name, key=str(key), public_ip=public_ip)


def cli(args: list[str]) -> tuple[int, dict | None, str]:
    command = ["oci", "--region", REGION, "--no-retry", "--connection-timeout", "30",
               "--read-timeout", "90", *args, "--output", "json"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=130, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        # Ambiguous network/launch outcome: never auto-retry.
        return 99, None, f"UnknownOutcome: {type(exc).__name__}"
    if result.returncode:
        raw = result.stderr or result.stdout
        # Normal OCI CLI exception formatting may be non-JSON. Preserve only
        # classification-safe phrases, never dump paths or credentials.
        low = raw.lower()
        if "out of host capacity" in low or "out of capacity" in low:
            return result.returncode, None, "Out of host capacity"
        if "toomanyrequests" in low or "too many requests" in low:
            return result.returncode, None, "TooManyRequests"
        if "limitexceeded" in low:
            return result.returncode, None, "LimitExceeded"
        # Avoid printing raw JSON/CLI output that may contain credential paths or request data.
        code = re.search(r"['\"]code['\"]\s*:\s*['\"]([^'\"]+)", raw)
        message = re.search(r"['\"]message['\"]\s*:\s*['\"]([^'\"]+)", raw)
        if code or message:
            return result.returncode, None, f"{code.group(1) if code else 'Error'}: {message.group(1) if message else 'No message'}"[:320]
        return result.returncode, None, "OCI CLI failed (check credentials, IAM, region and logs locally)"
    if args[:3] == ["compute", "instance", "list"] and not result.stdout.strip():
        # OCI CLI prints nothing (exit 0) when ListInstances returns zero
        # items. Only a successful list may be read as empty; empty output
        # from launch/get stays an unknown outcome below.
        return 0, {"data": []}, ""
    try:
        return 0, json.loads(result.stdout), ""
    except json.JSONDecodeError:
        return 99, None, "UnknownOutcome: invalid JSON from OCI CLI"


def classify(error: str) -> str:
    lower = error.lower()
    if "out of host capacity" in lower or "out of capacity" in lower:
        return "capacity"
    if "toomanyrequests" in lower or "too many requests" in lower or "429" in lower:
        return "rate-limit"
    return "halt"


def notify(message: str) -> None:
    token = os.environ.get("OCI_TELEGRAM_BOT_TOKEN", "")
    chat = os.environ.get("OCI_TELEGRAM_CHAT_ID", "")
    if not (token and chat):
        return
    data = urllib.parse.urlencode({"chat_id": chat, "text": message}).encode()
    request = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage", data=data)
    try:
        urllib.request.urlopen(request, timeout=10).close()
    except Exception:
        print("Telegram notification failed; check bot configuration", file=sys.stderr)


def save(path: Path, obj: dict) -> None:
    # Durable write: the launch intent must survive a crash or power loss
    # before the launch request is issued.
    temporary = path.with_suffix(".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(obj, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    temporary.replace(path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def halt(state: Path, reason: str, intent_id: str = "") -> int:
    record = {"status": "halt", "reason": reason, "updated": stamp()}
    if intent_id:
        record["intent_id"] = intent_id
    save(state, record)
    print(f"HALTED: {reason}", file=sys.stderr)
    notify(f"OCI A1 catcher HALTED: {reason}")
    return 1


def finish(state: Path, instance_id: str) -> int:
    save(state, {"status": "done", "instance_id": instance_id, "updated": stamp()})
    print(f"SUCCESS: {instance_id}")
    notify(f"OCI A1 instance RUNNING in Hyderabad: {instance_id}")
    return 0


def list_instances(config: dict) -> tuple[list | None, str]:
    rc, response, err = cli(["compute", "instance", "list", "--compartment-id", config["compartment"], "--all"])
    if rc:
        return None, err
    entries = response.get("data") if isinstance(response, dict) else None
    if not isinstance(entries, list):
        return None, "Instance list returned unexpected data"
    return entries, ""


def reconcile(config: dict, state: Path, recorded: dict) -> int:
    """Resolve a launch whose outcome was never recorded. Never launches."""
    intent = recorded.get("intent_id", "")
    if not re.fullmatch(r"[0-9a-f]{32}", intent):
        return halt(state, "Launch intent record is corrupt: manual reconciliation required")
    expired = now() >= dt.datetime.fromisoformat(recorded["started"]) + RECONCILE_GRACE

    def undetermined(reason: str) -> int:
        if expired:
            return halt(state, f"Launch outcome undetermined ({reason}): manual reconciliation required", intent)
        print(f"Launch intent {intent} unresolved ({reason}); re-checking next cycle, no new launch")
        return 0

    entries, err = list_instances(config)
    if entries is None:
        return undetermined(f"instance list failed: {err}")
    tagged = [item for item in entries if (item.get("freeform-tags") or {}).get(INTENT_TAG) == intent]
    if len(tagged) > 1:
        return halt(state, f"{len(tagged)} instances carry launch intent tag: manual reconciliation required", intent)
    if tagged:
        found = tagged[0]
        current = found.get("lifecycle-state")
        if current in GONE:
            return halt(state, f"Instance for launch intent entered {current}", intent)
        if not re.match(r"^ocid1\.instance\.", found.get("id", "")):
            return halt(state, "Tagged instance has no valid OCID: manual reconciliation required", intent)
        save(state, {"status": "pending", "instance_id": found["id"], "intent_id": intent, "updated": stamp()})
        print(f"Reconciled launch intent to {found['id']}; verifying RUNNING on next timer cycle")
        return 0
    active = [item for item in entries if item.get("lifecycle-state") not in GONE]
    if any(item.get("display-name") == config["name"] or item.get("shape") == SHAPE for item in active):
        return halt(state, "Untagged A1 or same-name instance found while launch intent unresolved: manual reconciliation required", intent)
    return undetermined("no instance carries the launch intent tag")


def run(config: dict, state: Path) -> int:
    if os.environ.get("OCI_ENABLE_LAUNCH") != "true" or os.environ.get("OCI_ACK_ACCOUNT_QUOTA") != "true":
        print("Live launch disabled. Set OCI_ENABLE_LAUNCH=true AND OCI_ACK_ACCOUNT_QUOTA=true after review.")
        return 0
    if state.exists():
        recorded = json.loads(state.read_text(encoding="utf-8"))
        status = recorded.get("status")
        if status in ("done", "halt"):
            print(f"Already {status}; no launch will occur. Review state before manually resetting.")
            return 0
        if status == "cooldown" and now() < dt.datetime.fromisoformat(recorded["next_attempt"]):
            print("Rate-limit cooldown still active")
            return 0
        if status == "pending":
            instance_id = recorded["instance_id"]
            rc, info, err = cli(["compute", "instance", "get", "--instance-id", instance_id])
            if rc:
                return halt(state, f"Cannot verify accepted launch: {err}")
            current = info["data"].get("lifecycle-state")
            if current == "RUNNING":
                return finish(state, instance_id)
            if current in ("TERMINATED", "TERMINATING"):
                return halt(state, f"Accepted instance entered {current}")
            print(f"Instance {instance_id} is {current}, no further launches")
            return 0
        if status == "launching":
            # A previous run recorded intent but not the outcome (crash,
            # restart or ambiguous API result): reconcile, never re-launch.
            return reconcile(config, state, recorded)
        if status != "cooldown":
            fail(f"Unrecognised state status {status!r}; refusing to launch")
    entries, err = list_instances(config)
    if entries is None:
        return halt(state, f"Preflight instance list failed: {err}")
    active = [item for item in entries if item.get("lifecycle-state") not in GONE]
    named = [item for item in active if item.get("display-name") == config["name"]]
    if named:
        found = named[0]
        save(state, {"status": "pending", "instance_id": found["id"], "updated": stamp()})
        print("Matching instance already exists; switched to verification, no duplicate launch")
        return 0
    if any(item.get("shape") == SHAPE for item in active):
        return halt(state, "Other active A1 instance in target compartment; re-check account quota")
    intent = uuid.uuid4().hex
    # Write-ahead: persist intent before the request leaves this host. If
    # this save fails, the exception aborts the run before any launch.
    record = {"status": "launching", "intent_id": intent, "display_name": config["name"],
              "started": stamp(), "updated": stamp()}
    save(state, record)
    args = ["compute", "instance", "launch", "--compartment-id", config["compartment"],
            "--availability-domain", config["ad"], "--display-name", config["name"],
            "--shape", SHAPE, "--shape-config", json.dumps({"ocpus": config["ocpus"], "memoryInGBs": config["memory"]}),
            "--image-id", config["image"], "--subnet-id", config["subnet"],
            "--ssh-authorized-keys-file", config["key"], "--assign-public-ip", config["public_ip"],
            "--freeform-tags", json.dumps({INTENT_TAG: intent})]
    rc, launched, err = cli(args)
    if rc:
        category = classify(err)
        # Capacity and rate-limit responses are definitive rejections, so
        # the intent can be cleared without risking a duplicate.
        if category == "capacity":
            state.unlink()
            print("Out of host capacity; timer will retry next cycle")
            return 0
        if category == "rate-limit":
            save(state, {"status": "cooldown", "next_attempt": (now() + dt.timedelta(minutes=30)).isoformat(), "updated": stamp()})
            print("OCI rate-limited; waiting 30 minutes")
            return 0
        if "limitexceeded" in err.lower():
            return halt(state, f"Launch rejected: {err}", intent)
        print(f"Launch outcome uncertain ({err}); reconciling", file=sys.stderr)
        return reconcile(config, state, record)
    data = launched.get("data") if isinstance(launched, dict) else None
    instance_id = data.get("id", "") if isinstance(data, dict) else ""
    if not re.match(r"^ocid1\.instance\.", instance_id):
        print("Launch accepted but instance ID missing; reconciling", file=sys.stderr)
        return reconcile(config, state, record)
    save(state, {"status": "pending", "instance_id": instance_id, "intent_id": intent, "updated": stamp()})
    print(f"Launch accepted: {instance_id}; verifying RUNNING on next timer cycle")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true", help="Permit writes only when env guards also explicitly enabled")
    args = parser.parse_args()
    try:
        config = configure()
        print(f"Target: {REGION}, {SHAPE}, {config['ocpus']} OCPU / {config['memory']} GB, public IP={config['public_ip']}")
        if not args.execute:
            print("DRY RUN ONLY: Configuration validated. No OCI calls or writes made.")
            return 0
        state_dir = Path(os.environ.get("OCI_STATE_DIR", "~/.local/state/oci-a1-catcher")).expanduser()
        state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(state_dir, 0o700)
        with (state_dir / "lock").open("a+") as lock:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("Another execution owns the lock; skipping")
                return 0
            return run(config, state_dir / "state.json")
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as exc:
        print(f"Configuration/state error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
