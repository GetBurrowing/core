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
  # both are about the ROW, not the viewer (`@root_admin?` gates that
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
  # ("Pin Gen-migration", "Pin Alex Morgan"). A channel is its `name`; a DM
  # or group has none and resolves through its participants.
  #
  # Channels short-circuit rather than falling through to
  # `sidebar_display_name/2`, which runs a `list_participants/1` query — the
  # control would otherwise add one query per channel row on every render.
  def sidebar_row_label(%{kind: "channel", name: name}, _user_id), do: name
  def sidebar_row_label(space, user_id), do: sidebar_display_name(space, user_id)

  # The row-actions target (task 019fe998): the phone Chat list's row sheet and
  # the desktop rail's dialog both read it. nil closes; a map opens with the
  # row's own name and pinned state.
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
  # The row sheet's title and accessible names carry the row's name, so they
  # mask exactly as the row does (`ChatLive.masked_space_name/2`, the org
  # rule). nil stays nil: the sheet is closed.
  def mask_row_target(nil, _assigns), do: nil

  def mask_row_target(%{name: name} = target, assigns),
    do: %{target | name: PlatformWeb.ChatLive.masked_space_name(assigns, name)}

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
  # `row_actions_sheet/1` (the phone Chat list's row sheet) reads both since
  # task 01a1557a-8562 stage 4: Hide where `hideable`, Close where `closeable`.
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
  # The design rule is that every rail row carries a three-dot menu and nothing
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

  # A pinned task row's menu holds one item, Unpin, and the designer stated the reason
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

  # ── Name filters (mobile channel search Stage 1; the phone Chat list's
  # search sheet and the external switcher since task 01a1557a-8562) ──────
  #
  # Render-time, in-memory filters over already-computed assigns. An empty
  # query passes everything through unchanged.
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
  def list_filter_pinned(entries, "", _user_id), do: entries

  def list_filter_pinned(entries, query, user_id) do
    Enum.filter(entries, fn %{kind: kind, space: space} ->
      drawer_match?(pinned_row_label(kind, space, user_id), query)
    end)
  end

  # Flat external switcher list (task 019f9257-a83e): the external mobile
  # switcher renders `@channels ++ @dm_conversations` as ONE flat list (no
  # sub-org sections), so its filter matches channels on `space.name` and
  # DM/group rows on their computed display name — the same label split the
  # rows themselves render. Kept separate from `list_filter_pinned`
  # (kind-tagged entries) and `list_filter_dms` (display-name-only) because
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
  def list_filter_dms(dms, "", _user_id), do: dms

  def list_filter_dms(dms, query, user_id) do
    Enum.filter(dms, &drawer_match?(sidebar_display_name(&1, user_id), query))
  end

  # Sub-org sections: filter each section's channels; drop sections with no
  # matches entirely (their headers would be noise), but keep headers on
  # sections that DO match — two orgs can hold same-named channels and the
  # section label is the only disambiguator.
  def list_filter_sections(sections, "", _mask_ctx), do: sections

  # Screen-share masking (task 01a00c66 stage 3): the filter runs against the
  # DISPLAYED channel label, never the stored name. Matching the stored name
  # would turn the search box into an oracle — type a real client name while
  # the drawer reads `Workspace B` and the matching row surfaces, confirming
  # the client list to anyone watching the share. A masked row must not be
  # reachable by the string it is hiding.
  def list_filter_sections(sections, query, mask_ctx) do
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

  # A peer install's message (task 01a199c7): its stored content, and so the
  # SQL `ts_headline` slice, is wrapped in the SECURITY NOTICE for agents. A
  # human sees an excerpt of the unwrapped body instead, escaped whole with no
  # `<mark>` re-enabled (the text is the peer's, not Postgres's). Known limit:
  # a search for a word in the notice still MATCHES such a message.
  def search_headline(%{metadata: %{"source" => "federation_inbound"}} = message) do
    case Platform.Chat.message_excerpt(Platform.Chat.human_content(message)) do
      "" -> Phoenix.HTML.html_escape("No searchable text")
      excerpt -> Phoenix.HTML.html_escape(excerpt)
    end
  end

  def search_headline(message) do
    headline =
      cond do
        present?(message.search_headline) -> message.search_headline
        present?(message.content) -> message.content
        true -> "No searchable text"
      end

    marked_text(headline)
  end

  @doc """
  Render a Postgres `ts_headline` fragment as safe HTML.

  The one sanitising path for any string that carries `<mark>` markup from
  Postgres and nothing else it is allowed to emit: escape the WHOLE string,
  then re-enable exactly the two tags we asked `ts_headline` for. The
  surrounding text is user-written — a canvas body, a message — so this is
  never `raw/1` on the input, only on a string every other tag has already
  been escaped out of.

  Extracted from `search_headline/1` when task `01a07402` stage 5 needed the
  same treatment for the canvas search snippet. It is one function rather than
  two so a change to what `ts_headline` is allowed to emit cannot be applied
  to message search and forgotten on canvas search.
  """
  @spec marked_text(String.t()) :: Phoenix.HTML.safe()
  def marked_text(text) when is_binary(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace("&lt;mark&gt;", "<mark>")
    |> String.replace("&lt;/mark&gt;", "</mark>")
    |> Phoenix.HTML.raw()
  end

  @doc """
  Split a `ts_headline` fragment at its FIRST `<mark>` pair.

  Returns `{leading, match, trailing}`. `match` is `nil` when the fragment
  carries no usable mark at all, and that is the caller's signal to fall back
  to the single `marked_text/1` span. Either context run is `nil` when it would
  render nothing, so a match at the very start or the very end does not leave
  an empty padded box in the row.

  ## Why the string is split at all

  The canvases drawer row cannot afford to truncate its snippet from the right.
  The brand rule is that the last thing allowed to truncate is the most
  meaningful, and on this row the meaningful fragment is the matched phrase:
  the corpus is ~409 canvases whose titles do not disambiguate, so a row
  showing context with the searched word clipped off the right edge is the
  original problem in a nicer font. Measured at 375px before this split: the
  snippet box ended at x=286 and the `<mark>` sat at x=317-377, entirely
  outside it.

  Splitting lets the template hold the match at `shrink-0 whitespace-nowrap`
  and let the two context runs yield around it, so the match survives at every
  width by construction — no breakpoint to tune and no viewport for the server
  to guess at. The server does not change: `ts_headline` already emits the
  `<mark>` sentinels and `Platform.Chat.ellipsised_headline/2` already recovers
  the source text by stripping them, so the match is ALREADY separable on the
  string that reaches the template.

  ## Only the FIRST mark is protected

  `MaxFragments=1` bounds fragments, not marks. `websearch_to_tsquery/2` marks
  every lexeme of a multi-word query and every occurrence of a repeated term,
  so one fragment can carry several `<mark>` pairs. Everything after the first
  `</mark>` stays in the trailing run, marks and all: those marks keep their
  styling and ride inside the run that truncates. Protecting all of them would
  make the row's unshrinkable width the sum of every match, which overflows the
  row and puts the bug back.

  ## Escaping

  Each run goes back through `marked_text/1`, so the escape-then-re-enable path
  is the same one and only one this module has. Never `raw/1` on any of it: the
  body is user-written. A user who types a literal `<mark>` into a canvas body
  can therefore steer where this split lands — exactly as they can already
  steer `marked_text/1`'s output, which is the same pre-existing property and
  not a new hole, since both ends escape everything else first.
  """
  @spec split_marked_snippet(String.t()) ::
          {Phoenix.HTML.safe() | nil, Phoenix.HTML.safe() | nil, Phoenix.HTML.safe() | nil}
  def split_marked_snippet(text) when is_binary(text) do
    with [leading, rest] <- String.split(text, "<mark>", parts: 2),
         [match, trailing] <- String.split(rest, "</mark>", parts: 2) do
      {snippet_run(leading), snippet_run(match), snippet_run(trailing)}
    else
      # No mark, or an opening tag with no closing one. Both fall back to the
      # single-span render rather than inventing a partition.
      _ -> {nil, nil, nil}
    end
  end

  # A run that would render nothing is `nil`, not an empty safe string: the
  # template keys the three spans off these, and a whitespace-only run would
  # otherwise contribute a flex gap on each side of nothing.
  defp snippet_run(text) do
    if String.trim(text) == "", do: nil, else: marked_text(text)
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
end
