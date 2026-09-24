# Testing and Tiden reporting

Run the package's Swift Testing suite through `Scripts/test.sh`:

```sh
Scripts/test.sh --tiden
Scripts/test.sh --tiden --filter ModelTests
```

`--tiden` creates a run in the active Tiden intent session before `swift test`, reports its results, and completes the run. The installed Tiden CLI reads the repository's existing binding; the script contains no API token or endpoint. `tiden run create --require-session` fails before tests start when no session is active. Other arguments are forwarded to `swift test`. For a local run without a Tiden write, omit `--tiden`:

```sh
Scripts/test.sh --filter ModelTests
```

The Swift package itself has no Python dependency. `Scripts/test.sh` and the standalone report converter require Python 3.9 or newer; the runner checks this before creating a Tiden run or invoking tests. Environments without Python can still run the package directly with `swift test`, though that command does not produce a Tiden report.

Each invocation keeps its Swift Testing JSONL stream, xUnit XML, converted Tiden JSON, and any Tiden responses in a unique directory under `.build/test-results`. Set `JEV_TEST_RESULTS_DIR` to choose another artifact parent, `SWIFT_COMMAND` to select a Swift executable, or `TIDEN_RUN_TITLE` to choose the run title. The runner uses `--disable-xctest` so the stream represents the entire selected test engine. A failing `swift test` status remains the runner's exit status after results are uploaded. If conversion or upload fails, it aborts the Tiden run and exits nonzero; it does not upload an incomplete or guessed result.

The parser is also usable with a JSONL event stream produced by an external Swift 6.4 runner:

```sh
python3 Scripts/report_swift_testing.py path/to/events.jsonl path/to/results.json "$PWD" 0
```

The final argument is the actual `swift test` process exit code and defaults to `0` when omitted. The parser accepts [Swift Testing's version 0 JSON event stream](https://github.com/swiftlang/swift-testing/blob/main/Documentation/ABI/JSON.md), emitted with `--event-stream-version 0 --event-stream-output-path PATH`. It writes a bare JSON array of Tiden `ResultCreate` objects. It derives each signature from the [Swift Testing test ID format](https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Test.ID.swift): `JevClientTests.ModelTests/jsonPreservesIntegers()/ModelTests.swift:7:5` becomes `JevClientTests::ModelTests::jsonPreservesIntegers()`. The source offset identifies the Swift test record but is removed from the stable Tiden signature. The stream's `sourceLocation.filePath` or version 0 `_filePath` supplies the repository relative `fields.file_path`; `fileID` is a fallback when an absolute build path points outside the current package checkout. Suite names form the root first `suitePath`.

One result is reported per test function. Parameterized case events and issues aggregate into that function's outcome, with failure taking precedence over skip and pass. Duration is measured between its `testStarted` and `testEnded` instants, in milliseconds. Tiden's CLI accepts only `id`, `title`, `signature`, `execution`, `suitePath`, and `fields` for these rows, so failure details remain in the JSONL and XML artifacts. The parser rejects an empty, incomplete, unknown version or event schema, identity mismatch, missing terminal outcome, skip only run, or nonzero test process exit without an attributed failed test. It never silently falls back to XML.

The reporting fixture check is:

```sh
python3 -m unittest discover -s Scripts -p 'test_report_swift_testing.py'
```

This checks the conversion rules with schema shaped fixtures. A real Swift Testing execution through `Scripts/test.sh --tiden` is still required to verify the installed toolchain and live Tiden integration. Build or fixture success alone does not establish that live report.
