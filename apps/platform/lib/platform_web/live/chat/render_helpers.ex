defmodule PlatformWeb.ChatLive.RenderHelpers do
  @moduledoc """
  Render-time helpers the chat template calls, lifted out of `ChatLive`.

  These were `defp` inside `PlatformWeb.ChatLive` and therefore reachable only
  from its colocated template. That made them the blocker on extracting any
  further slice of `chat_live.html.heex` into a `ChatLive.Partials`-style
  module: a partial cannot call a private function of another module, so every
  markup move stalled on the sixteen helpers below.

  One shared module keeps ONE definition of each. The alternative — copying a
  helper into whichever partial needs it — forks sixteen pieces of logic across
  six files, and the copies drift.

  Bodies are unchanged from `chat_live.ex` (task 01a0312e stage 1). This module
  adds no behaviour; it only changes where the functions live and their
  visibility.

  Deliberately NOT moved here:

    * `space_mask/1` and `masked_space_name/2` — they read LiveView assigns
      directly (`:sidebar_sections`, `:mask_names?`, `:revealed_section_ids`)
      and `refresh_page_title/1` feeds them `socket.assigns`.
    * `space_nav_target/1` — its own doc records that it is a deliberate public
      web-layer alias called as `PlatformWeb.ChatLive.space_nav_target/1` from
      `settings_component.ex` and `new_channel_component.ex`. Moving it would
      break those fully-qualified call sites.
    * `pinned_rail_entries/2` — already public, so it blocks nothing, and
      moving it would drag the `pinned_entry()` type and
      `pinned_conversation_entries/2` across with it.
  """

  import PlatformWeb.Components.ChatHelpers, only: [present?: 1]

  alias Platform.Chat

  # Which rows get the "Move to organisation…" control. Two conditions, and
  # both are about the ROW, not the viewer (`@fabrikam_admin?` gates that
  # separately):
  #
  #   * `kind == "channel"` — the Pinned block holds channels AND DMs in one
  #     flat list, and a DM has no org filing to move.
  #   * a real `org_id` — a channel with none renders under the fallback
  #     section (`Sidebar.default_section_id/3`), and filing it for the first
  #     time is a different action from moving it between two named orgs,
  #     with different copy. Out of scope for this stage.
  def movable_channel?(%{kind: "channel", org_id: org_id}), do: is_binary(org_id)
  def movable_channel?(_space), do: false

  def space_header_name(%{kind: "channel", name: name}, _participants, _user_id, mask),
    do: mask_space_name(mask, name)

  def space_header_name(space, participants, user_id, _mask) do
    Chat.display_name_for_space(space, participants, user_id)
  end

  def mask_space_name({ctx, sections}, name),
    do: Platform.Chat.SidebarMask.space_label(ctx, sections, name)

  def sidebar_display_name(space, current_user_id) do
    participants = Chat.list_participants(space.id)
    Chat.display_name_for_space(space, participants, current_user_id)
  end

  # The label a rail row shows, which is also what its pin control must name
  # ("Pin Gen-migration", "Pin Rowan Ellis"). A channel is its `name`; a DM
  # or group has none and resolves through its participants.
  #
  # Channels short-circuit rather than falling through to
  # `sidebar_display_name/2`, which runs a `list_participants/1` query — the
  # control would otherwise add one query per channel row on every render.
  def sidebar_row_label(%{kind: "channel", name: name}, _user_id), do: name
  def sidebar_row_label(space, user_id), do: sidebar_display_name(space, user_id)

  # The mobile drawer's row-actions sheet target (task 019fe998). nil closes
  # the sheet; a map opens it with the row's own name and pinned state.
  #
  # Derived at RENDER from `@row_actions_space_id` rather than snapshotted
  # when the control was tapped, so the header and the Pin/Unpin verb follow
  # the row. Snapshotting would leave the sheet asserting "Pin" on a
  # conversation a second tab had just pinned.
  #
  # Resolved against `channels ++ dms` (the unfiltered assigns) rather than
  # the rendered sections: a row is reachable from Pinned, from Direct
  # Messages or from a sub-org section, and the sheet should not care which
  # bucket it was tapped in. An id matching nothing — a stale click racing a
  # hide, or a hand-crafted payload — resolves to nil and the sheet stays
  # shut, which is why this returns nil rather than raising.
  def row_actions_target(nil, _channels, _dms, _pinned_ids, _user_id), do: nil

  # `hideable` and `movable` are the DESKTOP menu's item gates (task 019ff8ba
  # stage 1), resolved here rather than in a second resolver so both chromes
  # read one description of the row.
  #
  # They restate what the ROW could already do, so the menu adds no capability
  # anywhere. `hide_channel` writes `users.preferences["hidden_channel_ids"]`
  # and the Hidden drawer that reverses it lists CHANNELS, so a hidden DM
  # would have no way back — hence the kind check, and hence the pinned check,
  # since the Pinned block never carried a hide button either. `movable` is
  # `movable_channel?/1`, the same predicate that gated the row control.
  #
  # `closeable` is the exact complement (task 019ffc5f stage 2): the DM and
  # group rows Hide is refused on are the ones Close is FOR. It carries no
  # pinned check, and that is deliberate. Pin and Close are both explicit
  # statements about the same row, "always show me this" and "not now", and
  # pin wins: the close is recorded, the Pinned block ignores it, and the row
  # goes quiet only once the pin comes off. Offering Close on a pinned DM and
  # having it appear to do nothing is the cost, stated rather than discovered.
  #
  # `row_actions_sheet/1` (the phone drawer) reads `closeable` but still
  # ignores `hideable`, so its Hide item remains on every row it opens on.
  # That predates this stage and Hide is out of its scope.
  def row_actions_target(space_id, channels, dms, pinned_ids, user_id) do
    case Enum.find(channels ++ dms, &(&1.id == space_id)) do
      nil ->
        nil

      space ->
        pinned? = space_id in pinned_ids

        %{
          space_id: space.id,
          kind: :conversation,
          task_id: nil,
          name: sidebar_row_label(space, user_id),
          pinned: pinned?,
          hideable: space.kind == "channel" and not pinned?,
          movable: movable_channel?(space),
          closeable: space.kind in ["dm", "group"]
        }
    end
  end

  # The DESKTOP menu's subject (task 019ff8ba stage 1, amended 2026-08-13).
  #
  # Everything `row_actions_target/5` resolves, plus the pinned TASK rows.
  # Marlowe's rule is that every rail row carries a three-dot menu and nothing
  # else, so a task row has a trigger now, and a task-exec space is in neither
  # `@channels` nor `@dm_conversations` — the sheet's resolver returns nil for
  # it, which is what left the task rows without a menu until now.
  #
  # Conversations are tried FIRST and win a tie. The two lists are disjoint in
  # practice (a task-exec space is not a user conversation), and preferring the
  # conversation shape keeps the ordinary rows on one code path.
  #
  # `kind` is what `row_actions_dialog/1` branches on. It is stated rather than
  # inferred from `task_id`: the two unpins are different operations on
  # different tables, and a nil check would read as "no task id yet" rather
  # than "this is not a task".
  def rail_row_actions_target(nil, _channels, _dms, _task_spaces, _pinned_ids, _user_id), do: nil

  def rail_row_actions_target(space_id, channels, dms, task_spaces, pinned_ids, user_id) do
    case row_actions_target(space_id, channels, dms, pinned_ids, user_id) do
      nil -> pinned_task_actions_target(space_id, task_spaces, user_id)
      target -> target
    end
  end

  # A pinned task row's menu holds one item, Unpin, and Marlowe stated the reason
  # it is the only one: the pin is made on the Tasks page, not here. `hideable`
  # and `movable` are false rather than absent so both shapes answer the same
  # questions and the dialog needs no `Map.get/3`.
  defp pinned_task_actions_target(space_id, task_spaces, user_id) do
    case Enum.find(task_spaces, &(&1.id == space_id)) do
      nil ->
        nil

      space ->
        %{
          space_id: space.id,
          kind: :task,
          task_id: space.metadata["task_id"],
          name: pinned_row_label(:task, space, user_id),
          pinned: true,
          hideable: false,
          movable: false,
          closeable: false
        }
    end
  end

  # ── Drawer search filters (mobile channel search Stage 1) ─────────────
  #
  # Render-time, in-memory filters over the drawer's already-computed
  # assigns. An empty query passes everything through unchanged, so the
  # non-searching drawer renders exactly what it did before this stage.
  # Case-insensitive substring — no fuzzy matching at this scale
  # (~5 sections / <30 channels), where "just filtering" is enough.

  defp drawer_match?(nil, _query), do: false

  defp drawer_match?(name, query) when is_binary(name) do
    String.contains?(String.downcase(name), String.downcase(query))
  end

  # The Pinned block (`pinned_rail_entries/2` output). Matches each entry on
  # the label the ROW renders, which differs by kind: a channel's `name`, a
  # DM's resolved participant name, a task's display name. Matching on
  # `space.name` for all three — what the block's two halves used to do
  # separately — drops every pinned DM from search results, because a DM row
  # has no `name`.
  def drawer_filter_pinned(entries, "", _user_id), do: entries

  def drawer_filter_pinned(entries, query, user_id) do
    Enum.filter(entries, fn %{kind: kind, space: space} ->
      drawer_match?(pinned_row_label(kind, space, user_id), query)
    end)
  end

  # Flat external switcher list (task 019f9257-a83e): the external mobile
  # switcher renders `@channels ++ @dm_conversations` as ONE flat list (no
  # sub-org sections), so its filter matches channels on `space.name` and
  # DM/group rows on their computed display name — the same label split the
  # rows themselves render. Kept separate from `drawer_filter_pinned`
  # (kind-tagged entries) and `drawer_filter_dms` (display-name-only) because
  # this list is a flat list of plain spaces mixing both kinds.
  def drawer_filter_external_spaces(spaces, "", _user_id), do: spaces

  def drawer_filter_external_spaces(spaces, query, user_id) do
    Enum.filter(spaces, fn space ->
      label =
        if space.kind == "channel",
          do: space.name,
          else: sidebar_display_name(space, user_id)

      drawer_match?(label, query)
    end)
  end

  # DM rows are labeled by their computed display name (the other
  # participant / group title), so that is what the filter must match —
  # a DM's underlying space.name is not what the user sees.
  def drawer_filter_dms(dms, "", _user_id), do: dms

  def drawer_filter_dms(dms, query, user_id) do
    Enum.filter(dms, &drawer_match?(sidebar_display_name(&1, user_id), query))
  end

  # Sub-org sections: filter each section's channels; drop sections with no
  # matches entirely (their headers would be noise), but keep headers on
  # sections that DO match — two orgs can hold same-named channels and the
  # section label is the only disambiguator.
  def drawer_filter_sections(sections, "", _mask_ctx), do: sections

  # Screen-share masking (task 01a00c66 stage 3): the filter runs against the
  # DISPLAYED channel label, never the stored name. Matching the stored name
  # would turn the search box into an oracle — type a real client name while
  # the drawer reads `Workspace B` and the matching row surfaces, confirming
  # the client list to anyone watching the share. A masked row must not be
  # reachable by the string it is hiding.
  def drawer_filter_sections(sections, query, mask_ctx) do
    sections
    |> Enum.map(fn %{section: section, channels: channels} = entry ->
      %{
        entry
        | channels:
            Enum.filter(channels, fn channel ->
              mask_ctx
              |> Platform.Chat.SidebarMask.channel_label(section, channel.name)
              |> drawer_match?(query)
            end)
      }
    end)
    |> Enum.filter(fn %{channels: channels} -> channels != [] end)
  end

  # True when an active search matched nothing anywhere — drives the
  # dedicated "No matches" state (NOT the genuinely-empty-account copy).
  # Takes the drawer's mask context so the empty-state and the list agree.
  # Without it, a masked search for a real org name renders an EMPTY list with
  # no "No matches" line, and the difference between "blank" and "No matches"
  # is itself the oracle the masked filter just closed.
  def drawer_no_matches?(_pinned, _channel_sections, _sidebar_sections, "", _user_id, _mask_ctx),
    do: false

  def drawer_no_matches?(
        pinned_entries,
        channel_sections,
        sidebar_sections,
        query,
        user_id,
        mask_ctx
      ) do
    # Takes the MERGED Pinned block rather than `channel_sections.pinned`:
    # the block now holds task conversations too, and a query that matches
    # only a pinned task would otherwise render a row and the "No matches"
    # copy at the same time.
    drawer_filter_pinned(pinned_entries, query, user_id) == [] and
      drawer_filter_dms(channel_sections.dms, query, user_id) == [] and
      drawer_filter_sections(sidebar_sections, query, mask_ctx) == []
  end

  def unread_label(count) when count >= 9, do: "9+"
  def unread_label(count) when count > 0, do: Integer.to_string(count)
  def unread_label(_), do: nil

  # Which of a client section's channel rows the desktop rail draws (019fd80f
  # stage 3). Expanded draws all of them; COLLAPSED draws only the ones with
  # unread, which is the whole point of the feature — it is what lets someone
  # keep four clients closed and still see anything that moved. A collapse that
  # hid everything would be a worse Hide, since Hide at least frees the space.
  #
  # The index is the row's position in the FULL channel list, not in the
  # filtered one. It drives the keyboard move controls' disabled states, so a
  # peeked row keeps reasoning about the section as a whole: derived from the
  # filtered list, the first peeked row would report itself as the section's
  # first channel and refuse to move up past the quiet rows above it.
  #
  # The predicate is `count > 0`, which is exactly when `unread_label/1` returns
  # a label — a peeked row therefore always carries a visible pill, and no row
  # can be peeked on a count the reader cannot see.
  def section_channel_rows(channels, false = _collapsed?, _unread_counts) do
    Enum.with_index(channels)
  end

  def section_channel_rows(channels, true = _collapsed?, unread_counts) do
    channels
    |> Enum.with_index()
    |> Enum.filter(fn {space, _idx} -> Map.get(unread_counts, space.id, 0) > 0 end)
  end

  def search_headline(message) do
    headline =
      cond do
        present?(message.search_headline) -> message.search_headline
        present?(message.content) -> message.content
        true -> "No searchable text"
      end

    headline
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace("&lt;mark&gt;", "<mark>")
    |> String.replace("&lt;/mark&gt;", "</mark>")
    |> Phoenix.HTML.raw()
  end

  # Composer empty-state check for the send button's disabled attribute.
  # The form value can be nil (initial render), a binary, or a Phoenix.HTML.Form.normalize_value-shaped
  # value. Treat whitespace-only as empty so a stray space doesn't enable Send.
  def composer_empty?(form) do
    case form && form[:text] do
      %{value: value} -> blank?(value)
      _ -> true
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true

  # The visible name of a Pinned row. A task conversation's space name is a
  # generated `task-exec-<hex>` slug, so it has its own display helper; a DM
  # has no `name` at all and resolves through the participants query.
  def pinned_row_label(:task, space, _user_id),
    do: Platform.Tasks.ChatPins.display_name_for_space(space)

  def pinned_row_label(_kind, space, user_id), do: sidebar_row_label(space, user_id)

  # Mapping from `channel_sections/3` string bucket keys to the atom values
  # the `scope_pill` component takes. Called from the colocated heex
  # template, hence defp + same-module visibility.
  #
  # Task 01a0312e stage 1: it is now `def` in this module, imported by
  # `ChatLive`. The colocated template still reaches it unqualified; the
  # `defp` half of that sentence is what changed, not the call site.
  def sub_org_scope_atom("Paragon"), do: :paragon
  def sub_org_scope_atom("Soylent"), do: :soylent
  def sub_org_scope_atom("Fabrikam"), do: :fabrikam
  def sub_org_scope_atom("Wayne-Tech"), do: :wayne_tech
  def sub_org_scope_atom("SXI"), do: :sxi
  def sub_org_scope_atom("Cyberdyne"), do: :cyberdyne

  # Buckets now derive from the orgs table, so a bucket can name an org the
  # scope-colour vocabulary has never heard of. `nil` means "no pill" — the
  # drawer renders the bucket's plain name instead. Do NOT `String.to_atom/1`
  # here: `scope_pill`'s label/colour clauses are a closed enum and an unknown
  # atom would crash the render rather than degrade it.
  def sub_org_scope_atom(_bucket), do: nil
end
