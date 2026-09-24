#!/usr/bin/env python3
"""Convert Swift Testing JSON event stream ABI v0 to Tiden ResultCreate rows.

ABI: https://github.com/swiftlang/swift-testing/blob/main/Documentation/ABI/JSON.md
Test.ID: https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Test.ID.swift
"""

import argparse
import json
import math
import sys
import uuid
from pathlib import Path


class ReportError(Exception):
    pass


EVENT_KINDS = {
    "runStarted", "runEnded", "testStarted", "testEnded", "testSkipped",
    "testCaseStarted", "testCaseEnded", "issueRecorded", "valueAttached",
}


def require(condition, message):
    if not condition:
        raise ReportError(message)


def timestamp(event):
    instant = event.get("instant")
    require(isinstance(instant, dict), "event has no instant")
    value = instant.get("absolute")
    require(type(value) in (int, float) and math.isfinite(value), "invalid event instant")
    return value


def identity(test, package_root):
    test_id = test.get("id")
    name = test.get("name")
    source = test.get("sourceLocation")
    require(isinstance(test_id, str) and isinstance(name, str) and name,
            "test definition has no stable identity")
    require(isinstance(source, dict), f"test {test_id}: missing source location")
    line, column = source.get("line"), source.get("column")
    require(type(line) is int and line > 0 and type(column) is int and column > 0,
            f"test {test_id}: invalid source location")
    require("." in test_id, f"test {test_id}: unknown ID form")
    module, remainder = test_id.split(".", 1)
    parts = remainder.split("/")
    require(module and len(parts) >= 2 and all(parts), f"test {test_id}: unknown ID form")
    location_suffix = parts.pop()
    require(parts[-1] == name, f"test {test_id}: name does not match ID")
    file_id = source.get("fileID")
    file_path = source.get("filePath")
    legacy_file_path = source.get("_filePath")
    require(file_path is None or isinstance(file_path, str),
            f"test {test_id}: invalid filePath")
    require(legacy_file_path is None or isinstance(legacy_file_path, str),
            f"test {test_id}: invalid _filePath")
    require(not (file_path and legacy_file_path) or file_path == legacy_file_path,
            f"test {test_id}: conflicting source paths")
    file_path = file_path or legacy_file_path
    if file_id is not None:
        require(isinstance(file_id, str) and "/" in file_id,
                f"test {test_id}: invalid fileID")
        file_module, file_name = file_id.split("/", 1)
        require(file_module == module and file_name and Path(file_name).name == file_name,
                f"test {test_id}: fileID does not match module")
    elif isinstance(file_path, str) and file_path:
        file_name = Path(file_path).name
    else:
        raise ReportError(f"test {test_id}: no source file")
    require(location_suffix == f"{file_name}:{line}:{column}",
            f"test {test_id}: source location does not match ID")

    tests_root = (package_root / "Tests" / module).resolve()
    if isinstance(file_path, str) and file_path:
        candidate = Path(file_path)
        if not candidate.is_absolute():
            candidate = package_root / candidate
        candidate = candidate.resolve()
        if candidate.is_file() and candidate.is_relative_to(tests_root):
            source_file = candidate
        else:
            source_file = None
    else:
        source_file = None
    if source_file is None:
        matches = list(tests_root.rglob(file_name)) if tests_root.is_dir() else []
        require(len(matches) == 1, f"test {test_id}: source file is missing or ambiguous")
        source_file = matches[0].resolve()
    require(source_file.name == file_name and source_file.is_relative_to(tests_root)
            and source_file.is_relative_to(package_root),
            f"test {test_id}: source file does not match ID")
    suite_parts = [module, *parts[:-1]]
    signature = "::".join([*suite_parts, parts[-1]])
    return signature, suite_parts, source_file.relative_to(package_root).as_posix()


