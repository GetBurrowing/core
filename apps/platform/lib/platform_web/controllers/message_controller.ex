defmodule PlatformWeb.MessageController do
  @moduledoc """
  HTTP API for editing messages and reading their version history,
  per the editable-messages cross-phase contract
  (`docs/contracts/editable-messages-contract.md`, Section b + d).

  Routes:
    * `PATCH /api/messages/:id` — author-only edit. See Section (b)
      for response envelopes and the full error matrix
      (401 / 403 / 404 / 409 / 422). Frozen messages (Policy 2 in
      Section f) return 409 with a `freezing_action` payload.
    * `GET /api/messages/:id/versions` — newest-first list of prior
      versions for the message, backing the Version History popover
      in Section (d.2).

  Both routes require an authenticated browser session (see
  `PlatformWeb.Plugs.RequireAuthAPI`).

  Side effects on a successful edit:
    * Appends a row to `chat_message_versions` via
      `Platform.Chat.MessageVersions.record_edit/2`.
    * Broadcasts `{:message_edited, payload}` on the existing
      `Platform.Chat.PubSub.space_topic/1` per contract Section (c).
    * Emits `[:platform, :chat, :message_edited]` telemetry.

  Out of scope for this PR (deferred to a follow-up):
    * Rate limiting (contract D-3, 10/min/user/message) — no
      app-level rate-limit infra exists yet; flagged as a follow-up.
    * Server-side freeze trigger (Section f Policy 2) — this controller
      *honors* `message.frozen_at` if it's set, but the writer that
      *sets* the flag based on task/agent-action transitions lives in
      a different surface (agent runtime) and ships separately.
  """

  use PlatformWeb, :controller

  import Ecto.Query

  alias Platform.Chat.{Message, MessageVersions, Participant, PubSub}
  alias Platform.Repo

  @max_content_length 10_000
  @frozen_message "An agent has begun work on this message — send a follow-up to revise."

  # ──────────────────────────────────────────────────────────────────────────
  # PATCH /api/messages/:id
  # ──────────────────────────────────────────────────────────────────────────

  def update(conn, %{"id" => message_id} = params) do
    user = conn.assigns.current_user

    with {:ok, content} <- validate_content(params),
         {:ok, message} <- fetch_message(message_id),
         {:ok, participant} <- find_user_participant(user.id, message.space_id),
         :ok <- check_author(message, participant),
         :ok <- check_not_frozen(message) do
      if idempotent?(message, content) do
        render_envelope(conn, message)
      else
        apply_edit(conn, message, participant, content)
      end
    else
      {:error, status, code, extras} ->
        render_error(conn, status, code, extras)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # GET /api/messages/:id/versions
  # ──────────────────────────────────────────────────────────────────────────

  def versions(conn, %{"id" => message_id}) do
    user = conn.assigns.current_user

    with {:ok, message} <- fetch_message(message_id),
         {:ok, _participant} <- find_user_participant(user.id, message.space_id) do
      versions =
        message_id
        |> MessageVersions.list_versions()
        |> Enum.map(&version_payload/1)

      json(conn, %{data: versions})
    else
      {:error, status, code, extras} ->
        render_error(conn, status, code, extras)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Validation + lookups
  # ──────────────────────────────────────────────────────────────────────────

  defp validate_content(%{"content" => content}) when is_binary(content) do
    cond do
      content == "" ->
        validation_error(%{content: ["can't be blank"]})

      byte_size(content) > @max_content_length ->
        validation_error(%{
          content: ["is too long (max #{@max_content_length} characters)"]
        })

      true ->
        {:ok, content}
    end
  end

  defp validate_content(_), do: validation_error(%{content: ["is required"]})

  defp validation_error(errors),
    do: {:error, :unprocessable_entity, "validation_failed", %{errors: errors}}

  defp fetch_message(id) when is_binary(id) do
    case Repo.get(Message, id) do
      nil -> {:error, :not_found, "not_found", %{}}
      %Message{deleted_at: %DateTime{}} -> {:error, :not_found, "not_found", %{}}
      message -> {:ok, message}
    end
  end

  defp fetch_message(_), do: {:error, :not_found, "not_found", %{}}

  defp find_user_participant(user_id, space_id) do
    query =
      from(p in Participant,
        where:
          p.participant_id == ^user_id and
            p.participant_type == "user" and
            p.space_id == ^space_id,
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :forbidden, "forbidden_not_in_space", %{}}
      p -> {:ok, p}
    end
  end

  # Policy 3 of the contract: agents can't edit their own messages, humans
  # can't edit agent messages. Both reduce to the same author-id check —
  # this controller only runs under :require_auth_api which authenticates
  # a user, so the participant we just looked up is always a human
  # participant. If the message was authored by an agent, the agent's
  # participant.id != this user's participant.id and we 403.
  defp check_author(%Message{participant_id: pid}, %Participant{id: pid}), do: :ok
  defp check_author(_message, _participant), do: {:error, :forbidden, "forbidden_not_author", %{}}

  # Policy 2 of the contract: a frozen message returns 409 with a
  # freezing_action payload so the UI can render the disabled-pencil
  # tooltip (Section d.3).
  defp check_not_frozen(%Message{frozen_at: nil}), do: :ok

  defp check_not_frozen(%Message{} = message) do
    {:error, :conflict, "frozen", %{freezing_action: build_freezing_action(message)}}
  end

  defp build_freezing_action(message) do
    base = %{
      participant_id: message.frozen_by_participant_id,
      frozen_at: message.frozen_at
    }

    case message.frozen_by_participant_id &&
           Repo.get(Participant, message.frozen_by_participant_id) do
      %Participant{display_name: name} when is_binary(name) and name != "" ->
        Map.put(base, :participant_display_name, name)

      _ ->
        base
    end
  end

  defp idempotent?(%Message{content: existing}, new), do: (existing || "") == new

  # ──────────────────────────────────────────────────────────────────────────
  # Edit application
  # ──────────────────────────────────────────────────────────────────────────

  defp apply_edit(conn, message, participant, content) do
    now = DateTime.utc_now()
    previous_content = message.content || ""

    txn_result =
      Repo.transaction(fn ->
        with {:ok, updated} <-
               message |> Message.changeset(%{content: content, edited_at: now}) |> Repo.update(),
             {:ok, version} <-
               MessageVersions.record_edit(updated.id, %{
                 content: content,
                 edited_at: now,
                 edited_by_participant_id: participant.id,
                 edited_by_display_name: participant.display_name || "(unknown)"
               }) do
          {updated, version}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case txn_result do
      {:ok, {updated, version}} ->
        broadcast_edit(updated, previous_content, content, version, participant)
        emit_telemetry(updated)
        render_envelope(conn, updated)

      {:error, _changeset} ->
        # Schema-level rejection (e.g. content too long that the DB
        # would refuse). Should be rare since we validated above; fall
        # back to 422 with the changeset's errors.
        render_error(conn, :unprocessable_entity, "validation_failed", %{})
    end
  end

  defp broadcast_edit(updated, previous_content, new_content, version, participant) do
    payload = %{
      message: updated,
      previous_content: previous_content,
      version_number: version.version_number,
      edited_by_participant_id: participant.id,
      removed_substrings: compute_removed_substrings(previous_content, new_content)
    }

    PubSub.broadcast(updated.space_id, {:message_edited, payload})
  end

  defp emit_telemetry(message) do
    :telemetry.execute(
      [:platform, :chat, :message_edited],
      %{system_time: System.system_time()},
      %{message_id: message.id, space_id: message.space_id}
    )
  end

  # Section C.3 — detect shortened / removed-substring edits so in-context
  # agents can react to retractions. Algorithm: word-tokenize previous and
  # new content; collect runs of consecutive words that appear in previous
  # but not in new. Detection only — false positives are acceptable, false
  # negatives are not. Whitespace defines word boundaries.
  defp compute_removed_substrings(previous, new) do
    prev_words = String.split(previous, ~r/\s+/, trim: true)
    new_set = MapSet.new(String.split(new, ~r/\s+/, trim: true))

    {final_run, runs} =
      Enum.reduce(prev_words, {[], []}, fn word, {current_run, acc} ->
        if MapSet.member?(new_set, word) do
          {[], maybe_append_run(current_run, acc)}
        else
          {[word | current_run], acc}
        end
      end)

    final_run |> maybe_append_run(runs) |> Enum.reverse()
  end

  defp maybe_append_run([], acc), do: acc
  defp maybe_append_run(run, acc), do: [run |> Enum.reverse() |> Enum.join(" ") | acc]

  # ──────────────────────────────────────────────────────────────────────────
  # Rendering
  # ──────────────────────────────────────────────────────────────────────────

  defp render_envelope(conn, message) do
    versions_count = MessageVersions.count_versions(message.id)

    payload = %{
      id: message.id,
      content: message.content,
      edited_at: message.edited_at,
      versions_count: versions_count,
      space_id: message.space_id,
      thread_id: message.thread_id,
      participant_id: message.participant_id,
      author_display_name: message.author_display_name,
      author_avatar_url: message.author_avatar_url,
      content_type: message.content_type,
      frozen_at: message.frozen_at,
      frozen_by_participant_id: message.frozen_by_participant_id,
      corrects_message_id: message.corrects_message_id
    }

    json(conn, %{data: payload})
  end

  defp version_payload(v) do
    %{
      version_number: v.version_number,
      content: v.content,
      edited_at: v.edited_at,
      edited_by_participant_id: v.edited_by_participant_id,
      edited_by_display_name: v.edited_by_display_name
    }
  end

  defp render_error(conn, status, code, extras) do
    error =
      %{code: code, message: error_message(code)}
      |> Map.merge(extras)

    conn
    |> put_status(status)
    |> json(%{error: error})
  end

  defp error_message("forbidden_not_author"), do: "Only the message author can edit this message."
  defp error_message("forbidden_not_in_space"), do: "You are not a participant in this space."
  defp error_message("not_found"), do: "Message not found."
  defp error_message("frozen"), do: @frozen_message
  defp error_message("validation_failed"), do: "Request body failed validation."
end
