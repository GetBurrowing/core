defmodule Platform.Chat.Canvas.VersionHandlers do
  @moduledoc """
  Tool handlers for `canvas.versions` and `canvas.restore` (task 019e0ac0).

  Both tools resolve their canvas through `Platform.Chat.Canvas.ToolAccess`,
  which is the one authorization seam for the canvas MCP surface (task 019fb01b
  stage 1). They ask it different questions:

    * `canvas.versions` — `fetch_for_read/2`, the same call `canvas.describe`
      makes, so "same auth gate as canvas.describe" in the tool description is
      a fact rather than an aspiration.
    * `canvas.restore` — `fetch_for_write/3`, the same call `canvas.patch`
      makes. A restore is a full-document overwrite, so it is the most
      destructive write on the canvas surface, not the least.

  ## The fail-open both of these replaced

  Each tool used to run through a local `assert_member/2` that returned `:ok`
  whenever `context.agent_id` was nil, on the theory that such a caller had to
  be the in-app LiveView. Nothing enforced that theory: these handlers are only
  ever reached from `Platform.Federation.ToolSurface`, i.e. from a remote
  runtime, and `agent_id` is a nullable `:binary_id` on
  `Platform.Agents.AgentRuntime`, so a nil is reachable for an authenticated
  caller. Task 019e2c4b stage 2 took `canvas.restore` off it; task 019fb01b
  stage 3 took `canvas.versions` off it and DELETED the function, so nothing
  added here later can reach it by reflex.

  ## The circular-dependency constraint, still in force

  `assert_member/2` was local rather than a call into
  `Platform.Federation.ToolSurface.assert_agent_in_space/2` because the
  federation surface dispatches to this module, so pointing back at it would
  close a cycle. `ToolAccess` keeps that property: its dependency direction is
  `ToolAccess -> CanvasAccess -> Chat`, and nothing in it refers to the
  federation surface.
  """

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Canvas.ToolAccess
  alias Platform.Chat.Canvas.Versions

  @restore_denial "Access denied: canvas.restore overwrites the whole document, so it requires " <>
                    "participation in the canvas's space. Read access does not confer it."

  @restore_suggestion "Ask a human to add you to the space that owns this canvas."

  @doc """
  canvas.versions — paginated newest-first version metadata, for a caller
  authorized to read the canvas.

  Args: `%{"canvas_id" => string, "limit"? => integer, "before_revision"? =>
  integer}`. Returns `%{canvas_id, versions: [%{revision, written_at,
  written_by, op_summary}], next_cursor}`. `next_cursor` is the
  `before_revision` value to pass on the next page (nil when exhausted).

  Authorization resolves the canvas and the grant in one call
  (`ToolAccess.fetch_for_read/2`) rather than fetching first and asking after,
  which is what let the old `assert_member/2` be handed a canvas it then failed
  to protect. Revision numbers, write timestamps and `written_by` attribution
  are the payload here, so a fail-open on this tool leaks who worked on what
  and when across every tenant, without ever touching a document.
  """
  @spec versions(map(), map()) :: {:ok, map()} | {:error, map()}
  def versions(args, context) do
    with {:ok, canvas_id} <- require_string(args, "canvas_id"),
         {:ok, canvas} <- ToolAccess.fetch_for_read(canvas_id, context) do
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

  # The WRITE gate for `canvas.restore` (task 019e2c4b stage 2). Resolution
  # lives in `ToolAccess` (task 019fb01b stage 1); only the denial sentence is
  # this handler's, because only the sentence differs between the canvas write
  # tools. An unidentified actor denies — see the moduledoc for the fail-open
  # this replaced and why nil is a reachable caller shape.
  defp assert_writer(canvas_id, context) do
    case ToolAccess.fetch_for_write(canvas_id, context,
           denial: @restore_denial,
           suggestion: @restore_suggestion
         ) do
      {:ok, _canvas} -> :ok
      {:error, payload} -> {:error, payload}
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
