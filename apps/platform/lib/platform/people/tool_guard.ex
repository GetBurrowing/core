defmodule Platform.People.ToolGuard do
  @moduledoc """
  The people-page rules at the memory-tool boundary (task 01a1aa47 stage 5).

  The Historian-role holder writes people pages itself through
  `memory_create` / `memory_str_replace` / `memory_insert`, so the page
  grammar only holds if the tool surface enforces it on every write. This
  module owns that logic; `Platform.Federation.ToolSurface` makes one call
  per handler and stays ignorant of the people grammar.

    * `before_write/4` — for `org/page/people/` paths, runs
      `Platform.People.PageGuard.enforce/2` for the path's tier (the index
      is only scrubbed); every other path passes through untouched with
      empty counts.
    * `after_write/3` — for a card or private page: regenerates the index,
      emits `[:platform, :people, :page_written]`, and appends one
      `HR updated profiles: <paths>` journal line at most once per ten
      minutes per agent. The throttle reads today's journal rows; there is
      no process state.
    * `wrap_write/5` — `before_write`, the persist function, then
      `after_write` on success, merging `guard: counts` into the envelope
      when the counts are non-empty. This is the single call a write
      handler makes.
    * `before_read/2` — refuses a private-tier page where
      `Platform.People.Visibility.agent_context_allows?/2` says the subject
      is not present; the refusal never says whether the page exists.
    * `filter_search_hits/2` — drops private-tier hits the same way.
  """

  alias Platform.Org.Wiki.Journal
  alias Platform.People.{PageGuard, Pages, Privacy, Visibility}

  @journal_source "people:tool_guard"
  @journal_window_seconds 600

  @type counts :: %{optional(atom()) => non_neg_integer()}

  @doc "Guard the body an agent is about to persist at `path`."
  @spec before_write(String.t(), String.t(), term(), binary() | nil) ::
          {:ok, String.t(), counts()}
  def before_write(path, body, _agent, _workspace_id) when is_binary(path) and is_binary(body) do
    case Visibility.tier_of(path) do
      tier when tier in [:card, :private] ->
        {guarded, counts} = PageGuard.enforce(tier, body)
        {:ok, guarded, counts}

      :index ->
        {scrubbed, report} = Privacy.scrub(body)
        redactions = Enum.reduce(report, 0, fn %{count: n}, acc -> acc + n end)
        {:ok, scrubbed, if(redactions > 0, do: %{redactions: redactions}, else: %{})}

      :unknown ->
        {:ok, body, %{}}
    end
  end

  @doc """
  Side effects after a successful people-page write: index regeneration,
  telemetry, and the throttled journal line. A no-op for the index itself
  and for every path outside the people prefix. Always returns `:ok`.
  """
  @spec after_write(String.t(), term(), binary() | nil) :: :ok
  def after_write(path, agent, workspace_id) when is_binary(path) do
    if Visibility.tier_of(path) in [:card, :private] do
      agent_id = agent_id(agent)
      _ = Pages.regenerate_index(workspace_id, agent_id)

      :telemetry.execute(
        [:platform, :people, :page_written],
        %{count: 1, system_time: System.system_time()},
        %{paths: [path], workspace_id: workspace_id, updated_by: agent_id, via: :memory_tools}
      )

      maybe_journal([path], agent_id, workspace_id, DateTime.utc_now())
    end

    :ok
  end

  @doc """
  `before_write/4`, then `persist.(guarded_body)`, then `after_write/3` when
  the persist answered `{:ok, envelope}`. Non-empty counts are merged into
  the envelope under `:guard`.
  """
  @spec wrap_write(String.t(), String.t(), term(), binary() | nil, (String.t() -> term())) ::
          term()
  def wrap_write(path, body, agent, workspace_id, persist) when is_function(persist, 1) do
    {:ok, guarded, counts} = before_write(path, body, agent, workspace_id)

    case persist.(guarded) do
      {:ok, %{} = envelope} ->
        after_write(path, agent, workspace_id)
        if counts == %{}, do: {:ok, envelope}, else: {:ok, Map.put(envelope, :guard, counts)}

      other ->
        other
    end
  end

  @doc "May the caller behind `context` surface `path`? `context[:workspace_id]` scopes the lookup."
  @spec before_read(String.t(), map() | nil) :: :ok | {:error, map()}
  def before_read(path, context) when is_binary(path) do
    if Visibility.agent_context_allows?(path, context) do
      :ok
    else
      {:error,
       %{
         error:
           "memory_view: private profiles are only surfaced in a direct or group space the subject is in, or outside any space.",
         code: :private_profile_not_in_space,
         recoverable: false,
         suggestion:
           "Use the person's card instead, or read the private tier from a dm with the subject or from a system or execution dispatch."
       }}
    end
  end

  @doc """
  Drop private-tier hits the caller may not surface. Accepts the hit list or
  the whole `{:ok, %{results: hits}}` search envelope (then `match_count`
  is adjusted); anything else passes through.
  """
  @spec filter_search_hits(term(), map() | nil) :: term()
  def filter_search_hits(hits, context) when is_list(hits) do
    Enum.filter(hits, fn hit -> Visibility.agent_context_allows?(hit_path(hit), context) end)
  end

  def filter_search_hits({:ok, %{results: hits} = envelope}, context) when is_list(hits) do
    kept = filter_search_hits(hits, context)

    envelope =
      if Map.has_key?(envelope, :match_count),
        do: Map.put(envelope, :match_count, envelope.match_count - (length(hits) - length(kept))),
        else: envelope

    {:ok, Map.put(envelope, :results, kept)}
  end

  def filter_search_hits(other, _context), do: other

  # -- internals --------------------------------------------------------------

  defp hit_path(%{path: path}) when is_binary(path), do: path
  defp hit_path(%{"path" => path}) when is_binary(path), do: path
  defp hit_path(_), do: ""

  defp agent_id(%{id: id}) when is_binary(id), do: id
  defp agent_id(_), do: nil

  defp maybe_journal(paths, agent_id, workspace_id, now) do
    if journaled_recently?(agent_id, workspace_id, now) do
      :skipped
    else
      attrs =
        %{
          content: "HR updated profiles: " <> Enum.join(paths, ", "),
          date: DateTime.to_date(now),
          workspace_id: workspace_id,
          metadata: %{"source" => @journal_source, "agent_id" => agent_id, "paths" => paths}
        }
        |> maybe_put(:authored_by, agent_id)

      case Journal.append(attrs) do
        {:ok, _entry} -> :ok
        {:error, _changeset} -> :error
      end
    end
  end

  defp journaled_recently?(agent_id, workspace_id, now) do
    cutoff = DateTime.add(now, -@journal_window_seconds, :second)

    now
    |> DateTime.to_date()
    |> Journal.get_for_date(workspace_id: workspace_id)
    |> Enum.any?(fn entry ->
      meta = entry.metadata || %{}

      Map.get(meta, "source") == @journal_source and Map.get(meta, "agent_id") == agent_id and
        DateTime.compare(entry.inserted_at, cutoff) != :lt
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
