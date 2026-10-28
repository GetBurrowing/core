defmodule Platform.Chat.Canvas.Broadcasts do
  @moduledoc false
  import Ecto.Query
  alias Platform.Chat.Canvas
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Repo

  # Ownership moves take FOR UPDATE on this row. Hold a shared lock until
  # broadcasting finishes, so a delayed persistence task cannot publish to
  # the old space after the move's removal event. Use canonical metadata,
  # never the stale ownership on the writer's pre-move Ecto struct.
  def updated(%Canvas{id: id}) do
    Repo.transaction(fn ->
      case Repo.one(from(c in Canvas, where: c.id == ^id, lock: "FOR SHARE")) do
        %Canvas{deleted_at: nil} = canvas ->
          :telemetry.execute(
            [:platform, :chat, :canvas_updated],
            %{system_time: System.system_time()},
            %{
              canvas_id: canvas.id,
              space_id: canvas.space_id,
              document_kind: Platform.Chat.CanvasDocument.root_kind(canvas.document),
              title: canvas.title
            }
          )

          ChatPubSub.broadcast(canvas.space_id, {:canvas_updated, canvas})
          ChatPubSub.broadcast_canvas(canvas.id, {:canvas_updated, canvas})

        _ ->
          :ok
      end
    end)

    :ok
  end
end
