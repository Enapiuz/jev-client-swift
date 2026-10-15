# Testing

Run the package's Swift Testing suite through `Scripts/test.sh`:

```sh
Scripts/test.sh
Scripts/test.sh --filter ModelTests
```

Arguments are forwarded to `swift test`. The runner writes local artifacts and
does not update a tracker without its legacy `--tiden` option. **Codex must not
use `--tiden`**: ongoing work belongs to Intentor project `JEV`, as recorded in
[`AGENTS.md`](../AGENTS.md).

The package has no Python dependency. The artifact runner requires Python 3.9 or
newer. Without Python, run Swift Testing directly:

```sh
swift test
```

## Platform checks

Use the installed Swift 6.4 toolchain. On macOS or Linux:

```sh
Scripts/test.sh
swift build -c release
```

Keep the compiler distribution consistent when checking compiled examples:
Swiftly's `swift`/`swiftc` and Xcode's `xcrun swiftc` can report the same language
version while producing incompatible binary modules. Discover the package's
module directory with `swift build --show-bin-path` instead of assuming
`.build/debug/Modules`; Swift Build can use `.build/out/Products/Debug`.

In a restricted agent environment, SwiftPM may need `--disable-sandbox` and
writable cache paths for its nested build processes. Xcode may require access to
its normal services and caches outside that environment. A sandbox failure before
package discovery or compilation is not a source diagnostic; preserve the failed
log and rerun the scoped check with appropriate access rather than changing the
package's compiler or OS minimums.

On macOS with the iOS SDK, compile the package and its DocC catalog:

```sh
xcodebuild -scheme JevClient -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme JevClient -destination 'generic/platform=iOS' \
  -derivedDataPath .build/docc CODE_SIGNING_ALLOWED=NO docbuild
```

The suite includes model/validation, captured HTTP requests and loopback URLSession
checks. Experimental tests cover multipart/base64 image requests, explicit flags,
header overrides, retry replay and Box geometry. The SDK leaves image decoding,
dimensions and final processed/expanded size to the service; local fixture
success does not prove those service checks or model accuracy. iOS and DocC
builds are compile/documentation evidence, not runtime acceptance. Authenticated
paid calls, hosted CI and publication are separate from these local checks.

## Local artifacts and legacy reporting

Each normal invocation keeps its Swift Testing JSONL stream, xUnit XML and a
converted legacy report in a unique directory under `.build/test-results`. Set
`JEV_TEST_RESULTS_DIR` to choose another artifact parent, or `SWIFT_COMMAND` to
select a Swift executable. The runner uses `--disable-xctest` so the stream
represents the entire selected test engine. It preserves a failing test exit
status and rejects incomplete conversion.

The optional Tiden integration is retained for historical/Claude-side use.
`--tiden` creates a run in an active Tiden session, reports results and completes
the run; it can write responses alongside the artifacts. That integration is
outside Codex's workflow. The format details below describe the existing
converter, not an instruction to create or update Tiden records.

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

This checks the conversion rules with schema-shaped fixtures. A normal
`Scripts/test.sh` execution verifies the installed Swift runner and conversion.
It makes no claim about live legacy tracker integration.
