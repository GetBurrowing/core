defmodule Platform.Org.Wiki.Indexer.Payload do
  @moduledoc """
  Pure shapers that translate T2 wiki rows into `Platform.Memory.Provider`
  entries.

  Two corpora flow through the T3 indexer:

    * Pages — built from `%Platform.Org.WikiPage{}` rows. `memory_type` is
      `"page"`. `date` is required by the provider behaviour but pages have
      no natural date, so we stamp today's ISO date — ADR-0041's search
      design does not filter pages by date, so this is a no-op observable
      and keeps the schema honest.
    * Journal — built from `%Platform.Org.WikiJournalEntry{}` rows.
      `memory_type` is `"journal"`. `date` is the entry's own date.

  The memory-service contract (`/home/sloane/Code/suite/memory-service/src/memory_service/models.py`)
  accepts `memory_type` as free-form `str` — `"page"` and `"journal"` pass
  through unchanged. No follow-up PR to memory-service is required.

  These functions are **pure** so unit tests don't need a Repo and the
  indexer can build payloads in tight loops without surprise side effects.
  """

  alias Platform.Memory.Provider
  alias Platform.Org.WikiJournalEntry
  alias Platform.Org.WikiPage

  @page_memory_type "page"
  @journal_memory_type "journal"

  @doc "Canonical `memory_type` value the indexer stamps on page entries."
  @spec page_memory_type() :: String.t()
  def page_memory_type, do: @page_memory_type

  @doc "Canonical `memory_type` value the indexer stamps on journal entries."
  @spec journal_memory_type() :: String.t()
  def journal_memory_type, do: @journal_memory_type

  @doc """
  Build a `Provider.entry/0` from a `%WikiPage{}` row.

  The page's `id`, `content`, `workspace_id`, `file_key`, `version` and
  `frontmatter` survive through to the embedding store; `date` is stamped
  with today's ISO date because the schema requires one and pages aren't
  date-keyed in the search surface.
  """
  @spec from_page(WikiPage.t()) :: Provider.entry()
  def from_page(%WikiPage{} = page) do
    %{
      id: to_string(page.id),
      content: page.content || "",
      memory_type: @page_memory_type,
      date: today_iso(),
      workspace_id: nil_or_string(page.workspace_id),
      metadata: %{
        "file_key" => page.file_key,
        "version" => page.version,
        "frontmatter" => page.frontmatter || %{}
      }
    }
  end

  @doc """
  Build a `Provider.entry/0` from a `%WikiJournalEntry{}` row.

  Journal entries carry their own date and metadata (including the
  `"namespace"` key the journal module writes on append).
  """
  @spec from_journal_entry(WikiJournalEntry.t()) :: Provider.entry()
  def from_journal_entry(%WikiJournalEntry{} = entry) do
    %{
      id: to_string(entry.id),
      content: entry.content || "",
      memory_type: @journal_memory_type,
      date: date_to_iso(entry.date),
      workspace_id: nil_or_string(entry.workspace_id),
      metadata: entry.metadata || %{}
    }
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp today_iso, do: Date.utc_today() |> Date.to_iso8601()

  defp date_to_iso(%Date{} = d), do: Date.to_iso8601(d)
  defp date_to_iso(date) when is_binary(date), do: date
  defp date_to_iso(nil), do: today_iso()

  defp nil_or_string(nil), do: nil
  defp nil_or_string(v), do: to_string(v)
end