def convert(stream_path, package_root, process_exit_code=0):
    package_root = package_root.resolve()
    require(process_exit_code >= 0, "test process exit code must be nonnegative")
    require(package_root.is_dir(), "package root does not exist")
    try:
        content = stream_path.read_bytes()
    except OSError as error:
        raise ReportError(f"cannot read event stream: {error.strerror}") from error
    require(content and content.endswith(b"\n"), "empty or truncated event stream")
    definitions = {}
    suite_ids = set()
    run_start = run_end = None
    run_failed = False
    for number, raw_line in enumerate(content.splitlines(), 1):
        try:
            record = json.loads(raw_line)
        except (ValueError, UnicodeDecodeError) as error:
            raise ReportError(f"line {number}: invalid JSON") from error
        require(isinstance(record, dict) and type(record.get("version")) is int
                and record["version"] == 0, f"line {number}: unknown event schema/version")
        record_kind = record.get("kind")
        payload = record.get("payload")
        require(record_kind in ("test", "event") and isinstance(payload, dict),
                f"line {number}: unknown record schema")
        if record_kind == "test":
            test_kind = payload.get("kind")
            require(test_kind in ("suite", "function"),
                    f"line {number}: unknown test definition")
            if test_kind == "suite":
                suite_id = payload.get("id")
                require(isinstance(suite_id, str) and suite_id and suite_id not in suite_ids,
                        f"line {number}: invalid suite ID")
                suite_ids.add(suite_id)
                continue
            signature, suites, file_path = identity(payload, package_root)
            test_id = payload["id"]
            require(test_id not in definitions, f"line {number}: duplicate test ID")
            require(signature not in (item["signature"] for item in definitions.values()),
                    f"line {number}: duplicate stable signature {signature}")
            definitions[test_id] = {
                "signature": signature, "title": payload["name"],
                "suites": suites, "file_path": file_path,
                "start": None, "end": None, "skipped": False, "failed": False,
                "case_starts": 0, "case_ends": 0, "skip_at": None,
            }
            continue

        kind = payload.get("kind")
        require(kind in EVENT_KINDS, f"line {number}: unknown event kind {kind!r}")
        at = timestamp(payload)
        messages = payload.get("messages", [])
        require(isinstance(messages, list), f"line {number}: invalid messages")
        for message in messages:
            require(isinstance(message, dict) and isinstance(message.get("symbol"), str),
                    f"line {number}: invalid message")
        has_failure_message = any(message["symbol"] == "fail" for message in messages)
        test_id = payload.get("testID")
        if kind == "runStarted":
            require(test_id is None and run_start is None and run_end is None,
                    f"line {number}: duplicate or attributed run start")
            run_start = at
            continue
        require(run_start is not None and run_end is None,
                f"line {number}: event outside run")
        if kind == "runEnded":
            require(test_id is None and at >= run_start,
                    f"line {number}: invalid run end")
            run_end = at
            run_failed = has_failure_message
            continue
        require(isinstance(test_id, str) and test_id,
                f"line {number}: unattributed test event")
        if test_id not in definitions:
            # Swift Testing emits suite lifecycle events; only functions become rows.
            require(test_id in suite_ids and kind in
                    ("testStarted", "testEnded", "testSkipped", "valueAttached"),
                    f"line {number}: event has unknown test ID")
            continue
        item = definitions[test_id]
        require(item["end"] is None, f"line {number}: event after test end")
        if has_failure_message:
            item["failed"] = True
        if kind == "testStarted":
            require(item["start"] is None, f"line {number}: duplicate test start")
            item["start"] = at
        elif kind == "testCaseStarted":
            require(item["start"] is not None and at >= item["start"],
                    f"line {number}: case started outside test")
            item["case_starts"] += 1
        elif kind == "testCaseEnded":
            require(item["case_ends"] < item["case_starts"],
                    f"line {number}: unmatched case end")
            item["case_ends"] += 1
        elif kind == "issueRecorded":
            issue = payload.get("issue")
            require(isinstance(issue, dict) and type(issue.get("isKnown")) is bool,
                    f"line {number}: invalid issue")
            if "isFailure" in issue:
                require(type(issue["isFailure"]) is bool, f"line {number}: invalid issue failure flag")
                item["failed"] |= issue["isFailure"]
            else:
                item["failed"] |= not issue["isKnown"]
        elif kind == "testSkipped":
            item["skipped"] = True
            item["skip_at"] = at
        elif kind == "testEnded":
            require(item["start"] is not None and at >= item["start"],
                    f"line {number}: test ended without start")
            item["end"] = at
        # valueAttached carries no outcome.

    require(run_start is not None and run_end is not None, "missing run start or end")
    require(definitions, "no test definitions in event stream")
    rows = []
    for test_id, item in definitions.items():
        require(item["case_starts"] == item["case_ends"],
                f"test {test_id}: unmatched parameterized case events")
        require(item["end"] is not None or
                (item["skipped"] and item["case_starts"] == 0),
                f"test {test_id}: no terminal outcome")
        if item["end"] is not None:
            duration = round((item["end"] - item["start"]) * 1000)
        elif item["start"] is not None:
            duration = round((item["skip_at"] - item["start"]) * 1000)
        else:
            duration = 0
        require(duration >= 0, f"test {test_id}: negative duration")
        if item["failed"]:
            status = "failed"
        elif item["skipped"] and item["case_starts"] == 0:
            status = "skipped"
        else:
            status = "passed"
        rows.append({
            "id": str(uuid.uuid4()), "title": item["title"],
            "signature": item["signature"],
            "execution": {"status": status, "duration": duration},
            "suitePath": [{"title": title} for title in item["suites"]],
            "fields": {"file_path": item["file_path"]},
        })
    require(any(row["execution"]["status"] != "skipped" for row in rows),
            "no executed tests (all skipped)")
    require(not (process_exit_code != 0 or run_failed) or
            any(row["execution"]["status"] == "failed" for row in rows),
            "test process/run failed without an attributed failed test")
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stream", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("package_root", type=Path)
    parser.add_argument("process_exit_code", nargs="?", type=int, default=0)
    args = parser.parse_args()
    try:
        rows = convert(args.stream, args.package_root.resolve(), args.process_exit_code)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temp = args.output.with_name(args.output.name + ".tmp")
        temp.write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
        temp.replace(args.output)
    except (ReportError, OSError) as error:
        print(f"Swift Testing report rejected: {error}", file=sys.stderr)
        return 1
    counts = {status: sum(row["execution"]["status"] == status for row in rows)
              for status in ("passed", "failed", "skipped")}
    print(f"Swift Testing report: {counts['passed']} passed, {counts['failed']} failed, "
          f"{counts['skipped']} skipped -> {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
