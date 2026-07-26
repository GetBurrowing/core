# ADR 0107: Empty Status Section

## Status

## Context

Fixture. A `## Status` section with nothing under it. The parser must return
`nil`, not the next heading's text.
