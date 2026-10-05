defmodule PlatformWeb.AppApiController do
  @moduledoc """
  JSON API for the native iOS app (task 01a10882), under `/api/app`.

  `POST /session` is unauthenticated: it redeems the PKCE-bound exchange code
  from the OIDC callback for a bearer token. Every other action runs behind
  `PlatformWeb.Plugs.AppBearerAuth` (`:app_api`), which assigns
  `:current_user` and `:app_session`.

  External users: `:enforce_external_scope`'s plug is keyed on browser paths
  and would refuse every route here, so this controller applies the same
  predicates it does (`Platform.Chat.ExternalScope`) to the spaces it lists
  and writes to. `Chat.post_message_with_attachments/3` additionally runs its
  own external upload gate off `:poster_user_id`.

  Nothing here echoes a bearer token, login code or APNs device token in a
  response or a log line.
  """
  use PlatformWeb, :controller

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.ExternalScope
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Mobile
  alias Platform.Repo

  # ── session ──────────────────────────────────────────────────────────

  def create_session(conn, params) do
    case Mobile.exchange_code(params["code"], params["code_verifier"], %{
           app_install_id: params["app_install_id"],
           device_name: params["device_name"]
         }) do
      {:ok, %{token: token, handoff_code: handoff_code}} ->
        json(conn, %{
          token: token,
          handoff_url: handoff_url(conn, handoff_code, nil)
        })

      {:error, :invalid_code} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_grant"})
    end
  end

  @doc """
  `POST /api/app/handoff`: a fresh one-time handoff URL for the bearer's
  user. WKWebView drops the session-only `_platform_session` cookie when the
  app exits, so on a cold start or an install switch the app signs its web
  view back in with this instead of a new passkey sign-in. An optional
  `path` (a local path, see `Mobile.safe_return_path/1`) is where the
  handoff lands, so a notification's page opens directly.
  """
  def create_handoff(conn, params) do
    case Mobile.issue_handoff_code(conn.assigns.app_session) do
      {:ok, code} ->
        json(conn, %{handoff_url: handoff_url(conn, code, params["path"])})

      {:error, _changeset} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "handoff_not_created"})
    end
  end

  defp handoff_url(conn, code, path) do
    query =
      case Mobile.safe_return_path(path) do
        "/" -> [code: code]
        to -> [code: code, to: to]
      end

    url(conn, ~p"/auth/app/handoff?#{query}")
  end

  def delete_session(conn, _params) do
    {:ok, _session} = Mobile.revoke_session(conn.assigns.app_session)
    send_resp(conn, :no_content, "")
  end

  # ── devices ──────────────────────────────────────────────────────────

  def register_device(conn, params) do
    attrs = Map.take(params, ~w(token environment bundle_id app_install_id))

    case Mobile.register_device(conn.assigns.app_session, attrs) do
      {:ok, _device} ->
        json(conn, %{registered: true})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_device", fields: error_fields(changeset)})
    end
  end

  def unregister_device(conn, %{"app_install_id" => install_id}) do
    :ok = Mobile.unregister_device(conn.assigns.current_user, install_id)
    send_resp(conn, :no_content, "")
  end

  # ── spaces ───────────────────────────────────────────────────────────

  def spaces(conn, _params) do
    user = conn.assigns.current_user

    spaces =
      from(s in Space,
        join: p in Participant,
        on: p.space_id == s.id,
        where:
          p.participant_type == "user" and p.participant_id == ^user.id and
            is_nil(s.archived_at) and s.kind != "execution",
        order_by: [asc: s.name, asc: s.inserted_at],
        distinct: true
      )
      |> ExternalScope.scope_spaces(ExternalScope.for_user(user))
      |> Repo.all()

    agents_by_space = agents_by_space(Enum.map(spaces, & &1.id))

    json(conn, %{
      spaces:
        Enum.map(spaces, fn space ->
          %{
            id: space.id,
            name: space.name,
            slug: space.slug,
            kind: space.kind,
            agents: Map.get(agents_by_space, space.id, [])
          }
        end)
    })
  end

  defp agents_by_space([]), do: %{}

  defp agents_by_space(space_ids) do
    from(p in Participant,
      join: a in Agent,
      on: a.id == p.participant_id,
      where: p.space_id in ^space_ids and p.participant_type == "agent",
      order_by: [asc: a.name],
      select: {p.space_id, %{id: a.id, name: a.name, slug: a.slug}}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # ── messages ─────────────────────────────────────────────────────────

  def create_message(conn, %{"space_id" => space_id} = params) do
    user = conn.assigns.current_user

    with {:ok, space, participant} <- authorize_space(user, space_id),
         {:ok, mention} <- agent_mention(space.id, params["agent_id"]),
         {:ok, thread_id} <- resolve_thread(space.id, params["reply_to"]),
         content = compose_content(mention, params["text"]),
         {:ok, uploads} <- persist_file(params["file"]),
         :ok <- require_body(content, uploads) do
      attrs = %{
        space_id: space.id,
        thread_id: thread_id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      }

      case Chat.post_message_with_attachments(attrs, uploads, poster_user_id: user.id) do
        {:ok, message, attachments} ->
          conn
          |> put_status(:created)
          |> json(%{
            message: %{
              id: message.id,
              space_id: message.space_id,
              thread_id: message.thread_id,
              inserted_at: message.inserted_at
            },
            attachments: Enum.map(attachments, &%{id: &1.id, filename: &1.filename})
          })

        {:error, reason} ->
          AttachmentStorage.delete_many(uploads)
          post_error(conn, reason)
      end
    else
      {:error, status, code} ->
        conn
        |> put_status(status)
        |> json(%{error: code})
    end
  end

  defp authorize_space(user, space_id) do
    with %Space{archived_at: nil} = space <- Chat.get_space(space_id),
         true <- ExternalScope.authorized_space?(user, space),
         %Participant{} = participant <- user_participant(space.id, user.id) do
      {:ok, space, participant}
    else
      _ -> {:error, :forbidden, "forbidden"}
    end
  end

  defp user_participant(space_id, user_id) do
    Repo.one(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "user" and
            p.participant_id == ^user_id,
        limit: 1
      )
    )
  end

  # The agent must be on this space's roster: the share sheet only offers
  # agents `GET /spaces` returned for the space.
  defp agent_mention(_space_id, agent_id) when agent_id in [nil, ""], do: {:ok, nil}

  defp agent_mention(space_id, agent_id) when is_binary(agent_id) do
    if Platform.UUID.valid?(agent_id) do
      from(p in Participant,
        join: a in Agent,
        on: a.id == p.participant_id,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id,
        select: a.name,
        limit: 1
      )
      |> Repo.one()
      |> case do
        name when is_binary(name) and name != "" -> {:ok, "@[#{name}]"}
        _ -> {:error, :unprocessable_entity, "unknown_agent"}
      end
    else
      {:error, :unprocessable_entity, "unknown_agent"}
    end
  end

  defp agent_mention(_space_id, _agent_id), do: {:error, :unprocessable_entity, "unknown_agent"}

  # `reply_to` resolves the way Slack's Reply does: answering a TOP-LEVEL
  # message posts top-level in the same space; answering a message that is
  # itself inside a thread posts into that thread. The Lock Screen Reply sends
  # the notified message's id, and opening a new thread under it hid the
  # answer from the conversation timeline (Rowan's DM, 2026-10-05).
  defp resolve_thread(_space_id, reply_to) when reply_to in [nil, ""], do: {:ok, nil}

  defp resolve_thread(space_id, reply_to) when is_binary(reply_to) do
    case Chat.get_message(reply_to) do
      %{space_id: ^space_id, thread_id: thread_id} -> {:ok, thread_id}
      _ -> {:error, :unprocessable_entity, "invalid_reply_to"}
    end
  end

  defp resolve_thread(_space_id, _reply_to),
    do: {:error, :unprocessable_entity, "invalid_reply_to"}

  defp compose_content(mention, text) do
    text = if is_binary(text), do: String.trim(text), else: ""

    [mention, text]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp persist_file(nil), do: {:ok, []}
  defp persist_file(""), do: {:ok, []}

  defp persist_file(%Plug.Upload{path: path, filename: filename, content_type: content_type}) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        if size > PlatformWeb.ChatLive.max_upload_size() do
          {:error, :request_entity_too_large, "file_too_large"}
        else
          case AttachmentStorage.persist_upload(path, filename, content_type) do
            {:ok, attrs} -> {:ok, [attrs]}
            {:error, _reason} -> {:error, :internal_server_error, "storage_failed"}
          end
        end

      {:error, _} ->
        {:error, :unprocessable_entity, "invalid_file"}
    end
  end

  defp persist_file(_), do: {:error, :unprocessable_entity, "invalid_file"}

  defp require_body("", []), do: {:error, :unprocessable_entity, "empty_message"}
  defp require_body(_content, _uploads), do: :ok

  defp post_error(conn, reason) when reason in [:dm_not_allowed, :out_of_external_scope] do
    conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
  end

  defp post_error(conn, :space_archived) do
    conn |> put_status(:forbidden) |> json(%{error: "forbidden"})
  end

  defp post_error(conn, _reason) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "message_not_created"})
  end

  # ── counts ───────────────────────────────────────────────────────────

  def counts(conn, _params) do
    %{approvals: approvals, tasks: tasks, as_of: as_of} =
      Mobile.counts_for_user(conn.assigns.current_user)

    json(conn, %{approvals: approvals, tasks: tasks, as_of: DateTime.to_iso8601(as_of)})
  end

  # Field names only: a changeset's error tuples can carry the rejected
  # value in their opts, and the device token must never come back.
  defp error_fields(%Ecto.Changeset{errors: errors}) do
    errors |> Keyword.keys() |> Enum.uniq() |> Enum.map(&to_string/1)
  end
end
