defmodule PlatformWeb.Files.CanvasPresence do
  @moduledoc """
  Viewer-filtered canvas card presence with tokenized 30-second leave retention.
  Consumes the browser's existing space subscriptions without tracking its viewer.
  Retained identities are re-filtered on every reconciliation, including expiry.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView
  import Ecto.Query
  alias Platform.{Accounts, Chat, Repo}
  alias Platform.Chat.Presence
  alias Platform.Files.Browser
  alias PlatformWeb.ChatLive.PresenceHooks

  def attach(socket) do
    socket
    |> assign(canvas_previews: %{}, canvas_people: %{}, canvas_card_timers: %{})
    |> attach_hook(:canvas_cards_params, :handle_params, fn _, _, s ->
      if connected?(s), do: send(self(), :sync_canvas_cards)
      {:cont, s}
    end)
    |> attach_hook(:canvas_cards_info, :handle_info, &handle_info/2)
  end

  def sync(socket) do
    previews = Browser.canvas_previews(socket.assigns.viewer, socket.assigns.browser.items)

    spaces = previews |> Map.values() |> Enum.map(& &1.space_id) |> Enum.uniq()
    rosters = Map.new(spaces, &{&1, roster(socket.assigns.viewer, &1)})
    presences = Map.new(spaces, &{&1, Presence.list_space(&1)})

    people =
      Map.new(previews, fn {id, preview} ->
        roster = Map.fetch!(rosters, preview.space_id)
        active = project(Map.fetch!(presences, preview.space_id), id, roster)

        old =
          if get_in(socket.assigns.canvas_previews, [id, :space_id]) == preview.space_id,
            do: Map.get(socket.assigns.canvas_people, id, %{people: []}),
            else: %{people: []}

        retained =
          Enum.flat_map(old.people, fn p ->
            case Enum.find(roster, &(&1.id == p.id)) do
              nil -> []
              fresh -> [fresh]
            end
          end)

        {id, %{people: active, retained: retained}}
      end)

    {people, timers} = reconcile(people, socket.assigns.canvas_card_timers)
    topics = spaces ++ Browser.game_space_ids(socket.assigns.viewer, socket.assigns.browser.items)
    socket = PlatformWeb.Files.BrowserHooks.sync_topics(socket, topics)
    assign(socket, canvas_previews: previews, canvas_people: people, canvas_card_timers: timers)
  end

  # No presence metadata supplies names, avatars, or overflow counts: every
  # emitted identity comes from this visible DB roster and canonical profile map.
  def roster(viewer, space_id) do
    external? = Platform.Tenancy.external_user?(viewer.user)

    participants =
      Chat.list_participants(space_id)
      |> Enum.filter(fn p ->
        not external? or
          (p.participant_type == "user" and
             Chat.external_dm_permitted?(viewer.user.id, "user", p.participant_id))
      end)

    users =
      participants
      |> Enum.filter(&(&1.participant_type == "user"))
      |> Enum.map(& &1.participant_id)
      |> Accounts.get_users_map()

    agent_ids =
      participants
      |> Enum.filter(&(&1.participant_type == "agent"))
      |> Enum.map(& &1.participant_id)

    agents =
      Repo.all(from(a in Platform.Agents.Agent, where: a.id in ^agent_ids))
      |> Map.new(&{&1.id, &1})

    participants =
      Enum.filter(participants, fn p ->
        case p.participant_type do
          "user" ->
            case Map.get(users, p.participant_id) do
              nil ->
                false

              user ->
                Platform.Access.check(
                  Platform.Access.Scope.for_user(user),
                  "chat.read",
                  {:space, space_id}
                ) == :ok
            end

          "agent" ->
            case Map.get(agents, p.participant_id) do
              nil -> false
              agent -> Chat.agent_may_read_space?(agent, space_id)
            end

          _ ->
            false
        end
      end)

    avatars = Chat.agent_avatar_map_for_participants(participants)
    slots = Chat.agent_slot_map_for_participants(participants)

    participants
    |> Enum.reject(
      &(&1.participant_type == "user" and not Map.has_key?(users, &1.participant_id))
    )
    |> Enum.map(fn p ->
      PresenceHooks.participant_identity(p, Map.get(users, p.participant_id), avatars)
      |> Map.merge(%{
        id: p.id,
        principal_id: p.participant_id,
        slot: Map.get(slots, p.id, "blue")
      })
    end)
  end

  @doc "Merge sessions and intersect with the visible roster before emitting identities."
  def project(presences, canvas_id, roster) do
    roster
    |> Enum.filter(fn p ->
      [p.id, p.principal_id]
      |> Enum.any?(fn key ->
        presences
        |> Map.get(key, %{metas: []})
        |> Map.get(:metas, [])
        |> Enum.any?(&(get_in(&1, [:canvas, :canvas_id]) == canvas_id))
      end)
    end)
    |> Enum.uniq_by(&{&1.participant_type, &1.principal_id})
    |> Enum.sort_by(& &1.id)
  end

  defp reconcile(current, old_timers) do
    Enum.each(old_timers, fn {id, timer} ->
      if not Map.has_key?(current, id), do: Process.cancel_timer(timer.ref)
    end)

    Enum.reduce(current, {%{}, %{}}, fn {id, row}, {people, timers} ->
      old = old_timers[id]

      cond do
        row.people != [] ->
          if old, do: Process.cancel_timer(old.ref)
          {Map.put(people, id, %{people: row.people, leaving?: false}), timers}

        row.retained != [] ->
          timer = old || new_timer(id)

          {Map.put(people, id, %{people: row.retained, leaving?: true}),
           Map.put(timers, id, timer)}

        true ->
          if old, do: Process.cancel_timer(old.ref)
          {people, timers}
      end
    end)
  end

  defp new_timer(id) do
    token = make_ref()
    %{token: token, ref: Process.send_after(self(), {:canvas_card_expire, id, token}, 30_000)}
  end

  def handle_info(:sync_canvas_cards, socket), do: {:halt, sync(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    displayed? =
      Enum.any?(socket.assigns.canvas_previews, fn {_, p} ->
        Chat.PubSub.space_topic(p.space_id) == topic
      end)

    {:halt, if(displayed?, do: sync(socket), else: socket)}
  end

  def handle_info({:canvas_card_expire, id, token}, socket) do
    case socket.assigns.canvas_card_timers[id] do
      %{token: ^token} ->
        socket =
          assign(socket,
            canvas_people: Map.delete(socket.assigns.canvas_people, id),
            canvas_card_timers: Map.delete(socket.assigns.canvas_card_timers, id)
          )

        {:halt, sync(socket)}

      _ ->
        {:halt, socket}
    end
  end

  def handle_info(_, socket), do: {:cont, socket}
end
