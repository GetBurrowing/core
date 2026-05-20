defmodule Platform.Org.Wiki.Routing do
  @moduledoc """
  Path → policy classifier and write/read gate for the `memory_*` tool
  surface (ADR-0041, T5).

  Lives behind the `memory_*` tool dispatch in
  `Platform.Federation.ToolSurface` (stage 3) and `Platform.Org.Wiki.Search`
  (stage 4). Implements the canonical path namespace → policy table from
  `docs/stack/0041-org-memory-impl/t5-design-lock.md` §2 and the Historian
  predicate from §3.

  The module is mostly pure — `classify/1`, `historian?/1`, and `gate_write/3`
  for the catch-all and journal cases are I/O-free. The owner check
  (`space/<id>/private/<agent_id>/...`) needs a participation lookup, so
  `gate_write/3` / `gate_read/2` will call `Platform.Chat.list_spaces_for_agent/2`
  unless the caller pre-supplies the list via the `:agent_space_ids` opt
  (see `gate_write/3` docs).

  ## Stage-3 contract

  - `gate_write/3` returns `{:error, %{code, message, suggestion, recoverable}}`
    for any denial. The Historian-only denial against page paths carries the
    verbatim string from design lock §3 and a `:suggestion` of the form
    `"memory_create at <namespace>/journal/<YYYY-MM-DD>.md"` keyed to today's
    UTC date. Stage 3's `tool_surface.ex` surfaces those fields directly in
    the tool error envelope — do not reshape this tuple without updating
    `memory_tools_test.exs` and the e2e Case B assertions.
  """

  alias Platform.Agents.Agent
  alias Platform.Chat

  @type role :: :anyone | :historian | :owner | :rejected
  @type kind :: :page | :journal | :private | :unknown

  @type classification :: %{
          kind: kind(),
          write_role: role(),
          read_role: role(),
          namespace: String.t() | nil,
          journal_date: Date.t() | nil
        }

  @type error :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          required(:suggestion) => String.t(),
          required(:recoverable) => boolean()
        }

  @historian_event "daily_summary"

  # Page path: <ns>/page/<rest...>
  # ns ∈ {"org", "project/<uuid>", "space/<uuid>"}
  @page_re ~r/\A(?<ns>org|project\/[^\/]+|space\/[^\/]+)\/page\/(?<rest>.+)\z/

  # Journal path: <ns>/journal/<YYYY-MM-DD>.md
  @journal_re ~r/\A(?<ns>org|project\/[^\/]+|space\/[^\/]+)\/journal\/(?<date>\d{4}-\d{2}-\d{2})\.md\z/

  # Private path: space/<space_uuid>/private/<agent_uuid>/<rest...>
  @private_re ~r/\A(?<ns>space\/(?<space>[^\/]+))\/private\/(?<agent>[^\/]+)\/.+\z/

  ## ─────────────────────────────────────────────────────────────────────────
  ## Classification
  ## ─────────────────────────────────────────────────────────────────────────

  @doc """
  Classify a file-key path against the design-lock §2 policy table.

  Returns a `t:classification/0` map. Unknown paths (or malformed
  `<uuid>` slots that fail `Ecto.UUID.cast/1`) classify as
  `kind: :unknown` with both roles set to `:rejected` — the terminal
  catch-all from the table.
  """
  @spec classify(String.t()) :: classification()
  def classify(path) when is_binary(path) do
    cond do
      match = Regex.named_captures(@private_re, path) ->
        classify_private(match)

      match = Regex.named_captures(@journal_re, path) ->
        classify_journal(match)

      match = Regex.named_captures(@page_re, path) ->
        classify_page(match)

      true ->
        unknown()
    end
  end

  def classify(_), do: unknown()

  defp classify_private(%{"ns" => ns, "space" => space_id, "agent" => agent_id}) do
    with {:ok, _} <- Ecto.UUID.cast(space_id),
         {:ok, _} <- Ecto.UUID.cast(agent_id) do
      %{
        kind: :private,
        write_role: :owner,
        read_role: :owner,
        namespace: ns,
        journal_date: nil
      }
    else
      _ -> unknown()
    end
  end

  defp classify_journal(%{"ns" => ns, "date" => date_str}) do
    with :ok <- validate_namespace_uuid(ns),
         {:ok, date} <- Date.from_iso8601(date_str) do
      %{
        kind: :journal,
        write_role: :anyone,
        read_role: :anyone,
        namespace: ns,
        journal_date: date
      }
    else
      _ -> unknown()
    end
  end

  defp classify_page(%{"ns" => ns}) do
    case validate_namespace_uuid(ns) do
      :ok ->
        %{
          kind: :page,
          write_role: :historian,
          read_role: :anyone,
          namespace: ns,
          journal_date: nil
        }

      :error ->
        unknown()
    end
  end

  defp unknown do
    %{
      kind: :unknown,
      write_role: :rejected,
      read_role: :rejected,
      namespace: nil,
      journal_date: nil
    }
  end

  # "org" is always valid. "project/<uuid>" or "space/<uuid>" must Ecto.UUID.cast.
  defp validate_namespace_uuid("org"), do: :ok

  defp validate_namespace_uuid("project/" <> id), do: cast_uuid(id)
  defp validate_namespace_uuid("space/" <> id), do: cast_uuid(id)
  defp validate_namespace_uuid(_), do: :error

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> :ok
      :error -> :error
    end
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## Historian predicate (design lock §3)
  ## ─────────────────────────────────────────────────────────────────────────

  @doc """
  Returns `true` iff the given agent carries the Historian-role signal.

  Pre-T6 the signal is `"daily_summary" in agent.system_events`
  (`Platform.Agents.Agent.@valid_system_events`). T6 may layer a richer
  role model — when that lands, swap this implementation in place and
  callers (`gate_write/3`, `gate_read/2`) keep working.
  """
  @spec historian?(Agent.t() | nil) :: boolean()
  def historian?(%Agent{system_events: events}) when is_list(events),
    do: @historian_event in events

  def historian?(_), do: false

  ## ─────────────────────────────────────────────────────────────────────────
  ## Owner predicate (design lock §4)
  ## ─────────────────────────────────────────────────────────────────────────

  @doc """
  Returns `true` iff `agent` is the owner of `path`.

  Owner-of-private rules (design lock §4):
  - `path` must classify as `:private`.
  - The `<agent_id>` slot in the path must equal `agent.id`.
  - The agent must participate in `<space_id>` (or the caller supplies the
    space-id list via the `:agent_space_ids` opt to skip the DB hit).

  For paths that don't classify as private, returns `false` — the caller
  is responsible for routing non-private paths through the right predicate.
  """
  @spec owner_of?(String.t(), Agent.t() | nil, keyword()) :: boolean()
  def owner_of?(path, agent, opts \\ [])

  def owner_of?(_path, nil, _opts), do: false

  def owner_of?(path, %Agent{id: agent_id} = agent, opts) when is_binary(path) do
    case Regex.named_captures(@private_re, path) do
      %{"space" => space_id, "agent" => path_agent_id} ->
        with {:ok, casted_agent} <- Ecto.UUID.cast(path_agent_id),
             {:ok, casted_space} <- Ecto.UUID.cast(space_id),
             true <- casted_agent == agent_id,
             true <- participant?(agent, casted_space, opts) do
          true
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  def owner_of?(_path, _agent, _opts), do: false

  defp participant?(%Agent{id: agent_id}, space_id, opts) do
    case Keyword.fetch(opts, :agent_space_ids) do
      {:ok, ids} when is_list(ids) -> space_id in ids
      :error -> space_id in Enum.map(Chat.list_spaces_for_agent(agent_id), & &1.id)
    end
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## Write/read gates (design lock §5)
  ## ─────────────────────────────────────────────────────────────────────────

  @doc """
  Authorize a write action against `path` for `agent`.

  Returns `:ok` or `{:error, error_map()}`. Error map fields per
  design lock §3/§5:

  - `:code` — `:historian_required | :not_owner | :rejected_namespace | :invalid_agent`
  - `:message` — user-facing prose; for `:historian_required` against a
    page path the literal verbatim string from §3
  - `:suggestion` — actionable next step. For `:historian_required` this is
    `"memory_create at <namespace>/journal/<YYYY-MM-DD>.md"` where the date is
    today UTC.
  - `:recoverable` — `true` when the caller can reasonably retry via the
    suggested path; `false` for `:rejected_namespace`.

  Opts:
  - `:agent_space_ids` — pre-resolved list of space ids the agent
    participates in. When supplied, skips the `Chat.list_spaces_for_agent/2`
    DB lookup. Stage 3/4 callers that already preload this list should
    pass it through.
  - `:today` — `Date.t()`, overrides the journal-suggestion date (test seam).
  """
  @spec gate_write(Agent.t() | nil, String.t(), keyword()) ::
          :ok | {:error, error()}
  def gate_write(agent, path, opts \\ []) when is_binary(path) do
    case classify(path) do
      %{kind: :unknown} -> {:error, rejected_namespace_error(path)}
      %{kind: :journal} -> :ok
      %{kind: :page, namespace: ns} -> page_write_gate(agent, ns, opts)
      %{kind: :private} -> private_gate(agent, path, opts)
    end
  end

  @doc """
  Authorize a read action against `path` for `agent`.

  Page and journal reads are `:anyone` per §2 — `:ok` for any non-nil
  classification. Private reads require ownership (same predicate as
  writes). Unknown paths reject.
  """
  @spec gate_read(Agent.t() | nil, String.t(), keyword()) ::
          :ok | {:error, error()}
  def gate_read(agent, path, opts \\ []) when is_binary(path) do
    case classify(path) do
      %{kind: :unknown} -> {:error, rejected_namespace_error(path)}
      %{kind: :page} -> :ok
      %{kind: :journal} -> :ok
      %{kind: :private} -> private_gate(agent, path, opts)
    end
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## Gate internals
  ## ─────────────────────────────────────────────────────────────────────────

  defp page_write_gate(agent, namespace, opts) do
    if historian?(agent) do
      :ok
    else
      {:error, historian_required_error(namespace, opts)}
    end
  end

  defp private_gate(nil, _path, _opts), do: {:error, not_owner_error()}

  defp private_gate(%Agent{} = agent, path, opts) do
    if owner_of?(path, agent, opts), do: :ok, else: {:error, not_owner_error()}
  end

  defp private_gate(_, _, _), do: {:error, invalid_agent_error()}

  defp historian_required_error(namespace, opts) do
    today = Keyword.get(opts, :today, Date.utc_today())
    suggested_path = "#{namespace}/journal/#{Date.to_iso8601(today)}.md"
    suggestion = "memory_create at #{suggested_path}"

    %{
      code: :historian_required,
      message:
        "This path requires the Historian role. Propose the change via a journal entry instead — #{suggestion}.",
      suggestion: suggestion,
      recoverable: true
    }
  end

  defp not_owner_error do
    %{
      code: :not_owner,
      message:
        "This path is owned by another agent. You may only read or write your own `space/<id>/private/<your-agent-id>/...` paths.",
      suggestion: "Use a path under space/<id>/private/<your-agent-id>/ that you own.",
      recoverable: true
    }
  end

  defp invalid_agent_error do
    %{
      code: :invalid_agent,
      message: "An authenticated agent context is required for this path.",
      suggestion: "Retry with a valid agent identity.",
      recoverable: false
    }
  end

  defp rejected_namespace_error(path) do
    %{
      code: :rejected_namespace,
      message:
        "Path #{inspect(path)} does not match any recognised memory namespace. Allowed prefixes: org/page, org/journal, project/<uuid>/page, project/<uuid>/journal, space/<uuid>/page, space/<uuid>/journal, space/<uuid>/private/<agent_uuid>.",
      suggestion: "Use a recognised path prefix.",
      recoverable: false
    }
  end
end
