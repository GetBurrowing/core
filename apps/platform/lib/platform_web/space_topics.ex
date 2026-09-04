defmodule PlatformWeb.SpaceTopics do
  @moduledoc """
  Single writer for the per-space PubSub subscriptions on a LiveView pid:
  `chat:space:<id>`, and — since task 01a0691d stage 3 — `space_agents:<id>`.

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

  @owners [:roster, :presence, :chat_rail, :chat_active, :tasks_exec, :meeting]

  # ── The second topic family: `space_agents:<id>` (task 01a0691d stage 3) ──
  #
  # Same registry, same asymmetry, and until this task the same accident
  # waiting to happen. `space_agents:<id>` carries `{:roster_changed, _}` and
  # used to have exactly ONE subscriber per pid — ShellLive's roster branch —
  # so a bare `Phoenix.PubSub.unsubscribe/2` there was sound by having no
  # co-owner to destroy. The People tab's invite rows need the same message on
  # `/meetings` and on the quickmeet, both of which mount inside that same
  # shell pid, which retires the "sole owner" premise the bare unsubscribe
  # rested on.
  #
  # Bringing it here rather than teaching the shell to be careful is
  # deliberate, and it is this module's own argument (see "Why a refcount
  # owned by only one surface would be worse"): the moment a topic has two
  # writers on one pid, a guard held by only one of them is UNSOUND, not
  # merely incomplete. The second writer's raw unsubscribe destroys the
  # registration while the first still believes it holds one, and the topic
  # goes silently dead — the failure mode is a People tab that simply stops
  # updating, with nothing in a log to say so.
  #
  # A SEPARATE holder map rather than a shared one, because the two topics are
  # held by overlapping-but-different owner sets and a single map keyed only by
  # space id could not distinguish "holds chat:space:<id>" from "holds
  # space_agents:<id>". Releasing one would then unsubscribe the other.
  @agents_assign :agent_topic_holders

  @agents_owners [:roster, :meeting, :quickmeet]

  @typedoc """
  Closed set of surfaces permitted to hold a `chat:space:<id>` subscription on a
  shell pid. Closed on purpose: an unknown atom is a typo, and a typo that
  created a phantom holder would pin a subscription open forever with no surface
  able to release it. Prefer hard failure over quiet degradation.

  Every member must be spelled in THREE places -- `@owners` (what the `when
  owner in @owners` guards enforce), this union, and this prose. A tag added to
  `@owners` alone compiles and passes, and the type simply becomes a lie.

  `:meeting` is `PlatformWeb.MeetingLive`, which mounts inside the same shell
  pid as `ShellLive` and so shares its registrations. It gets its OWN tag rather
  than reusing `:presence` or `:chat_rail`: two surfaces sharing one tag means
  MeetingLive's release also drops the other surface's hold, which is precisely
  the collision the holder map exists to remove. Holders must be
  distinguishable or the map buys nothing.
  """
  @type owner ::
          :roster | :presence | :chat_rail | :chat_active | :tasks_exec | :meeting

  @typedoc """
  Closed set of surfaces permitted to hold a `space_agents:<id>` subscription.
  Same discipline as `t:owner/0`, spelled in the same three places
  (`@agents_owners`, this union, this prose), and a deliberately SHORTER list:
  only three surfaces want roster changes.

    * `:roster` — `PlatformWeb.ShellLive`'s `{:roster_resolved, _}` branch,
      which drives the global Agents meter.
    * `:meeting` — `PlatformWeb.MeetingLive`, member and guest mounts, for the
      People tab's invite rows.
    * `:quickmeet` — `PlatformWeb.ChatLive.MeetingHooks`, the same rows on the
      chat surface. It is NOT `:meeting` even though both are "the People
      tab": `/meetings` auto-joins through `MeetingHooks.do_join/1`, so one
      atom would mean the quickmeet's leave teardown released the hold
      `MeetingLive` still needs for a page that is still open.
  """
  @type agents_owner :: :roster | :meeting | :quickmeet

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
    do_hold(socket, @assign, space_id, owner)
  end

  @doc """
  Drops `owner` from `space_id`'s holder set, unsubscribing iff it just emptied.

  A release by a surface that never held the space is a no-op: it must NOT
  unsubscribe, because the registration it would destroy belongs to somebody
  else. This is the case an unguarded decrement gets wrong.
  """
  @spec release(Phoenix.LiveView.Socket.t(), binary(), owner()) :: Phoenix.LiveView.Socket.t()
  def release(socket, space_id, owner) when is_binary(space_id) and owner in @owners do
    do_release(socket, @assign, space_id, owner)
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
    do_release_all(socket, @assign, owner)
  end

  @doc """
  Whether `owner` currently holds `space_id` on this socket.
  """
  @spec held_by?(Phoenix.LiveView.Socket.t(), binary(), owner()) :: boolean()
  def held_by?(socket, space_id, owner) when is_binary(space_id) and owner in @owners do
    do_held_by?(socket, @assign, space_id, owner)
  end

  # ── `space_agents:<id>` ───────────────────────────────────────────────────
  #
  # The same four calls against the second holder map. Separate public
  # functions rather than a topic argument on the existing ones so the
  # `owner in @owners` / `owner in @agents_owners` guards stay compile-time
  # closed per topic: `:chat_active` is meaningless for the roster topic and
  # `:quickmeet` is meaningless for the chat topic, and a shared entry point
  # would have to accept both and lose that.

  @doc """
  Returns the list of owner atoms recognised for `space_agents:<id>`.
  """
  @spec agents_owners() :: [agents_owner()]
  def agents_owners, do: @agents_owners

  @doc """
  Records `owner` as a holder of `space_agents:<space_id>`, subscribing iff
  nobody held it yet. See `hold/3`; the semantics are identical.
  """
  @spec hold_agents(Phoenix.LiveView.Socket.t(), binary(), agents_owner()) ::
          Phoenix.LiveView.Socket.t()
  def hold_agents(socket, space_id, owner)
      when is_binary(space_id) and owner in @agents_owners do
    do_hold(socket, @agents_assign, space_id, owner)
  end

  @doc """
  Drops `owner` from `space_agents:<space_id>`'s holder set, unsubscribing iff
  it just emptied. See `release/3`.

  This is the call that replaced `ShellLive.release_roster_subscriptions/1`'s
  bare `Phoenix.PubSub.unsubscribe/2`. The bare form removed EVERY registration
  the pid held for the topic, so the shell re-resolving its roster to a
  different space silently killed the People tab's live updates on a call that
  was still in progress.
  """
  @spec release_agents(Phoenix.LiveView.Socket.t(), binary(), agents_owner()) ::
          Phoenix.LiveView.Socket.t()
  def release_agents(socket, space_id, owner)
      when is_binary(space_id) and owner in @agents_owners do
    do_release(socket, @agents_assign, space_id, owner)
  end

  @doc """
  Drops `owner` from every `space_agents:<id>` it holds. See `release_all/2`.
  """
  @spec release_all_agents(Phoenix.LiveView.Socket.t(), agents_owner()) ::
          Phoenix.LiveView.Socket.t()
  def release_all_agents(socket, owner) when owner in @agents_owners do
    do_release_all(socket, @agents_assign, owner)
  end

  @doc """
  Whether `owner` currently holds `space_agents:<space_id>` on this socket.
  """
  @spec agents_held_by?(Phoenix.LiveView.Socket.t(), binary(), agents_owner()) :: boolean()
  def agents_held_by?(socket, space_id, owner)
      when is_binary(space_id) and owner in @agents_owners do
    do_held_by?(socket, @agents_assign, space_id, owner)
  end

  @doc """
  The PubSub topic `Platform.Chat.broadcast_roster_changed/3` publishes
  `{:roster_changed, space_id}` on.

  Public so tests can read the registry for it without re-spelling the string,
  and so this module is the only place in `apps/platform/lib` that builds it
  for a SUBSCRIBE. `Platform.Chat` still builds it for the broadcast.
  """
  @spec agents_topic(binary()) :: String.t()
  def agents_topic(space_id) when is_binary(space_id), do: "space_agents:#{space_id}"

  # ── Shared implementation ─────────────────────────────────────────────────
  #
  # Parameterised on the ASSIGN KEY, which also selects the topic: the two
  # families are otherwise the same algorithm, and duplicating it would mean
  # the refcount could be fixed in one and left broken in the other.

  defp do_hold(socket, assign_key, space_id, owner) do
    socket = seed(socket, assign_key)
    holders = socket.assigns[assign_key]
    current = Map.get(holders, space_id, MapSet.new())

    if MapSet.size(current) == 0 do
      subscribe(assign_key, space_id)
    end

    assign(socket, assign_key, Map.put(holders, space_id, MapSet.put(current, owner)))
  end

  defp do_release(socket, assign_key, space_id, owner) do
    socket = seed(socket, assign_key)
    holders = socket.assigns[assign_key]
    current = Map.get(holders, space_id, MapSet.new())

    if MapSet.member?(current, owner) do
      remaining = MapSet.delete(current, owner)
      assign(socket, assign_key, put_or_drop(assign_key, holders, space_id, remaining))
    else
      socket
    end
  end

  defp do_release_all(socket, assign_key, owner) do
    socket = seed(socket, assign_key)

    socket.assigns[assign_key]
    |> Enum.reduce(socket, fn {space_id, _set}, acc ->
      do_release(acc, assign_key, space_id, owner)
    end)
  end

  defp do_held_by?(socket, assign_key, space_id, owner) do
    case socket.assigns do
      %{^assign_key => holders} when is_map(holders) ->
        holders |> Map.get(space_id, MapSet.new()) |> MapSet.member?(owner)

      _ ->
        false
    end
  end

  defp seed(socket, @assign), do: ensure_holders(socket)

  defp seed(socket, @agents_assign) do
    case socket.assigns do
      %{@agents_assign => holders} when is_map(holders) -> socket
      _ -> assign(socket, @agents_assign, %{})
    end
  end

  defp subscribe(@assign, space_id), do: Chat.PubSub.subscribe(space_id)

  defp subscribe(@agents_assign, space_id),
    do: Phoenix.PubSub.subscribe(Platform.PubSub, agents_topic(space_id))

  defp unsubscribe(@assign, space_id), do: Chat.PubSub.unsubscribe(space_id)

  defp unsubscribe(@agents_assign, space_id),
    do: Phoenix.PubSub.unsubscribe(Platform.PubSub, agents_topic(space_id))

  # An emptied set is deleted rather than stored as an empty MapSet, so the
  # holder map does not grow without bound over a long-lived shell session --
  # `release_all/2` walks every key on every call.
  defp put_or_drop(assign_key, holders, space_id, remaining) do
    if MapSet.size(remaining) == 0 do
      unsubscribe(assign_key, space_id)
      Map.delete(holders, space_id)
    else
      Map.put(holders, space_id, remaining)
    end
  end
end
