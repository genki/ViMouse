---
title: ViMouse conversion server API
permalink: /conversion-server/
---

# ViMouse conversion server API

ViMouse can call a local conversion server when self conversion is enabled.
The default endpoint is:

```text
POST http://127.0.0.1:8767/convert
```

The server is intended for a trusted local machine or LAN. Do not expose it
directly to the Internet unless you add your own authentication and network
controls.

## Health check

```http
GET /health
```

A `200 OK` response is enough for a basic health check. The response body is not
used by ViMouse.

## Convert request

ViMouse sends UTF-8 JSON:

```json
{
  "input": "konnichiwa.",
  "context": "",
  "max_len": 16,
  "max_new_tokens": 16,
  "num_beams": 5
}
```

Fields:

- `input`: Required. Romaji text to convert.
- `context`: Optional. Context before the current input. ViMouse currently sends
  an empty string.
- `max_len`: Optional. Maximum output length hint.
- `num_beams`: Optional. Preferred number of deterministic model beams. Servers
  may return fewer candidates, but Ogura2-compatible servers should use this to
  return several ranked candidates when practical.

Compatible servers may also accept aliases such as `text` or `source` for the
input text, but `input` is the canonical field for ViMouse.

## Ogura-compatible input policy

Ogura-compatible conversion servers should tokenize the request input with the
same policy used by the bundled Ogura server:

```text
mode: aligned
ambiguity_profile: orthography
space_policy: auto
strict tokenization: enabled
```

This accepts supported romaji ambiguity such as common Hepburn/Kunrei notation,
particle spelling, and long-vowel variants that the Ogura token map can
represent. It should not silently train or serve arbitrary unparsed Latin
fragments as normal input. If an input cannot be represented by the active Ogura
token map, the server may return an error and ViMouse will use local fallback
candidates.

## Convert response

The preferred response shape is:

```json
{
  "ok": true,
  "kind": "ogura2",
  "output": "こんにちは。",
  "raw_output": "こんにちは。",
  "candidates": [
    { "text": "こんにちは。", "score": 1.0 },
    { "text": "こんにちわ。", "score": 0.82 }
  ],
  "elapsed": 0.65,
  "model_elapsed": 0.64,
  "detail": "model=best"
}
```

Fields:

- `ok`: Optional boolean. Use `false` with `error` for explicit failures.
- `output`: Preferred committed conversion result.
- `raw_output`: Optional raw model output for diagnostics. ViMouse may show this
  in test/debug output, but the user-facing candidate should be in `output`.
- `candidates`: Optional candidate list. Each item should include `text` and may
  include a numeric `score`.
- `elapsed` or `model_elapsed`: Optional server-side timing in seconds.
- `detail`: Optional human-readable diagnostic detail.

ViMouse also accepts these compatible response shapes:

```json
{ "candidates": [{ "text": "こんにちは。", "score": 1.0 }] }
```

```json
{ "output": "こんにちは。", "score": 1.0 }
```

```json
{ "response": "こんにちは。" }
```

```json
{ "choices": [{ "message": { "content": "こんにちは。" } }] }
```

Candidate text fields may be named `text`, `output`, or `candidate`.
Candidates containing the Unicode replacement character `U+FFFD` are invalid.
ViMouse ignores them and falls back when no usable server candidate remains.

## Punctuation policy

The conversion server should preserve the user's terminal punctuation intent.
For example, `konnichiwa.` should return `こんにちは。`, while `konnichiwa`
should not invent a final punctuation mark. If post-processing normalizes ASCII
punctuation to Japanese punctuation, apply it only when the source input
contains that punctuation.

## Timeouts and fallback

ViMouse defaults to a 10 second timeout. When the request fails, returns invalid
JSON, contains no usable candidate, or exceeds the timeout, ViMouse falls back to
its local candidates. For interactive use, keep typical conversion latency under
1 to 2 seconds.

## Decision feedback

Ogura2-compatible servers should also accept conversion decision logs:

```http
POST /feedback
```

ViMouse sends this request asynchronously after a partial commit or final
commit. Failure to send feedback does not block input.

```json
{
  "schema_version": 1,
  "kind": "vimouse_self_conversion_decision",
  "action": "partial_commit",
  "input": "sitekudasai",
  "context": "確認",
  "selected_index": 0,
  "selected": { "text": "してください", "score": 0.82 },
  "candidates": [
    { "text": "してください", "score": 0.82 },
    { "text": "sitekudasai", "score": 0.05 }
  ],
  "unselected_candidates": [
    { "text": "sitekudasai", "score": 0.05 }
  ]
}
```

The bundled Ogura2 server appends these records as JSON Lines under
`logs/ogura2_feedback/YYYYMMDD.jsonl` by default. Use `--feedback-log-dir` to
change the destination.

## Examples

Health check:

```sh
curl -i http://127.0.0.1:8767/health
```

Conversion:

```sh
curl -s http://127.0.0.1:8767/convert \
  -H 'Content-Type: application/json' \
  -d '{"input":"konnichiwa.","context":"","max_len":16,"max_new_tokens":16,"num_beams":5}'
```
