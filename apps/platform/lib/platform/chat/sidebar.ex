defmodule Platform.Chat.Sidebar do
  @moduledoc """
  Sidebar shape: the admin-curated org default + (Stage 3) per-user overrides.

  This module (Stage 2) covers the **default** layer — reading the ordered
  section list and the Fabrikam-admin-gated curation writes. The split between
  channel *identity* (`chat_spaces.org_id`, global, admin) and per-user
  *arrangement* (Stage 3, `users.preferences`) is the core design decision:
  a regular user rearranges their own view; only a Fabrikam admin changes what
  everyone sees by default.

  Every write is authorized through `Platform.Tenancy.fabrikam_admin?/1` —
  the controls in the LiveView (Stage 6) are an affordance, not the gate.
  """
  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Section
  alias Platform.Repo
  alias Platform.Tenancy

  # users.preferences keys for the per-user arrangement layer (Stage 3).
  @section_order_key "chat_section_order"
  @channel_order_key "chat_channel_order"
  @hidden_sections_key "chat_hidden_sections"
  # Collapse is NOT hide. A hidden section leaves the rail entirely (and takes
  # its channels with it); a collapsed section still renders its header, just
  # without its channel rows. The two keys stay separate so a user can undo
  # either one on its own.
  @collapsed_sections_key "chat_collapsed_sections"
  # Pinned CONVERSATIONS, not pinned channels. The key holds `chat_spaces` ids
  # of either kind, because the Pinned block lifts channels and direct messages
  # into one flat list. Naming it `chat_pinned_channels` would buy a migration
  # the first time someone pins a DM.
  @pinned_spaces_key "chat_pinned_spaces"

  @doc """
  The org-default sections, ordered by admin position then name.

  ALL rows, including sections whose org is archived — the curation writes
  and the admin editor need the full set. The RENDER path must use
  `list_active_default_sections/0` instead.
  """
  @spec list_default_sections() :: [Section.t()]
  def list_default_sections do
    Repo.all(from(s in Section, order_by: [asc: s.position, asc: s.name]))
  end

  @doc """
  The org-default sections a user should actually SEE — `list_default_sections/0`
  minus any section whose org is archived (task 019f4eaa).

  Archiving an org cascade-hides its projects and channels, but a section is a
  row of its own in `channel_sections` and the cascade never touched it. So the
  channels correctly vanished while the org's section header kept rendering
  above an empty "No channels yet" placeholder — the org looked half-deleted.
  Marlowe hit this walking the review.

  Mirrors `Tenancy.list_tenants/0` vs `list_active_tenants_unscoped/0`: the data API
  keeps returning every row; only the render path filters. Restoring the org
  brings the section back with no extra work, because nothing about the
  section row ever changed.
  """
  @spec list_active_default_sections() :: [Section.t()]
  def list_active_default_sections do
    Repo.all(
      from(s in Section,
        join: o in Platform.Tenancy.Org,
        on: o.id == s.org_id,
        where: is_nil(o.archived_at),
        order_by: [asc: s.position, asc: s.name]
      )
    )
  end

  @doc "Rename an org-default section (Fabrikam admin only)."
  @spec rename_section(map(), binary(), String.t()) ::
          {:ok, Section.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def rename_section(actor, section_id, name) when is_binary(name) do
    with_admin(actor, fn -> update_section(section_id, %{name: name}) end)
  end

  @doc "Recolor an org-default section (Fabrikam admin only). `color` is a scope token, e.g. \"sxi\"."
  @spec recolor_section(map(), binary(), String.t()) ::
          {:ok, Section.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def recolor_section(actor, section_id, color) when is_binary(color) do
    with_admin(actor, fn -> update_section(section_id, %{color: color}) end)
  end

  @doc """
  Set the admin default section order from an ordered list of section ids
  (Fabrikam admin only). Unknown ids are skipped (skip-unknown robustness).
  Returns `{:ok, updated_count}`.
  """
  @spec reorder_sections(map(), [binary()]) ::
          {:ok, non_neg_integer()} | {:error, :unauthorized}
  def reorder_sections(actor, ordered_ids) when is_list(ordered_ids) do
    with_admin(actor, fn ->
      now = DateTime.utc_now()

      {:ok, count} =
        Repo.transaction(fn ->
          ordered_ids
          |> Enum.with_index()
          |> Enum.reduce(0, fn {id, idx}, acc ->
            {n, _} =
              from(s in Section, where: s.id == ^id)
              |> Repo.update_all(set: [position: idx, updated_at: now])

            acc + n
          end)
        end)

      {:ok, count}
    end)
  end

  @doc """
  Globally reassign a channel to another section by setting its identity
  `chat_spaces.org_id` (Fabrikam admin only). This is the "everyone sees it
  there" action.

  Also prunes the reassigned channel from every user's `chat_channel_order`
  so the admin move wins over a stale personal placement (design decision
  1a) — after pruning, the channel falls back to its new org_id default
  section in each user's view.
  """
  @spec reassign_channel(map(), binary(), binary() | nil) ::
          {:ok, Chat.Space.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def reassign_channel(actor, channel_id, org_id) when is_binary(channel_id) do
    with_admin(actor, fn ->
      case Chat.get_space(channel_id) do
        nil ->
          {:error, :not_found}

        space ->
          with {:ok, updated} <- Chat.assign_space_org(space, org_id) do
            prune_channel_from_overrides(channel_id)
            {:ok, updated}
          end
      end
    end)
  end

  # ── Per-user resolver (Stage 3) ─────────────────────────────────────────

  @typedoc """
  A rendered section + its ordered channels + whether the user has collapsed it.

  `collapsed?` is presentation state, not filtering: the entry is present either
  way, and `channels` is populated either way. Only the render decides whether to
  draw the rows.
  """
  @type resolved :: %{
          section: Section.t(),
          channels: [Chat.Space.t()],
          collapsed?: boolean()
        }

  @doc """
  Flatten resolved sections into one ordered channel list — the user's
  curated arrangement, left-to-right / top-to-bottom.

  This is THE bridge between the sectioned surfaces (drawer, desktop rail)
  and flat ones (the mobile pills strip): both consume the same resolver
  output, so they cannot drift. Because the input is the resolver's
  hidden-filtered result, hidden channels/sections are absent here too —
  hidden means hidden everywhere (Marlowe's decision, 2026-07-05).
  """
  @spec flatten_sections([resolved()]) :: [Chat.Space.t()]
  def flatten_sections(sections), do: Enum.flat_map(sections, & &1.channels)

  @doc """
  Resolve the sidebar for a user: org default sections + their personal
  overrides. Loads sections and the user's prefs, then delegates to the pure
  `resolve/3`. Anonymous / unknown user ids resolve to the plain default.

  Reads `list_active_default_sections/0`, NOT `list_default_sections/0` — an
  archived org must not keep a section header in anyone's sidebar.
  """
  @spec resolve_for_user(binary() | nil, [Chat.Space.t()]) :: [resolved()]
  def resolve_for_user(user_id, channels) do
    resolve(list_active_default_sections(), channels, Accounts.get_user_preferences(user_id))
  end

  @doc """
  Pure merge of org-default `sections` + `channels` + a user `prefs` map.

  Order of operations: (1) order sections by `chat_section_order`, skipping
  unknown ids and appending sections the user hasn't ordered; (2) drop
  `chat_hidden_sections` (a hidden section takes its channels with it —
  design decision (a)); (3) place each channel in the user's chosen section
  via `chat_channel_order`, else its `org_id` default section, with
  user-ordered channels first and new/unplaced channels appended; (4) stamp
  `collapsed?` from `chat_collapsed_sections`.

  Step (4) is a FLAG, never a filter. A collapsed section keeps its place in
  the list and keeps its resolved `channels`, so the render can still count
  unread activity inside it and `flatten_sections/1` still sees those channels.
  Collapse is the one override in this module that changes nothing about what
  the resolver returns beyond the boolean.

  Every lookup is skip-unknown: stale section/channel ids in prefs are
  silently ignored so a poisoned preference can never crash the rail. A
  collapsed id naming a deleted section is simply a MapSet miss, so deleting or
  archiving an org never needs a cleanup pass over preferences.
  """
  @spec resolve([Section.t()], [Chat.Space.t()], map()) :: [resolved()]
  def resolve(sections, channels, prefs) when is_list(sections) and is_list(channels) do
    hidden = MapSet.new(prefs[@hidden_sections_key] || [])
    collapsed = MapSet.new(prefs[@collapsed_sections_key] || [])
    channel_order = prefs[@channel_order_key] || %{}

    visible_sections =
      sections
      |> order_sections(prefs[@section_order_key])
      |> Enum.reject(&MapSet.member?(hidden, &1.id))

    visible_sections
    |> place_channels(sections, channels, channel_order)
    |> Enum.map(&Map.put(&1, :collapsed?, MapSet.member?(collapsed, &1.section.id)))
  end

  # ── Per-user preference writes (Stage 3) ────────────────────────────────

  @doc "Persist the user's section order (list of section ids)."
  @spec put_section_order(binary(), [binary()]) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def put_section_order(user_id, ordered_ids) when is_list(ordered_ids) do
    Accounts.update_user_preference(user_id, @section_order_key, ordered_ids)
  end

  @doc """
  Set the ordered channel ids for one section in the user's view, moving any
  of those channels out of other sections (single-placement invariant).
  """
  @spec put_channel_order(binary(), binary(), [binary()]) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def put_channel_order(user_id, section_id, channel_ids)
      when is_binary(section_id) and is_list(channel_ids) do
    current = Accounts.get_user_preferences(user_id)[@channel_order_key] || %{}
    moving = MapSet.new(channel_ids)

    next =
      current
      |> Map.new(fn {sid, ids} ->
        {sid, if(sid == section_id, do: ids, else: Enum.reject(ids, &MapSet.member?(moving, &1)))}
      end)
      |> Map.put(section_id, channel_ids)

    Accounts.update_user_preference(user_id, @channel_order_key, next)
  end

  @doc "Hide or show a section in the user's view."
  @spec set_section_hidden(binary(), binary(), boolean()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_section_hidden(user_id, section_id, hidden?) when is_binary(section_id) do
    current = Accounts.get_user_preferences(user_id)[@hidden_sections_key] || []

    next =
      if hidden?,
        do: Enum.uniq([section_id | current]),
        else: Enum.reject(current, &(&1 == section_id))

    Accounts.update_user_preference(user_id, @hidden_sections_key, next)
  end

  @doc """
  Collapse or expand a section in the user's view.

  Distinct from `set_section_hidden/3`: collapsing keeps the section in the
  rail and only folds away its channel rows, so it writes a different
  preference key and neither call disturbs the other.

  Takes the DESIRED next state rather than flipping, so a double-fire from a
  render race is idempotent instead of a silent re-expand.
  """
  @spec set_section_collapsed(binary(), binary(), boolean()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_section_collapsed(user_id, section_id, collapsed?) when is_binary(section_id) do
    current = Accounts.get_user_preferences(user_id)[@collapsed_sections_key] || []

    next =
      if collapsed?,
        do: Enum.uniq([section_id | current]),
        else: Enum.reject(current, &(&1 == section_id))

    Accounts.update_user_preference(user_id, @collapsed_sections_key, next)
  end

  # ── Pinned conversations (task 019fd80f stage 1) ────────────────────────
  #
  # Storage choice, and the evidence for it. Neither existing pin table can
  # represent "this user pinned this conversation":
  #
  #   * `chat_pins` (`Platform.Chat.Pin`) is MESSAGE pinning. `message_id` is
  #     NOT NULL with an FK to `chat_messages`, so there is no row shape for a
  #     pin that names only a space.
  #
  #   * `task_chat_pins` (`Platform.Tasks.ChatPin`) pins a TASK. The FK is
  #     `task_id` into `tasks`, ON DELETE CASCADE, and the space is recovered
  #     indirectly. A channel or a DM has no task, so it cannot be stored.
  #
  # So this is a `users.preferences` key alongside the four arrangement keys
  # above, which is also where every other per-user rail override already
  # lives.

  @doc """
  The user's pinned space ids, in pin order (most-recently-pinned last).

  A list rather than a `MapSet` because the Pinned block renders in this
  order. Use `pinned_space_ids/1` for the O(1) membership check on the
  exclusion path, and `Platform.Chat.PinnedSpaces.partition/2` to resolve
  ids against loaded spaces.

  Empty list for anonymous or unknown user ids.
  """
  @spec list_pinned_space_ids(binary() | nil) :: [binary()]
  def list_pinned_space_ids(user_id) do
    user_id
    |> Accounts.get_user_preferences()
    |> Map.get(@pinned_spaces_key, [])
    |> List.wrap()
  end

  @doc """
  The user's pinned space ids as a `MapSet`, for the per-row membership test
  on the render path. Empty set for anonymous or unknown user ids.
  """
  @spec pinned_space_ids(binary() | nil) :: MapSet.t(binary())
  def pinned_space_ids(user_id), do: user_id |> list_pinned_space_ids() |> MapSet.new()

  @doc """
  Pin or unpin a conversation for a user.

  Takes the DESIRED next state rather than flipping, so a double-fire from a
  render race is idempotent instead of a silent unpin.

  Accepts any `chat_spaces` id with no `kind` restriction: the Pinned block
  holds channels and direct messages in one list.

  Pinning APPENDS, so the block reads most-recently-pinned last. Re-pinning
  an already-pinned space keeps its existing position rather than moving it
  to the end, so a repeated event cannot shuffle the block. There is no
  position field; reordering within the block is out of scope.

  Returns `{:error, :not_found}` when the id matches no user row. Anonymous
  chat sessions carry a generated UUID, and callers treat that as a no-op.
  """
  @spec set_space_pinned(binary(), binary(), boolean()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_space_pinned(user_id, space_id, pinned?) when is_binary(space_id) do
    current = list_pinned_space_ids(user_id)

    next =
      if pinned?,
        do: Enum.uniq(current ++ [space_id]),
        else: Enum.reject(current, &(&1 == space_id))

    Accounts.update_user_preference(user_id, @pinned_spaces_key, next)
  end

  @doc """
  Reset the user's sidebar to the org default by clearing all five override
  keys (the no-copy-on-write "reset to default"). No-op for anonymous ids.
  """
  @spec reset_to_default(binary()) :: {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def reset_to_default(user_id) do
    with {:ok, _} <- Accounts.update_user_preference(user_id, @section_order_key, nil),
         {:ok, _} <- Accounts.update_user_preference(user_id, @channel_order_key, %{}),
         {:ok, _} <- Accounts.update_user_preference(user_id, @hidden_sections_key, []),
         {:ok, _} <- Accounts.update_user_preference(user_id, @collapsed_sections_key, []) do
      Accounts.update_user_preference(user_id, @pinned_spaces_key, [])
    end
  end

  @doc """
  Remove a channel from every user's `chat_channel_order` (used when an admin
  reassigns its org_id, decision 1a). Scans users with a non-empty channel
  order; fine at current scale (rare admin action) — a JSONB-targeted query
  is a future optimization if user counts grow.
  """
  @spec prune_channel_from_overrides(binary()) :: :ok
  def prune_channel_from_overrides(channel_id) when is_binary(channel_id) do
    User
    |> Repo.all()
    |> Enum.each(fn %User{id: id, preferences: prefs} ->
      cco = (is_map(prefs) && prefs[@channel_order_key]) || %{}

      if is_map(cco) and channel_referenced?(cco, channel_id) do
        pruned = Map.new(cco, fn {sid, ids} -> {sid, List.delete(ids, channel_id)} end)
        Accounts.update_user_preference(id, @channel_order_key, pruned)
      end
    end)

    :ok
  end

  # ── internal ──────────────────────────────────────────────────────────

  defp channel_referenced?(channel_order, channel_id) do
    Enum.any?(channel_order, fn {_sid, ids} -> is_list(ids) and channel_id in ids end)
  end

  # Order sections by the user's saved id list, skipping unknown ids and
  # appending any sections the user hasn't placed (by admin position). A nil
  # / non-list pref falls back entirely to admin order.
  defp order_sections(sections, order_ids) when is_list(order_ids) do
    by_id = Map.new(sections, &{&1.id, &1})

    ordered =
      order_ids
      |> Enum.map(&Map.get(by_id, &1))
      |> Enum.reject(&is_nil/1)

    placed = MapSet.new(ordered, & &1.id)
    remaining = Enum.reject(sections, &MapSet.member?(placed, &1.id))

    ordered ++ remaining
  end

  defp order_sections(sections, _), do: sections

  # Distribute channels into the visible sections: user-placed channels (in
  # their saved order) first, then channels defaulting to that section by
  # org_id (excluding any the user explicitly placed elsewhere).
  defp place_channels(visible_sections, all_sections, channels, channel_order) do
    by_id = Map.new(channels, &{&1.id, &1})
    explicitly_placed = explicitly_placed_ids(channel_order)
    fallback_id = fallback_section_id(all_sections)
    org_to_section = Map.new(all_sections, &{&1.org_id, &1.id})

    Enum.map(visible_sections, fn section ->
      user_channels =
        (channel_order[section.id] || [])
        |> Enum.map(&Map.get(by_id, &1))
        |> Enum.reject(&is_nil/1)

      default_channels =
        Enum.filter(channels, fn ch ->
          not MapSet.member?(explicitly_placed, ch.id) and
            default_section_id(ch, org_to_section, fallback_id) == section.id
        end)

      %{section: section, channels: user_channels ++ default_channels}
    end)
  end

  defp explicitly_placed_ids(channel_order) do
    channel_order
    |> Enum.flat_map(fn {_sid, ids} -> if is_list(ids), do: ids, else: [] end)
    |> MapSet.new()
  end

  # A channel's default section is the one owned by its org; channels with no
  # matching section (nil/unknown org_id) fall back to the first section.
  defp default_section_id(%{org_id: org_id}, org_to_section, fallback_id) do
    Map.get(org_to_section, org_id, fallback_id)
  end

  defp fallback_section_id([]), do: nil

  defp fallback_section_id(sections) do
    sections |> Enum.min_by(& &1.position, fn -> hd(sections) end) |> Map.get(:id)
  end

  # `section_id` is a `phx-value-` param off the sidebar rename/recolor events.
  # Malformed collapses into the existing :not_found contract.
  defp update_section(section_id, attrs) do
    if Platform.UUID.valid?(section_id) do
      case Repo.get(Section, section_id) do
        nil -> {:error, :not_found}
        section -> section |> Section.changeset(attrs) |> Repo.update()
      end
    else
      {:error, :not_found}
    end
  end

  defp with_admin(actor, fun) do
    if Tenancy.fabrikam_admin?(actor), do: fun.(), else: {:error, :unauthorized}
  end
end
