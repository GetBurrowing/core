defmodule Platform.Chat.Presence do
  @moduledoc """
  Phoenix.Presence for tracking online participants in chat spaces.

  Started automatically by `Platform.Application` after PubSub.

  ## Tracking a participant

  Call from a connected LiveView (or any long-lived process) using the
  topic returned by `Platform.Chat.PubSub.space_topic/1`:

      topic = Platform.Chat.PubSub.space_topic(space_id)
      Platform.Chat.Presence.track(self(), topic, participant_id, %{
        participant_type: "user",
        display_name: "Alice",
        joined_at: DateTime.utc_now()
      })

  Or use the convenience helpers that accept a `space_id` directly:

      Platform.Chat.Presence.track_in_space(self(), space_id, participant_id, %{
        participant_type: "user",
        display_name: "Alice"
      })

  ## Listing presences

      presences = Platform.Chat.Presence.list_space(space_id)
      # => %{"participant-uuid" => %{metas: [%{display_name: "Alice", phx_ref: "…"}]}}

  ## Online count

      Platform.Chat.Presence.online_count(space_id)
      # => 3

  ## Presence diffs in LiveView

  Presence diffs are broadcast on the space topic, so a single
  `Platform.Chat.PubSub.subscribe/1` call receives both chat events and
  presence diffs:

      # in mount/3
      Platform.Chat.PubSub.subscribe(space.id)

      # handle_info callback
      def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
        # diff = %{joins: %{}, leaves: %{}}
        {:noreply, update_presences(socket, diff)}
      end
  """

  use Phoenix.Presence,
    otp_app: :platform,
    pubsub_server: Platform.PubSub

  require Logger

  alias Platform.Agents.WorkspaceBootstrap
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub

  # ── Convenience helpers (space_id ─► topic) ──────────────────────────────────

  @doc """
  Track `pid` as an online participant in `space_id`.

  `key` is the participant's UUID string. `meta` is any serialisable map.
  """
  @spec track_in_space(pid(), binary(), binary(), map()) ::
          {:ok, binary()} | {:error, term()}
  def track_in_space(pid, space_id, key, meta \\ %{}) do
    track(pid, ChatPubSub.space_topic(space_id), key, meta)
  end

  @doc "Update the presence metadata for `key` in `space_id`."
  @spec update_in_space(pid(), binary(), binary(), map() | (map() -> map())) ::
          {:ok, binary()} | {:error, term()}
  def update_in_space(pid, space_id, key, meta) do
    update(pid, ChatPubSub.space_topic(space_id), key, meta)
  end

  @doc """
  Explicitly untrack `key` from `space_id`.

  Presence is cleaned up automatically when the process exits; only call
  this to remove presence early (e.g. user navigates away from a space tab).
  """
  @spec untrack_in_space(pid(), binary(), binary()) :: :ok
  def untrack_in_space(pid, space_id, key) do
    untrack(pid, ChatPubSub.space_topic(space_id), key)
  end

  @doc """
  Return the current presence map for a space.

  Shape: `%{key => %{metas: [meta_map, …]}}` where `key` is the
  participant UUID string.
  """
  @spec list_space(binary()) :: map()
  def list_space(space_id) do
    list(ChatPubSub.space_topic(space_id))
  end

  @doc "Return the number of unique participants currently online in a space."
  @spec online_count(binary()) :: non_neg_integer()
  def online_count(space_id) do
    space_id |> list_space() |> map_size()
  end

  # ── Guarded helpers (a dead tracker must not look like an empty room) ────────
  #
  # `Phoenix.Tracker` can fail in TWO distinct ways here, and a guard that
  # handles only the first is a half-fix that looks complete:
  #
  #   1. The tracker is terminated, so its ETS table is gone and
  #      `[{:pool_size, size}] = :ets.lookup(tracker_name, :pool_size)` raises
  #      **ArgumentError** — a raise, caught by `rescue`.
  #   2. The table survives but the shard serving the topic is unreachable, so
  #      `GenServer.call/3` **exits `:noproc`** — an exit, which `rescue` does
  #      NOT catch.
  #
  # `guarded/2` catches both and returns `{:error, reason}`.

  @doc """
  Track `pid` in `space_id`, returning `{:error, reason}` instead of crashing
  the caller when the presence backend is unreachable.

  "Nobody is here" and "we could not ask" are different facts and must stay
  distinguishable — see `list_online_for_viewer/1`, the prior art for this
  `{:ok, _} | {:error, reason}` vocabulary, whose `{:error, _}` branch is what
  renders the shell's "presence unavailable" state rather than an empty roster.
  """
  @spec safe_track_in_space(pid(), binary(), binary(), map()) ::
          {:ok, binary()} | {:error, term()}
  def safe_track_in_space(pid, space_id, key, meta \\ %{}) do
    guarded("track_in_space", fn ->
      case track_in_space(pid, space_id, key, meta) do
        {:ok, ref} -> {:ok, ref}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Untrack `key` from `space_id`, returning `{:error, reason}` instead of
  crashing the caller when the presence backend is unreachable.

  A failed untrack is not a successful one: callers must be able to tell "the
  participant is no longer tracked" from "we could not reach presence to ask",
  the same two-fact distinction `list_online_for_viewer/1` encodes.
  """
  @spec safe_untrack_in_space(pid(), binary(), binary()) :: :ok | {:error, term()}
  def safe_untrack_in_space(pid, space_id, key) do
    case guarded("untrack_in_space", fn -> {:ok, untrack_in_space(pid, space_id, key)} end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Return `{:ok, count}` for a space, or `{:error, reason}` when the presence
  backend is unreachable.

  It must never return `0` for a failed read: a genuinely empty space and a
  broken presence backend are different facts, and collapsing them into a zero
  is the exact defect `list_online_for_viewer/1` was written to avoid — its
  `{:error, _}` branch is load-bearing, not a decorative nicety.
  """
  @spec safe_online_count(binary()) :: {:ok, non_neg_integer()} | {:error, term()}
  def safe_online_count(space_id) do
    guarded("online_count", fn -> {:ok, online_count(space_id)} end)
  end

  # Runs `fun`, converting BOTH tracker failure modes (an ArgumentError raise
  # from the destroyed pool_size table, and a `:noproc` exit from an
  # unreachable shard) into `{:error, reason}`.
  @spec guarded(binary(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  defp guarded(label, fun) do
    fun.()
  rescue
    error ->
      Logger.error("presence #{label} failed: #{Exception.format(:error, error, __STACKTRACE__)}")

      {:error, error}
  catch
    :exit, reason ->
      Logger.error("presence #{label} failed: exited with #{inspect(reason)}")
      {:error, {:exit, reason}}
  end

  @doc """
  Return the OTHER users currently online anywhere the `viewer` may observe.

  There is no platform-wide presence topic — `Phoenix.Presence` here is
  per-space — so the "platform" answer for a viewer is the UNION of the
  per-space presences across `Chat.list_viewer_presence_space_ids/1`, deduped
  by participant id. That union is bounded by the viewer's own memberships,
  which is what keeps it cheap and what keeps a foreign org's names out.

  Three states, deliberately distinguishable:

    * `{:ok, []}` — nobody else is online. A real answer.
    * `{:ok, [%{user_id: id, name: name}, …]}` — sorted by name.
    * `{:error, reason}` — the presence backend or the scoping query raised.

  A failure must never be able to render as a zero: an empty office and a
  broken read are different facts and callers have to be able to tell them
  apart.

  Only presences whose meta `participant_type` is `"user"` are included, and
  the viewer's own id is excluded — the badge means "other people". Names come
  from the presence meta `display_name`, falling back to the participant row's
  `display_name` in one of the viewer's OWN spaces, never from a space outside
  the scoped set.

  Online-ness is membership in the presence map rather than a boolean on a
  roster row, so there is no code path that can emit an offline entry and the
  count and the list cannot diverge.
  """
  @spec list_online_for_viewer(map() | nil) ::
          {:ok, [%{user_id: binary(), name: binary()}]} | {:error, term()}
  def list_online_for_viewer(%{id: viewer_id} = viewer) when is_binary(viewer_id) do
    space_ids = Chat.list_viewer_presence_space_ids(viewer)

    online =
      Enum.reduce(space_ids, %{}, fn space_id, acc ->
        space_id
        |> list_space()
        |> Enum.reduce(acc, &merge_online_entry(&1, &2, viewer_id))
      end)

    fallbacks =
      online
      |> Enum.filter(fn {_id, name} -> is_nil(name) end)
      |> Enum.map(&elem(&1, 0))
      |> participant_name_fallbacks(space_ids)

    list =
      online
      |> Enum.map(fn {id, name} ->
        %{user_id: id, name: name || Map.get(fallbacks, id) || "Unknown"}
      end)
      |> Enum.sort_by(& &1.name)

    {:ok, list}
  rescue
    error ->
      Logger.error(
        "presence union read failed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      {:error, error}
  end

  def list_online_for_viewer(_viewer), do: {:ok, []}

  defp merge_online_entry({key, %{metas: metas}}, acc, viewer_id) do
    user_meta = Enum.find(metas, &(Map.get(&1, :participant_type) == "user"))

    cond do
      key == viewer_id -> acc
      is_nil(user_meta) -> acc
      true -> Map.update(acc, key, presence_name(user_meta), &(&1 || presence_name(user_meta)))
    end
  end

  defp merge_online_entry(_entry, acc, _viewer_id), do: acc

  defp presence_name(meta) do
    case Map.get(meta, :display_name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp participant_name_fallbacks([], _space_ids), do: %{}

  defp participant_name_fallbacks(missing_ids, space_ids) do
    wanted = MapSet.new(missing_ids)

    space_ids
    |> Enum.flat_map(&Chat.list_participants(&1, participant_type: "user"))
    |> Enum.reduce(%{}, fn participant, acc ->
      name = presence_name(%{display_name: participant.display_name})

      if not is_nil(name) and MapSet.member?(wanted, participant.participant_id) do
        Map.put_new(acc, participant.participant_id, name)
      else
        acc
      end
    end)
  end

  @doc """
  The set of space_ids an EXTERNAL user may receive presence/typing for — a
  `MapSet` of the spaces they are a `chat_participants` member of
  (rbac-external-users M10).

  This is the allowlist the `ChatLive` subscribe loop intersects the
  workspace-wide topic set against, and the same set the `PresenceHooks`
  consumer guards check membership in — one source of truth for both the
  subscription and the consumption scope.

  Internal (non-external) callers pass `nil` downstream, meaning "no
  restriction": their presence/typing behavior is unchanged. Only external
  users are narrowed to this set, so no internal path regresses.
  """
  @spec external_scope_space_ids(binary()) :: MapSet.t(binary())
  def external_scope_space_ids(user_id) when is_binary(user_id) do
    user_id |> Chat.list_member_space_ids() |> MapSet.new()
  end

  @doc """
  Return runtime-backed presence for the configured native agent in a space.
  """
  @spec native_agent_presence(binary(), keyword()) :: map()
  def native_agent_presence(space_id, opts \\ []) do
    status = WorkspaceBootstrap.status(opts)

    participant =
      case status.agent do
        nil ->
          nil

        agent ->
          Chat.list_participants(space_id, participant_type: "agent")
          |> Enum.find(&(&1.participant_id == agent.id))
      end

    Map.merge(status, %{
      joined?: not is_nil(participant),
      participant: participant,
      indicator: native_agent_indicator(status)
    })
  end

  defp native_agent_indicator(%{reachable?: true}), do: :online
  defp native_agent_indicator(%{configured?: true}), do: :offline
  defp native_agent_indicator(_status), do: :missing

  # ── Canvas engagement (ADR 0036) ────────────────────────────────────────
  #
  # Canvas engagement is a facet of space presence, not a parallel channel.
  # Each participant's meta can carry an optional `canvas` bag describing the
  # canvas they are currently engaged with:
  #
  #     %{
  #       canvas_id: "...",
  #       engagement: :viewing | :editing,
  #       focus_node_id: "...",       # only when :editing
  #       kind_state: %{...}          # kind-specific cursor/selection
  #     }
  #
  # Presence is opt-in by intentional interaction — opening a detail panel,
  # focusing an editable node, entering a canvas-centric space view. Passive
  # scroll-past does NOT register.

  @doc """
  Set the canvas engagement bag on `key`'s presence meta in `space_id`.

  Merges into any existing meta; pass `nil` as the canvas meta to clear.
  """
  @spec set_canvas_engagement(pid(), binary(), binary(), map() | nil) ::
          {:ok, binary()} | {:error, term()}
  def set_canvas_engagement(pid, space_id, key, canvas_meta) do
    update_in_space(pid, space_id, key, fn existing ->
      case canvas_meta do
        nil -> Map.delete(existing, :canvas)
        %{} -> Map.put(existing, :canvas, canvas_meta)
      end
    end)
  end

  @doc "Clear canvas engagement for `key` in `space_id`."
  @spec clear_canvas_engagement(pid(), binary(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def clear_canvas_engagement(pid, space_id, key) do
    set_canvas_engagement(pid, space_id, key, nil)
  end

  @doc """
  List participants currently engaged with a canvas in a space.

  Returns `%{viewing: [%{key, meta}], editing: [%{key, meta}]}`. Viewers
  may also be listed under `:editing` when a focus node is set — that is
  the stronger signal, so `:editing` takes precedence.
  """
  @spec list_canvas_engagement(binary(), binary()) :: %{viewing: [map()], editing: [map()]}
  def list_canvas_engagement(space_id, canvas_id) do
    space_id
    |> list_space()
    |> Enum.reduce(%{viewing: [], editing: []}, fn {key, %{metas: metas}}, acc ->
      metas
      |> Enum.find(fn m ->
        case Map.get(m, :canvas) do
          %{canvas_id: ^canvas_id} -> true
          _ -> false
        end
      end)
      |> case do
        nil ->
          acc

        meta ->
          canvas_meta = meta.canvas

          entry = %{
            key: key,
            participant_type: Map.get(meta, :participant_type),
            display_name: Map.get(meta, :display_name),
            focus_node_id: Map.get(canvas_meta, :focus_node_id),
            kind_state: Map.get(canvas_meta, :kind_state, %{})
          }

          case Map.get(canvas_meta, :engagement) do
            :editing -> %{acc | editing: [entry | acc.editing]}
            _ -> %{acc | viewing: [entry | acc.viewing]}
          end
      end
    end)
  end
end
