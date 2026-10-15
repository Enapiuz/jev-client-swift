# Jev 1.14 and experimental features

This guide describes the SDK's protocol support. Local tests verify encoding,
transport and validation; they do not establish live model accuracy. TypeSafe
labels images and Box experimental and may change their formats and limits.

## Models and opt-in

As documented on 15 October 2026, `jev-preview` resolves to `jev-1.14.0`, while
`jev-latest` resolves to `jev-1.13.0`. Aliases can move. Pin `.jev1_14_0` when using
Box, and retain the response's resolved `model` when auditing results. The SDK
keeps `.latest` as its default and permits custom model IDs.

`JevExperimentalFeatures` exposes independent optional `images` and `longContext`
flags on `JevConfiguration` and `RequestOptions`. Nil leaves a flag unchanged;
false explicitly disables it. Evaluation header precedence is:

1. Configuration raw headers.
2. Configuration typed experimental flags.
3. Per-call raw headers.
4. Per-call typed experimental flags.

Header names are case-insensitive. With default configuration and options, neither
experimental header is sent. Raw headers remain available for future service
extensions. Requests containing assets or Box require an effective
`TypeSafe-Danger-Zone-Images: true`; the SDK does not enable it or switch models
automatically.

| Option | Header | Service behavior |
| --- | --- | --- |
| `images` | `TypeSafe-Danger-Zone-Images` | Allows images on 1.13 and 1.14, and Box on 1.14. |
| `longContext` | `TypeSafe-Danger-Zone-Long-Context` | Raises both context limits to 262k tokens on either version. |

Without long context, the documented limits are 64k tokens per request and 32k
per question. Long context is slower and less accurate. It does not raise byte
limits, and the SDK does not estimate tokens. Data-sharing settings are a separate
account choice; the SDK does not change them.

## Images and references

Construct `ImageAsset(data:format:)` with prepared PNG or JPEG bytes and an
`ImageFormat` (`.png`, `.jpg` or `.jpeg`). Assets are held in the request's
`[String: ImageAsset]` map. Use a fresh UUID string as each map key, and place that
reference in a `JSONValue` string in state, instructions or criteria. Existing
Choice, Score, Noul and typed Choice helpers accept assets too.

References match ordinary text, including inside longer strings. An object key,
question ID or Choice label is not replaced. Short references such as `cat` can
accidentally match `category`; UUIDs reduce that risk. Every asset must be used.
The SDK checks for obvious unused assets, but the service determines final
substitution when references overlap. An arbitrary string without an asset is
ordinary text, so the SDK cannot infer that it was intended as a missing image.

An image shared by many questions should normally appear once in state. Each
reference occurrence expands into another image for the model, even though the
image file is uploaded once. Repeated occurrences therefore consume additional
context and expanded-size allowance. Score legends echo references as text.

`ImageUploadEncoding.multipart` is the default for requests with assets. It sends
the JSON as the first part named `request`, followed by generated file parts.
Choose `.base64JSON` with `imageUploadEncoding` on configuration or per-call
options when a proxy requires JSON. Base64 adds about one third to image size.
Requests without assets remain ordinary JSON. The SDK owns the Content-Type and
multipart boundary. Bodies are buffered and reused across retry attempts;
retrying an evaluation can repeat billable work.

## Box and presence

`Question.box(instructions:)` asks for one target in one image, without criteria.
Use it in a mixed batch or call `client.box(...)`. `BoxAnswer` contains
`BoxCoordinates` and a separate confidence. The batch accessor is
`response.box("questionID")`.

Coordinates are fractions of the original prepared image, measured from the
top-left: `left`/`right` along width, `top`/`bottom` along height. The SDK requires
finite values in 0...1 with `left < right` and `top < bottom`; confidence is also
finite in 0...1. It does not clamp malformed geometry or convert coordinates to
platform-specific rectangles.

**Box always returns a box.** It has no not-found result, including when the
target is absent. Pair Box with a Noul presence question when absence matters,
and let the application decide its thresholds and whether to use the geometry.
The SDK does not infer detection or prescribe a confidence threshold. See the
README image example for a combined request.

Box needs at least one image asset. The SDK rejects the known incompatible
`jev-1.13.0` model locally. Moving aliases and custom model IDs are left to the
service; `.latest` may still resolve to an incompatible model, so pin 1.14 or use
`.preview` deliberately.

## Preparation and limits

The SDK checks nonblank asset reference keys, at most 1,024 UTF-8 bytes per key
and 65,536 bytes total, nonempty image data, at most 16 MiB per file, and at most
32 MiB for the final HTTP body, including base64 or multipart framing. Requests
fail before transport when these checks or the image opt-in fail. The SDK does
not decode image pixels or reproduce the service's image processing.

The following documented service requirements remain the caller's responsibility
and are validated by the service:

- Still PNG or JPEG; animated PNG is rejected. Prepare an upright image because
  the service removes metadata and does not apply EXIF orientation.
- Width and height each 256...1568 pixels, with total area
  78,400...2,458,624 pixels. A 256 × 256 image is too small despite its valid sides.
- All images together after service processing: at most 32 MiB. Re-encoding can
  grow them. Expanded content after reference replacement also has a 32 MiB limit.
- Prefer baseline JPEG. Convert HEIC, WebP, GIF or video frames before sending.

The SDK does not resize, rotate, crop or transcode files, fetch image URLs, or
add an image-processing dependency. A service rejection remains a `JevError.http`
with the original response metadata and bytes. One invalid image rejects the
whole request; do not interpret that failure as a negative decision.

## Compatibility and evidence

Existing calls retain their defaults. Adding Box introduces new cases to the
public `Question` and `Answer` enums, so consumers with exhaustive switches must
handle them. Minimum OS/compiler requirements and the dependency-free transport
are unchanged. No feature flag changes data-sharing policy or credential storage.

Use `Scripts/test.sh` without `--tiden` and the platform checks in
[`Documentation/Testing.md`](../Documentation/Testing.md). Captured-request and
loopback tests verify the wire contract. Live authenticated requests and model
quality are separate checks requiring appropriate authorization and examples.

## Official references

- [Jev 1.14 release](https://typesafe.ai/blog/jev-1-14)
- [Models, aliases and long context](https://docs.typesafe.ai/models)
- [Images, multipart, reference matching and limits](https://docs.typesafe.ai/images)
- [Box contract and presence guidance](https://docs.typesafe.ai/primitives/box)
- [General API and request rules](https://docs.typesafe.ai/api)
