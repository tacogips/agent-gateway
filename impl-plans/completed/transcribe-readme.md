# Transcribe CLI: README Documentation

**Status**: Completed
**Plan ID**: `transcribe-readme`
**Wave**: 1 (no dependencies; documentation only)
**Depends On**: none
**Design Reference**: `design-docs/specs/design-transcribe-cli.md` (Synopsis, Output And Exit Codes, Secrets, Code Placement)

## Purpose

The acceptance criteria require README.md to list the
`agent-gateway transcribe` subcommand with an example.
`design-docs/specs/command.md` was already updated in the accepted design
step. Do not edit it.

## Repository Context

- README.md has no general "Usage" section. Each feature has its own
  section with a `bash` CLI example.
- Imitate `## Vendor model catalog` (about line 205) and
  `## Subscription usage` (about line 267, with its CLI example at lines
  273-274).
- The target section is `## Audio transcription` (about line 320). Today it
  covers only the Swift library API.

## Write Ownership

- `README.md`
- `impl-plans/active/transcribe-readme.md` (progress log section only)

Edit discipline:

- Re-read `README.md` right before each edit.
- Record `shasum -a 256 README.md` in the progress log before the first
  edit and after the last one.
- If the hash changes in a way your own edits do not explain, stop and
  record the drift. Do not overwrite it.

## Changes

Edit only the `## Audio transcription` section. Insert new content after
the intro sentence and before the existing `swift` library snippet. Keep
every existing line in the section, so the diff only adds lines.

1. One sentence saying the same feature is available on the CLI.
2. A `bash` block:
   - `agent-gateway transcribe --vendor openai --model whisper-1 --file meeting.m4a --language ja`
   - `agent-gateway transcribe --vendor gemini --model gemini-3.5-flash-lite --file memo.wav --output json`
   - `agent-gateway transcribe --vendor openrouter --model openai/gpt-4o-audio-preview --file note.ogg --api-key-environment OPENROUTER_API_KEY`
3. A flag list:
   - required: `--vendor <openai|gemini|openrouter>`, `--model <id>`,
     `--file <path>`;
   - optional: `--mime-type`, `--language`, `--prompt`,
     `--api-key-environment`, `--base-url`, `--timeout-seconds` (default
     120), `--output text|json` (default `text`).
4. Output:
   - `text` prints only the transcript;
   - `json` prints one line, for example
     `{"model":"whisper-1","text":"...","vendor":"openai"}`.
5. MIME inference from the extension: wav, mp3/mpga/mpeg, m4a/mp4, webm,
   ogg/oga, flac, aac. Any other extension needs `--mime-type`.
6. Errors:
   - Diagnostics go to stderr only, as
     `transcription failed (<code>): <message>`, with exit 1.
   - Invalid flags exit 2.
   - Unsupported vendors give `-32021` before any file or network I/O.
   - Vendor HTTP failures keep `vendor HTTP <status>: <body>` (code
     `-32010`), so `insufficient_quota` and `rate_limit_exceeded` stay
     distinguishable.
   - A missing credential gives `-32011` and names only the environment
     variable.
7. One sentence saying that credentials are referenced only by
   environment-variable name and are never printed.

## Pitfalls

- Use only facts stated in the accepted design. Do not invent flags,
  defaults, or codes.
- Do not reflow or edit other README sections.
- No emojis. English only.

## Verification (repository root, foreground)

| Command | Must show |
| --- | --- |
| `grep -n "agent-gateway transcribe" README.md` | at least 3 lines, all after the `## Audio transcription` heading line and before `## Provider routing library` |
| `grep -c -- "-32021\|-32010\|-32011\|--mime-type\|--output" README.md` | at least 5 |
| `git diff --numstat README.md` | the deleted-lines column is `0` |
| `git diff README.md` | only additions inside `## Audio transcription` |

Record the commands, outputs, and exit codes in the progress log.

## Done Criteria

- [x] The `## Audio transcription` section contains the CLI examples, the
      flags, the output, the MIME inference rules, the errors, and the
      secrets note.
- [x] No deleted lines, and no edits outside the section.

## Progress Log

- 2026-11-12: Plan created.
- 2026-11-12: Implemented both done criteria in README.md; formal review is pending. README SHA-256 before: `d9b47bf897f2764b42532721d8bb9ddefc488cb2d67d5d0602c4e1e3550a6fbc`; after: `ee878297ce3e034b0775c02d7783731b589556e29526b2509a6a86732205949c`.
- Verification (all exit 0; complete output in `tmp/transcribe-cli-20261112/transcribe-readme/verification-*.log`): `grep -n "agent-gateway transcribe" README.md` found lines 328-330; `grep -n "^## Audio transcription\|^## Provider routing library" README.md` found lines 320 and 387; `grep -c -- "-32021\|-32010\|-32011\|--mime-type\|--output" README.md` returned 9; `git diff --numstat README.md` returned 28 additions and 0 deletions; `git diff README.md` showed additions only in the target section; `git status --porcelain --untracked-files=all` recorded the shared working tree.
- 2026-11-12: Completed. Reviews accepted. Step 8 documentation refresh changed one line in the section (the intro now ends with a period instead of a colon, because the CLI paragraph follows it) and added "From Swift, call the library API directly:" before the Swift snippet. The section matches `agent-gateway --help`.
