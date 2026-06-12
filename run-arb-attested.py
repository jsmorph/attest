#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# ///
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import threading
import time
from pathlib import Path


SUCCESS_OBJECTS = {
    "run.log",
    "manifest.json",
    "manifest.sha384",
    "attestation.b64",
    "aar-output.tar.gz",
}
PARTIAL_OBJECTS = {"run.log", "aar-partial.tar.gz"}
DEFAULT_PCR12 = "0" * 96


class RunnerError(Exception):
    pass


def utc_stamp() -> str:
    return dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")


def validate_example(value: str) -> None:
    if not value or value.startswith(".") or "/" in value or ".." in value:
        raise RunnerError(f"invalid example name: {value}")


def validate_run_id(value: str) -> None:
    if not value or value.startswith(".") or "/" in value or ".." in value or "\n" in value:
        raise RunnerError(f"invalid run ID: {value}")


def require_s3_prefix(name: str, value: str) -> str:
    if not value.startswith("s3://"):
        raise RunnerError(f"{name} must start with s3://")
    return value.rstrip("/")


def sha384_file(path: Path) -> str:
    h = hashlib.sha384()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_line(path: Path, line: str) -> None:
    with path.open("a", encoding="utf-8") as f:
        f.write(line.rstrip("\n"))
        f.write("\n")


def run_command(cmd: list[str], log_path: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log_path is not None and result.stdout:
        with log_path.open("a", encoding="utf-8") as f:
            f.write(result.stdout)
    if check and result.returncode != 0:
        raise RunnerError(f"command failed with exit status {result.returncode}: {shlex.join(cmd)}")
    return result


def ssh(args: argparse.Namespace, remote: str, log_path: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run_command(["ssh", args.dev_host, remote], log_path=log_path, check=check)


def quote(value: str) -> str:
    return shlex.quote(value)


def build_remote_exec_command(args: argparse.Namespace, run_id: str, output_prefix: str) -> str:
    remote_runner = f"{args.remote_attest_dir.rstrip('/')}/run-aar.sh"
    env = {
        "AWS_DEFAULT_REGION": args.aws_region,
        "INSTANCE_TYPE": args.instance_type,
        "POLL_ATTEMPTS": str(args.exec_poll_attempts),
        "EXEC_ENV_VARS": "INPUT_PREFIX,IMAGE_TAR_S3,AAR_EXAMPLE,RUN_ID,OUTPUT_PREFIX",
        "INPUT_PREFIX": args.input_prefix,
        "IMAGE_TAR_S3": args.image_tar_s3,
        "AAR_EXAMPLE": args.example,
        "RUN_ID": run_id,
        "OUTPUT_PREFIX": output_prefix,
    }
    if args.iam_instance_profile:
        env["IAM_INSTANCE_PROFILE"] = args.iam_instance_profile
    if args.root_volume_size_gb:
        env["ROOT_VOLUME_SIZE_GB"] = args.root_volume_size_gb
    env_text = " ".join(f"{name}={quote(value)}" for name, value in env.items())
    return "\n".join(
        [
            "set -eu",
            f"cd {quote(args.remote_attest_dir)}",
            f"env {env_text} ./exec.sh {quote(args.exec_ami)} {quote(remote_runner)}",
        ]
    )


def start_launcher(args: argparse.Namespace, run_id: str, output_prefix: str, launcher_log: Path) -> tuple[subprocess.Popen[str], dict[str, str | None], threading.Thread]:
    state: dict[str, str | None] = {"instance_id": None}
    remote = build_remote_exec_command(args, run_id, output_prefix)
    proc = subprocess.Popen(
        ["ssh", args.dev_host, remote],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
    )

    def read_output() -> None:
        assert proc.stdout is not None
        with launcher_log.open("a", encoding="utf-8") as log:
            for line in proc.stdout:
                log.write(line)
                log.flush()
                match = re.match(r"Instance:\s+(i-[0-9a-fA-F]+)", line.strip())
                if match:
                    state["instance_id"] = match.group(1)

    thread = threading.Thread(target=read_output, daemon=True)
    thread.start()
    return proc, state, thread


def list_s3_objects(args: argparse.Namespace, output_prefix: str) -> set[str]:
    remote = (
        f"AWS_DEFAULT_REGION={quote(args.aws_region)} "
        f"aws s3 ls {quote(output_prefix.rstrip('/') + '/')}"
    )
    result = ssh(args, remote, check=False)
    if result.returncode != 0:
        return set()
    objects: set[str] = set()
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] != "PRE":
            objects.add(parts[3])
    return objects


def classify_objects(objects: set[str]) -> str | None:
    if SUCCESS_OBJECTS.issubset(objects):
        return "success"
    if PARTIAL_OBJECTS.issubset(objects):
        return "partial"
    return None


def terminate_instance(args: argparse.Namespace, instance_id: str, progress_log: Path) -> None:
    write_line(progress_log, f"{utc_stamp()} terminating instance {instance_id}")
    remote = (
        f"AWS_DEFAULT_REGION={quote(args.aws_region)} "
        f"aws ec2 terminate-instances --instance-ids {quote(instance_id)} >/dev/null"
    )
    ssh(args, remote, check=False)


def stop_launcher(proc: subprocess.Popen[str], progress_log: Path) -> None:
    if proc.poll() is not None:
        return
    write_line(progress_log, f"{utc_stamp()} stopping remote launcher")
    proc.terminate()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=15)


