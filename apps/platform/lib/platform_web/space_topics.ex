defmodule PlatformWeb.SpaceTopics do
  @moduledoc """
  Single writer for the `chat:space:<id>` PubSub subscription on a LiveView pid.

  ## Why this module exists

  `Phoenix.PubSub` starts its registry with `keys: :duplicate`
  (`deps/phoenix_pubsub/lib/phoenix/pubsub/supervisor.ex:31`). `subscribe/3` is a
  bare `Registry.register/3` (`deps/phoenix_pubsub/lib/phoenix/pubsub.ex:205`)
  and `unsubscribe/2` is `Registry.unregister/2`
  (`deps/phoenix_pubsub/lib/phoenix/pubsub.ex:216`). The asymmetry is the whole
  problem: **subscribe adds ONE registration, unsubscribe removes ALL of that
  pid's registrations for the topic.**

  Four independent code sites subscribe `chat:space:<id>` *from the same pid*,
  because `PlatformWeb.ShellLive` is an `on_mount` hook (see `router.ex`,
  `live_session :authenticated`, `on_mount: [PlatformWeb.ShellLive,
  {PlatformWeb.LiveAuth, :default}]`) and therefore runs inside the LiveView
  process rather than beside it:

    1. `shell_live.ex` — roster branch (`{:roster_resolved, sid}`)
    2. `shell_live.ex` — presence branch (`{:presence_spaces_resolved, ids}`)
    3. `chat_live.ex` — `subscribe_space/2` / `unsubscribe_space/2`
    4. `tasks_live.ex` — `resubscribe_execution_space/2`

  Each keeps its own bookkeeping (`:roster_space_id`, `:shell_chat_space_ids`,
  `:subscribed_space_ids`, `:subscribed_execution_space_id`) and each issues raw
  subscribe/unsubscribe calls. Two registrations on one pid mean every broadcast
  is delivered twice.

  ## Why a refcount owned by only one surface would be worse

  A refcount maintained by only one of the four writers is **unsound, and
  strictly worse than the duplicate it fixes**. A second writer's raw
  `unsubscribe` destroys the registration while the refcount still shows a
  holder; the refcount then declines to re-subscribe and the topic is silently
  dead — events delivered *never*, and reported as fine. Today's defect is
  honest (delivered twice); that failure mode is silent. So the invariant is:
  **one writer for `chat:space:<id>` on this pid — this module — adopted by all
  four sites.**

  ## Correction to the premise this work was filed on

  `chat_live.ex` has **already** adopted a module-local held set (task
  `01a017a3`, landed on `main`): `:subscribed_space_ids`, a `MapSet` seeded in
  `mount/3` and maintained only by `subscribe_space/2` / `unsubscribe_space/2`.
  There is no unconditional bare `ChatPubSub.unsubscribe` in that module. The
  problem is *not* that `chat_live` is unguarded — it is that its guard is
  scoped to ONE MODULE while the registrations are scoped to the PROCESS.
  `unsubscribe_space(socket, prev.id)` in `handle_params/3`'s teardown still
  destroys ShellLive's registrations, and `chat_live.ex` already documents that
  as a KNOWN DEVIATION whose reconciliation is "owed as a follow-up". This
  module is that follow-up.

  ## Design

  Socket-assign backed, because ShellLive, ChatLive and TasksLive share ONE
  socket. The assign `:chat_space_holders` is the record; the registry is what
  the *tests* read. Deliberately **not** the process dictionary, and the
  registry is never interrogated on the hot path.

      socket = SpaceTopics.ensure_holders(socket)
      socket = SpaceTopics.hold(socket, space_id, :roster)
      socket = SpaceTopics.hold(socket, space_id, :chat_active)
      # exactly one registration; both surfaces believe they hold it
      socket = SpaceTopics.release(socket, space_id, :chat_active)
      # still exactly one registration — :roster still holds
      socket = SpaceTopics.release(socket, space_id, :roster)
      # now zero
  """

  import Phoenix.Component, only: [assign: 3]

  alias Platform.Chat

  @assign :chat_space_holders

  @owners [:roster, :presence, :chat_rail, :chat_active, :tasks_exec]

  @typedoc """
  Closed set of surfaces permitted to hold a `chat:space:<id>` subscription on a
  shell pid. Closed on purpose: an unknown atom is a typo, and a typo that
  created a phantom holder would pin a subscription open forever with no surface
  able to release it. Prefer hard failure over quiet degradation.
  """
  @type owner :: :roster | :presence | :chat_rail | :chat_active | :tasks_exec

  @typedoc "Space id => the set of owners currently holding its subscription."
  @type holders :: %{optional(binary()) => MapSet.t(owner())}

  @doc """
  Returns the list of recognised owner atoms.
  """
  @spec owners() :: [owner()]
  def owners, do: @owners

  @doc """
  Seeds the `:chat_space_holders` assign if it is not already present.

  Idempotent, and callable from any of the three mounts: `ShellLive`'s
  `on_mount` hook runs *before* the view's own `mount/3`, so whichever runs
  first seeds and the rest are no-ops. Re-seeding would silently discard live
  holders, so an existing map is left exactly as it is.
  """
  @spec ensure_holders(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def ensure_holders(socket) do
    case socket.assigns do
      %{@assign => holders} when is_map(holders) -> socket
      _ -> assign(socket, @assign, %{})
    end
  end

  @doc """
  Records `owner` as a holder of `space_id`, subscribing iff nobody held it yet.

  Idempotent for a repeated hold by the same owner: `MapSet.put/2` is a no-op
  and the set was already non-empty, so no second registration is taken.
  """
  @spec hold(Phoenix.LiveView.Socket.t(), binary(), owner()) :: Phoenix.LiveView.Socket.t()
  def hold(socket, space_id, owner) when is_binary(space_id) and owner in @owners do
    socket = ensure_holders(socket)
    holders = socket.assigns[@assign]
    current = Map.get(holders, space_id, MapSet.new())

    if MapSet.size(current) == 0 do
      Chat.PubSub.subscribe(space_id)
    end

    assign(socket, @assign, Map.put(holders, space_id, MapSet.put(current, owner)))
  end

  @doc """
  Drops `owner` from `space_id`'s holder set, unsubscribing iff it just emptied.

  A release by a surface that never held the space is a no-op: it must NOT
  unsubscribe, because the registration it would destroy belongs to somebody
  else. This is the case an unguarded decrement gets wrong.
  """
  @spec release(Phoenix.LiveView.Socket.t(), binary(), owner()) :: Phoenix.LiveView.Socket.t()
  def release(socket, space_id, owner) when is_binary(space_id) and owner in @owners do
    socket = ensure_holders(socket)
    holders = socket.assigns[@assign]
    current = Map.get(holders, space_id, MapSet.new())

    if MapSet.member?(current, owner) do
      remaining = MapSet.delete(current, owner)
      assign(socket, @assign, put_or_drop(holders, space_id, remaining))
    else
      socket
    end
  end

  @doc """
  Drops `owner` from every space it holds, unsubscribing exactly those that
  emptied.

  Needed by the shell's presence path, which resolves a whole list of space ids
  at once and has no single id to release when the viewer's presence set
  changes.
  """
  @spec release_all(Phoenix.LiveView.Socket.t(), owner()) :: Phoenix.LiveView.Socket.t()
  def release_all(socket, owner) when owner in @owners do
    socket = ensure_holders(socket)

    socket.assigns[@assign]
    |> Enum.reduce(socket, fn {space_id, _set}, acc -> release(acc, space_id, owner) end)
  end

  @doc """
  Whether `owner` currently holds `space_id` on this socket.
  """
  @spec held_by?(Phoenix.LiveView.Socket.t(), binary(), owner()) :: boolean()
  def held_by?(socket, space_id, owner) when is_binary(space_id) and owner in @owners do
    case socket.assigns do
      %{@assign => holders} when is_map(holders) ->
        holders |> Map.get(space_id, MapSet.new()) |> MapSet.member?(owner)

      _ ->
        false
    end
  end

  # An emptied set is deleted rather than stored as an empty MapSet, so the
  # holder map does not grow without bound over a long-lived shell session --
  # `release_all/2` walks every key on every call.
  defp put_or_drop(holders, space_id, remaining) do
    if MapSet.size(remaining) == 0 do
      Chat.PubSub.unsubscribe(space_id)
      Map.delete(holders, space_id)
    else
      Map.put(holders, space_id, remaining)
    end
  end
end
