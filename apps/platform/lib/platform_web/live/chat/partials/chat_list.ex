defmodule PlatformWeb.ChatLive.Partials.ChatList do
  @moduledoc """
  The phone Chat tab: `<section id="chat-list">`, the conversation list at
  `/chat` (task 01a1557a-8562, Burrow redesign rung 6, stage 2).

  Same split as `ChatLive.Partials`, `Partials.Rail` and
  `Partials.ExternalRail` (ADR 0035): function components, no state, each
  taking a declared set of attrs. The render gate lives INSIDE `chat_list/1`
  (`@live_action == :index and !@embedded and !@external?`), so the call site
  in `chat_live.html.heex` states no condition of its own.

  Mobile only: the root carries `lg:hidden`. Desktop keeps the rail, and a
  desktop `/chat` patches into a channel once `ViewportBreakpoint` reports the
  side of `lg` it is on (`ChatLive.handle_event("chat_viewport", ...)`).

  ## Order

  PINNED (the Agents row, then `ChatLive.pinned_rail_entries/2` in its order),
  SPACES (`Sidebar.flatten_sections(@sidebar_sections)`, the curated order the
  pills and the desktop rail use), DIRECT (`@channel_sections.dms`, the rail's
  Direct list: pinned and closed conversations already removed, so no row
  appears twice) and ARCHIVED (only while `@archived_open`).

  ## Every row is a plain patch link

  No `phx-click` on any link in this list. A bare-string `phx-click` on a
  `patch`/`navigate` link throws in the client, and a `JS.push` on one never
  reaches the server (rung 5 measured 0 of 45 taps). State that must reset
  when the reader leaves the list resets in `handle_params/3` for `:show`.
  `chat_live_chat_list_test.exs` refutes a `phx-click` on any link here.

  ## Paint (Saru's ruling, canvas 01a15d7c `ground`)

  The list ground is base-200. A pressed row paints base-100 (`active:`), and
  there is NO hover state on anything in the list: it renders only on the
  phone. The notification banner lifts off the list on base-100 with
  `border-edge`, as a sheet does. Text is body or `text-subtle`, nothing else.
  The pairs are measured in all ten variants by
  `test/platform/design/chat_list_contrast_guard_test.exs`.

  ## THE MASKING ATTRS ARE NOT OPTIONAL

  `ChatLive.masked_space_name/2` reads `:sidebar_sections`, `:mask_names?` and
  `:revealed_section_ids` through TOLERANT access, so a component that forgets
  to declare them renders REAL names with the mask on and passes every markup
  assertion. `chat_list/1` declares all three and hands `Map.take(assigns,
  @mask_keys)` down, as `Partials.Rail` and `Partials.ExternalRail` do.

  What the mask covers here is EXACTLY the existing org-derived rule
  (`SidebarMask.space_label/3`), the same toggle the rail and the drawer obey:
  an org-derived channel name masks, a project-code channel (`#atlas`) and a
  person's name do not. On top of that, while masked:

    * every excerpt renders as one fixed-length placeholder, so neither its
      text nor its length leaks, and the row does not change height;
    * a row whose name the rule masked draws a neutral base-300 disc with no
      initial and no agent accent, because the initial would spell the start
      of the name (Saru, canvas 01a15d7c rev 4).

  There is no per-section reveal and no mask strip on the list (coverage row
  20 is DROP).
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.ChatLive.RenderHelpers, only: [unread_label: 1, search_headline: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias Phoenix.LiveView.JS

  alias PlatformWeb.ChatLive

  @mask_keys [:sidebar_sections, :mask_names?, :revealed_section_ids]

  # The masked excerpt. Fixed length on purpose: a placeholder whose length
  # tracked the hidden text would publish it.
  @masked_excerpt "••••••••••••••••••••"

  attr(:live_action, :atom, required: true)
  attr(:embedded, :boolean, required: true)
  attr(:external?, :boolean, required: true)
  # The three masking attrs (see the moduledoc).
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)
  attr(:sidebar_sections, :list, required: true)
  attr(:channel_sections, :map, required: true)
  attr(:pinned_task_spaces, :list, required: true)
  attr(:agents_block, :any, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:archived_channels, :list, required: true)
  attr(:archived_open, :boolean, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:list_excerpts, :map, required: true)
  attr(:list_identities, :map, required: true)
  attr(:push_permission, :any, required: true)
  attr(:notification_banner_dismissed, :boolean, required: true)
  # The sheets (stage 3): `ChatListHooks` owns all three.
  attr(:list_sheet, :any, required: true)
  attr(:list_search_query, :string, required: true)
  attr(:list_search_results, :map, required: true)
  # Edit order (stage 4): the rail's personal-edit mode, and its announcer.
  attr(:sidebar_edit, :boolean, required: true)
  attr(:reorder_announcement, :any, required: true)

  @doc "The list. Renders nothing unless the gate in the moduledoc holds."
  def chat_list(assigns) do
    assigns =
      assigns
      |> assign(:mask_assigns, Map.take(assigns, @mask_keys))
      |> assign(
        :pinned_rows,
        ChatLive.pinned_rail_entries(assigns.channel_sections.pinned, assigns.pinned_task_spaces)
      )
      |> assign(:space_rows, Platform.Chat.Sidebar.flatten_sections(assigns.sidebar_sections))
      |> assign(:dm_rows, assigns.channel_sections.dms)

    ~H"""
    <section
      :if={@live_action == :index and !@embedded and !@external?}
      id="chat-list"
      data-role="chat-list"
      class="flex min-h-0 min-w-0 flex-1 flex-col bg-base-200 text-base-content lg:hidden"
      aria-label="Chat"
    >
      <header class="flex h-12 flex-shrink-0 items-center gap-1 pl-4 pr-2">
        <h1 class="text-lg font-semibold">Chat</h1>
        <span data-role="chat-list-subtitle" class="min-w-0 flex-1 truncate text-xs text-subtle">
          {cond do
            @sidebar_edit -> "editing order · tap ⋯ to finish"
            @mask_names? -> "names masked"
            true -> nil
          end}
        </span>
        <%!-- Prototype master-mobile.html v3 :542-544, aria-labels verbatim.
             Buttons, never links: a bare event is fine on them. --%>
        <.header_button
          role="chat-list-search"
          sheet="search"
          icon="hero-magnifying-glass"
          label="Search channels and DMs"
        />
        <.header_button
          role="chat-list-new"
          sheet="new"
          icon="hero-plus"
          label="New channel or conversation"
        />
        <.header_button
          role="chat-list-options"
          sheet="options"
          icon="hero-ellipsis-horizontal"
          label="List options: edit order, mask names, archived"
        />
      </header>

      <div id="chat-list-scroller" class="clears-tab-bar min-h-0 flex-1 overflow-y-auto">
        <%!-- Edit order's screen-reader feedback: the rail's own announcer
             copy ("Moved X up"). Rendered as soon as the mode opens, because
             aria-live announces CHANGES to a region already in the DOM. --%>
        <div :if={@sidebar_edit} class="sr-only" aria-live="polite" data-role="chat-list-announcer">
          {@reorder_announcement}
        </div>
        <.list_banner
          push_permission={@push_permission}
          dismissed={@notification_banner_dismissed}
        />

        <%= if @channels == [] and @dm_conversations == [] and @pinned_task_spaces == [] and is_nil(@agents_block) do %>
          <div data-role="chat-list-empty" class="px-8 py-16 text-center">
            <p class="text-sm text-subtle">No channels yet.</p>
            <p class="text-sm text-subtle">Create one or ask someone to add you.</p>
            <button
              type="button"
              phx-click="new_channel_open"
              class="btn btn-primary btn-sm mt-4"
              data-role="chat-list-empty-new-channel"
            >
              <span class="hero-plus size-4" aria-hidden="true"></span> New channel
            </button>
          </div>
        <% else %>
          <section
            :if={@agents_block || @pinned_rows != []}
            data-role="chat-list-pinned"
            aria-labelledby="chat-list-label-pinned"
          >
            <.section_label id="chat-list-label-pinned">Pinned</.section_label>
            <.agents_row
              :if={@agents_block}
              editing={@sidebar_edit}
              agents_block={@agents_block}
              unread_counts={@unread_counts}
              list_excerpts={@list_excerpts}
              mask_assigns={@mask_assigns}
            />
            <%= for %{kind: kind, space: space} = entry <- @pinned_rows do %>
              <.row
                space={space}
                kind={kind}
                name={row_name(kind, space, @list_identities)}
                agent={row_agent(space, @list_identities)}
                unread={Map.get(@unread_counts, space.id, 0)}
                excerpt={Map.get(@list_excerpts, space.id)}
                mask_assigns={@mask_assigns}
                restricted?={MapSet.member?(@restricted_channel_ids, space.id)}
                editing={@sidebar_edit}
                long_press={kind != :task}
                move={pinned_move(entry)}
              />
            <% end %>
          </section>

          <section data-role="chat-list-spaces" aria-labelledby="chat-list-label-spaces">
            <.section_label id="chat-list-label-spaces">Spaces</.section_label>
            <%= if @space_rows == [] do %>
              <.section_empty
                role="chat-list-spaces-empty"
                copy="You're not in any channels yet."
                label="New channel"
                event="new_channel_open"
              />
            <% else %>
              <%!-- Spaces is the flattened sub-org sections, rendered section
                   by section so each row knows its section: `move_channel`
                   moves within one section, so a row's ↑/↓ stop at its
                   section's ends (crossing sections is coverage row 32's
                   open question). --%>
              <%= for %{section: section, channels: section_channels} <- @sidebar_sections,
                      {space, index} <- Enum.with_index(section_channels) do %>
                <.row
                  space={space}
                  kind={:channel}
                  name={space.name}
                  agent={nil}
                  unread={Map.get(@unread_counts, space.id, 0)}
                  excerpt={Map.get(@list_excerpts, space.id)}
                  mask_assigns={@mask_assigns}
                  restricted?={MapSet.member?(@restricted_channel_ids, space.id)}
                  editing={@sidebar_edit}
                  long_press
                  move={channel_move(space, section, index, length(section_channels))}
                />
              <% end %>
            <% end %>
          </section>

          <section data-role="chat-list-direct" aria-labelledby="chat-list-label-direct">
            <.section_label id="chat-list-label-direct">Direct</.section_label>
            <%= if @dm_rows == [] do %>
              <.section_empty
                role="chat-list-direct-empty"
                copy="No conversations yet."
                label="New conversation"
                event="new_conversation_open"
              />
            <% else %>
              <%= for space <- @dm_rows do %>
                <.row
                  space={space}
                  kind={:dm}
                  name={row_name(:dm, space, @list_identities)}
                  agent={row_agent(space, @list_identities)}
                  unread={Map.get(@unread_counts, space.id, 0)}
                  excerpt={Map.get(@list_excerpts, space.id)}
                  mask_assigns={@mask_assigns}
                  restricted?={false}
                  editing={@sidebar_edit}
                  long_press
                />
              <% end %>
            <% end %>
          </section>

          <section
            :if={@archived_open and @archived_channels != []}
            data-role="chat-list-archived"
            aria-labelledby="chat-list-label-archived"
          >
            <.section_label id="chat-list-label-archived">Archived</.section_label>
            <%= for space <- @archived_channels do %>
              <.row
                space={space}
                kind={:channel}
                name={space.name}
                agent={nil}
                unread={Map.get(@unread_counts, space.id, 0)}
                excerpt={Map.get(@list_excerpts, space.id)}
                mask_assigns={@mask_assigns}
                restricted?={MapSet.member?(@restricted_channel_ids, space.id)}
                editing={@sidebar_edit}
                long_press={false}
              />
            <% end %>
          </section>
        <% end %>
      </div>

      <.search_sheet
        open={@list_sheet == :search}
        query={@list_search_query}
        results={@list_search_results}
        channels={@channels}
        dm_conversations={@dm_conversations}
        archived_channels={@archived_channels}
        restricted_channel_ids={@restricted_channel_ids}
        unread_counts={@unread_counts}
        list_excerpts={@list_excerpts}
        list_identities={@list_identities}
        mask_assigns={@mask_assigns}
      />
      <.new_sheet open={@list_sheet == :new} />
      <.options_sheet
        open={@list_sheet == :options}
        mask_names?={@mask_names?}
        archived_open={@archived_open}
        sidebar_edit={@sidebar_edit}
      />
    </section>
    """
  end

  attr(:role, :string, required: true)
  attr(:sheet, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)

  defp header_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_list_sheet"
      phx-value-sheet={@sheet}
      data-role={@role}
      aria-label={@label}
      class="flex size-11 shrink-0 items-center justify-center rounded-full text-base-content active:bg-base-100 focus-visible-ring"
    >
      <span class={[@icon, "size-6"]} aria-hidden="true"></span>
    </button>
    """
  end

  # ── sheets (stage 3) ──────────────────────────────────────────────────
  #
  # Every sheet: `<.sheet placement={:bottom} class="... lg:hidden">` with
  # rung 5's `handle_close` (the handle is the Close button) and
  # `swipe_dismiss`. base-100 surface, base-content labels, subtle meta, rows
  # at least 44px, pressed rows on base-200 as the More sheet's are. No hover
  # anywhere.

  attr(:open, :boolean, required: true)
  attr(:query, :string, required: true)
  attr(:results, :map, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:archived_channels, :list, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:list_excerpts, :map, required: true)
  attr(:list_identities, :map, required: true)
  attr(:mask_assigns, :map, required: true)

  defp search_sheet(assigns) do
    assigns =
      assign(
        assigns,
        :spaces_by_id,
        Map.new(
          assigns.channels ++ assigns.dm_conversations ++ assigns.archived_channels,
          &{&1.id, &1}
        )
      )

    ~H"""
    <.sheet
      id="chat-list-search-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_list_sheet"
      class="chat-list-sheet chat-list-search-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Search</:title>
      <%!-- Rendered only while open, so `SearchFocus` mounts with the sheet
           and focuses the field then (data-search-intent), not once at page
           load while the sheet is shut. --%>
      <div :if={@open} class="flex min-h-0 flex-col">
        <form
          class="relative px-4 pb-2"
          role="search"
          phx-change="list_search"
          phx-submit="list_search"
        >
          <span
            class="hero-magnifying-glass pointer-events-none absolute left-7 top-1/2 size-4 -translate-y-1/2 text-subtle"
            aria-hidden="true"
          >
          </span>
          <input
            id="chat-list-search-input"
            type="search"
            name="value"
            value={@query}
            phx-hook="SearchFocus"
            data-search-intent="true"
            data-blur-on-scroll="chat-list-search-results"
            phx-debounce="200"
            maxlength="100"
            placeholder="Find channel, DM or message"
            autocomplete="off"
            autocorrect="off"
            autocapitalize="none"
            spellcheck="false"
            enterkeyhint="go"
            aria-label="Find channel, DM or message"
            class="h-11 w-full rounded-lg border border-edge bg-base-200 pl-9 pr-3 text-base placeholder:text-subtle focus:border-primary focus:outline-none"
          />
        </form>

        <div id="chat-list-search-results" data-role="chat-list-search-results">
          <%= if @query == "" do %>
            <section :if={@results.recent != []} data-role="chat-list-search-recent">
              <.section_label id="chat-list-search-label-recent">Recent</.section_label>
              <.search_space_row
                :for={space <- @results.recent}
                space={space}
                unread_counts={@unread_counts}
                list_excerpts={@list_excerpts}
                list_identities={@list_identities}
                mask_assigns={@mask_assigns}
                restricted_channel_ids={@restricted_channel_ids}
              />
            </section>
          <% else %>
            <section :if={@results.channels != []} data-role="chat-list-search-channels">
              <.section_label id="chat-list-search-label-channels">Channels</.section_label>
              <.search_space_row
                :for={space <- @results.channels}
                space={space}
                unread_counts={@unread_counts}
                list_excerpts={@list_excerpts}
                list_identities={@list_identities}
                mask_assigns={@mask_assigns}
                restricted_channel_ids={@restricted_channel_ids}
              />
            </section>
            <section :if={@results.dms != []} data-role="chat-list-search-direct">
              <.section_label id="chat-list-search-label-direct">Direct</.section_label>
              <.search_space_row
                :for={space <- @results.dms}
                space={space}
                unread_counts={@unread_counts}
                list_excerpts={@list_excerpts}
                list_identities={@list_identities}
                mask_assigns={@mask_assigns}
                restricted_channel_ids={@restricted_channel_ids}
              />
            </section>
            <section :if={@results.messages != []} data-role="chat-list-search-messages">
              <.section_label id="chat-list-search-label-messages">Messages</.section_label>
              <.message_hit
                :for={msg <- @results.messages}
                :if={Map.has_key?(@spaces_by_id, msg.space_id)}
                msg={msg}
                space={Map.fetch!(@spaces_by_id, msg.space_id)}
                list_identities={@list_identities}
                mask_assigns={@mask_assigns}
              />
            </section>
            <p
              :if={@results.channels == [] and @results.dms == [] and @results.messages == []}
              data-role="chat-list-search-no-matches"
              class="px-4 py-6 text-sm text-subtle"
            >
              No matches for “{@query}”
            </p>
          <% end %>
        </div>
      </div>
    </.sheet>
    """
  end

  attr(:space, :map, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:list_excerpts, :map, required: true)
  attr(:list_identities, :map, required: true)
  attr(:mask_assigns, :map, required: true)
  attr(:restricted_channel_ids, :any, required: true)

  # A channel or conversation result: the list's own row, with the sheet's
  # pressed paint and its own DOM ids.
  defp search_space_row(assigns) do
    kind = if assigns.space.kind in ["dm", "group"], do: :dm, else: :channel
    assigns = assign(assigns, :kind, kind)

    ~H"""
    <.row
      space={@space}
      kind={@kind}
      name={row_name(@kind, @space, @list_identities)}
      agent={row_agent(@space, @list_identities)}
      unread={Map.get(@unread_counts, @space.id, 0)}
      excerpt={Map.get(@list_excerpts, @space.id)}
      mask_assigns={@mask_assigns}
      restricted?={MapSet.member?(@restricted_channel_ids, @space.id)}
      pressed="active:bg-base-200"
      id_prefix="chat-list-search"
    />
    """
  end

  attr(:msg, :map, required: true)
  attr(:space, :map, required: true)
  attr(:list_identities, :map, required: true)
  attr(:mask_assigns, :map, required: true)

  # A message hit: a plain patch link to the existing `?message=` deep link,
  # no phx-click. The snippet goes through `RenderHelpers.search_headline/1`,
  # the one sanitising path for `ts_headline` markup. While masked it renders
  # the fixed placeholder and no snippet text. The author is a PERSON's name
  # (the message's author snapshot), which the org rule does not mask, so it
  # is shown as the rail and the drawer show people's names.
  defp message_hit(assigns) do
    kind = if assigns.space.kind in ["dm", "group"], do: :dm, else: :channel
    name = row_name(kind, assigns.space, assigns.list_identities)

    assigns =
      assigns
      |> assign(:space_name, ChatLive.masked_space_name(assigns.mask_assigns, name))
      |> assign(:masked?, assigns.mask_assigns[:mask_names?] == true)
      |> assign(:author, PlatformWeb.ChatLive.PresenceHooks.sender_name(%{}, assigns.msg))

    ~H"""
    <.link
      patch={~p"/chat/#{ChatLive.space_nav_target(@space)}?message=#{@msg.id}"}
      data-role="chat-list-message-hit"
      data-space-id={@space.id}
      data-message-id={@msg.id}
      class="flex min-h-11 flex-col justify-center gap-0.5 px-4 py-2 active:bg-base-200 focus-visible-ring"
    >
      <span class="flex min-w-0 items-baseline gap-2">
        <span class="min-w-0 truncate text-[15px] font-semibold text-base-content">
          {@space_name}
        </span>
        <span class="shrink-0 truncate text-xs text-subtle">{@author}</span>
      </span>
      <span data-role="chat-list-snippet" class="block truncate text-[13px] text-subtle">
        <%= if @masked? do %>
          <span aria-hidden="true">{masked_excerpt()}</span>
          <span class="sr-only">Message hidden</span>
        <% else %>
          {search_headline(@msg)}
        <% end %>
      </span>
    </.link>
    """
  end

  attr(:open, :boolean, required: true)

  defp new_sheet(assigns) do
    ~H"""
    <.sheet
      id="chat-list-new-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_list_sheet"
      class="chat-list-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>New</:title>
      <div class="flex flex-col pb-2">
        <.sheet_action
          role="chat-list-new-channel"
          click={JS.push("close_list_sheet") |> JS.push("new_channel_open")}
          icon="hero-hashtag"
          label="New channel"
          meta="name, people, your agent"
        />
        <.sheet_action
          role="chat-list-new-conversation"
          click={JS.push("close_list_sheet") |> JS.push("new_conversation_open")}
          icon="hero-chat-bubble-left-right"
          label="New conversation"
          meta="DM a person or agent"
        />
      </div>
    </.sheet>
    """
  end

  attr(:role, :string, required: true)
  attr(:click, :any, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:meta, :string, required: true)

  defp sheet_action(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@click}
      data-role={@role}
      class="flex min-h-13 w-full items-center gap-3 rounded-field px-4 py-2 text-left active:bg-base-200 focus-visible-ring"
    >
      <span class={[@icon, "size-5 shrink-0 text-base-content"]} aria-hidden="true"></span>
      <span class="min-w-0 flex-1">
        <span class="block text-[15px] text-base-content">{@label}</span>
        <span class="block text-[13px] text-subtle">{@meta}</span>
      </span>
    </button>
    """
  end

  attr(:open, :boolean, required: true)
  attr(:mask_names?, :boolean, required: true)
  attr(:archived_open, :boolean, required: true)
  attr(:sidebar_edit, :boolean, required: true)

  defp options_sheet(assigns) do
    ~H"""
    <.sheet
      id="chat-list-options-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_list_sheet"
      class="chat-list-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Chat list</:title>
      <div class="flex flex-col pb-2">
        <%!-- Entering Edit order closes the sheet so the arrows are in view;
             the header subtitle says how to finish (tap ⋯ again). --%>
        <.switch_row
          role="chat-list-option-edit-order"
          js={
            if @sidebar_edit,
              do: JS.push("toggle_sidebar_edit"),
              else: JS.push("close_list_sheet") |> JS.push("toggle_sidebar_edit")
          }
          on?={@sidebar_edit}
          label="Edit order"
          meta="move channels and sections up / down"
        />
        <.switch_row
          role="chat-list-option-mask"
          js={JS.push("toggle_mask_names", value: %{masked: to_string(!@mask_names?)})}
          on?={@mask_names?}
          label="Mask names"
          meta="for screen sharing"
        />
        <.switch_row
          role="chat-list-option-archived"
          js={JS.push("toggle_archived_section")}
          on?={@archived_open}
          label="Show archived"
          meta={nil}
        />
      </div>
    </.sheet>
    """
  end

  attr(:role, :string, required: true)
  attr(:js, :any, required: true)
  attr(:on?, :boolean, required: true)
  attr(:label, :string, required: true)
  attr(:meta, :any, required: true)

  # A toggle row: `role="switch"` with `aria-checked`, the whole row the
  # control. It fires the rail's own events (`toggle_mask_names`,
  # `toggle_archived_section`) through `JS.push`, so the rail's literal
  # `phx-click="toggle_mask_names"` control stays the only element carrying
  # that attribute (the mask suites select it by that literal). Track primary when on (measured >= 3:1 on base-100), base-300
  # when off, with the knob carrying the boundary.
  defp switch_row(assigns) do
    ~H"""
    <button
      type="button"
      role="switch"
      aria-checked={to_string(@on?)}
      phx-click={@js}
      data-role={@role}
      class="flex min-h-13 w-full items-center gap-3 rounded-field px-4 py-2 text-left active:bg-base-200 focus-visible-ring"
    >
      <span class="min-w-0 flex-1">
        <span class="block text-[15px] text-base-content">{@label}</span>
        <span :if={@meta} class="block text-[13px] text-subtle">{@meta}</span>
      </span>
      <span
        data-role="chat-list-switch-track"
        class={[
          "relative inline-flex h-6 w-10 shrink-0 items-center rounded-full",
          if(@on?, do: "bg-primary", else: "bg-base-300")
        ]}
        aria-hidden="true"
      >
        <span class={[
          "absolute size-5 rounded-full border border-edge bg-base-100",
          if(@on?, do: "left-[1.125rem]", else: "left-0.5")
        ]}>
        </span>
      </span>
    </button>
    """
  end

  attr(:id, :string, required: true)
  slot(:inner_block, required: true)

  # Uppercase via CSS, at the 12px floor (the prototype's 11px raised), in the
  # shell sidebar labels' tracking.
  defp section_label(assigns) do
    ~H"""
    <h2 id={@id} class="px-4 pt-4 pb-1 text-xs font-semibold uppercase tracking-widest text-subtle">
      {render_slot(@inner_block)}
    </h2>
    """
  end

  attr(:role, :string, required: true)
  attr(:copy, :string, required: true)
  attr(:label, :string, required: true)
  attr(:event, :string, required: true)

  defp section_empty(assigns) do
    ~H"""
    <div data-role={@role} class="flex items-center gap-3 px-4 py-3">
      <p class="min-w-0 flex-1 text-sm text-subtle">{@copy}</p>
      <button
        type="button"
        phx-click={@event}
        class="btn btn-primary btn-sm shrink-0"
        data-role={@role <> "-action"}
      >
        {@label}
      </button>
    </div>
    """
  end

  attr(:push_permission, :any, required: true)
  attr(:dismissed, :boolean, required: true)

  # Coverage row 40. Shown while the browser permission is still `prompt` and
  # the viewer has not dismissed it. Both controls are buttons, never links,
  # so a bare event is fine on them.
  defp list_banner(assigns) do
    ~H"""
    <div
      :if={@push_permission == "prompt" and not @dismissed}
      data-role="chat-list-notification-banner"
      class="mx-4 mt-2 flex items-center gap-3 rounded-xl border border-edge bg-base-100 px-3 py-2.5"
    >
      <span class="hero-bell size-5 shrink-0 text-subtle" aria-hidden="true"></span>
      <div class="min-w-0 flex-1">
        <p class="text-sm font-semibold text-base-content">Enable notifications</p>
        <p class="text-xs text-subtle">mentions and DMs, nothing else</p>
      </div>
      <button
        type="button"
        phx-click="enable_notifications"
        class="btn btn-primary btn-sm shrink-0"
        data-role="chat-list-notification-enable"
      >
        Enable
      </button>
      <button
        type="button"
        phx-click="dismiss_notification_banner"
        class="flex size-11 shrink-0 items-center justify-center rounded-lg text-subtle"
        aria-label="Dismiss"
        data-role="chat-list-notification-dismiss"
      >
        <span class="hero-x-mark size-5" aria-hidden="true"></span>
      </button>
    </div>
    """
  end

  attr(:agents_block, :map, required: true)
  attr(:editing, :boolean, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:list_excerpts, :map, required: true)
  attr(:mask_assigns, :map, required: true)

  # The Agents row: the agents space, with its leader's avatar in the leader's
  # rung-3 slot. It patches to the agents space exactly as the drawer's
  # `drawer_agents/1` does (rung 8 owns the Agents sheet).
  defp agents_row(assigns) do
    leader = assigns.agents_block.leader

    assigns =
      assign(
        assigns,
        :agent,
        leader &&
          %{
            name: leader.name,
            avatar_url: leader.avatar_url,
            slot: Platform.Agents.ColorPalette.slot_for(Map.get(leader, :color))
          }
      )

    ~H"""
    <.row
      space={@agents_block.space}
      kind={:agents}
      name={@agents_block.space.name}
      agent={@agent}
      unread={Map.get(@unread_counts, @agents_block.space.id, 0)}
      excerpt={Map.get(@list_excerpts, @agents_block.space.id)}
      mask_assigns={@mask_assigns}
      restricted?={false}
      editing={@editing}
    />
    """
  end

  attr(:space, :map, required: true)
  attr(:kind, :atom, required: true)
  attr(:name, :string, required: true)
  attr(:agent, :any, required: true)
  attr(:unread, :integer, required: true)
  attr(:excerpt, :any, required: true)
  attr(:mask_assigns, :map, required: true)
  attr(:restricted?, :boolean, required: true)
  # The pressed ground: base-100 on the base-200 list, base-200 inside a
  # base-100 sheet (the More sheet's paint).
  attr(:pressed, :string, default: "active:bg-base-100")
  # DOM ids must stay unique when one space renders in the list AND in a sheet.
  attr(:id_prefix, :string, default: "chat-list")
  # Edit order (stage 4): the list is arranging. Unread dots hide, the row's
  # long-press is inert, and a row with a `move` shows ↑/↓.
  attr(:editing, :boolean, default: false)
  # The row link carries the generic `RowLongPress` hook, opening the row
  # sheet. Off for the Agents row (its membership is derived, so pin, hide
  # and order are all wrong for it), pinned tasks, Archived and search rows.
  attr(:long_press, :boolean, default: false)
  # nil, or %{event, values, up?, down?}: the existing rail event this row's
  # ↑/↓ push, its values, and whether each direction is enabled.
  attr(:move, :any, default: nil)

  # One row. The whole row is the link (at least 44px tall), with no
  # phx-click. Name `min-w-0 truncate`; time and dot never shrink.
  defp row(assigns) do
    shown = ChatLive.masked_space_name(assigns.mask_assigns, assigns.name)
    masked? = assigns.mask_assigns[:mask_names?] == true

    assigns =
      assigns
      |> assign(:shown_name, shown)
      |> assign(:name_masked?, shown != assigns.name)
      |> assign(:excerpts_masked?, masked?)
      |> assign(:unread_text, unread_label(assigns.unread))

    ~H"""
    <%= if @restricted? do %>
      <div
        data-role="restricted-channel-row"
        data-space-id={@space.id}
        aria-disabled="true"
        class="flex min-h-11 items-center gap-3 px-4 py-3"
      >
        <span
          class="flex size-[42px] shrink-0 items-center justify-center rounded-full bg-base-300 text-subtle"
          aria-hidden="true"
        >
          <span class="hero-lock-closed size-5"></span>
        </span>
        <span class="min-w-0 flex-1">
          <span class="block truncate text-[15px] font-semibold text-base-content">
            {@shown_name}
          </span>
          <span class="block truncate text-[13px] text-subtle">Restricted, ask an admin</span>
        </span>
      </div>
    <% else %>
      <%!-- The link and the ↑/↓ are SIBLINGS: a button nested in an <a> is
           invalid HTML, and a tap on it would bubble into the patch. --%>
      <div class="flex items-center" data-role="chat-list-row-wrap" data-space-id={@space.id}>
        <.link
          id={"#{@id_prefix}-row-#{@space.id}"}
          patch={~p"/chat/#{ChatLive.space_nav_target(@space)}"}
          data-role="chat-list-row"
          data-space-id={@space.id}
          data-row-kind={@kind}
          data-unread={to_string(@unread > 0)}
          phx-hook={@long_press && "RowLongPress"}
          data-long-press-event={@long_press && "open_list_sheet"}
          data-long-press-sheet={@long_press && "row"}
          data-long-press-space-id={@long_press && @space.id}
          data-editing={@long_press && to_string(@editing)}
          class={[
            "chat-list-row flex min-h-11 min-w-0 flex-1 items-center gap-3 px-4 py-3 focus-visible-ring",
            @pressed
          ]}
        >
          <.avatar
            kind={@kind}
            name={@name}
            agent={@agent}
            masked?={@name_masked?}
          />
          <span class="min-w-0 flex-1">
            <span class="flex items-baseline gap-2">
              <span class="min-w-0 flex-1 truncate text-[15px] font-semibold text-base-content">
                {@shown_name}
              </span>
              <time
                :if={@excerpt}
                id={"#{@id_prefix}-time-#{@space.id}"}
                phx-hook="LocalTime"
                datetime={DateTime.to_iso8601(@excerpt.inserted_at)}
                data-local-time={DateTime.to_iso8601(@excerpt.inserted_at)}
                class="shrink-0 whitespace-nowrap tabular-nums text-xs text-subtle"
              >
                {Calendar.strftime(@excerpt.inserted_at, "%H:%M")}
              </time>
            </span>
            <span
              :if={@excerpt}
              data-role="chat-list-excerpt"
              class={[
                "block truncate text-[13px]",
                if(@unread > 0, do: "text-base-content", else: "text-subtle")
              ]}
            >
              <%= if @excerpts_masked? do %>
                <span aria-hidden="true">{masked_excerpt()}</span>
                <span class="sr-only">Message hidden</span>
              <% else %>
                {excerpt_text(@kind, @space, @excerpt)}
              <% end %>
            </span>
          </span>
          <span
            :if={@unread_text && !@editing}
            data-role="chat-list-unread-dot"
            class="size-2 shrink-0 rounded-full bg-primary"
            role="img"
            aria-label={"#{@unread_text} unread"}
          >
          </span>
        </.link>
        <span
          :if={@editing && @move}
          class="flex shrink-0 items-center pr-2"
          data-role="chat-list-move"
        >
          <.move_button move={@move} direction="up" name={@shown_name} />
          <.move_button move={@move} direction="down" name={@shown_name} />
        </span>
      </div>
    <% end %>
    """
  end

  attr(:move, :map, required: true)
  attr(:direction, :string, required: true)
  attr(:name, :string, required: true)

  # A 44px ↑ or ↓: base-content enabled, the disabled token at a group's end
  # (WCAG exempts an inactive control from the contrast floor). No hover.
  defp move_button(assigns) do
    enabled? = if assigns.direction == "up", do: assigns.move.up?, else: assigns.move.down?
    assigns = assign(assigns, :enabled?, enabled?)

    ~H"""
    <button
      type="button"
      phx-click={JS.push(@move.event, value: Map.put(@move.values, :direction, @direction))}
      disabled={!@enabled?}
      data-role={"chat-list-move-#{@direction}"}
      aria-label={"Move #{@name} #{@direction}"}
      class={[
        "flex size-11 items-center justify-center rounded-full focus-visible-ring",
        if(@enabled?, do: "text-base-content active:bg-base-100", else: "text-disabled")
      ]}
    >
      <span
        class={[if(@direction == "up", do: "hero-arrow-up", else: "hero-arrow-down"), "size-5"]}
        aria-hidden="true"
      >
      </span>
    </button>
    """
  end

  # Pinned conversations reorder through the rail's `move_pinned`; a pinned
  # task row has no `move_index` (task pins are not hand-ordered) and no
  # arrows.
  defp pinned_move(%{move_index: nil}), do: nil

  defp pinned_move(%{space: space, move_index: index, move_count: count}) do
    %{
      event: "move_pinned",
      values: %{space_id: space.id},
      up?: index > 0,
      down?: index < count - 1
    }
  end

  # A Spaces row reorders within its own sub-org section, through the rail's
  # `move_channel`.
  defp channel_move(space, section, index, count) do
    %{
      event: "move_channel",
      values: %{channel_id: space.id, section_id: section.id},
      up?: index > 0,
      down?: index < count - 1
    }
  end

  attr(:kind, :atom, required: true)
  attr(:name, :string, required: true)
  attr(:agent, :any, required: true)
  attr(:masked?, :boolean, required: true)

  # 42px disc. Masked: neutral, no initial, no accent. Agent: the agent's
  # image or initial, ringed in its rung-3 slot. Task: a check glyph.
  # Otherwise the name's first letter (a channel's without its `#`).
  defp avatar(assigns) do
    ~H"""
    <%= cond do %>
      <% @masked? -> %>
        <span
          data-role="chat-list-avatar"
          data-avatar="masked"
          class="size-[42px] shrink-0 rounded-full bg-base-300"
          aria-hidden="true"
        >
        </span>
      <% @agent -> %>
        <span
          data-role="chat-list-avatar"
          data-avatar="agent"
          data-agent-slot={@agent.slot}
          class="msg-agent-avatar flex size-[42px] shrink-0 items-center justify-center overflow-hidden rounded-full bg-base-300 text-[15px] font-semibold text-base-content"
          aria-hidden="true"
        >
          <img
            :if={@agent.avatar_url}
            src={@agent.avatar_url}
            alt=""
            class="size-full object-cover"
            loading="lazy"
          />
          <span :if={!@agent.avatar_url}>{initial(@agent.name)}</span>
        </span>
      <% @kind == :task -> %>
        <span
          data-role="chat-list-avatar"
          data-avatar="task"
          class="flex size-[42px] shrink-0 items-center justify-center rounded-full bg-base-300 text-base-content"
          aria-hidden="true"
        >
          <span class="hero-check size-5"></span>
        </span>
      <% true -> %>
        <span
          data-role="chat-list-avatar"
          data-avatar="initial"
          class="flex size-[42px] shrink-0 items-center justify-center rounded-full bg-base-300 text-[15px] font-semibold text-base-content"
          aria-hidden="true"
        >
          {initial(@name)}
        </span>
    <% end %>
    """
  end

  @doc false
  def masked_excerpt, do: @masked_excerpt

  # '<author>: <content>' everywhere but a one-to-one DM, where the author is
  # the row's own name and the prefix would only repeat it.
  defp excerpt_text(:dm, %{kind: "dm"}, %{content: content}), do: content

  defp excerpt_text(_kind, _space, %{author_name: author, content: content})
       when is_binary(author) and author != "",
       do: "#{author}: #{content}"

  defp excerpt_text(_kind, _space, %{content: content}), do: content

  defp initial(name) when is_binary(name) do
    name
    |> String.trim_leading("#")
    |> String.trim()
    |> String.first()
    |> case do
      nil -> ""
      ch -> String.upcase(ch)
    end
  end

  defp initial(_), do: ""

  defp row_name(:channel, space, _identities), do: space.name

  defp row_name(_kind, space, identities) do
    case Map.get(identities, space.id) do
      %{name: name} -> name
      _ -> space.name || ""
    end
  end

  defp row_agent(space, identities) do
    case Map.get(identities, space.id) do
      %{agent: agent} -> agent
      _ -> nil
    end
  end
end
