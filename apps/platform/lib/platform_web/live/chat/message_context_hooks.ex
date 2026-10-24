defmodule PlatformWeb.ChatLive.MessageContextHooks do
  @moduledoc """
  Lifecycle hook module for the "Context" affordance on agent messages
  (task 01a0d8de stage 3): what an agent message is answering, for a reader
  who arrives hours later.

  An agent message can carry two annotations in its metadata, both written
  by `Platform.Chat.ReplyContext` (stage 2) for federated agents, and the
  first also by built-in agents (`AgentResponder`):

    * `"reply_to_message_id"` — the message it answers;
    * `"reply_context"` — one line from the agent, already normalised and
      mention-escaped at write time.

  The panel opens from the actions sheet's 'What this is answering' row (the
  header "Context" button and the hover row were deleted in redesign rung
  9). When a message carries neither annotation, opening it runs
  `Platform.Chat.ContextSummary.summarize/3` (stage 1) for THIS viewer, and
  'Retry summary' runs it again.

  ## Assigns owned

    * `:message_context` — nil, or the open panel's state (see
      `t:state/0`).
    * `:message_context_mobile?` — which side of `lg` the viewport is on,
      reported by the `ViewportBreakpoint` hook. It picks the panel's frame:
      a non-modal popover on desktop, a bottom sheet on mobile. The server
      renders exactly ONE of the two, never both behind CSS, because the
      sheet is `aria-modal` and a hidden modal dialog still tells a screen
      reader the page behind it is inert (the same reason
      `MeetingLive` renders one call-rail wrapper).

  ## Events

    * `open_message_context` / `close_message_context`
    * `summarise_message_context` / `retry_message_context`
    * `jump_to_answered_message`
    * `message_context_viewport`

  ## Info handled

    * `{:message_context_summary, token, result}` — the summary task's
      answer. `token` is the panel's current request token; an answer for a
      panel that has since closed or moved to another message is dropped.
    * `{:message_context_summary_timeout, token}` — a task that died without
      answering must not leave the panel on its skeleton forever.

  ## What the viewer may see

  Every message this module reads is re-read with the viewer's
  `external_scope`, checked against the ACTIVE space and `deleted_at`, and
  for the answered message also against the viewer's `history_visible_from`.
  A target that fails any check renders as "a message you don't have access
  to"; its content, author and time never reach the assigns.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_patch: 2, push_event: 3]

  alias Platform.Chat
  alias Platform.Chat.ContextSummary
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias PlatformWeb.ChatLive.PresenceHooks

  @summary_timeout_ms 30_000

  @type reply_to ::
          nil
          | %{
              status: :visible,
              message_id: binary(),
              author: String.t(),
              at: DateTime.t() | nil,
              preview: String.t()
            }
          | %{status: :no_access}

  @type state :: %{
          message_id: binary(),
          agent_name: String.t(),
          agent_slot: String.t(),
          agent_context: String.t() | nil,
          reply_to: reply_to(),
          summary: nil | :loading | {:ok, map()} | {:error, term()},
          token: reference() | nil
        }

  @doc "Attach the Context handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:message_context, nil)
    |> assign(:message_context_mobile?, false)
    |> attach_hook(:message_context_events, :handle_event, &handle_event/3)
    |> attach_hook(:message_context_info, :handle_info, &handle_info/2)
  end

  defp agent_context(msg) do
    case Map.get(msg, :metadata) do
      %{"reply_context" => text} when is_binary(text) ->
        if String.trim(text) == "", do: nil, else: text

      _ ->
        nil
    end
  end

  defp reply_to_id(msg) do
    case Map.get(msg, :metadata) do
      %{"reply_to_message_id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # ── Events ─────────────────────────────────────────────────────────

  defp handle_event("open_message_context", %{"message-id" => id}, socket) do
    {:halt, open(socket, id, summarise: :when_empty)}
  end

  defp handle_event("summarise_message_context", %{"message-id" => id}, socket) do
    {:halt, open(socket, id, summarise: :always)}
  end

  defp handle_event("retry_message_context", _params, socket) do
    case socket.assigns.message_context do
      %{message_id: id} -> {:halt, open(socket, id, summarise: :always)}
      _ -> {:halt, socket}
    end
  end

  defp handle_event("close_message_context", _params, socket) do
    {:halt, assign(socket, :message_context, nil)}
  end

  defp handle_event("jump_to_answered_message", %{"message-id" => id}, socket) do
    space = socket.assigns[:active_space]

    case visible_message(socket, id) do
      %Message{} = target when not is_nil(space) ->
        {:halt,
         socket
         |> assign(:message_context, nil)
         |> push_event("chat:message-jump", %{id: target.id})
         |> push_patch(to: "/chat/#{Chat.space_path_segment(space)}?message=#{target.id}")}

      _ ->
        {:halt, socket}
    end
  end

  # The `ViewportBreakpoint` report. Anything but a literal boolean is
  # ignored rather than coerced, as in `MeetingLive`'s handler.
  defp handle_event("message_context_viewport", %{"below" => below}, socket)
       when is_boolean(below) do
    {:halt, assign(socket, :message_context_mobile?, below)}
  end

  defp handle_event("message_context_viewport", _params, socket), do: {:halt, socket}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # ── Info ───────────────────────────────────────────────────────────

  defp handle_info({:message_context_summary, token, result}, socket) do
    case socket.assigns.message_context do
      %{token: ^token} = state ->
        {:halt, assign(socket, :message_context, %{state | summary: result, token: nil})}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_info({:message_context_summary_timeout, token}, socket) do
    case socket.assigns.message_context do
      %{token: ^token, summary: :loading} = state ->
        {:halt,
         assign(socket, :message_context, %{state | summary: {:error, :timeout}, token: nil})}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Opening the panel ──────────────────────────────────────────────

  defp open(socket, id, summarise: mode) do
    with %Message{} = msg <- visible_message(socket, id),
         true <- agent_message?(socket, msg) do
      agent_context = agent_context(msg)
      reply_to = resolve_reply_to(socket, reply_to_id(msg))

      state = %{
        message_id: msg.id,
        agent_name: PresenceHooks.sender_name(socket.assigns[:participants_map] || %{}, msg),
        agent_slot:
          Platform.Agents.ColorPalette.slot_for(
            Map.get(socket.assigns[:agent_slots_map] || %{}, msg.participant_id)
          ),
        agent_context: agent_context,
        reply_to: reply_to,
        summary: nil,
        token: nil
      }

      state =
        if mode == :always or (agent_context == nil and reply_to == nil),
          do: start_summary(socket, state, msg),
          else: state

      assign(socket, :message_context, state)
    else
      _ -> socket
    end
  end

  defp agent_message?(socket, %Message{participant_id: pid}) do
    MapSet.member?(socket.assigns[:agent_participant_ids] || MapSet.new(), pid)
  end

  # A message the viewer may see: inside their external scope, in the
  # ACTIVE space (a hand-built event naming another space's message is
  # refused here), not deleted, and not before their history grant.
  defp visible_message(socket, id) do
    space = socket.assigns[:active_space]

    with %{id: space_id} <- space,
         %Message{} = msg <- Chat.get_message(id, scope: socket.assigns[:external_scope]),
         true <- msg.space_id == space_id,
         true <- is_nil(msg.deleted_at),
         true <- within_grant?(msg, socket.assigns[:current_participant]) do
      msg
    else
      _ -> nil
    end
  end

  defp within_grant?(%Message{inserted_at: at}, %Participant{
         history_visible_from: %DateTime{} = from
       })
       when not is_nil(at) do
    DateTime.compare(at, from) != :lt
  end

  defp within_grant?(_msg, _participant), do: true

  defp resolve_reply_to(_socket, nil), do: nil

  defp resolve_reply_to(socket, id) do
    case visible_message(socket, id) do
      %Message{} = target ->
        %{
          status: :visible,
          message_id: target.id,
          author: PresenceHooks.sender_name(socket.assigns[:participants_map] || %{}, target),
          at: Chat.message_ordered_at(target),
          preview: preview(target.content)
        }

      nil ->
        %{status: :no_access}
    end
  end

  defp preview(content) when is_binary(content) do
    content
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 280)
  end

  defp preview(_), do: ""

  # ── The summary task ───────────────────────────────────────────────

  defp start_summary(socket, state, %Message{} = msg) do
    lv = self()
    token = make_ref()
    viewer = socket.assigns[:current_participant]
    scope = socket.assigns[:external_scope]

    {:ok, _pid} =
      Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
        result =
          try do
            ContextSummary.summarize(msg, viewer, scope: scope)
          rescue
            _ -> {:error, :crashed}
          catch
            _, _ -> {:error, :crashed}
          end

        send(lv, {:message_context_summary, token, normalise_result(result)})
      end)

    Process.send_after(lv, {:message_context_summary_timeout, token}, summary_timeout_ms())

    %{state | summary: :loading, token: token}
  end

  defp normalise_result({:ok, %{text: _} = result}), do: {:ok, result}
  defp normalise_result({:error, reason}), do: {:error, reason}
  defp normalise_result(_other), do: {:error, :unexpected}

  defp summary_timeout_ms do
    Application.get_env(:platform, :message_context_summary_timeout_ms, @summary_timeout_ms)
  end
end
