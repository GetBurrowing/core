defmodule Platform.Memory.JournalSweep do
  @moduledoc """
  Post-append `<synthesis-proposal>` sweep for journal writes.

  ## Why this module exists

  Proposals reach `/memory/proposals` through
  `Platform.Memory.Proposals.ingest_from_journal/3`. Page-shaped writes
  get there via the hook inside
  `Platform.Org.Context.upsert_context_file/3` — that is the path the
  `memory.dreaming` handler takes, and it works.

  Journal-shaped writes did not. `Platform.Org.Wiki.Journal.append/2`
  inserts an `org_wiki_journal_entries` row and never touches
  `Platform.Memory`, so an agent emitting proposal blocks through the
  `memory_create` tool — the only write target a dreaming run is
  authorised to use — produced durable journal text that no parser ever
  saw. Same author, same blocks, same day, silently invisible.

  The sweep can't live in `Journal` (the T2 layering guard in
  `wiki_t2_e2e_test.exs` forbids a `Platform.Memory` call site there) and
  can't live in `Platform.Org.Context` (pinned by sha256 in three e2e
  guards, pending T5 retirement). So it lives here, and journal writers
  call it explicitly after a successful append.

  ## Callers

    * `Platform.Federation.ToolSurface` — `memory_create` on a journal path
    * `PlatformWeb.OrgMemoryLive.View` — the `/org_memory` journal pane

  Any future journal writer that can carry agent- or human-authored
  prose must call this too, or its proposals will vanish the same way.
  """

  require Logger

  alias Platform.Memory.Proposals
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.WikiJournalEntry

  @doc """
  Sweep a freshly appended entry for `<synthesis-proposal>` blocks.

  Always returns `:ok`. Runs outside the insert, so a parser bug or a
  proposals-side constraint failure can never turn a durable append into
  an error — the journal is the source of truth and proposals are a
  derived review surface. Ingestion is idempotent on
  `(workspace_id, block_hash)`, so sweeping the same body twice inserts
  each block once.
  """
  @spec sweep(WikiJournalEntry.t(), String.t()) :: :ok
  def sweep(%WikiJournalEntry{} = entry, namespace) when is_binary(namespace) do
    file_key = Journal.virtual_file_key(namespace, entry.date)

    if Proposals.journal_path?(file_key) do
      case Proposals.ingest_from_journal(entry.workspace_id, file_key, entry.content) do
        {:ok, count} when count > 0 ->
          Logger.debug(
            "[memory.proposals] ingested #{count} block(s) from #{file_key} " <>
              "(entry_id=#{entry.id} workspace_id=#{inspect(entry.workspace_id)})"
          )

          :ok

        {:ok, 0} ->
          :ok
      end
    else
      :ok
    end
  rescue
    e ->
      Logger.error(
        "[memory.proposals] journal sweep crashed for entry_id=#{entry.id}: " <>
          Exception.message(e)
      )

      :ok
  end
end
