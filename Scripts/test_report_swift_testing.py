"""Schema-faithful Swift Testing ABI v0 fixtures for the Tiden bridge."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from report_swift_testing import ReportError, convert


TEST_ID = "JevClientTests.ModelTests/jsonPreservesIntegers()/ModelTests.swift:7:5"


def record(kind, payload):
    return {"version": 0, "kind": kind, "payload": payload}


def event(kind, second, test_id=None, **fields):
    payload = {
        "kind": kind,
        "instant": {"absolute": second, "since1970": 1_700_000_000 + second},
        "messages": [],
        **fields,
    }
    if test_id is not None:
        payload["testID"] = test_id
    return record("event", payload)


class SwiftTestingReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = self.root / "Tests/JevClientTests/ModelTests.swift"
        source.parent.mkdir(parents=True)
        source.write_text("// fixture\n", encoding="utf-8")
        self.stream = self.root / "events.jsonl"
        self.definition = record("test", {
            "kind": "function", "id": TEST_ID, "name": "jsonPreservesIntegers()",
            "isParameterized": True,
            "sourceLocation": {
                "fileID": "JevClientTests/ModelTests.swift",
                "line": 7, "column": 5,
            },
        })

    def write(self, records):
        self.stream.write_text("".join(json.dumps(item) + "\n" for item in records),
                               encoding="utf-8")

    def successful_run(self):
        return [
            self.definition,
            event("runStarted", 1),
            event("testStarted", 2, TEST_ID),
            event("testCaseStarted", 2.1, TEST_ID),
            event("testCaseEnded", 2.4, TEST_ID),
            event("testEnded", 2.5, TEST_ID),
            event("runEnded", 3),
        ]

    def test_parameterized_failure_preserves_definition_identity_and_duration(self):
        records = self.successful_run()
        records[5:5] = [
            event("testCaseStarted", 2.45, TEST_ID),
            event("issueRecorded", 2.48, TEST_ID,
                  issue={"isKnown": False}),
            event("testCaseEnded", 2.8, TEST_ID),
        ]
        records[8]["payload"]["instant"]["absolute"] = 2.9
        self.write(records)
        rows = convert(self.stream, self.root, 1)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["signature"],
                         "JevClientTests::ModelTests::jsonPreservesIntegers()")
        self.assertEqual(row["execution"], {"status": "failed", "duration": 900})
        self.assertEqual(row["suitePath"],
                         [{"title": "JevClientTests"}, {"title": "ModelTests"}])
        self.assertEqual(row["fields"],
                         {"file_path": "Tests/JevClientTests/ModelTests.swift"})

    def test_rejects_empty_incomplete_unknown_and_unattributed_process_failure(self):
        bad_streams = (
            [],
            self.successful_run()[:-1],
            [*self.successful_run()[:-2], event("runEnded", 3)],
            [*self.successful_run()[:-1], event("unfamiliarEvent", 3)],
            [{**self.definition, "version": 1}, *self.successful_run()[1:]],
        )
        for records in bad_streams:
            with self.subTest(records=len(records)):
                self.write(records)
                with self.assertRaises(ReportError):
                    convert(self.stream, self.root)
        self.write(self.successful_run())
        with self.assertRaisesRegex(ReportError, "without an attributed failed test"):
            convert(self.stream, self.root, 1)

    def test_rejects_only_skips_and_identity_mismatch(self):
        records = [
            self.definition,
            event("runStarted", 1),
            event("testSkipped", 2, TEST_ID),
            event("runEnded", 3),
        ]
        self.write(records)
        with self.assertRaisesRegex(ReportError, "all skipped"):
            convert(self.stream, self.root)
        records[0]["payload"]["name"] = "renamed()"
        self.write(records)
        with self.assertRaisesRegex(ReportError, "name does not match ID"):
            convert(self.stream, self.root)

    def test_relocated_absolute_source_path_uses_file_id(self):
        self.definition["payload"]["sourceLocation"]["filePath"] = (
            "/workspace/JevClient/Tests/JevClientTests/ModelTests.swift"
        )
        self.write(self.successful_run())
        rows = convert(self.stream, self.root)
        self.assertEqual(rows[0]["fields"]["file_path"],
                         "Tests/JevClientTests/ModelTests.swift")

    def test_legacy_file_path_disambiguates_duplicate_basenames(self):
        nested = self.root / "Tests/JevClientTests/Nested/ModelTests.swift"
        nested.parent.mkdir(parents=True)
        nested.write_text("// nested fixture\n", encoding="utf-8")
        self.definition["payload"]["sourceLocation"]["_filePath"] = str(nested)
        self.write(self.successful_run())
        rows = convert(self.stream, self.root)
        self.assertEqual(rows[0]["fields"]["file_path"],
                         "Tests/JevClientTests/Nested/ModelTests.swift")

    def test_bash_launcher_forwards_zero_or_spaced_arguments_and_keeps_failure(self):
        fake_swift = self.root / "fake-swift"
        fake_swift.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['FAKE_SWIFT_ARGS'], 'w', encoding='utf-8') as output:\n"
            "    json.dump(sys.argv[1:], output)\n"
            "sys.exit(47)\n",
            encoding="utf-8",
        )
        fake_swift.chmod(0o755)
        launcher = Path(__file__).resolve().parent / "test.sh"
        for index, forwarded in enumerate(([], ["--filter", "Suite name with spaces"])):
            with self.subTest(forwarded=forwarded):
                argv_path = self.root / f"args-{index}.json"
                environment = os.environ.copy()
                environment.update({
                    "SWIFT_COMMAND": str(fake_swift),
                    "FAKE_SWIFT_ARGS": str(argv_path),
                    "JEV_TEST_RESULTS_DIR": str(self.root / "run-results"),
                    "PYTHONDONTWRITEBYTECODE": "1",
                })
                completed = subprocess.run(
                    ["/bin/bash", str(launcher), *forwarded],
                    cwd=self.root, env=environment, capture_output=True, text=True,
                    timeout=30, check=False,
                )
                self.assertTrue(argv_path.is_file(), completed.stderr)
                argv = json.loads(argv_path.read_text(encoding="utf-8"))
                self.assertEqual(argv[:4],
                                 ["test", "--disable-xctest", "--event-stream-version", "0"])
                self.assertEqual(argv[4], "--event-stream-output-path")
                self.assertEqual(argv[6], "--xunit-output")
                self.assertEqual(argv[8:], forwarded)
                self.assertIn("Swift Testing report rejected:", completed.stderr)
                self.assertEqual(completed.returncode, 47, completed.stderr)


if __name__ == "__main__":
    unittest.main()
