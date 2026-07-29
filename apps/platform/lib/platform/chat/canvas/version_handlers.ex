defmodule Platform.Chat.Canvas.VersionHandlers do
  @moduledoc """
  Tool handlers for `canvas.versions` and `canvas.restore` (task 019e0ac0).

  Authorization mirrors the existing canvas surface:

    * `canvas.versions` — same gate as `canvas_get` (read membership in the
      canvas's space, asserted via `Platform.Federation.ToolSurface`'s
      `assert_agent_in_space/2`-equivalent here).
    * `canvas.restore` — same gate as `canvas.patch`, literally: both call
      `Platform.Chat.CanvasAccess.fetch_for_writer/2` (task 019e2c4b stage 2).
      A restore is a full-document overwrite, so it is the most destructive
      write on the canvas surface, not the least.

  Until stage 2 that second bullet was aspirational: `canvas.restore` used a
  local `assert_member/2` that fell through to `:ok` whenever `context.agent_id`
  was nil. `agent_id` is not required on `Platform.Agents.AgentRuntime`, so an
  authenticated runtime with no linked agent is a reachable state — and it
  could restore any canvas in any space. Read authorization is unchanged and
  still uses `assert_member/2`.
  """

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.Versions
  alias Platform.Chat.CanvasAccess

  @doc """
  canvas.versions — paginated newest-first version metadata.

  Args: `%{"canvas_id" => string, "limit"? => integer, "before_revision"? =>
  integer}`. Returns `%{canvas_id, versions: [%{revision, written_at,
  written_by, op_summary}], next_cursor}`. `next_cursor` is the
  `before_revision` value to pass on the next page (nil when exhausted).
  """
  @spec versions(map(), map()) :: {:ok, map()} | {:error, map()}
  def versions(args, context) do
    with {:ok, canvas_id} <- require_string(args, "canvas_id"),
         {:ok, canvas} <- fetch_canvas(canvas_id),
         :ok <- assert_member(canvas.space_id, context) do
      limit = clamp_limit(Map.get(args, "limit", 20))
      before_revision = parse_optional_integer(Map.get(args, "before_revision"))

      rows =
        Versions.list_for_canvas(canvas.id,
          limit: limit,
          before_revision: before_revision
        )

      next_cursor =
        case rows do
          [] -> nil
          _ when length(rows) < limit -> nil
          _ -> List.last(rows).revision
        end

      {:ok,
       %{
         canvas_id: canvas.id,
         versions: Enum.map(rows, &serialize_row/1),
         next_cursor: next_cursor
       }}
    end
  end

  @doc """
  canvas.restore — overwrite the live canvas with a historical revision's
  document. Produces a new version row at `current_revision + 1` with
  `ops: [["restore_from_revision", revision]]`.
  """
  @spec restore(map(), map()) :: {:ok, map()} | {:error, map()}
  def restore(args, context) do
    with {:ok, canvas_id} <- require_string(args, "canvas_id"),
         {:ok, revision} <- require_integer(args, "revision"),
         {:ok, canvas} <- fetch_canvas(canvas_id),
         :ok <- assert_writer(canvas.id, context),
         {:ok, version} <- fetch_version(canvas.id, revision),
         {:ok, %{revision: current_revision}} <- CanvasServer.describe(canvas.id) do
      attribution = attribution_from_context(context, canvas.space_id)

      operations = [{:replace_document, version.document}]

      case CanvasServer.apply_patches(canvas.id, operations, current_revision, attribution) do
        {:ok, new_revision} ->
          # Re-tag the just-written version row's ops to reflect that this is
          # a restore — the in-memory ops list would otherwise serialize as a
          # generic `replace_document`, hiding the restore intent in history.
          rewrite_restore_ops(canvas.id, new_revision, revision)

          {:ok,
           %{
             canvas_id: canvas.id,
             revision: new_revision,
             restored_from: revision
           }}

        {:conflict, payload} ->
          {:error,
           %{
             error: "canvas.restore conflict: #{inspect(payload.reason)}",
             recoverable: true,
             conflict: payload
           }}

        {:error, reason} ->
          {:error, %{error: "canvas.restore failed: #{inspect(reason)}", recoverable: true}}
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp serialize_row(row) do
    %{
      revision: row.revision,
      written_at: format_datetime(row.written_at),
      written_by: row.written_by || %{},
      op_summary: Versions.op_summary(row)
    }
  end

  defp fetch_canvas(canvas_id) do
    case Chat.get_canvas(canvas_id) do
      nil ->
        {:error,
         %{
           error: "Canvas not found: #{canvas_id}",
           recoverable: false,
           suggestion: "Use canvas_list to find available canvases in the space"
         }}

      canvas ->
        {:ok, canvas}
    end
  end

  defp fetch_version(canvas_id, revision) do
    case Versions.get(canvas_id, revision) do
      nil ->
        {:error,
         %{
           error: "Canvas #{canvas_id} has no version at revision #{revision}",
           recoverable: false,
           suggestion: "Use canvas.versions to list available revisions"
         }}

      version ->
        {:ok, version}
    end
  end

  # The WRITE gate for `canvas.restore` (task 019e2c4b stage 2), replacing the
  # fail-open `assert_member/2` below.
  #
  # Deliberately NOT `assert_member/2`: that returns `:ok` when `agent_id` is
  # nil on the theory that the caller must be the in-app LiveView. Nothing
  # enforces that theory on this handler — it is only ever reached from
  # `Platform.Federation.ToolSurface`, i.e. from a remote runtime — and
  # `agent_id` is not required on an `AgentRuntime`, so nil is reachable for an
  # authenticated caller. Here an unidentified actor denies.
  defp assert_writer(canvas_id, context) do
    case CanvasAccess.fetch_for_writer(canvas_id, actor_from_context(context)) do
      {:ok, _canvas} ->
        :ok

      {:error, :not_found} ->
        {:error, %{error: "canvas #{canvas_id} not found", recoverable: false}}

      {:error, :forbidden} ->
        {:error,
         %{
           error:
             "Access denied: canvas.restore overwrites the whole document, so it requires " <>
               "participation in the canvas's space. Read access does not confer it.",
           recoverable: false,
           canvas_id: canvas_id,
           suggestion: "Ask a human to add you to the space that owns this canvas."
         }}
    end
  end

  defp actor_from_context(context) when is_map(context) do
    cond do
      is_binary(Map.get(context, :agent_id)) -> {:agent, Map.get(context, :agent_id)}
      is_binary(Map.get(context, :user_id)) -> {:user, Map.get(context, :user_id)}
      true -> nil
    end
  end

  defp actor_from_context(_context), do: nil

  # Mirrors Platform.Federation.ToolSurface.assert_agent_in_space/2 but local
  # so this module doesn't take a circular dep on the federation surface.
  # Same contract: agent must be a participant in the space; user-driven calls
  # without an agent context fall through (the caller is the LiveView, which
  # checks membership at navigation time).
  defp assert_member(space_id, context) do
    cond do
      is_nil(space_id) ->
        {:error, %{error: "space_id is required", recoverable: true}}

      Map.get(context, :agent_id) == nil ->
        # No agent — treat as an in-app caller; the LiveView path is its own
        # auth gate. Still reject if there's no canvas in scope at all (caught
        # earlier by fetch_canvas/1).
        :ok

      true ->
        agent_id = Map.get(context, :agent_id)

        case Chat.get_agent_participant(space_id, agent_id) do
          %Chat.Participant{} ->
            :ok

          _ ->
            {:error,
             %{
               error: "Access denied: agent is not a participant in space #{space_id}",
               recoverable: false,
               suggestion: "Use space_list to find spaces the agent has access to"
             }}
        end
    end
  end

  defp attribution_from_context(context, space_id) do
    cond do
      is_binary(Map.get(context, :agent_id)) ->
        agent_id = Map.get(context, :agent_id)
        participant = Chat.get_agent_participant(space_id, agent_id)

        Versions.attribution_from_fields(%{
          type: "agent",
          id: participant && participant.id,
          display_name: participant && participant.display_name,
          slug: agent_id
        })

      is_binary(Map.get(context, :participant_id)) ->
        Versions.attribution_from_fields(%{
          type: Map.get(context, :participant_type) || "user",
          id: Map.get(context, :participant_id),
          display_name: Map.get(context, :display_name)
        })

      is_binary(Map.get(context, :user_id)) ->
        Versions.attribution_from_fields(%{
          type: "user",
          id: Map.get(context, :user_id),
          display_name: Map.get(context, :display_name)
        })

      true ->
        %{"type" => "system"}
    end
  end

  # The version-row write happens inside Canvas.Server.do_persist async; we
  # poll briefly for the row to appear so the explicit restore-marker survives
  # in history rather than the literal replace_document op. Best-effort — if
  # the row doesn't show up in the budget, leave the generic ops behind; the
  # restored document is still accurate.
  defp rewrite_restore_ops(canvas_id, revision, source_revision) do
    case wait_for_version_row(canvas_id, revision, 250) do
      {:ok, version} ->
        version
        |> Ecto.Changeset.change(%{
          ops: %{"ops" => [["restore_from_revision", source_revision]]}
        })
        |> Platform.Repo.update()

        :ok

      :timeout ->
        :ok
    end
  end

  defp wait_for_version_row(canvas_id, revision, deadline_ms) do
    do_wait_for_version_row(canvas_id, revision, System.monotonic_time(:millisecond), deadline_ms)
  end

  defp do_wait_for_version_row(canvas_id, revision, started_at_ms, deadline_ms) do
    case Versions.get(canvas_id, revision) do
      nil ->
        elapsed = System.monotonic_time(:millisecond) - started_at_ms

        if elapsed >= deadline_ms do
          :timeout
        else
          Process.sleep(10)
          do_wait_for_version_row(canvas_id, revision, started_at_ms, deadline_ms)
        end

      version ->
        {:ok, version}
    end
  end

  defp clamp_limit(v) when is_integer(v), do: v |> max(1) |> min(100)
  defp clamp_limit(_), do: 20

  defp parse_optional_integer(nil), do: nil
  defp parse_optional_integer(v) when is_integer(v), do: v

  defp parse_optional_integer(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_optional_integer(_), do: nil

  defp require_string(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, %{error: "missing or invalid \"#{key}\" (string)", recoverable: true}}
    end
  end

  defp require_integer(map, key) do
    case Map.get(map, key) do
      v when is_integer(v) ->
        {:ok, v}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n}
          _ -> {:error, %{error: "missing or invalid \"#{key}\" (integer)", recoverable: true}}
        end

      _ ->
        {:error, %{error: "missing or invalid \"#{key}\" (integer)", recoverable: true}}
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
