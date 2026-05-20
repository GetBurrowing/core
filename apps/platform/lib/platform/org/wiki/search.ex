defmodule Platform.Org.Wiki.Search do
  @moduledoc """
  Cross-corpus search for the `memory_search` tool (ADR-0041, T5).

  Stage 1 (this commit) — module shell only. The RRF fusion algorithm
  + ACL-aware hydration land in stage 4 against the design lock at
  `docs/stack/0041-org-memory-impl/t5-design-lock.md`.

  Fuses three lexical channels (`org_wiki_pages`, `org_wiki_journal_entries`,
  `chat_messages`) with a single semantic channel (`Platform.Memory.search/3`
  via the T3 indexer) using Reciprocal Rank Fusion at k=60.
  """
end
