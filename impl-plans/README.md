# Implementation Plans

Implementation plans translate design documents into actionable work.

- Active plans live in `impl-plans/active/`.
- Completed plans move to `impl-plans/completed/`.
- Use `impl-plans/templates/plan-template.md` for new plans.

## Completed

Subscription usage (`design-docs/specs/design-subscription-usage.md`):

- `impl-plans/completed/subscription-usage-types.md`: public types and ISO 8601 date parsing.
- `impl-plans/completed/subscription-usage-exchange.md`: interactive JSON-line stdio exchange.
- `impl-plans/completed/subscription-usage-readme.md`: README documentation.
- `impl-plans/completed/subscription-usage-reader-cli.md`: reader, vendor parsers and CLI command.

The dispatch manifest
`impl-plans/completed/subscription-usage-20261031-dispatch.json` is the
workflow dispatch record.

Transcribe CLI (`design-docs/specs/design-transcribe-cli.md`):

- `impl-plans/completed/transcribe-transport-seam.md`: internal transport seam and shared vendor validation.
- `impl-plans/completed/transcribe-cli-command.md`: `agent-gateway transcribe` command, dispatch, usage and tests.
- `impl-plans/completed/transcribe-readme.md`: README documentation.

The dispatch manifest
`impl-plans/active/transcribe-cli-20261112-dispatch.json` stays in place as
the workflow dispatch record, because the accepted checkpoint commit refers to
it by that path.

Transcription failure contract (`design-docs/specs/design-transcription-failure.md`):

- `impl-plans/completed/transcription-failure-type.md`: public `GatewayTranscriptionFailure`, classification, Retry-After parsing and redaction.
- `impl-plans/completed/transcription-failure-pipeline.md`: structured failures from the transport pipeline and the per-call redirect-refusing delegate.
- `impl-plans/completed/transcription-failure-loopback.md`: real-URLSession loopback redirect regression test with a mutation check.
- `impl-plans/completed/transcription-failure-cli.md`: six-line structured stderr in `agent-gateway transcribe`.
- `impl-plans/completed/transcription-failure-readme.md`: README failure contract documentation.

The dispatch manifest
`impl-plans/active/transcription-failure-20261112-dispatch.json` stays in place
as the workflow dispatch record, because the accepted checkpoint commit refers
to it by that path.
