#!/usr/bin/env python3
"""Helix RC: normal VRChat launch, no capture probes or frame dumps."""

import argparse
import collections
import hashlib
import ipaddress
import json
import os
import signal
import subprocess
import tempfile
import threading
import time
from pathlib import Path

PACKAGE = "org.meumeu.wivrn.sgsr1"
ACTIVITY = "org.meumeu.wivrn.MainActivity"


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def command(args, timeout=60):
    return subprocess.check_output(
        [str(x) for x in args], stderr=subprocess.STDOUT, timeout=timeout
    ).decode()


def remember_children(parent, expected, owned):
    try:
        children = Path(f"/proc/{parent}/task/{parent}/children").read_text().split()
    except FileNotFoundError:
        return
    for item in children:
        pid = int(item)
        try:
            if Path(f"/proc/{pid}/exe").resolve() == expected:
                owned[pid] = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
            remember_children(pid, expected, owned)
        except FileNotFoundError:
            pass


def stop_children(owned, sig):
    for pid, start in owned.items():
        try:
            if Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19] == start:
                os.kill(pid, sig)
        except ProcessLookupError:
            pass
        except FileNotFoundError:
            pass


def profile():
    path = Path.home() / ".nv/nvidia-application-profiles-rc"
    data = json.loads(path.read_text()) if path.exists() else {"profiles": [], "rules": []}
    entry = {"name": "HelixWiVRnAllowP0", "settings": [{"key": "0x166c5e", "value": 0}]}
    rule = {"pattern": {"feature": "procname", "matches": "wivrn-server"}, "profile": entry["name"]}
    existing = next((p for p in data.get("profiles", []) if p["name"] == entry["name"]), None)
    if existing is not None and existing != entry:
        raise RuntimeError("Existing profile differs; preserving it")
    if existing == entry and rule in data.get("rules", []):
        print("NVIDIA WiVRn P0 allowance already installed")
        return
    data.setdefault("profiles", [])
    if existing is None:
        data["profiles"].append(entry)
    data.setdefault("rules", [])
    if rule not in data["rules"]:
        data["rules"].append(rule)
    path.parent.mkdir(exist_ok=True)
    before = path.read_bytes() if path.exists() else None
    fd, temporary = tempfile.mkstemp(prefix=".helix-profile-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
        if (path.read_bytes() if path.exists() else None) != before:
            raise RuntimeError("Profile changed concurrently")
        if before is not None:
            backup = path.with_name(path.name + ".helix-backup-" + str(time.time_ns()))
            backup.write_bytes(before)
            backup.chmod(0o600)
        os.replace(temporary, path)
        assert json.loads(path.read_text()) == data
    finally:
        Path(temporary).unlink(missing_ok=True)
    print("Installed WiVRn-only P0 allowance:", path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--encoder", choices=("nvenc", "vulkan"), default="nvenc")
    parser.add_argument("--host", help="host LAN IPv4 address (required to launch)")
    parser.add_argument("--quest", help="Quest LAN IPv4 address (required to launch)")
    parser.add_argument(
        "--install-profile",
        action="store_true",
        help="install WiVRn-only NVIDIA P2 workaround and exit",
    )
    parser.add_argument(
        "--check", action="store_true", help="verify bundle checksums without launching"
    )
    parser.add_argument(
        "--seconds", type=int, default=0, help="optional bounded run; default until Ctrl+C"
    )
    args = parser.parse_args()
    if args.seconds < 0:
        parser.error("--seconds must be nonnegative")
    if args.install_profile:
        profile()
        return
    root = args.bundle.resolve(strict=True)
    seal = json.loads((root / "seal.json").read_text())
    for name, wanted in seal["artifacts"].items():
        target = (root / name).resolve(strict=True)
        if not target.is_relative_to(root) or digest(target) != wanted:
            raise RuntimeError("Artifact changed: " + name)
    for name, wanted in seal.get("external_artifacts", {}).items():
        if digest(name) != wanted:
            raise RuntimeError("External runtime changed: " + name)
    if args.check:
        print("RC bundle integrity PASS")
        return
    if not args.host or not args.quest:
        parser.error("launch requires --host HOST_LAN_IP --quest QUEST_LAN_IP")
    host = str(ipaddress.IPv4Address(args.host))
    quest = str(ipaddress.IPv4Address(args.quest))
    serial = quest + ":5555"
    names = command(["ps", "-eo", "comm="]).splitlines()
    if any(x.strip() in ("wivrn-server", "wivrn-dashboard", "VRChat.exe") for x in names):
        raise RuntimeError("Close existing WiVRn/VRChat first")
    if "src " + host not in command(["ip", "-4", "route", "get", quest]):
        raise RuntimeError("Host LAN source differs from RC configuration")
    command(["adb", "connect", serial], 20)

    def adb(*items, timeout=60):
        return command(["adb", "-s", serial, *items], timeout)

    if "mWakefulness=Awake" not in adb("shell", "dumpsys", "power"):
        raise RuntimeError("Quest must be awake")
    focus = adb("shell", "dumpsys", "activity", "activities")
    if any("GuardianDialogActivity" in x for x in focus.splitlines() if "ResumedActivity:" in x):
        raise RuntimeError("Clear Quest Guardian dialog")
    runtime_paths = [
        Path.home() / ".config/openvr/openvrpaths.vrpath",
        Path.home() / ".config/openxr/1/active_runtime.json",
    ]
    before = {p: p.read_bytes() if p.is_file() else None for p in runtime_paths}
    server = None
    reader = None
    owned = {}
    owned_game = {}
    game_launched = False

    def remember_game():
        if not game_launched:
            return
        for item in Path("/proc").iterdir():
            if not item.name.isdigit():
                continue
            try:
                if (item / "comm").read_text().strip() == "VRChat.exe":
                    owned_game[int(item.name)] = (
                        (item / "stat").read_text().rsplit(")", 1)[1].split()[19]
                    )
            except FileNotFoundError:
                pass

    # The frozen server discovers its dev manifest beside its executable's
    # parent directory. A private same-filesystem hardlink staging area preserves
    # its normal runtime manager without modifying any sealed package files.
    with tempfile.TemporaryDirectory(prefix=".helix-session-", dir=root) as temporary:
        temp = Path(temporary)
        (temp / "server").mkdir()
        session_server = temp / "server/wivrn-server"
        os.link(root / "server/wivrn-server", session_server)
        paths = adb("shell", "pm", "path", PACKAGE).strip().splitlines()
        installed = False
        if len(paths) == 1 and paths[0].startswith("package:"):
            adb("pull", paths[0][8:], temp / "installed.apk")
            installed = digest(temp / "installed.apk") == seal["artifacts"]["client.apk"]
        if not installed:
            adb("install", "-r", root / "client.apk", timeout=120)
            path = adb("shell", "pm", "path", PACKAGE).strip().removeprefix("package:")
            adb("pull", path, temp / "installed.apk")
            if digest(temp / "installed.apk") != seal["artifacts"]["client.apk"]:
                raise RuntimeError("Installed APK mismatch")
        manifest = json.loads((root / "runtime-template.json").read_text())
        manifest["runtime"]["library_path"] = str(root / "runtime/libopenxr_wivrn.so")
        manifest["runtime"]["MND_libmonado_path"] = str(root / "runtime/libmonado_wivrn.so")
        runtime_json = temp / "openxr_wivrn-dev.json"
        runtime_json.write_text(json.dumps(manifest))
        config = {
            "encoder": {"encoder": args.encoder, "codec": "h265"},
            "bit-depth": 10,
            "tcp-only": False,
            "publish-service": "none",
            "application": [],
            "openvr-compat-path": "/opt/xrizer",
        }
        (temp / "config.json").write_text(json.dumps(config))
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith(("HELIX_", "PAIR_")) and k != "WIVRN_DUMP_VIDEO"
        }
        for key, separator in [("LD_LIBRARY_PATH", ":"), ("LD_PRELOAD", " ")]:
            if key in env:
                env[key] = separator.join(
                    x for x in env[key].split(separator) if "nvenc-pair-probe" not in x
                )
        env["XR_RUNTIME_JSON"] = str(runtime_json)
        lines = collections.deque(maxlen=128)
        try:
            server = subprocess.Popen(
                [str(session_server), "-f", str(temp / "config.json"), "--no-publish-service"],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )

            def drain():
                for line in server.stdout:
                    lines.append(line[:4096])
                    print(line, end="", flush=True)

            reader = threading.Thread(target=drain, daemon=True)
            reader.start()

            def wait_for(text, seconds):
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    remember_children(server.pid, session_server, owned)
                    remember_game()
                    if server.poll() is not None:
                        raise RuntimeError("Server exited; see console")
                    if any(text in x for x in list(lines)):
                        return
                    time.sleep(0.2)
                raise RuntimeError("Timeout waiting for " + text)

            wait_for(" starting", 15)
            adb("shell", "am", "force-stop", PACKAGE)
            adb(
                "shell",
                "am",
                "start",
                "-W",
                "-a",
                "android.intent.action.VIEW",
                "-d",
                "wivrn://" + host,
                "-n",
                PACKAGE + "/" + ACTIVITY,
            )
            wait_for("Client connected", 45)
            game_launched = True
            subprocess.run(
                ["steam", "-applaunch", "438100", "-vrmode", "openvr"], check=True, timeout=30
            )
            wait_for("application_name: 'VRChat'", 90)
            mapped = False
            for item in Path("/proc").iterdir():
                if not item.name.isdigit():
                    continue
                try:
                    if (item / "comm").read_text().strip() != "VRChat.exe":
                        continue
                    maps = (item / "maps").read_text()
                    if (
                        str(root / "runtime/libopenxr_wivrn.so") in maps
                        and "/opt/xrizer/bin/linux64/vrclient.so" in maps
                    ):
                        mapped = True
                except FileNotFoundError:
                    pass
            if not mapped:
                raise RuntimeError("VRChat did not map the RC runtime and xrizer")
            print("Helix RC running. Ctrl+C stops. Encoder:", args.encoder, flush=True)
            start = time.monotonic()
            while not args.seconds or time.monotonic() - start < args.seconds:
                remember_children(server.pid, session_server, owned)
                remember_game()
                if server.poll() is not None:
                    raise RuntimeError("Server exited")
                time.sleep(0.5)
        except KeyboardInterrupt:
            pass
        finally:
            if server:
                remember_game()
                remember_children(server.pid, session_server, owned)
                if server.poll() is None:
                    server.terminate()
                stop_children(owned, signal.SIGTERM)
                try:
                    server.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=5)
                time.sleep(2)
                stop_children(owned, signal.SIGKILL)
                stop_children(owned_game, signal.SIGTERM)
                time.sleep(1)
                stop_children(owned_game, signal.SIGKILL)
                if reader:
                    reader.join(timeout=3)
                if reader and reader.is_alive():
                    raise RuntimeError("Server output reader did not stop")
                try:
                    adb("shell", "am", "force-stop", PACKAGE)
                except subprocess.SubprocessError:
                    pass
            for path, content in before.items():
                if (path.read_bytes() if path.is_file() else None) != content:
                    raise RuntimeError("Runtime setting restoration failed: " + str(path))
    print("Session stopped; runtime settings restored")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        raise SystemExit("Stopped: " + str(exc))
