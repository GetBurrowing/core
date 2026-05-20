defmodule Platform.Org.Wiki.Routing do
  @moduledoc """
  Path → policy classifier and write/read gate for the `memory_*` tool
  surface (ADR-0041, T5).

  Stage 1 (this commit) — module shell only. The classifier, gate, and
  Historian predicate land in stage 2 against the design lock at
  `docs/stack/0041-org-memory-impl/t5-design-lock.md`.

  Pure module: no `Repo`, no I/O, no telemetry. Trivially unit-testable.
  """
end
