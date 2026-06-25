defmodule Platform.Responsibilities.ContextProviders do
  @moduledoc """
  Built-in context providers for the cross-cutting slots both Hal's
  `memory.daily_summary` and the upcoming `meetings.summarize` responsibility
  request (ADR-0041 M8 stage 1).

  Where `Platform.Responsibilities.ContextGatherer` returns a single
  flat `%{name => payload}` map across the platform-owned symbolic
  names, this module exposes the per-slot materialisers in the shape
  M1's `Provider.gather_context/2` contract expects:

      gather_context(:org_identity, opts) :: {:ok, %{org_identity: payload}} | {:error, term()}

  Two reasons to keep it separate from `ContextGatherer`:

    1. The Provider behaviour wants `{:ok, map}` / `{:error, term}` —
       ContextGatherer's tolerant "always-returns-a-map, missing values
       become `nil`" contract is the right choice for the router's
       batch gather but a poor fit for per-slot error surfacing
       (Hal's first nightly on a fresh org must distinguish "file
       missing" from "DB down").

    2. Stages 2 and 3 register the responsibilities that name these
       slots in their `context_provided` list; routing them through a
       single, named module keeps the provider/registry wiring clean
       (`{Platform.Responsibilities.ContextProviders, :gather_context, []}`
       rather than scattering closures).

  Adding new slots: extend `gather_context/2` with a new clause AND
  add the resolver to `ContextGatherer` (so the router's batch path
  also picks it up).
  """

  require Logger

  alias Platform.Meetings
  alias Platform.Meetings.SummaryPrompt
  alias Platform.Meetings.Transcript
  alias Platform.Org.Context, as: OrgContext

  @type slot :: :org_identity | :recent_journal | :meeting_transcript

  @doc """
  Materialise a single slot into the shape M1 providers consume.

  ## Slots

    * `:org_identity` — loads `ORG_IDENTITY.md` via
      `Platform.Org.Context.get_file/1`. Returns `missing?: true` with
      empty body when the file row doesn't exist (Hal's first nightly
      on a fresh org must not crash).
    * `:recent_journal` — last 7 days from `Platform.Org.Context.recent_memory/2`.
      Honours `opts[:workspace_id]` for scoping.
    * `:meeting_transcript` — requires `opts[:transcript_id]`. Loads the
      transcript and formats segments via `SummaryPrompt.format_segments/1`.
      Returns `{:error, :not_found}` if no transcript with that ID exists,
      `{:error, :missing_transcript_id}` if no ID provided.
  """
  @spec gather_context(slot(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def gather_context(slot, opts \\ [])

  def gather_context(:org_identity, _opts) do
    case safe(fn -> OrgContext.get_file("ORG_IDENTITY.md") end) do
      {:ok, nil} ->
        {:ok,
         %{
           org_identity: %{
             content: "",
             version: nil,
             missing?: true
           }
         }}

      {:ok, %{content: content, version: version}} ->
        {:ok,
         %{
           org_identity: %{
             content: content || "",
             version: version,
             missing?: false
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def gather_context(:recent_journal, opts) do
    opts = to_keyword(opts)
    workspace_id = Keyword.get(opts, :workspace_id)
    days = Keyword.get(opts, :days, 7)

    recent_opts = if workspace_id, do: [workspace_id: workspace_id], else: []

    case safe(fn -> OrgContext.recent_memory(days, recent_opts) end) do
      {:ok, grouped} when is_list(grouped) ->
        total = grouped |> Enum.map(fn {_date, entries} -> length(entries) end) |> Enum.sum()

        {:ok,
         %{
           recent_journal: %{
             days: days,
             entries_by_date: grouped,
             total: total
           }
         }}

      {:ok, _other} ->
        # Defensive: if recent_memory ever changes shape, surface an empty
        # window rather than crashing the dispatch pipeline.
        {:ok, %{recent_journal: %{days: days, entries_by_date: [], total: 0}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def gather_context(:meeting_transcript, opts) do
    opts = to_keyword(opts)

    case Keyword.get(opts, :transcript_id) do
      nil ->
        {:error, :missing_transcript_id}

      id when is_binary(id) ->
        case safe(fn -> Meetings.get_transcript(id) end) do
          {:ok, nil} ->
            {:error, :not_found}

          {:ok, %Transcript{} = transcript} ->
            segments = transcript.segments || []

            {:ok,
             %{
               meeting_transcript: %{
                 transcript_id: transcript.id,
                 formatted_text: SummaryPrompt.format_segments(segments),
                 segment_count: length(segments),
                 duration_ms: max_end_time(segments)
               }
             }}

          {:error, reason} ->
            {:error, reason}
        end

      _other ->
        {:error, :invalid_transcript_id}
    end
  end

  def gather_context(slot, _opts) do
    {:error, {:unknown_slot, slot}}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp to_keyword(opts) when is_list(opts), do: opts

  defp to_keyword(opts) when is_map(opts) do
    Enum.map(opts, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> []
  end

  defp to_keyword(_), do: []

  defp max_end_time([]), do: 0

  defp max_end_time(segments) do
    segments
    |> Enum.map(fn segment ->
      end_time = segment["end_time"] || segment[:end_time] || 0
      if is_number(end_time), do: end_time, else: 0
    end)
    |> Enum.max(fn -> 0 end)
    |> trunc()
  end

  # Wrap upstream lookups so a missing module / unexpected raise
  # surfaces as `{:error, term}` rather than aborting the caller. The
  # M6 router treats `{:error, _}` as a dispatch failure and decides
  # whether to retry / log / fall back.
  defp safe(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    error ->
      Logger.warning(
        "[ContextProviders] lookup raised: #{Exception.message(error)} — returning error"
      )

      {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason ->
      Logger.warning("[ContextProviders] lookup exited: #{inspect(reason)}")
      {:error, {:exit, reason}}
  end
end
