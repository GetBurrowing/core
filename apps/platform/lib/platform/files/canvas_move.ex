defmodule Platform.Files.CanvasMove do
  @moduledoc false
  import Ecto.Query
  alias Platform.{Chat, Repo}
  alias Platform.Chat.{Canvas, CanvasRoom}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Files.BrowserActions

  # Called by the canvas server. A monotone epoch quarantines every pre-move
  # subscription, including tool subscribers, even after moving back.
  def perform(actor, canvas_id, destination_id) do
    result =
      Repo.transaction(fn ->
        _ = Repo.one!(from(c in Canvas, where: c.id == ^canvas_id, lock: "FOR UPDATE"))

        with {:ok, canvas} <- BrowserActions.authorize_move(actor, canvas_id, destination_id) do
          if canvas.space_id == destination_id do
            {canvas, canvas}
          else
            moved =
              canvas
              |> Ecto.Changeset.change(
                space_id: destination_id,
                location_epoch: canvas.location_epoch + 1
              )
              |> Repo.update!()

            # Only canvas-owned uploads follow their owner. A message attachment
            # remains in its original space even if the document references it.
            Repo.update_all(
              from(a in Chat.Attachment,
                where: a.canvas_id == ^canvas_id and is_nil(a.message_id)
              ),
              set: [space_id: destination_id]
            )

            {canvas, moved}
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {old, moved}} ->
        if old.space_id != moved.space_id do
          stop_rooms(canvas_id)
          removed = %{id: canvas_id, space_id: old.space_id}
          ChatPubSub.broadcast(old.space_id, {:canvas_deleted, removed})

          Phoenix.PubSub.broadcast(
            Platform.PubSub,
            ChatPubSub.canvas_topic(canvas_id, old.location_epoch),
            {:canvas_deleted, removed}
          )

          ChatPubSub.broadcast(
            moved.space_id,
            {:canvas_arrived, %{id: moved.id, space_id: moved.space_id}}
          )
        end

        {:ok, moved}

      error ->
        error
    end
  end

  # Arrival is an invalidation, never a document delivery. A destination
  # member's personal read deny still applies after a different user moves it.
  def fetch_arrival(actor, %{id: id, space_id: space_id}) do
    with {:ok, viewer} <- BrowserActions.viewer(actor),
         {:ok, %{space_id: ^space_id} = canvas} <-
           Platform.Files.Browser.fetch_source(viewer, {:canvas, id}) do
      {:ok, canvas}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def read_event(actor, %Canvas{} = canvas) do
    # A queued pre-move payload still says epoch zero. Read current ownership
    # before trusting that payload, or it could revive a removed old-space row.
    case Chat.get_canvas(canvas.id) do
      %{location_epoch: epoch} when epoch > 0 ->
        fetch_arrival(actor, Map.take(canvas, [:id, :space_id]))

      %Canvas{} ->
        {:ok, canvas}

      _ ->
        {:error, :not_found}
    end
  end

  def read_event(actor, %{location_epoch: epoch} = canvas) when epoch > 0,
    do: fetch_arrival(actor, Map.take(canvas, [:id, :space_id]))

  def read_event(_actor, canvas), do: {:ok, canvas}

  defp stop_rooms(canvas_id) do
    Registry.select(Platform.Chat.Registry, [
      {{{:canvas_room, canvas_id, :"$1"}, :_, :_}, [], [:"$1"]}
    ])
    |> Enum.each(&CanvasRoom.stop(canvas_id, &1))
  end

  # Production patches carry a user id or an author participant id. Recheck
  # inside the writer, closing the authorize-before-move race. Identity-less
  # calls remain the explicitly trusted server primitive.
  def authorize_patch(canvas_id, attribution) do
    case actor(attribution) do
      nil ->
        :ok

      actor ->
        case Chat.CanvasAccess.fetch_for_writer(canvas_id, actor) do
          {:ok, canvas} ->
            if Chat.space_writable?(canvas.space_id), do: :ok, else: {:error, :space_archived}

          error ->
            error
        end
    end
  end

  defp actor(attribution) do
    type = Map.get(attribution, "type") || Map.get(attribution, :type)
    id = Map.get(attribution, "id") || Map.get(attribution, :id)

    if type in ["user", "agent"] && Platform.UUID.valid?(id) do
      case Chat.get_participant(id) do
        %{participant_type: "agent", participant_id: agent_id} -> {:agent, agent_id}
        %{participant_type: "user", participant_id: user_id} -> {:user, user_id}
        _ when type == "user" -> {:user, id}
        _ -> {:agent, id}
      end
    end
  end
end
