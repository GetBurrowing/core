defmodule Platform.Chat.Canvas.Versions do
  @moduledoc """
  Read/write helpers for `canvas_versions` (task 019e0ac0).

  All writes go through `multi_insert/5` so callers can compose them inside the
  same `Ecto.Multi` as the canvas mutation that produced them. There is no
  `insert/5` shortcut on purpose — atomicity with the canvas write is the
  whole point of the table; a successful version row paired with a failed
  canvas write would silently corrupt history.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Version
  alias Platform.Repo

  @doc """
  Add a `canvas_versions` insert step to a multi.

  `written_by_attribution` is the denormalized author shape — see
  `attribution_for_participant/1` and `attribution_for_agent/2`. Either can be
  built ahead of time when the participant struct is already loaded.
  """
  @spec multi_insert(Multi.t(), atom(), binary(), pos_integer(), map(), map()) :: Multi.t()
  def multi_insert(multi, step_name, canvas_id, revision, document, written_by_attribution)
      when is_binary(canvas_id) and is_integer(revision) and is_map(document) and
             is_map(written_by_attribution) do
    multi_insert(multi, step_name, canvas_id, revision, document, written_by_attribution, nil)
  end

  @spec multi_insert(Multi.t(), atom(), binary(), pos_integer(), map(), map(), list() | nil) ::
          Multi.t()
  def multi_insert(multi, step_name, canvas_id, revision, document, written_by_attribution, ops)
      when is_binary(canvas_id) and is_integer(revision) and is_map(document) and
             is_map(written_by_attribution) do
    Multi.run(multi, step_name, fn repo, _changes ->
      attrs = %{
        canvas_id: canvas_id,
        revision: revision,
        document: document,
        ops: ops,
        written_by: written_by_attribution,
        written_at: DateTime.utc_now()
      }

      %Version{}
      |> Version.changeset(attrs)
      |> repo.insert()
    end)
  end

  @doc """
  List versions for a canvas, newest-first. `limit` defaults to 20, capped at
  100. `before_revision` is an exclusive upper-bound cursor for paging older
  rows.
  """
  @spec list_for_canvas(binary(), keyword()) :: [Version.t()]
  def list_for_canvas(canvas_id, opts \\ []) when is_binary(canvas_id) do
    limit =
      opts
      |> Keyword.get(:limit, 20)
      |> max(1)
      |> min(100)

    before_revision = Keyword.get(opts, :before_revision)

    base =
      from(v in Version,
        where: v.canvas_id == ^canvas_id,
        order_by: [desc: v.revision],
        limit: ^limit
      )

    query =
      case before_revision do
        nil -> base
        rev when is_integer(rev) -> from(v in base, where: v.revision < ^rev)
      end

    Repo.all(query)
  end

  @doc "Fetch the version row for `(canvas_id, revision)`, or `nil`."
  @spec get(binary(), pos_integer()) :: Version.t() | nil
  def get(canvas_id, revision) when is_binary(canvas_id) and is_integer(revision) do
    Repo.one(from(v in Version, where: v.canvas_id == ^canvas_id and v.revision == ^revision))
  end

  @doc """
  Build the denormalized author attribution from a `Platform.Chat.Participant`
  struct.

  Returns the canonical shape `%{"type", "id", "display_name", "slug"?}` —
  string keys so the JSONB column round-trips identically. `slug` is set
  from `agent_id` when the participant is an agent, mirroring the runtime's
  agent_id-first lookups.
  """
  @spec attribution_for_participant(map()) :: map()
  def attribution_for_participant(%{
        participant_type: type,
        participant_id: pid,
        display_name: name,
        id: participant_row_id
      }) do
    base = %{
      "type" => type || "unknown",
      "id" => participant_row_id,
      "participant_id" => pid,
      "display_name" => name
    }

    if type == "agent" and is_binary(pid) do
      Map.put(base, "slug", pid)
    else
      base
    end
  end

  def attribution_for_participant(other) when is_map(other) do
    %{
      "type" =>
        Map.get(other, :participant_type) || Map.get(other, "participant_type") || "unknown",
      "id" => Map.get(other, :id) || Map.get(other, "id"),
      "display_name" => Map.get(other, :display_name) || Map.get(other, "display_name")
    }
  end

  def attribution_for_participant(_), do: %{"type" => "unknown"}

  @doc """
  Build attribution from raw fields. Used by paths that don't have a
  participant struct in scope (e.g. `Canvas.Server` persist callbacks invoked
  by an async task).
  """
  @spec attribution_from_fields(map()) :: map()
  def attribution_from_fields(fields) when is_map(fields) do
    type = Map.get(fields, :type) || Map.get(fields, "type") || "unknown"
    id = Map.get(fields, :id) || Map.get(fields, "id")
    display_name = Map.get(fields, :display_name) || Map.get(fields, "display_name")
    slug = Map.get(fields, :slug) || Map.get(fields, "slug")

    base = %{
      "type" => type,
      "id" => id,
      "display_name" => display_name
    }

    if is_binary(slug), do: Map.put(base, "slug", slug), else: base
  end

  def attribution_from_fields(_), do: %{"type" => "unknown"}

  @doc """
  Best-effort attribution from a canvas's snapshotted creator fields. Used by
  the create path when a Participant lookup isn't worth the round-trip.
  """
  @spec attribution_from_canvas(Canvas.t()) :: map()
  def attribution_from_canvas(%Canvas{} = canvas) do
    %{
      "type" => canvas.created_by_participant_type || "unknown",
      "id" => canvas.created_by,
      "display_name" => canvas.created_by_display_name
    }
  end

  @doc """
  Resolve a tool-call `context` into the denormalized author shape, preferring
  the most specific identity the caller actually carries: agent, then chat
  participant, then user, then `system`.

  Lives here rather than beside a single handler because both write paths that
  have a caller identity — `canvas.patch` and `canvas.restore` — need the same
  answer. Two copies of an attribution resolver is how those paths drifted to
  two different answers in the first place (task 019fed8d): the restore path
  resolved the agent, the patch path passed nothing and recorded `unknown`.

  Note the tail is `system`, never `unknown`. `unknown` is what an *absent*
  attribution decays to, so a deliberate identity-less write recorded as
  `unknown` is indistinguishable from an attribution bug.
  """
  @spec attribution_from_context(map(), binary() | nil) :: map()
  def attribution_from_context(context, space_id) when is_map(context) do
    cond do
      is_binary(Map.get(context, :agent_id)) ->
        agent_id = Map.get(context, :agent_id)
        participant = space_id && Chat.get_agent_participant(space_id, agent_id)

        attribution_from_fields(%{
          type: "agent",
          id: participant && participant.id,
          display_name: participant && participant.display_name,
          slug: agent_id
        })

      is_binary(Map.get(context, :participant_id)) ->
        attribution_from_fields(%{
          type: Map.get(context, :participant_type) || "user",
          id: Map.get(context, :participant_id),
          display_name: Map.get(context, :display_name)
        })

      is_binary(Map.get(context, :user_id)) ->
        attribution_from_fields(%{
          type: "user",
          id: Map.get(context, :user_id),
          display_name: Map.get(context, :display_name)
        })

      true ->
        %{"type" => "system"}
    end
  end

  def attribution_from_context(_context, _space_id), do: %{"type" => "system"}

  @doc """
  Derive a 1-sentence human-readable summary from the stored ops list.

  Mirrors the patch op shape (lists, since the JSONB encoder turns tuples
  into arrays). For the create row (`ops: nil`) returns the literal "initial
  create".
  """
  @spec op_summary(any()) :: String.t()
  def op_summary(nil), do: "initial create"
  def op_summary([]), do: "no-op"
  def op_summary(%Version{} = v), do: op_summary(Version.ops(v))
  def op_summary(%{"ops" => ops}), do: op_summary(ops)

  def op_summary(ops) when is_list(ops) do
    cond do
      single_restore?(ops) ->
        "restore from revision #{single_restore_target(ops)}"

      length(ops) == 1 ->
        summarize_one(List.first(ops))

      true ->
        first_summary = summarize_one(List.first(ops))
        "#{first_summary} (+#{length(ops) - 1} more)"
    end
  end

  def op_summary(_), do: "unknown"

  defp single_restore?([["restore_from_revision", _]]), do: true
  defp single_restore?(_), do: false

  defp single_restore_target([["restore_from_revision", r]]), do: r
  defp single_restore_target(_), do: nil

  defp summarize_one(["set_props", id, props]) when is_map(props),
    do: "set_props on #{format_id(id)} (#{map_size(props)} keys)"

  defp summarize_one(["replace_children", id, children]) when is_list(children),
    do: "replace_children on #{format_id(id)} (#{length(children)} children)"

  defp summarize_one(["append_child", id, _child]),
    do: "append_child on #{format_id(id)}"

  defp summarize_one(["delete_node", id]),
    do: "delete_node #{format_id(id)}"

  defp summarize_one(["replace_document", _doc]),
    do: "replace_document"

  defp summarize_one(["restore_from_revision", r]),
    do: "restore from revision #{r}"

  defp summarize_one([name | _]) when is_binary(name), do: name
  defp summarize_one(other), do: inspect(other)

  defp format_id(id) when is_binary(id), do: "'#{id}'"
  defp format_id(id), do: inspect(id)
end
