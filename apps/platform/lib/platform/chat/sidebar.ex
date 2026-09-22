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
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Section
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat
  alias Platform.Roles
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

  @doc """
  Ensure the org has its `channel_sections` row, creating it if absent.

  Until task 01a00910 NOTHING in `apps/platform/lib` ever created one — the
  only rows in the table came from the `20260604000100_create_channel_sections`
  seed, which covered the orgs that existed on 2026-06-04. Every org created
  after that date had no section, so `default_section_id/3` fell through to
  `fallback_section_id/1` and its channels rendered under whichever section
  happened to hold the lowest `position`. That is the Cyberdyne symptom.

  Idempotent via `on_conflict: :nothing` against the real
  `unique_index(:channel_sections, [:org_id])`, so a second call for the same
  org is a no-op that still returns the existing row.

  `color` mirrors the seed migration EXACTLY: the org slug with `_` → `-`.
  Org slugs are stored underscore-form (`wayne_tech`) while section colour
  tokens and the `.bg-<token>-dot` CSS classes are hyphen-form; reversing the
  replace yields a section whose `section_dot_class/1` lookup misses and whose
  dot silently disappears.

  `position` is `max(position) + 1`. Two concurrent creates can read the same
  max and land on the same position; `org_id` is what's unique, so the conflict
  target does not catch it. Accepted deliberately — org creation is rare and
  Fabrikam-admin-gated, ties only make the render order of two brand-new sections
  nondeterministic, and an admin reorder renumbers them. Serializing this
  behind an advisory lock would buy strictness nothing reads.
  """
  @spec ensure_default_section(Tenancy.Org.t()) :: {:ok, Section.t()} | {:error, term()}
  def ensure_default_section(%Tenancy.Org{} = org) do
    next_position = (Repo.one(from(s in Section, select: max(s.position))) || -1) + 1

    %Section{}
    |> Section.changeset(%{
      org_id: org.id,
      name: org.name,
      color: String.replace(org.slug || "", "_", "-"),
      position: next_position
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: :org_id)
    |> case do
      # `on_conflict: :nothing` still hands back the changeset's struct — id and
      # all — even when the INSERT was skipped, so the returned struct is NOT
      # evidence of the row that's actually in the table. Re-read by `org_id`
      # (the unique key) so a second call returns the EXISTING section rather
      # than a phantom carrying an id no row has.
      {:ok, %Section{}} -> {:ok, Repo.get_by(Section, org_id: org.id)}
      other -> other
    end
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

  Personal arrangement is NOT touched. Design decision 1a (prune the channel
  out of every user's `chat_channel_order` so the admin move overrides a
  personal placement) was REVERSED on 2026-08-06. None of the products
  surveyed for that decision (Slack, Linear, Teams, Notion, Discord)
  overwrites a user's own arrangement from an admin action, and Microsoft
  shipped the equivalent in Teams and then withdrew it. Wiping a placement
  the user made by hand is the specific behaviour that was rejected here.
  `prune_channel_from_overrides/1` survives as a public operation for a
  caller that deliberately wants the wipe; the reassign path is not one.

  The split this produces needs no machinery, because `place_channels/4`
  already draws the line: a user who never placed this channel has no
  `chat_channel_order` entry for it, so it resolves through its (new)
  `org_id` and relocates to the destination section on its own; a user who
  did place it stays in that function's `explicitly_placed` set, so the
  channel keeps their section and cannot also appear in the destination.

  That second half holds only while the section they chose is still VISIBLE
  to them. `place_channels/4` walks `visible_sections` only, so a channel
  placed into a section the user has HIDDEN renders nowhere: the destination
  skips it as explicitly placed, and its own section is not in the list. That
  is the intended contract (hidden takes its channels with it), and it is what
  stops an admin move from also un-hiding a channel.

  An ARCHIVED org is a different case and no longer behaves that way. Since
  task 019fd7f8, `place_channels/4` counts a `chat_channel_order` entry only
  when its section id is present in `all_sections`, so a placement into an
  archived org's section is inert in both directions: it neither keeps the
  channel nor withholds it from its `org_id` default, and the channel resolves
  to the destination section like any unplaced one. See the scoping rule on
  `place_channels/4`. That repair is read-side in the resolver, so it mutates
  no preference and touches no write path, which is why it did not have to
  live behind an admin reassign.

  Emits `[:platform, :chat, :channel_reassigned]` after a successful write.
  `Platform.Chat.TelemetryHandler` bridges it to the audit store.
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
            emit_channel_reassigned(actor, updated, space.org_id)
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

  Skip-unknown is SYMMETRIC for `chat_channel_order`. An entry filed under a
  section id absent from `sections` is ignored in both directions: it neither
  places its channels nor withholds them from their `org_id` default. Gating
  only the placing let an entry that could never place a channel still hide it
  from every section, which is the defect fixed in task 019fd7f8. The gate is
  presence in `sections`, NOT visibility: a hidden section is still present,
  so it goes on withholding its channels per decision (a) above.
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
  Move one pinned conversation to a new position in the user's pin order
  (task 019fe987).

  Reordering is a REWRITE of `chat_pinned_spaces`, which is already an
  ordered list. There is no position column and no second preference key:
  the list's own order is what the Pinned block renders, via
  `Platform.Chat.PinnedSpaces.partition/2`.

  `to_index` is an index into the list with `space_id` REMOVED, so it names
  the slot the pin lands in. `0` is the top of the block and
  `length(list) - 1` is the bottom. Callers derive it from the rendered
  order; see `PlatformWeb.ChatLive`'s `pinned_destination_index/3`.

  Tolerant on both arguments, matching the skip-unknown property the read
  side already holds (`PinnedSpaces` drops a pinned id that names no live
  space, so a stale id survives in preferences indefinitely and can reach
  this function):

    * a `space_id` that is not in the list leaves the list unchanged
    * a `to_index` outside `0..length(rest)` leaves the list unchanged

  Neither raises. An unchanged list is still written, so the return shape
  matches `set_space_pinned/3` on every path.
  """
  @spec move_pinned_space(binary(), binary(), integer()) ::
          {:ok, User.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def move_pinned_space(user_id, space_id, to_index)
      when is_binary(space_id) and is_integer(to_index) do
    next =
      user_id
      |> list_pinned_space_ids()
      |> move_pin(space_id, to_index)

    Accounts.update_user_preference(user_id, @pinned_spaces_key, next)
  end

  # Guard the out-of-range cases explicitly rather than leaning on
  # `List.insert_at/3`, which treats a negative index as "from the end" and
  # any index past the tail as "append". Both would silently relocate a pin
  # on a payload that means nothing, which is worse than ignoring it.
  defp move_pin(current, space_id, to_index) do
    rest = Enum.reject(current, &(&1 == space_id))

    if space_id in current and to_index >= 0 and to_index <= length(rest) do
      List.insert_at(rest, to_index, space_id)
    else
      current
    end
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
  Remove a channel from every user's `chat_channel_order`.

  NOT called from `reassign_channel/3` any more: design decision 1a was
  reversed on 2026-08-06 (the reasoning lives on that function). This stays
  public because it is the only way to clear a channel out of personal
  arrangements wholesale, and it is spec'd and tested on its own terms.

  Scans every user and rewrites the ones that reference the channel. Fine at
  current scale for a rare, deliberate action; a JSONB-targeted query is the
  optimization if user counts grow.
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

  # The audit trail for the admin identity move. `Platform.Audit` documents
  # `record/1` as NOT the preferred entry point: emitting on the
  # `[:platform, domain, action]` convention is what gets the row written, via
  # `Platform.Chat.TelemetryHandler`. That is why neither this module nor the
  # LiveView calls `Audit.record/1` directly. Registration in that handler's
  # `@chat_events` is load-bearing: an unregistered emit fails SILENTLY, with
  # nothing raised and simply no audit row.
  #
  # A nil org id (the channel had none, or is being cleared) is OMITTED rather
  # than passed as nil. The handler's `ensure_json_safe/1` stringifies atoms
  # and nil is an atom, so a nil value would persist as the literal "nil".
  defp emit_channel_reassigned(actor, space, from_org_id) do
    metadata =
      %{
        actor_id: Map.get(actor, :id),
        actor_type: "user",
        resource_type: "chat_space",
        action: "channel_reassigned",
        # The handler derives the `resource_id` COLUMN from `space_id`
        # (`resource_id_from/1`), so a `resource_id` key here would be inert
        # and would read as though it were the one that lands.
        space_id: space.id
      }
      |> put_present(:from_org_id, from_org_id)
      |> put_present(:to_org_id, space.org_id)

    :telemetry.execute(
      [:platform, :chat, :channel_reassigned],
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp put_present(metadata, _key, nil), do: metadata
  defp put_present(metadata, key, value), do: Map.put(metadata, key, value)

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
  # org_id (excluding any the user explicitly placed into a section that is
  # still present in `all_sections`).
  #
  # `explicitly_placed` is scoped to `all_sections`, NOT `visible_sections`.
  # A `chat_channel_order` entry does two things: it places a channel into
  # section S, and it withholds that channel from its org default. Both have
  # to be gated on the same condition, or a channel can be withheld by an
  # entry that can never place it (task 019fd7f8). Placing is already
  # visibility-gated by construction, since the walk below is over
  # `visible_sections`; withholding is gated on presence. A HIDDEN section is
  # still present, so it keeps withholding its channels, which is what makes
  # hiding take its channels with it (design decision (a)).
  defp place_channels(visible_sections, all_sections, channels, channel_order) do
    by_id = Map.new(channels, &{&1.id, &1})
    fallback_id = fallback_section_id(all_sections)
    org_to_section = Map.new(all_sections, &{&1.org_id, &1.id})
    known_section_ids = MapSet.new(all_sections, & &1.id)
    explicitly_placed = explicitly_placed_ids(channel_order, known_section_ids)

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

  # Only entries naming a section that still exists count. An entry filed
  # under a vanished section id places nothing, so it must withhold nothing.
  defp explicitly_placed_ids(channel_order, known_section_ids) do
    channel_order
    |> Enum.flat_map(fn {sid, ids} ->
      if MapSet.member?(known_section_ids, sid) and is_list(ids), do: ids, else: []
    end)
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

  # ── Agents goal surface (task 01a0b491, stage 4) ───────────────────────────

  @agents_leader_role "agents_leader"

  @doc """
  Whether the agents goal surface renders at all.

  ONE switch for the whole feature: the rail block above Pinned and the
  space header's goal line both ask this and both render NOTHING when it
  is false. Set in `config/runtime.exs` from `AGENTS_GOAL_SURFACE`,
  default off in every environment.

  It is not a permission and not a per-user preference — it is a build
  gate, so it is read straight from application env at render time rather
  than carried through a context struct.
  """
  @spec agents_surface_enabled?() :: boolean()
  def agents_surface_enabled? do
    Application.get_env(:platform, :agents_goal_surface, false) == true
  end

  @doc """
  The rail block's data, or `nil`.

  Returns `nil` — meaning render nothing, no label and no placeholder —
  when the flag is off or no space carries a goal. The top of a 260px
  rail is too expensive to spend on a feature nobody has adopted, which
  is the same rule `pinned_block/1` states for its own empty case.

  The shape is `%{space: %Space{}, leader: %Agent{} | nil}`. The leader
  is resolved by `agents_leader/1`, NOT read off the space row directly —
  see that function for why.
  """
  @spec agents_rail_block() :: %{space: term(), leader: term() | nil} | nil
  def agents_rail_block do
    if agents_surface_enabled?() do
      case AgentsGoalHeartbeat.agents_space() do
        nil -> nil
        space -> %{space: space, leader: agents_leader(space)}
      end
    end
  end

  @doc """
  Removes the agents space from a channel list, keyed on the rail block
  the caller RENDERS.

  Invariant: it excludes exactly the space `agents_block` shows, and
  nothing else. A `nil` block (flag off, or no space carries a goal)
  returns `channels` unchanged, so with the feature off the org list is
  exactly what it was before this function existed.

  It takes the block rather than querying `agents_rail_block/0` itself on
  purpose. The block and the org list must answer from the SAME snapshot:
  a fresh query here could disagree with a stale `@agents_block` and drop
  the channel from the org list while the block does not show it, leaving
  it reachable nowhere. Keyed on the rendered block, a stale snapshot errs
  toward listing the channel (or showing it in the block), never neither.

  Only the listing changes. The space keeps its `org_id`, membership and
  access; `place_channels/4` never sees it.
  """
  @spec reject_agents_space([%{id: term()}], %{space: %{id: term()}} | nil) :: [%{id: term()}]
  def reject_agents_space(channels, nil), do: channels

  def reject_agents_space(channels, %{space: %{id: id}}) do
    Enum.reject(channels, &(&1.id == id))
  end

  @doc """
  The header goal panel for `space`, or `nil`.

  `nil` when the flag is off, when there is no space, or when the space
  carries no goal — which is what makes an ordinary channel's header
  identical to what it was before this feature existed. That absence is
  the positive control for every assertion about the panel.

  `measurement` is DERIVED HERE on every call, never cached beside the
  goal. That is what makes a saved goal whose measurement can no longer
  be derived show the no-measurement state immediately rather than the
  previous goal's stale number: there is no stored number for the header
  to fall back to.
  """
  @spec goal_panel(term()) :: map() | nil
  def goal_panel(%Chat.Space{goal: goal} = space) when is_binary(goal) and goal != "" do
    if agents_surface_enabled?() do
      %{
        space: space,
        goal: goal,
        measurement: AgentsGoalHeartbeat.measure(space, goal),
        leader: agents_leader(space)
      }
    end
  end

  def goal_panel(_space), do: nil

  @doc """
  Whether `space` may be offered its FIRST goal.

  True only when ALL hold: the space is a non-archived `kind: "channel"`
  whose own goal is nil or `""`, the flag is on, and NO space on the
  install carries a goal (`AgentsGoalHeartbeat.agents_space/0` is nil).
  Clauses are ordered so the struct match and the flag short-circuit
  before the one DB query.

  Why install-wide, not every channel: `agents_space/0` takes the
  EARLIEST goal-carrying space, so a first goal on a second channel
  yields a goal but not the agents surface. Two identical controls with
  two different outcomes and no visible difference is the trap this
  scope exists to avoid. Setting a goal where none exists anywhere is
  exactly the adoption case; an ordinary per-channel goal has no
  consumer today.

  Takes no user: the admin gate stays `can_edit_goal?` in the LiveView.
  `save_goal` also calls this, because `Chat.update_space/2` broadcasts
  nothing and a second window's invitation can be stale.

  BEST-EFFORT, not a database invariant: this is a read that runs before
  the write, so two admins submitting at the same instant can both pass
  it. The consequence is bounded — `agents_space/0` picks the earliest
  goal-carrying space deterministically, so the rail stays stable.
  `agents_space/0` also returns nil when its query raises, so a DB error
  reads as "no goal anywhere" here.
  """
  @spec first_goal_offered?(term()) :: boolean()
  def first_goal_offered?(%Chat.Space{kind: "channel", archived_at: nil, goal: goal})
      when goal in [nil, ""] do
    agents_surface_enabled?() and is_nil(AgentsGoalHeartbeat.agents_space())
  end

  def first_goal_offered?(_space), do: false

  @doc """
  The agent accountable for `space`'s goal.

  ROLE FIRST, column second. `role_assignments` is the live pin and it
  broadcasts on `Roles.assignments_topic/0`, so resolving the role here
  is what lets a leader swap repaint both avatars with no reload;
  resolving `chat_spaces.leader_agent_id` first would pin the surface to
  a column nothing broadcasts about. The column is the fallback for an
  install that set a leader on the space without pinning the role.

  Returns `nil` when neither names an existing agent — the rail row then
  renders its glyph slot empty rather than a placeholder face.
  """
  @spec agents_leader(term()) :: term() | nil
  def agents_leader(%Chat.Space{leader_agent_id: column_id}) do
    case Roles.agent_id_for_role(@agents_leader_role) do
      id when is_binary(id) -> Repo.get(Agent, id) || fetch_agent(column_id)
      _ -> fetch_agent(column_id)
    end
  end

  def agents_leader(_), do: nil

  @doc """
  The role key the agents surface reads its leader from.

  Exposed so a LiveView can filter `{:role_assignment_changed, ...}`
  broadcasts without restating the string.
  """
  @spec agents_leader_role() :: String.t()
  def agents_leader_role, do: @agents_leader_role

  defp fetch_agent(id) when is_binary(id), do: Repo.get(Agent, id)
  defp fetch_agent(_), do: nil
end
