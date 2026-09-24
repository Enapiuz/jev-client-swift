#!/usr/bin/env bash
# Run Swift Testing with durable local artifacts and optional Tiden reporting.
set -u

package_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P) || exit 1
cd "$package_root" || exit 1

report_tiden=0
test_args=()
for arg in "$@"; do
    if [[ "$arg" == --tiden ]]; then
        report_tiden=1
        continue
    fi
    case "$arg" in
        --event-stream-output-path|--event-stream-output-path=*|--event-stream-version|--event-stream-version=*|--xunit-output|--xunit-output=*|--disable-swift-testing|--enable-xctest)
            printf 'Reserved Swift Testing reporting option: %s\n' "$arg" >&2
            exit 2
            ;;
    esac
    test_args+=("$arg")
done

if ! command -v python3 >/dev/null 2>&1 ||
   ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
    printf 'Scripts/test.sh requires Python 3.9+ for Swift Testing result reporting. Install it or run swift test directly.\n' >&2
    exit 2
fi

swift_command=${SWIFT_COMMAND:-swift}
results_root=${JEV_TEST_RESULTS_DIR:-.build/test-results}
if ! mkdir -p "$results_root"; then
    printf 'Cannot create test results directory: %s\n' "$results_root" >&2
    exit 1
fi
artifact_dir=$(mktemp -d "$results_root/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || exit 1
artifact_dir=$(cd "$artifact_dir" && pwd -P) || exit 1
stream_path="$artifact_dir/events.jsonl"
xunit_path="$artifact_dir/tests.xml"
report_path="$artifact_dir/results.json"
printf 'Test artifacts: %s\n' "$artifact_dir" >&2

run_seq=
abort_run() {
    if [[ -n "$run_seq" ]]; then
        if ! tiden run abort "$run_seq" --format json > "$artifact_dir/abort.json"; then
            printf 'Could not abort Tiden run %s; inspect it manually.\n' "$run_seq" >&2
        fi
    fi
}

if (( report_tiden )); then
    title=${TIDEN_RUN_TITLE:-Swift Testing $(date -u +%Y-%m-%dT%H:%M:%SZ)}
    if ! tiden run create --require-session --title "$title" --format json > "$artifact_dir/run.json"; then
        printf 'Tiden run creation failed; tests were not started.\n' >&2
        exit 1
    fi
    if ! run_seq=$(python3 -c 'import json,sys; value=json.load(open(sys.argv[1],encoding="utf-8")).get("seqNum"); assert type(value) is int and value > 0; print(value)' "$artifact_dir/run.json"); then
        printf 'Tiden run created but its sequence number was not readable; inspect %s.\n' "$artifact_dir/run.json" >&2
        exit 1
    fi
    printf 'Tiden run: %s\n' "$run_seq" >&2
fi

# Bash 3.2 treats an empty array as unbound with set -u.
"$swift_command" test --disable-xctest --event-stream-version 0 \
    --event-stream-output-path "$stream_path" --xunit-output "$xunit_path" \
    ${test_args[@]+"${test_args[@]}"}
swift_status=$?

if ! python3 "$package_root/Scripts/report_swift_testing.py" \
    "$stream_path" "$report_path" "$package_root" "$swift_status"; then
    printf 'Swift Testing results were not reportable; raw artifacts remain in %s.\n' "$artifact_dir" >&2
    abort_run
    if (( swift_status != 0 )); then exit "$swift_status"; fi
    exit 1
fi
failed_count=$(python3 -c 'import json,sys; print(sum(row["execution"]["status"] == "failed" for row in json.load(open(sys.argv[1], encoding="utf-8"))))' "$report_path") || {
    printf 'Could not read converted test statuses.\n' >&2
    abort_run
    exit 1
}
result_status=$swift_status
if (( failed_count > 0 && result_status == 0 )); then
    result_status=1
fi

if (( report_tiden )); then
    if ! tiden run report "$run_seq" "$report_path" --format json > "$artifact_dir/report.json"; then
        printf 'Tiden rejected the results for run %s.\n' "$run_seq" >&2
        abort_run
        if (( result_status != 0 )); then exit "$result_status"; fi
        exit 1
    fi
    tiden run complete "$run_seq" --format json > "$artifact_dir/complete.json"
    complete_status=$?
    if (( complete_status != 0 )); then
        printf 'Tiden completion returned %s for run %s; inspect %s.\n' \
            "$complete_status" "$run_seq" "$artifact_dir/complete.json" >&2
        if (( result_status != 0 )); then exit "$result_status"; fi
        exit "$complete_status"
    fi
fi

exit "$result_status"
