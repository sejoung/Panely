#!/usr/bin/env python3
"""Select, generate, validate and copy manual captures. Standard library only."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib


PROJECT_ROOT = Path(__file__).resolve().parent.parent
CATALOG = Path(__file__).with_name("manual-snapshots.json")
CACHE_ROOT = (
    Path.home() / "Library/Containers/io.github.sejoung.Panely.debug"
    / "Data/Library/Caches/panely-snapshots"
)


def load_catalog(path=CATALOG):
    captures = json.loads(path.read_text())["captures"]
    if not captures:
        raise ValueError("The capture catalog is empty")
    ids, tests, files = set(), set(), set()
    for capture in captures:
        name, test, outputs = capture["id"], capture["test"], capture["files"]
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name) or name in ids:
            raise ValueError(f"Invalid or duplicate capture id: {name}")
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", test) or test in tests:
            raise ValueError(f"Invalid or duplicate capture test: {test}")
        if not outputs:
            raise ValueError(f"No output files for {name}")
        for file in outputs:
            if not re.fullmatch(r"[0-9]{2}-[a-z0-9-]+\.png", file) or file in files:
                raise ValueError(f"Invalid or duplicate output file: {file}")
            files.add(file)
        ids.add(name)
        tests.add(test)
    return captures


def select_captures(captures, selectors):
    if not selectors:
        return captures
    selected = set()
    for token in selectors:
        matches = []
        for capture in captures:
            aliases = {capture["id"], capture["test"]}
            for file in capture["files"]:
                aliases.update([file, Path(file).stem, file.split("-", 1)[0]])
            if token in aliases:
                matches.append(capture["id"])
        if not matches:
            raise ValueError(f"Unknown capture: {token}. Use --list to see available captures.")
        selected.update(matches)
    return [capture for capture in captures if capture["id"] in selected]


def build_command(captures, derived_data):
    return [
        "xcodebuild", "test", "-project", "Panely.xcodeproj", "-scheme", "Panely",
        "-destination", "platform=macOS", "-derivedDataPath", str(derived_data),
        "-parallel-testing-enabled", "NO",
        # Swift Testing method filters need the trailing parentheses.
        *[f"-only-testing:PanelyTests/SnapshotGalleryTests/{c['test']}()" for c in captures],
        "CODE_SIGN_IDENTITY=-",
    ]


def run_xcodebuild(command, env, log_path):
    with log_path.open("w") as log:
        process = subprocess.Popen(
            command, cwd=PROJECT_ROOT, env=env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, bufsize=1,
        )
        try:
            for line in process.stdout:
                log.write(line)
                log.flush()
                if any(word in line for word in ("📸", "error:", "✘", "✔ Test", "** TEST")):
                    if "com.apple.linkd.autoShortcut" not in line:
                        print(line, end="", flush=True)
            code = process.wait()
        except KeyboardInterrupt:
            process.terminate()
            process.wait()
            raise
    if code:
        raise RuntimeError(f"xcodebuild failed ({code}). Full log: {log_path}")


def validate_outputs(staging, captures):
    expected = {file for capture in captures for file in capture["files"]}
    actual = {file.name for file in staging.glob("*.png")}
    if actual != expected:
        raise RuntimeError(
            f"Capture output mismatch. Missing: {sorted(expected - actual)}; "
            f"unexpected: {sorted(actual - expected)}. Staging: {staging}"
        )
    # Reject empty/truncated files before replacing any documentation images.
    for name in sorted(expected):
        if not valid_png((staging / name).read_bytes()):
            raise RuntimeError(f"Invalid PNG capture: {staging / name}")
    return sorted(expected)


def valid_png(data):
    if (len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n"
            or data[8:16] != b"\x00\x00\x00\x0dIHDR"
            or min(struct.unpack(">II", data[16:24])) == 0):
        return False
    offset, has_pixels = 8, False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        end = offset + 12 + length
        if end > len(data):
            return False
        kind = data[offset + 4:offset + 8]
        checksum = struct.unpack(">I", data[end - 4:end])[0]
        if zlib.crc32(data[offset + 4:end - 4]) != checksum:
            return False
        has_pixels |= kind == b"IDAT" and length > 0
        if kind == b"IEND":
            return has_pixels and length == 0 and end == len(data)
        offset = end
    return False


def generate(captures, output, derived_data, cache_root=CACHE_ROOT, dry_run=False):
    run_id = str(uuid.uuid4())
    staging = cache_root / "runs" / run_id
    command = build_command(captures, derived_data)
    print(f"Captures: {', '.join(c['id'] for c in captures)}")
    print(f"Output: {output}\nStaging: {staging}")
    if dry_run:
        print("TEST_RUNNER_PANELY_GENERATE_SNAPSHOTS=1 "
              f"TEST_RUNNER_PANELY_SNAPSHOT_RUN_ID={run_id} " + shlex.join(command))
        return
    env = os.environ.copy()
    env["TEST_RUNNER_PANELY_GENERATE_SNAPSHOTS"] = "1"
    env["TEST_RUNNER_PANELY_SNAPSHOT_RUN_ID"] = run_id
    descriptor, log_name = tempfile.mkstemp(prefix="panely-snapshots-", suffix=".log")
    os.close(descriptor)
    log_path = Path(log_name)
    print(f"Build log: {log_path}", flush=True)
    run_xcodebuild(command, env, log_path)
    files = validate_outputs(staging, captures)
    output.mkdir(parents=True, exist_ok=True)
    for name in files:
        # Stage beside the destination, then atomically replace that one file.
        descriptor, temporary = tempfile.mkstemp(prefix=".capture-", suffix=".png", dir=output)
        os.close(descriptor)
        try:
            shutil.copyfile(staging / name, temporary)
            os.replace(temporary, output / name)
        finally:
            Path(temporary).unlink(missing_ok=True)
        print(f"Saved {output / name}")
    shutil.rmtree(staging)
    print(f"Done: {len(files)} PNGs. Full log: {log_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="list capture ids and output files")
    parser.add_argument("--only", action="append", default=[], metavar="ID[,ID...]",
                        help="capture ids, test names, PNG names or two-digit numbers; repeatable")
    parser.add_argument("--output", type=Path, default=PROJECT_ROOT / "docs/screenshots",
                        help="destination directory (default: docs/screenshots)")
    parser.add_argument("--derived-data", type=Path,
                        default=Path(os.environ.get("PANELY_DERIVED_DATA_PATH", "/private/tmp/PanelyDerivedData")))
    parser.add_argument("--dry-run", action="store_true", help="show the command without running or writing")
    args = parser.parse_args()
    try:
        captures = load_catalog()
        selectors = [token.strip() for group in args.only for token in group.split(",")]
        captures = select_captures(captures, selectors)
        if args.list:
            for capture in captures:
                print(f"{capture['id']:<24} {', '.join(capture['files'])}")
            return 0
        generate(captures, args.output.resolve(), args.derived_data.resolve(), dry_run=args.dry_run)
        return 0
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Capture cancelled.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
