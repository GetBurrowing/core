defmodule PlatformWeb.Tasks.PinHooks do
  @moduledoc """
  Lifecycle hook module for Pin-to-Chat on the Tasks surface
  (task 019f62a1 stage 4; extracted in task 01a008f6 stage 7).

  Mirrors `PlatformWeb.ChatLive.PinHooks`. A LifecycleHook rather than a
  LiveComponent for the same reason ADR 0035 gives there: the UI is
  distributed (the toggle button lives inside `TaskDetailComponent`'s
  header, the state it drives is per-task and read across the panel) and
  there is no contiguous markup region to own.

  Owns:

    * Assigns: `:current_user_email`, `:my_pinned_task_ids`
    * Info:    `{:task_pin_added, payload}`, `{:task_pin_removed, payload}`
      (two clauses each — the current user's pins, and everybody else's)

  Zero events: the pin toggle itself is `TaskDetailComponent`'s
  `"detail_toggle_pin"`, extracted in stage 4. The component writes through
  `Platform.Tasks.ChatPins`, which broadcasts on the global space-lifecycle
  topic, and the socket-side MapSet is refreshed from that broadcast — so
  the button re-renders solid/outline in step with the truth on disk even
  when somebody else (or, in future, an agent) fired the pin.

  ## Usage

      # In TasksLive.mount/3, with the session's user id:
      socket = PlatformWeb.Tasks.PinHooks.attach(socket, session["current_user_id"])
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Accounts
  alias Platform.Tasks.ChatPins

  @doc """
  Seed the pin assigns and attach the `:handle_info` hook.

  The `ChatPubSub.subscribe_spaces/0` call stays in `TasksLive.mount/3`
  alongside the other `connected?`-gated subscribes — the pins ride the
  shared space-lifecycle topic, so there is no pin-specific subscription
  to own here.
  """
  @spec attach(Phoenix.LiveView.Socket.t(), binary() | nil) :: Phoenix.LiveView.Socket.t()
  def attach(socket, current_user_id) do
    # Resolve the acting user's email once at mount so the pin flow doesn't
    # do a Repo.get on every keystroke of the detail panel. Nil when the
    # session has no user_id (anonymous) or the user row was deleted.
    email = fetch_user_email(current_user_id)

    # Pins are keyed by email for user participants — see `ChatPins.pin/3`
    # and the stage-3 mention-propagation pass in `Platform.Chat`. `MapSet`
    # gives O(1) membership checks so the detail panel's `pinned_by_me?/3`
    # helper stays a pure lookup, not a Repo query, across every re-render.
    pinned =
      case email do
        nil -> MapSet.new()
        e -> MapSet.new(ChatPins.pinned_task_ids_for(%{kind: "user", id: e}))
      end

    socket
    |> assign(:current_user_email, email)
    |> assign(:my_pinned_task_ids, pinned)
    |> attach_hook(:tasks_pin_info, :handle_info, &handle_info/2)
  end

  # Global space-lifecycle broadcasts for task pin add/remove. Only the
  # CURRENT user's pins land in the socket-side MapSet — other users' pins
  # ride the same topic but must not shift this panel's button state.
  # `participant_kind == "user"` also filters out agent pins (agents get
  # their pin flow via the stage-3 mention-propagation pass; they don't
  # drive this human panel).
  defp handle_info(
         {:task_pin_added,
          %{task_id: task_id, participant_kind: "user", participant_id: participant_id}},
         socket
       ) do
    if participant_id == socket.assigns[:current_user_email] do
      {:halt,
       assign(socket, :my_pinned_task_ids, MapSet.put(socket.assigns.my_pinned_task_ids, task_id))}
    else
      {:halt, socket}
    end
  end

  defp handle_info({:task_pin_added, _payload}, socket), do: {:halt, socket}

  defp handle_info(
         {:task_pin_removed,
          %{task_id: task_id, participant_kind: "user", participant_id: participant_id}},
         socket
       ) do
    if participant_id == socket.assigns[:current_user_email] do
      {:halt,
       assign(
         socket,
         :my_pinned_task_ids,
         MapSet.delete(socket.assigns.my_pinned_task_ids, task_id)
       )}
    else
      {:halt, socket}
    end
  end

  defp handle_info({:task_pin_removed, _payload}, socket), do: {:halt, socket}

  defp handle_info(_message, socket), do: {:cont, socket}

  defp fetch_user_email(nil), do: nil

  defp fetch_user_email(user_id) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      %{email: email} when is_binary(email) -> email
      _ -> nil
    end
  end
end
