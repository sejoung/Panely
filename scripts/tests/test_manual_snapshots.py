"""Capture selection and failed-run protection without launching Xcode."""

from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import re
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib


SCRIPT = Path(__file__).resolve().parents[1] / "manual-snapshots.py"
spec = importlib.util.spec_from_file_location("manual_snapshots", SCRIPT)
snapshots = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshots)


def sample_png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\x00\xff\xff\xff"))
            + chunk(b"IEND", b""))


class ManualSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.captures = snapshots.load_catalog()
        self.selection = snapshots.select_captures(self.captures, ["25"])

    def test_catalog_matches_all_gallery_tests_and_outputs(self):
        gallery = (snapshots.PROJECT_ROOT / "PanelyTests/Snapshots/SnapshotGalleryTests.swift").read_text()
        self.assertEqual({c["test"] for c in self.captures}, set(re.findall(r"@Test func (\w+)\(", gallery)))
        self.assertEqual({f for c in self.captures for f in c["files"]},
                         set(re.findall(r'"([0-9]{2}-[a-z0-9-]+\.png)"', gallery)))

    def test_selecting_either_frame_selects_the_whole_gesture_once(self):
        selected = snapshots.select_captures(self.captures, ["26", "balloon-add", "25-translation-drag-selection.png"])
        self.assertEqual(selected, self.selection)
        command = snapshots.build_command(selected, Path("/tmp/DerivedData with spaces"))
        filters = [arg for arg in command if arg.startswith("-only-testing:")]
        self.assertEqual(filters, ["-only-testing:PanelyTests/SnapshotGalleryTests/addingMissedBalloon()"])
        self.assertIn("/tmp/DerivedData with spaces", command)

    def test_unknown_selection_fails_instead_of_running_everything(self):
        with self.assertRaisesRegex(ValueError, "Unknown capture"):
            snapshots.select_captures(self.captures, ["missing"])

    def run_generation(self, make_outputs, directory):
        cache, output = directory / "cache", directory / "output"

        def fake_xcode(command, env, log):
            run_id = env["TEST_RUNNER_PANELY_SNAPSHOT_RUN_ID"]
            staging = cache / "runs" / run_id
            staging.mkdir(parents=True)
            make_outputs(staging)

        with patch.object(snapshots, "run_xcodebuild", side_effect=fake_xcode), redirect_stdout(io.StringIO()):
            snapshots.generate(self.selection, output, directory / "derived", cache_root=cache)

    def test_a_partial_run_never_uses_old_images_or_overwrites_docs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            names = self.selection[0]["files"]
            old = root / "cache/runs/old"
            output = root / "output"
            old.mkdir(parents=True)
            output.mkdir()
            for name in names:
                (old / name).write_bytes(sample_png())
                (output / name).write_bytes(b"existing documentation")
            with self.assertRaisesRegex(RuntimeError, "Missing"):
                self.run_generation(lambda staging: (staging / names[0]).write_bytes(sample_png()), root)
            self.assertTrue(all((output / name).read_bytes() == b"existing documentation" for name in names))

    def test_truncated_png_prevents_all_copies(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def write(staging):
                for name in self.selection[0]["files"]:
                    (staging / name).write_bytes(sample_png())
                (staging / self.selection[0]["files"][-1]).write_bytes(sample_png()[:-5])

            with self.assertRaisesRegex(RuntimeError, "Invalid PNG"):
                self.run_generation(write, root)
            self.assertFalse((root / "output").exists())

    def test_success_copies_only_selected_images(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "output"
            output.mkdir()
            (output / "unrelated.png").write_bytes(b"keep")

            def write(staging):
                for name in self.selection[0]["files"]:
                    (staging / name).write_bytes(sample_png())

            self.run_generation(write, root)
            for name in self.selection[0]["files"]:
                self.assertEqual((output / name).read_bytes(), sample_png())
            self.assertEqual((output / "unrelated.png").read_bytes(), b"keep")
            self.assertFalse(list(output.glob(".capture-*")))

    def test_failed_build_never_copies_outputs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.object(snapshots, "run_xcodebuild", side_effect=RuntimeError("build failed")), redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "build failed"):
                    snapshots.generate(self.selection, root / "output", root / "derived", cache_root=root / "cache")
            self.assertFalse((root / "output").exists())

    def test_unexpected_output_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)

            def write(staging):
                for name in self.selection[0]["files"]:
                    (staging / name).write_bytes(sample_png())
                (staging / "unexpected.png").write_bytes(sample_png())

            with self.assertRaisesRegex(RuntimeError, "unexpected.png"):
                self.run_generation(write, root)
            self.assertFalse((root / "output").exists())


if __name__ == "__main__":
    unittest.main()
