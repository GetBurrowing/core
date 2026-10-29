defmodule Platform.Chat.Canvas.Restore do
  @moduledoc """
  Actor-authorized, optimistic history restore shared by the two human canvas
  surfaces (task 01a1557a, rung 17). The canvas server serializes the command
  with patches and ownership moves. Source ops and both snapshots commit in
  the canonical canvas/version transaction, never in a later tagging task.
  """
  alias Platform.{Access, Chat, Repo}
  alias Platform.Chat.{Canvas, CanvasAccess, CanvasPatch, CanvasSearchIndex}
  alias Platform.Chat.Canvas.{Server, ScriptedEmbeds, Version, Versions}
  alias Platform.Files.BrowserActions
  alias Ecto.Multi

  # canvas_versions.revision is PostgreSQL integer (int4). Check before
  # any Versions.get/2, including forged legacy drawer confirmation events.
  @max_revision 2_147_483_647
  def restore(actor, canvas_id, source_revision, expected_revision)
      when is_integer(source_revision) and source_revision > 0 and
             source_revision <= @max_revision and
             is_integer(expected_revision) and expected_revision > 0 and
             expected_revision < @max_revision do
    with {:ok, _, _} <- authorize(actor, canvas_id) do
      Server.restore(canvas_id, actor, source_revision, expected_revision)
    end
  end

  def restore(_, _, _, _), do: {:error, :invalid_revision}

  def authorize(actor, canvas_id) do
    with {:ok, viewer} <- BrowserActions.viewer(actor),
         {:ok, canvas} <- CanvasAccess.fetch_for_writer(canvas_id, viewer.user),
         :ok <- Access.check(viewer.access_scope, "canvas.read", {:canvas, canvas.id}),
         :ok <- Access.check(viewer.access_scope, "canvas.write", {:canvas, canvas.id}),
         true <- Chat.space_writable?(canvas.space_id) do
      participant =
        Enum.find(
          Chat.list_participants(canvas.space_id),
          &(&1.participant_type == "user" and &1.participant_id == viewer.user.id)
        )

      attribution =
        if participant,
          do: Versions.attribution_for_participant(participant),
          else:
            Versions.attribution_from_context(
              %{user_id: viewer.user.id, display_name: viewer.user.name},
              canvas.space_id
            )

      {:ok, canvas, attribution}
    else
      false -> {:error, :space_archived}
      {:error, _} = error -> error
    end
  end

  @doc false
  def perform(state, actor, source_revision, expected_revision) do
    with {:ok, canvas, attribution} <- authorize(actor, state.canvas_id),
         :ok <- at_head(state.revision, expected_revision),
         true <- state.revision < @max_revision,
         true <-
           is_integer(source_revision) and source_revision > 0 and
             source_revision < state.revision and source_revision <= @max_revision,
         %Version{} = source <- Versions.get(canvas.id, source_revision),
         {:ok, document} <-
           CanvasPatch.apply_many(state.document, [{:replace_document, source.document}]),
         {:ok, document, refs} <-
           ScriptedEmbeds.stamp(document, %{
             canvas_id: canvas.id,
             space_id: canvas.space_id,
             actor: attribution,
             verified: state.embed_refs
           }) do
      revision = state.revision + 1
      document = Map.put(document, "revision", revision)

      multi =
        Multi.new()
        |> Multi.run(:authorized, fn _repo, _ -> authorize_for_transaction(actor, canvas.id) end)
        |> Multi.run(:previous_head, fn repo, _ -> preserve_head(repo, canvas, state) end)
        |> Multi.update(:canvas, Canvas.changeset(canvas, %{document: document}))
        |> CanvasSearchIndex.upsert_multi(:canvas_search, & &1.canvas)
        |> Versions.multi_insert(:canvas_version, canvas.id, revision, document, attribution, [
          ["restore_from_revision", source_revision]
        ])

      case Repo.transaction(multi) do
        {:ok, %{canvas: updated}} -> {:ok, updated, refs}
        {:error, _, reason, _} -> {:error, reason}
      end
    else
      {:conflict, _} = conflict -> conflict
      {:error, _} = error -> error
      _ -> {:error, :revision_not_found}
    end
  end

  defp authorize_for_transaction(actor, id) do
    case authorize(actor, id) do
      {:ok, canvas, _} -> {:ok, canvas}
      error -> error
    end
  end

  defp at_head(revision, revision), do: :ok
  defp at_head(current, _), do: {:conflict, %{reason: :stale_revision, current_revision: current}}

  defp preserve_head(repo, canvas, state) do
    attrs = %{
      canvas_id: canvas.id,
      revision: state.revision,
      document: state.document,
      written_by: Versions.attribution_from_canvas(canvas),
      written_at: canvas.updated_at
    }

    %Version{}
    |> Version.changeset(attrs)
    |> repo.insert(on_conflict: :nothing, conflict_target: [:canvas_id, :revision])
  end
end