def download_artifacts(args: argparse.Namespace, run_id: str, output_prefix: str, out_dir: Path, objects: set[str], progress_log: Path) -> set[str]:
    remote_tmp = f"/tmp/run-arb-attested-{run_id}-{os.getpid()}"
    remote = "\n".join(
        [
            "set -eu",
            f"mkdir -p {quote(remote_tmp)}",
            f"AWS_DEFAULT_REGION={quote(args.aws_region)} aws s3 cp {quote(output_prefix.rstrip('/') + '/')} {quote(remote_tmp + '/')} --recursive --no-progress >/dev/null",
            f"find {quote(remote_tmp)} -maxdepth 1 -type f -printf '%f\\n' | sort",
        ]
    )
    result = ssh(args, remote, log_path=progress_log)
    remote_objects = {line.strip() for line in result.stdout.splitlines() if line.strip()}
    names = sorted(objects | remote_objects)
    for name in names:
        if "/" in name or name.startswith("."):
            continue
        run_command(["scp", f"{args.dev_host}:{remote_tmp}/{name}", str(out_dir / name)], log_path=progress_log)
    ssh(args, f"rm -rf {quote(remote_tmp)}", check=False)
    return names


def safe_extract(archive: Path, dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    dest_root = dest.resolve()
    with tarfile.open(archive, "r:gz") as tf:
        for member in tf.getmembers():
            target = (dest / member.name).resolve()
            if target != dest_root and dest_root not in target.parents:
                raise RunnerError(f"archive member escapes output directory: {member.name}")
        tf.extractall(dest)


def extract_archives(out_dir: Path, status: str) -> None:
    if status == "success":
        safe_extract(out_dir / "aar-output.tar.gz", out_dir / "aar-output")
    elif status == "partial":
        safe_extract(out_dir / "aar-partial.tar.gz", out_dir / "aar-partial")


def verify_manifest_and_archive(args: argparse.Namespace, out_dir: Path, output_prefix: str, verification_log: Path) -> None:
    manifest_path = out_dir / "manifest.json"
    manifest_hash_path = out_dir / "manifest.sha384"
    archive_path = out_dir / "aar-output.tar.gz"
    run_log_path = out_dir / "run.log"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    checks = [
        ("manifest.sha384", sha384_file(manifest_path) == manifest_hash_path.read_text(encoding="utf-8").strip()),
        ("mode", manifest.get("mode") == "aar"),
        ("aar_example", manifest.get("aar_example") == args.example),
        ("output_prefix", manifest.get("output_prefix") == output_prefix),
        ("archive_key", manifest.get("aar_archive_key") == output_prefix.rstrip("/") + "/aar-output.tar.gz"),
        ("run.log sha384", sha384_file(run_log_path) == manifest.get("log_sha384")),
        ("archive sha384", sha384_file(archive_path) == manifest.get("aar_archive_sha384")),
        ("archive bytes", str(archive_path.stat().st_size) == manifest.get("aar_archive_bytes")),
        ("container image id present", bool(manifest.get("container_image_id"))),
        ("container tar hash present", bool(manifest.get("container_image_tar_sha384"))),
    ]
    failed = [name for name, ok in checks if not ok]
    for name, ok in checks:
        write_line(verification_log, f"{name}: {'ok' if ok else 'failed'}")
    if failed:
        raise RunnerError("manifest or archive verification failed: " + ", ".join(failed))


def verify_attestation(args: argparse.Namespace, out_dir: Path, verification_log: Path) -> None:
    parser = Path(args.parser)
    if not parser.exists():
        raise RunnerError(f"attestation parser not found: {parser}")
    attestation = out_dir / "attestation.b64"
    attestation_txt = out_dir / "attestation.txt"
    result = run_command([args.uv, "run", str(parser), str(attestation)], check=False)
    attestation_txt.write_text(result.stdout, encoding="utf-8")
    if result.returncode != 0:
        raise RunnerError("attestation parser failed")
    manifest_sha384 = (out_dir / "manifest.sha384").read_text(encoding="utf-8").strip()
    checks = [
        ("signature", re.search(r"^Signature: VALID\b", result.stdout, re.MULTILINE) is not None),
        ("user_data", re.search(rf"^User Data: {re.escape(manifest_sha384)}$", result.stdout, re.MULTILINE) is not None),
    ]
    expected_pcrs = {
        4: args.expected_pcr4,
        7: args.expected_pcr7,
        12: args.expected_pcr12,
    }
    for index, expected in expected_pcrs.items():
        if expected:
            checks.append(
                (
                    f"PCR {index}",
                    re.search(rf"^PCR {index:2d}: {re.escape(expected.upper())}$", result.stdout, re.MULTILINE) is not None,
                )
            )
    failed = [name for name, ok in checks if not ok]
    for name, ok in checks:
        write_line(verification_log, f"{name}: {'ok' if ok else 'failed'}")
    if failed:
        raise RunnerError("attestation verification failed: " + ", ".join(failed))


def verify_success(args: argparse.Namespace, out_dir: Path, output_prefix: str) -> None:
    verification_log = out_dir / "verification.log"
    verify_manifest_and_archive(args, out_dir, output_prefix, verification_log)
    verify_attestation(args, out_dir, verification_log)


def prepare_out_dir(path: Path, allow_nonempty: bool) -> None:
    path.mkdir(parents=True, exist_ok=True)
    if any(path.iterdir()) and not allow_nonempty:
        raise RunnerError(f"output directory is not empty: {path}")


def write_run_env(args: argparse.Namespace, out_dir: Path, run_id: str, output_prefix: str) -> None:
    values = {
        "AAR_EXAMPLE": args.example,
        "INPUT_PREFIX": args.input_prefix,
        "RUN_ID": run_id,
        "OUTPUT_PREFIX": output_prefix,
        "EXEC_AMI": args.exec_ami,
        "DEV_HOST": args.dev_host,
        "REMOTE_ATTEST_DIR": args.remote_attest_dir,
        "AWS_REGION": args.aws_region,
        "INSTANCE_TYPE": args.instance_type,
        "IAM_INSTANCE_PROFILE": args.iam_instance_profile,
        "IMAGE_TAR_S3": args.image_tar_s3,
    }
    with (out_dir / "run.env").open("w", encoding="utf-8") as f:
        for name, value in values.items():
            f.write(f"{name}={value}\n")


def poll_until_terminal(args: argparse.Namespace, proc: subprocess.Popen[str], state: dict[str, str | None], output_prefix: str, progress_log: Path) -> tuple[str, set[str]]:
    deadline = time.monotonic() + args.timeout_seconds
    last_objects: set[str] = set()
    while True:
        objects = list_s3_objects(args, output_prefix)
        if objects:
            last_objects = objects
        status = classify_objects(objects)
        names = ",".join(sorted(objects)) if objects else "none"
        instance = state.get("instance_id") or "pending"
        line = f"{utc_stamp()} still moving: instance={instance} objects={names}"
        print(line, flush=True)
        write_line(progress_log, line)
        if status is not None:
            return status, objects
        exit_code = proc.poll()
        if exit_code is not None:
            objects = list_s3_objects(args, output_prefix)
            status = classify_objects(objects)
            if status is not None:
                return status, objects
            raise RunnerError(f"remote launcher exited with status {exit_code} before terminal S3 artifacts appeared")
        if time.monotonic() >= deadline:
            names = ",".join(sorted(last_objects)) if last_objects else "none"
            raise RunnerError(f"timeout waiting for terminal S3 artifacts; last objects={names}")
        time.sleep(args.poll_interval_seconds)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser_path = Path(__file__).with_name("parse_attestation.py")
    p = argparse.ArgumentParser(description="Run an attested AAR example through the exec AMI.")
    p.add_argument("--example", required=True)
    p.add_argument("--input-prefix", required=True)
    p.add_argument("--exec-ami", required=True)
    p.add_argument("--out-dir", required=True, type=Path)
    p.add_argument("--run-id")
    p.add_argument("--output-prefix")
    p.add_argument("--output-root", default=os.environ.get("OUTPUT_ROOT", "s3://agentcourt-data/arbattest/aar-runs"))
    p.add_argument("--dev-host", default=os.environ.get("DEV_HOST", "dev"))
    p.add_argument("--remote-attest-dir", default=os.environ.get("REMOTE_ATTEST_DIR", "/home/ec2-user/attest"))
    p.add_argument("--aws-region", default=os.environ.get("AWS_REGION", "us-east-2"))
    p.add_argument("--instance-type", default=os.environ.get("INSTANCE_TYPE", "m5.4xlarge"))
    p.add_argument("--iam-instance-profile", default=os.environ.get("IAM_INSTANCE_PROFILE", "ec2-nix-builder"))
    p.add_argument("--image-tar-s3", default=os.environ.get("IMAGE_TAR_S3", "s3://agentcourt-data/arbattest/images/arb-glue-poc.tar"))
    p.add_argument("--root-volume-size-gb", default=os.environ.get("ROOT_VOLUME_SIZE_GB", ""))
    p.add_argument("--exec-poll-attempts", type=int, default=int(os.environ.get("POLL_ATTEMPTS", "1800")))
    p.add_argument("--poll-interval-seconds", type=int, default=int(os.environ.get("POLL_INTERVAL_SECONDS", "30")))
    p.add_argument("--timeout-seconds", type=int, default=int(os.environ.get("TIMEOUT_SECONDS", "10800")))
    p.add_argument("--allow-nonempty-out-dir", action="store_true")
    p.add_argument("--verify", action="store_true")
    p.add_argument("--uv", default=os.environ.get("UV") or shutil.which("uv") or "uv")
    p.add_argument("--parser", default=os.environ.get("ATTESTATION_PARSER", str(parser_path)))
    p.add_argument("--expected-pcr4", default=os.environ.get("EXPECTED_PCR4", ""))
    p.add_argument("--expected-pcr7", default=os.environ.get("EXPECTED_PCR7", ""))
    p.add_argument("--expected-pcr12", default=os.environ.get("EXPECTED_PCR12", DEFAULT_PCR12))
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        validate_example(args.example)
        args.input_prefix = require_s3_prefix("input prefix", args.input_prefix)
        args.image_tar_s3 = require_s3_prefix("image tar S3 path", args.image_tar_s3)
        output_root = require_s3_prefix("output root", args.output_root)
        run_id = args.run_id or f"aar-{args.example}-{utc_stamp()}"
        validate_run_id(run_id)
        output_prefix = args.output_prefix.rstrip("/") if args.output_prefix else f"{output_root}/{run_id}"
        output_prefix = require_s3_prefix("output prefix", output_prefix)
        prepare_out_dir(args.out_dir, args.allow_nonempty_out_dir)
        progress_log = args.out_dir / "progress.log"
        launcher_log = args.out_dir / "launcher.log"
        write_run_env(args, args.out_dir, run_id, output_prefix)
        write_line(progress_log, f"{utc_stamp()} starting run {run_id}")
        proc, state, thread = start_launcher(args, run_id, output_prefix, launcher_log)
        try:
            status, objects = poll_until_terminal(args, proc, state, output_prefix, progress_log)
            downloaded = download_artifacts(args, run_id, output_prefix, args.out_dir, objects, progress_log)
            if status == "success" and args.verify:
                verify_success(args, args.out_dir, output_prefix)
            extract_archives(args.out_dir, status)
            if proc.poll() is None:
                instance_id = state.get("instance_id")
                if instance_id:
                    terminate_instance(args, instance_id, progress_log)
                stop_launcher(proc, progress_log)
            thread.join(timeout=5)
            write_line(progress_log, f"{utc_stamp()} completed with status {status}")
            print(f"completed: status={status} out_dir={args.out_dir}", flush=True)
            if downloaded:
                print("downloaded: " + ",".join(sorted(downloaded)), flush=True)
            return 0 if status == "success" else 1
        except BaseException:
            if proc.poll() is None:
                instance_id = state.get("instance_id")
                if instance_id:
                    terminate_instance(args, instance_id, progress_log)
                stop_launcher(proc, progress_log)
            raise
    except RunnerError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
