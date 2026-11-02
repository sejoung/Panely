"""Check runner orchestration without building Xcode projects or fetching models."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


PROJECT = Path(__file__).resolve().parents[2]


class TestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="panely-runner-tests-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.records = self.root / "invocations.jsonl"
        self.results = self.root / "results with spaces"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "xcodebuild"
        stub.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
            import json, os, pathlib, sys
            if '-version' in sys.argv:
                print('Xcode test fixture')
                sys.exit(0)
            records = pathlib.Path(os.environ['PANELY_RUNNER_STUB_RECORDS'])
            count = len(records.read_text().splitlines()) if records.exists() else 0
            args = sys.argv[1:]
            entry = {'args': args, 'flags': {k: v for k, v in os.environ.items() if k.startswith('TEST_RUNNER_')}}
            with records.open('a') as output:
                output.write(json.dumps(entry) + '\\n')
            bundle = pathlib.Path(args[args.index('-resultBundlePath') + 1])
            bundle.mkdir()
            (bundle / 'test-result.txt').write_text('stub result')
            print('unfiltered diagnostic details', flush=True)
            if count + 1 == int(os.environ.get('PANELY_RUNNER_STUB_FAIL_AT', '0')):
                sys.exit(65)
            if args[0] == 'build':
                app = pathlib.Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Release/Panely.app'
                (app / 'Contents/MacOS').mkdir(parents=True)
                (app / 'Contents/MacOS/Panely').write_text('fixture executable')
                print('** BUILD SUCCEEDED **')
                sys.exit(0)
            if os.environ.get('PANELY_RUNNER_STUB_QUIET') != '1':
                print('✔ Test run with 1 test passed.')
                print('** TEST SUCCEEDED **')
        '''))
        stub.chmod(0o755)
        for name in ('lipo', 'codesign'):
            verification = bin_dir / name
            verification.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                import json, os, pathlib, sys
                tool = pathlib.Path(sys.argv[0]).name
                records = pathlib.Path(os.environ['PANELY_RUNNER_STUB_RECORDS']).with_name('verifications.jsonl')
                with records.open('a') as output:
                    output.write(json.dumps({'tool': tool, 'args': sys.argv[1:]}) + '\\n')
                target = sys.argv[1] if tool == 'lipo' else sys.argv[-1]
                if not pathlib.Path(target).exists():
                    sys.exit(7)
                sys.exit(int(os.environ.get('PANELY_VERIFY_FAIL_' + tool.upper(), '0')))
            '''))
            verification.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                                PANELY_RUNNER_STUB_RECORDS=str(self.records))

    def run_script(self, *args, script="test.sh", flags=None):
        environment = dict(self.environment, **(flags or {}))
        return subprocess.run(
            ["/bin/bash", str(PROJECT / "scripts" / script),
             "--derived-data", str(self.root / "build cache"),
             "--results-dir", str(self.results), *args],
            env=environment, text=True, capture_output=True, timeout=20,
        )

    def invocations(self):
        return [json.loads(line) for line in self.records.read_text().splitlines()] if self.records.exists() else []

    def test_repeats_are_separate_processes_with_unique_logs_and_bundles(self):
        result = self.run_script("--repeat", "3", "--only", "TranslationControllerTests")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.invocations()
        self.assertEqual([c['args'][0] for c in calls], ['test', 'test-without-building', 'test-without-building'])
        for call in calls:
            self.assertIn('-only-testing:PanelyTests/TranslationControllerTests', call['args'])
            self.assertEqual(call['args'][call['args'].index('-configuration') + 1], 'Debug')
        self.assertEqual(len(list(self.results.glob('*/run-*.log'))), 3)
        self.assertEqual(len(list(self.results.glob('*/run-*.xcresult'))), 3)
        self.assertEqual(len(list(self.results.glob('*/run-*.command'))), 3)

    def test_failure_keeps_xcodebuild_exit_code_and_stops_repetition(self):
        result = self.run_script("--repeat", "5", flags={'PANELY_RUNNER_STUB_FAIL_AT': '2'})
        self.assertEqual(result.returncode, 65)
        self.assertEqual(len(self.invocations()), 2)
        self.assertIn('Run 2 failed (exit 65)', result.stderr)
        self.assertIn('unfiltered diagnostic details', next(self.results.glob('*/run-2.log')).read_text())

    def test_no_matching_console_output_does_not_create_a_failure(self):
        result = self.run_script(flags={'PANELY_RUNNER_STUB_QUIET': '1'})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_skip_build_and_legacy_arguments_are_forwarded_literally(self):
        sentinel = self.root / 'must not be created'
        setting = f'CUSTOM_SETTING=$(touch "{sentinel}")'
        result = self.run_script('--skip-build', '-only-testing:PanelyTests/DebouncerTests', setting)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.invocations()[0]['args']
        self.assertEqual(args[0], 'test-without-building')
        self.assertIn(setting, args)
        self.assertIn('-only-testing:PanelyTests/DebouncerTests', args)
        self.assertFalse(sentinel.exists())

    def test_clean_build_applies_only_to_the_first_run(self):
        result = self.run_script('--clean', '--repeat', '2')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.invocations()
        self.assertEqual(calls[0]['args'][:2], ['clean', 'test'])
        self.assertEqual(calls[1]['args'][0], 'test-without-building')

    def test_bad_options_fail_before_starting_xcodebuild(self):
        for args in [('--repeat', '0'), ('--repeat', '-1'), ('--repeat', '101'), ('--repeat', 'abc'),
                     ('--repeat',), ('--only',), ('--clean', '--skip-build'),
                     ('--configuration', 'Unknown'), ('--unknown',), ('-test-iterations', '5')]:
            with self.subTest(args=args):
                result = self.run_script(*args)
                self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.invocations(), [])

    def test_tier_wrappers_share_the_runner_and_keep_their_environment(self):
        for script, option, expected in [
            ('test-slow.sh', 'TEST_RUNNER_PANELY_SLOW_TESTS', '1'),
            ('test-visual.sh', 'TEST_RUNNER_PANELY_VISUAL_TESTS', '1'),
            ('test-ocr.sh', 'TEST_RUNNER_PANELY_TEST_COMIC_OCR', '1'),
        ]:
            with self.subTest(script=script):
                result = self.run_script('--only', 'SelectedSuite', script=script)
                self.assertEqual(result.returncode, 0, result.stderr)
                call = self.invocations()[-1]
                self.assertEqual(call['flags'][option], expected)
                self.assertIn('-only-testing:PanelyTests/SelectedSuite', call['args'])
                if script == 'test-visual.sh':
                    self.assertNotIn('-only-testing:PanelyTests/VisualRegressionTests', call['args'])

    def test_release_check_builds_both_architectures_and_verifies_the_app(self):
        result = self.run_script(script='check-release.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.invocations()[0]['args']
        self.assertEqual(args[0], 'build')
        self.assertEqual(args[args.index('-configuration') + 1], 'Release')
        self.assertEqual(args[args.index('-destination') + 1], 'generic/platform=macOS')
        self.assertIn('ARCHS=arm64 x86_64', args)
        self.assertIn('ONLY_ACTIVE_ARCH=NO', args)
        self.assertFalse(any('Onone' in arg for arg in args))
        checks = [json.loads(line) for line in (self.root / 'verifications.jsonl').read_text().splitlines()]
        self.assertEqual([c['tool'] for c in checks], ['lipo', 'lipo', 'codesign'])
        self.assertEqual(checks[0]['args'][1:], ['-verify_arch', 'arm64'])
        self.assertEqual(checks[1]['args'][1:], ['-verify_arch', 'x86_64'])
        self.assertIn('unfiltered diagnostic details', next(self.results.glob('*/build.log')).read_text())
        self.assertTrue(next(self.results.glob('*/build.xcresult')).is_dir())
        self.assertTrue(next(self.results.glob('*/build.command')).is_file())
        self.assertTrue(next(self.results.glob('*/toolchain.log')).is_file())

    def test_release_build_failure_preserves_exit_code_and_skips_verification(self):
        result = self.run_script(script='check-release.sh', flags={'PANELY_RUNNER_STUB_FAIL_AT': '1'})
        self.assertEqual(result.returncode, 65)
        self.assertIn('exit 65', result.stderr)
        self.assertFalse((self.root / 'verifications.jsonl').exists())
        self.assertIn('unfiltered diagnostic details', next(self.results.glob('*/build.log')).read_text())

    def test_release_check_rejects_a_missing_architecture(self):
        result = self.run_script(script='check-release.sh', flags={'PANELY_VERIFY_FAIL_LIPO': '42'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing a required architecture', result.stderr)


if __name__ == '__main__':
    unittest.main()
