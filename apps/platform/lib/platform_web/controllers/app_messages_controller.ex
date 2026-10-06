defmodule PlatformWeb.AppMessagesController do
  @moduledoc """
  The native app's message actions (task 01a111bb stage 2), behind
  `PlatformWeb.Plugs.AppBearerAuth` (`:app_api`). They back the iOS 27
  messages domain's editSentMessage, unsendMessage and setMessageReadStatus
  schemas.

    * `PATCH /api/app/messages/:id {text}` edits through
      `Platform.Chat.Messages.Edit.apply_edit/3`, the entry the web inline
      editor uses, so the agent-began-work freeze answers 409 `frozen` with
      the freezing participant's display name (`by`) and nothing else.
    * `DELETE /api/app/messages/:id` unsends through
      `Platform.Chat.delete_message/1` (a soft delete). No web delete handler
      exists to mirror (ChatLive has none on 2026-10-06), so the guards are
      exactly the two below; the space-archived refusal is `delete_message`'s
      own.
    * `POST /api/app/spaces/:space_id/read {message_id, read}`: `read: true`
      moves the caller's read cursor with `Platform.Chat.mark_space_read/2`.
      `read: false` is 422 `not_supported`: there is no mark-unread.

  Every route authorizes the space with
  `Platform.Mobile.AppEntities.authorize_space/2` (exists, not archived,
  external scope, participant). Edit and unsend also require
  `Platform.Chat.authorize_author/2`; marking read does not, because the
  messages a person marks read are other people's.

  A message in a space the caller cannot use answers 404, the same as one
  that does not exist. Nothing here logs message content.
  """
  use PlatformWeb, :controller

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Messages.Edit
  alias Platform.Mobile.AppEntities

  @max_text_length 10_000

  # ── edit ─────────────────────────────────────────────────────────────

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, text} <- validate_text(params["text"]),
         {:ok, message, participant} <- own_message(user, id) do
      case Edit.apply_edit(message, participant, text) do
        {:ok, updated} ->
          json(conn, %{id: updated.id, edited_at: updated.edited_at})

        {:error, :frozen, freezing_action} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "frozen", by: Map.get(freezing_action, :participant_display_name)})

        {:error, _changeset} ->
          error(conn, :unprocessable_entity, "not_edited")
      end
    else
      {:error, status, code} -> error(conn, status, code)
    end
  end

  # ── unsend ───────────────────────────────────────────────────────────

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, message, _participant} <- own_message(user, id) do
      case Chat.delete_message(message) do
        {:ok, _deleted} -> send_resp(conn, :no_content, "")
        {:error, :space_archived} -> error(conn, :forbidden, "forbidden")
        {:error, _reason} -> error(conn, :unprocessable_entity, "not_deleted")
      end
    else
      {:error, status, code} -> error(conn, status, code)
    end
  end

  # ── read status ──────────────────────────────────────────────────────

  def read(conn, %{"space_id" => space_id} = params) do
    user = conn.assigns.current_user

    with {:ok, space, participant} <- space_for(user, space_id),
         {:ok, message} <- message_in_space(params["message_id"], space.id) do
      case params["read"] do
        value when value in [true, "true"] ->
          :ok = Chat.mark_space_read(participant.id, message.id)
          json(conn, %{read: true, message_id: message.id})

        value when value in [false, "false"] ->
          error(conn, :unprocessable_entity, "not_supported")

        _ ->
          error(conn, :unprocessable_entity, "invalid_read")
      end
    else
      {:error, status, code} -> error(conn, status, code)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  # The message, its space authorized for the caller, and the caller as its
  # author. 404 when the message is missing, deleted, or in a space the
  # caller cannot use; 403 when it is someone else's.
  defp own_message(user, id) do
    with %Message{deleted_at: nil} = message <- Chat.get_message(id),
         {:ok, _space, participant} <- AppEntities.authorize_space(user, message.space_id) do
      case Chat.authorize_author(message, participant) do
        :ok -> {:ok, message, participant}
        {:error, :forbidden} -> {:error, :forbidden, "forbidden"}
      end
    else
      _ -> {:error, :not_found, "not_found"}
    end
  end

  defp space_for(user, space_id) do
    case AppEntities.authorize_space(user, space_id) do
      {:ok, space, participant} -> {:ok, space, participant}
      {:error, :forbidden} -> {:error, :not_found, "not_found"}
    end
  end

  defp message_in_space(message_id, space_id) do
    case Chat.get_message(message_id) do
      %Message{space_id: ^space_id, deleted_at: nil} = message -> {:ok, message}
      _ -> {:error, :unprocessable_entity, "invalid_message_id"}
    end
  end

  defp validate_text(text) when is_binary(text) do
    cond do
      String.trim(text) == "" -> {:error, :unprocessable_entity, "empty_text"}
      String.length(text) > @max_text_length -> {:error, :unprocessable_entity, "text_too_long"}
      true -> {:ok, text}
    end
  end

  defp validate_text(_), do: {:error, :unprocessable_entity, "empty_text"}

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
