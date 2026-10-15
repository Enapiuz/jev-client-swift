# JevClient

## Tracking

Intentor project: **JevClient (`JEV`)**, ID `EEDA90FA-3E62-4E5C-BE5B-732C67349650`.
Use Intentor for ongoing work. The `.tiden` directory and optional Tiden reporting
scripts are historical/Claude-side tooling; Codex must not invoke their tracker
operations.

## SDK changes

Preserve the dependency-free, cross-platform core and its declared Swift and OS
minimums. Experimental service capabilities require explicit opt-in; image bytes,
states and response bodies must stay out of lifecycle logs and error messages.

For API or experimental-feature changes, read `docs/experimental-features.md` and
verify version-sensitive contracts against the linked official TypeSafe sources.
Keep README examples and DocC signatures consistent with the public API.

## Verification

Use `Scripts/test.sh` without `--tiden` for the full local suite. See
`Documentation/Testing.md` for build and platform checks. Local HTTP fixtures
verify the SDK protocol; they do not establish authenticated service behavior or
model accuracy. Preserve that distinction in reports.
