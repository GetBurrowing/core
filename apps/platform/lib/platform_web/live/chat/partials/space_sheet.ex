defmodule PlatformWeb.ChatLive.Partials.SpaceSheet do
  @moduledoc """
  The phone space sheet (task 01a1557a-8a6d, rung 7): everything about the
  open space, one tap from its name. The conversation header's title button
  (`Partials.Conversation.space_header/1`, `data-role="space-title"`) opens
  it; `SpaceSheetHooks` owns `@space_sheet`.

  Function components, no state, the same split as `Partials.ChatList`
  (ADR 0035). The sheet is `lg:hidden`: desktop keeps its header controls.

  ## The sheet

  `<.sheet ... handle_close swipe_dismiss>`, BOTH flags. Without
  `handle_close` the handle is a bare div with `touch-action: auto`, the
  browser claims a touch swipe-down and sends `pointercancel`, and the sheet
  never closes. `handle_close` also hides the title visually, so the body
  draws a visible, `aria-hidden` copy of it.

  ## THE TWO NAME NODES BOTH MASK

  The space name appears twice here: the sheet's accessible title and the
  visible title line. Both go through `space_header_name/4` +
  `space_mask/1`, as the header's title nodes do, and all three masking attrs
  are declared. `ChatLive.space_mask/1` reads them through tolerant access, so
  a forgotten declaration does not crash: it renders the REAL name with
  masking on (see `Partials.Conversation`, "THE MASKING ATTRS ARE NOT
  OPTIONAL").

  ## Rows

  Prototype v3 order and copy (master-mobile.html, the Space segment). Stage 1
  rows: Canvases in this space, Members (channels only), Agents (where the
  header's Agents entry renders; it opens the Agents sheet), Start a call (the Meet button's gate), Space
  settings. Stage 2 adds Search in space (first), Threads and Pinned; stage 3
  adds Goal and Scope in their prototype positions. There are no placeholder
  rows. Nothing destructive appears here: archive and deletion stay in the
  settings modal.

  ## Pages (stage 2)

  Search, Pinned and Threads open INSIDE this sheet as pushed pages, with a
  back arrow (`space_sheet_back`) and their own heading; the sr-only sheet
  title follows the page. They are never a second sheet on top. Each page
  fires the EXISTING event that already owns the action (`search_submit`,
  `search_clear`, `search_open_result`, `pin_toggle`), so the authorization
  and side effects stay in one place. A zero count renders no badge, never
  "0". Jumping to a message (a Search result, a Pinned row, a Threads row)
  also SCROLLS to it: `search_open_result` carries `from=space_sheet` and a
  Threads row fires `space_sheet_open_thread`, and `SpaceSheetHooks` pushes
  `chat:scroll-to-message`, or anchors the window on the message when it is
  not loaded (stage 5; see the hook's moduledoc).

  A row that ACTS is a `<button type="button">` firing
  `JS.push("close_space_sheet") |> JS.push(<event>)`, so the existing
  handler runs unchanged. A row that NAVIGATES must be a plain `<.link patch>`
  with NO `phx-click`: a bare-string `phx-click` on a patch link throws in
  the client, and a `JS.push` on a redirect link never reaches the server.

  Palette: the sheet is base-100, so a pressed row is base-200
  (`active:bg-base-200`). No hover utility on the phone. Labels are body
  (`text-base text-base-content`), previews and counts `text-sm text-subtle`.
  """

  use Phoenix.Component

  import PlatformWeb.ChatLive.RenderHelpers, only: [search_headline: 1, space_header_name: 4]

  import PlatformWeb.Components.ChatHelpers,
    only: [attachment_url: 1, format_bytes: 1, present?: 1]

  import PlatformWeb.Components.ChatMessage, only: [local_time: 1]
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  import PlatformWeb.ChatLive.Partials.Conversation,
    only: [agents_entry?: 3, goal_panel: 1, title_prefix: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Chat.SidebarMask
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.MembersComponent
  alias PlatformWeb.ChatLive.Partials.DetailsPanel
  alias PlatformWeb.ChatLive.Partials.AgentsSheet
  alias PlatformWeb.ChatLive.PresenceHooks

  attr(:space_sheet, :any, required: true)
  attr(:active_space, :any, required: true)
  attr(:space_participants, :list, required: true)
  attr(:user_id, :any, required: true)
  # The three masking attrs. Both name nodes below read them through
  # `space_mask/1`; see the moduledoc.
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)
  attr(:sidebar_sections, :list, required: true)
  attr(:external?, :boolean, required: true)
  attr(:canvases, :list, required: true)
  attr(:show_canvases, :boolean, required: true)
  attr(:meetings_enabled, :boolean, required: true)
  attr(:in_meeting, :boolean, required: true)
  attr(:agent_presence, :map, required: true)
  attr(:has_agent_participant, :boolean, required: true)
  # `Chat.agent_attention_state/1`, for the Agents row's meta.
  attr(:agent_attention, :any, required: true)
  # Stage 2's pages.
  attr(:search_query, :any, required: true)
  attr(:search_results, :list, required: true)
  attr(:participants_map, :map, required: true)
  attr(:pins, :list, required: true)
  attr(:space_sheet_pins, :list, required: true)
  attr(:space_sheet_threads, :list, required: true)
  # Stage 3's pages: the goal (`goal_panel/1`'s attrs) and the scope.
  attr(:goal_panel, :any, required: true)
  attr(:goal_edit, :boolean, required: true)
  attr(:can_edit_goal?, :boolean, required: true)
  attr(:goal_invite?, :boolean, default: false)
  attr(:goal_scope_options, :list, default: [])
  attr(:goal_scope_error, :atom, default: nil)
  attr(:goal_cadence_form, :map, default: nil)
  attr(:goal_time_zone, :string, default: nil)
  attr(:active_space_scope, :any, required: true)
  attr(:active_space_org, :any, default: nil)
  attr(:scope_filter, :any, required: true)
  # Stage 4's Links & files segments: nil until a segment first shows.
  attr(:space_sheet_files, :any, default: nil)
  attr(:space_sheet_links, :any, default: nil)

  @doc "The space sheet. The caller gates it on `@active_space && !@embedded`."
  def space_sheet(assigns) do
    name = display_name(assigns)

    assigns =
      assigns
      |> assign(:name, name)
      |> assign(:title, page_title(assigns.space_sheet, name))

    ~H"""
    <.sheet
      id="space-sheet"
      open={@space_sheet != nil}
      placement={:bottom}
      on_close="close_space_sheet"
      class="space-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>{@title}</:title>
      <.sections
        surface={:sheet}
        prefix="space-sheet"
        page={@space_sheet}
        name={@name}
        active_space={@active_space}
        space_participants={@space_participants}
        user_id={@user_id}
        mask_names?={@mask_names?}
        revealed_section_ids={@revealed_section_ids}
        sidebar_sections={@sidebar_sections}
        external?={@external?}
        canvases={@canvases}
        show_canvases={@show_canvases}
        meetings_enabled={@meetings_enabled}
        in_meeting={@in_meeting}
        agent_presence={@agent_presence}
        has_agent_participant={@has_agent_participant}
        agent_attention={@agent_attention}
        search_query={@search_query}
        search_results={@search_results}
        participants_map={@participants_map}
        pins={@pins}
        page_pins={@space_sheet_pins}
        page_threads={@space_sheet_threads}
        goal_panel={@goal_panel}
        goal_edit={@goal_edit}
        can_edit_goal?={@can_edit_goal?}
        goal_invite?={@goal_invite?}
        goal_scope_options={@goal_scope_options}
        goal_scope_error={@goal_scope_error}
        goal_cadence_form={@goal_cadence_form}
        goal_time_zone={@goal_time_zone}
        active_space_scope={@active_space_scope}
        active_space_org={@active_space_org}
        scope_filter={@scope_filter}
        page_files={@space_sheet_files}
        page_links={@space_sheet_links}
      />
    </.sheet>
    """
  end

  @doc """
  The space name both surfaces title themselves with: the "#" prefix for a
  channel, then `space_header_name/4` through `space_mask/1`, so a masked
  space shows its mask on the sheet and on the desktop panel alike.
  """
  def display_name(assigns) do
    title_prefix(assigns.active_space) <>
      space_header_name(
        assigns.active_space,
        assigns.space_participants,
        assigns.user_id,
        space_mask(assigns)
      )
  end

  @doc "The heading a page shows: the page's name, or the space's on a strip page."
  def page_title(:search, name), do: "Search in " <> name
  def page_title(:pinned, _name), do: "Pinned"
  def page_title(:threads, _name), do: "Threads"
  def page_title(:goal, _name), do: "Goal"
  def page_title(:scope, _name), do: "Scope"
  def page_title(_page, name), do: name

  # ── Sections: one body for the phone sheet and the desktop panel ──────

  attr(:surface, :atom, required: true, values: [:sheet, :panel])
  # Every id and data-role below is "<prefix>-...": "space-sheet" on the
  # sheet, "details" on the panel, so both can be in the DOM at once.
  attr(:prefix, :string, required: true)
  # The page shown: `@space_sheet` on the sheet, `@details_panel` on the
  # panel. Same shapes (`:space`, `{:links, seg}`, `:search`, `:pinned`,
  # `:threads`, `:goal`, `:scope`).
  attr(:page, :any, required: true)
  attr(:name, :string, required: true)
  attr(:active_space, :any, required: true)
  attr(:space_participants, :list, required: true)
  attr(:user_id, :any, required: true)
  attr(:mask_names?, :boolean, required: true)
  attr(:revealed_section_ids, :any, required: true)
  attr(:sidebar_sections, :list, required: true)
  attr(:external?, :boolean, required: true)
  attr(:canvases, :list, required: true)
  attr(:show_canvases, :boolean, required: true)
  attr(:meetings_enabled, :boolean, required: true)
  attr(:in_meeting, :boolean, required: true)
  attr(:agent_presence, :map, required: true)
  attr(:has_agent_participant, :boolean, required: true)
  attr(:agent_attention, :any, required: true)
  attr(:search_query, :any, required: true)
  attr(:search_results, :list, required: true)
  attr(:participants_map, :map, required: true)
  attr(:pins, :list, required: true)
  attr(:page_pins, :list, required: true)
  attr(:page_threads, :list, required: true)
  attr(:goal_panel, :any, required: true)
  attr(:goal_edit, :boolean, required: true)
  attr(:can_edit_goal?, :boolean, required: true)
  attr(:goal_invite?, :boolean, default: false)
  attr(:goal_scope_options, :list, default: [])
  attr(:goal_scope_error, :atom, default: nil)
  attr(:goal_cadence_form, :map, default: nil)
  attr(:goal_time_zone, :string, default: nil)
  attr(:active_space_scope, :any, required: true)
  attr(:active_space_org, :any, default: nil)
  attr(:scope_filter, :any, required: true)
  attr(:page_files, :any, default: nil)
  attr(:page_links, :any, default: nil)
  # Panel only (Burrow redesign 22 stage 4): the desktop Members and Agents
  # popovers, rendered right under their rows so the row is their anchor.
  # The sheet passes neither; its rows open the phone sheets.
  slot(:members_popover)
  slot(:agents_popover)

  @doc """
  The space sheet's body (Burrow redesign 22 stage 3): the title line or the
  back row, the segment strip, the Links & files segments, the Space rows and
  the pushed pages. `space_sheet/1` renders it with `surface={:sheet}`; the
  desktop details panel (`Partials.DetailsPanel`) with `surface={:panel}`.

  What the surface changes, and nothing else:

    * ids and data-roles take `prefix`;
    * the page events: `space_sheet_page` / `space_sheet_back` on the sheet,
      `details_page` / `details_back` on the panel;
    * an action row on the sheet pushes `close_space_sheet` first; on the
      panel it fires the existing event alone and the panel stays open;
    * the sheet draws its own title line on a strip page (the panel's header
      already carries the name);
    * the panel omits "Search in space" and ends the Space rows with "Hide
      channel" (channels) or "Close conversation" (DMs and groups), with
      "Promote to channel" before it on a group conversation;
    * the panel renders the desktop Members and Agents popovers (the
      `members_popover` / `agents_popover` slots) under their rows;
    * paint: the sheet's 44px phone rows with `active:` press; the panel's
      compact desktop rows on base-200, whose paint (hover included) is
      `DetailsPanel.paint/1`'s, so this phone file carries no hover utility.

  The jump rows (a Search result, a Pinned row, a Threads row) keep
  `from=space_sheet` on both surfaces: that names `SpaceSheetHooks`' jump,
  which both use.
  """
  def sections(assigns) do
    assigns =
      assigns
      |> assign(:title, page_title(assigns.page, assigns.name))
      |> assign(:scope_label, scope_label(assigns))

    ~H"""
    <p
      :if={@surface == :sheet and strip_page?(@page)}
      class="truncate px-4 pb-2 text-lg font-semibold text-base-content"
      aria-hidden="true"
      data-role={@prefix <> "-title"}
    >
      {@title}
    </p>
    <div
      :if={!strip_page?(@page)}
      class={
        pick(
          @surface,
          "flex min-w-0 items-center gap-1 px-2 pb-2",
          "flex min-w-0 items-center gap-1 px-1 pb-1"
        )
      }
    >
      <button
        type="button"
        phx-click={back_event(@surface)}
        data-role={@prefix <> "-back"}
        aria-label="Back"
        class={
          pick(
            @surface,
            "flex size-11 shrink-0 items-center justify-center rounded-lg text-base-content active:bg-base-200 focus-visible-ring",
            DetailsPanel.paint(:back)
          )
        }
      >
        <span
          class={pick(@surface, "hero-arrow-left size-5", "hero-arrow-left size-4")}
          aria-hidden="true"
        >
        </span>
      </button>
      <p
        class={
          pick(
            @surface,
            "min-w-0 truncate text-lg font-semibold text-base-content",
            "min-w-0 truncate text-sm font-semibold text-base-content"
          )
        }
        aria-hidden={pick(@surface, "true", nil)}
        data-role={@prefix <> "-title"}
      >
        {@title}
      </p>
    </div>
    <.segment_strip :if={strip_page?(@page)} surface={@surface} prefix={@prefix} page={@page} />
    <.links_page
      :if={match?({:links, _}, @page)}
      surface={@surface}
      prefix={@prefix}
      seg={elem(@page, 1)}
      canvases={@canvases}
      files={@page_files || []}
      links={@page_links || []}
    />
    <div
      :if={@page == :space}
      class={pick(@surface, "flex flex-col pb-2", "flex flex-col gap-px pb-2")}
      data-role={@prefix <> "-page"}
      data-page="space"
    >
      <.sheet_row
        :if={@surface == :sheet}
        surface={@surface}
        role={@prefix <> "-search"}
        icon="hero-magnifying-glass"
        label="Search in space"
        click={JS.push(page_event(@surface), value: %{page: "search"})}
      />
      <.sheet_row
        surface={@surface}
        role={@prefix <> "-canvases"}
        icon="hero-rectangle-group"
        label="Canvases in this space"
        preview={count_preview(@canvases)}
        click={lead(@surface) |> JS.push("space_canvases_browser")}
      />
      <%!-- The phone way into the Members sheet (task 01a1557a-8f80 stage
           3): every space but a DM, like the header entry; the meta is the
           people count. --%>
      <.sheet_row
        :if={@active_space.kind != "dm"}
        surface={@surface}
        role={@prefix <> "-members"}
        icon="hero-users"
        label="Members"
        preview={MembersComponent.people_label(@space_participants)}
        click={lead(@surface) |> JS.push("members_open")}
      />
      <%= if @active_space.kind != "dm" do %>
        {render_slot(@members_popover)}
      <% end %>
      <%!-- The phone way into the Agents sheet (task 01a1557a-8f80 stage
           2): the header entry's condition (`agents_entry?/3`); the meta is
           the masters' '2/4 awake · on-mention'. --%>
      <.sheet_row
        :if={agents_entry?(@agent_presence, @has_agent_participant, @active_space)}
        surface={@surface}
        role={@prefix <> "-agents"}
        icon="hero-cpu-chip"
        label="Agents"
        preview={AgentsSheet.entry_meta(@agent_attention, @active_space)}
        click={lead(@surface) |> JS.push("agents_open")}
      />
      <%= if agents_entry?(@agent_presence, @has_agent_participant, @active_space) do %>
        {render_slot(@agents_popover)}
      <% end %>
      <.sheet_row
        surface={@surface}
        role={@prefix <> "-threads"}
        icon="hero-chat-bubble-left-right"
        label="Threads"
        preview={count_preview(@page_threads)}
        click={JS.push(page_event(@surface), value: %{page: "threads"})}
      />
      <.sheet_row
        surface={@surface}
        role={@prefix <> "-pinned"}
        icon="hero-bookmark"
        label="Pinned"
        preview={count_preview(@pins)}
        click={JS.push(page_event(@surface), value: %{page: "pinned"})}
      />
      <%!-- The goal strip's own condition. No goal yet (an admin's
           invitation): "Add a goal" in body text, no number. --%>
      <.sheet_row
        :if={@goal_panel || @goal_invite?}
        surface={@surface}
        role={@prefix <> "-goal"}
        icon="hero-flag"
        label="Goal"
        preview={if @goal_panel, do: @goal_panel.goal, else: "Add a goal"}
        preview_body={is_nil(@goal_panel)}
        click={JS.push(page_event(@surface), value: %{page: "goal"})}
      />
      <%!-- The mobile header pill's condition (internal users, a channel
           with an org scope). The preview is the pill's masked label. --%>
      <.sheet_row
        :if={!@external? && @active_space_scope}
        surface={@surface}
        role={@prefix <> "-scope"}
        icon="hero-tag"
        label="Scope"
        preview={scope_preview(@scope_label, @scope_filter == @active_space_scope)}
        click={JS.push(page_event(@surface), value: %{page: "scope"})}
      />
      <%!-- Notifications (task 01a14a91) goes here, once a per-space
           notification setting exists for it to open. --%>
      <.sheet_row
        :if={@meetings_enabled && !@in_meeting && !@external?}
        surface={@surface}
        role={@prefix <> "-call"}
        icon="hero-phone"
        label="Start a call"
        click={lead(@surface) |> JS.push("meeting_join")}
      />
      <.sheet_row
        surface={@surface}
        role={@prefix <> "-settings"}
        icon="hero-cog-6-tooth"
        label="Space settings"
        click={lead(@surface) |> JS.push("settings_open")}
      />
      <%!-- Panel only, not in canvas (Burrow redesign 22 stage 4): a group
           conversation's "Promote to channel", moved here from the old
           desktop header with its form and event, so the feature stays. --%>
      <DetailsPanel.promote_row :if={
        @surface == :panel and @active_space.kind == "group" and !@active_space.is_direct
      } />
      <%!-- Panel only, last (master-desktop.html L843): the row menu's own
           events. A DM or a group closes (`close_dm`); a channel hides
           (`hide_channel`). Archive is in Space settings, not a second row. --%>
      <.sheet_row
        :if={@surface == :panel and @active_space.kind in ["dm", "group"]}
        surface={@surface}
        role={@prefix <> "-close-dm"}
        icon="hero-x-circle"
        label="Close conversation"
        click={JS.push("close_dm", value: %{id: @active_space.id})}
      />
      <.sheet_row
        :if={@surface == :panel and @active_space.kind not in ["dm", "group"]}
        surface={@surface}
        role={@prefix <> "-hide"}
        icon="hero-eye-slash"
        label="Hide channel"
        click={JS.push("hide_channel", value: %{id: @active_space.id})}
      />
    </div>

    <.search_page
      :if={@page == :search}
      surface={@surface}
      prefix={@prefix}
      name={@name}
      query={@search_query}
      results={@search_results}
      participants_map={@participants_map}
    />
    <.pinned_page
      :if={@page == :pinned}
      surface={@surface}
      prefix={@prefix}
      pins={@page_pins}
      archived?={not is_nil(@active_space.archived_at)}
    />
    <.threads_page
      :if={@page == :threads}
      surface={@surface}
      prefix={@prefix}
      threads={@page_threads}
    />
    <%!-- Rendered only on this page, with prefixed ids. Gated on the Goal
         row's own condition (the deleted desktop strip's, Burrow redesign 22
         stage 4), so a page pushed with no goal and no invitation shows no
         goal UI. --%>
    <div
      :if={@page == :goal and (@goal_panel || @goal_invite?)}
      class={pick(@surface, "flex items-start gap-2 px-4 pb-3", "flex items-start gap-2 px-2 pb-3")}
      data-role={@prefix <> "-page"}
      data-page="goal"
    >
      <.goal_panel
        active_space={@active_space}
        goal_panel={@goal_panel}
        goal_edit={@goal_edit}
        can_edit_goal?={@can_edit_goal?}
        goal_invite?={@goal_invite?}
        goal_scope_options={@goal_scope_options}
        goal_scope_error={@goal_scope_error}
        goal_cadence_form={@goal_cadence_form}
        goal_time_zone={@goal_time_zone}
        id_prefix={@prefix <> "-"}
      />
    </div>
    <.scope_page
      :if={@page == :scope && !@external? && @active_space_scope}
      surface={@surface}
      prefix={@prefix}
      label={@scope_label}
      on?={@scope_filter == @active_space_scope}
      value={scope_value(assigns)}
    />
    """
  end

  # The surface's own class string or value: the sheet's first, the panel's
  # second.
  defp pick(:sheet, sheet, _panel), do: sheet
  defp pick(:panel, _sheet, panel), do: panel

  defp page_event(:sheet), do: "space_sheet_page"
  defp page_event(:panel), do: "details_page"

  defp back_event(:sheet), do: "space_sheet_back"
  defp back_event(:panel), do: "details_back"

  # What an action row does before its own event: the sheet shuts, the panel
  # stays open.
  defp lead(:sheet), do: JS.push("close_space_sheet")
  defp lead(:panel), do: %JS{}

  # ── Search ────────────────────────────────────────────────────────────

  attr(:surface, :atom, required: true)
  attr(:prefix, :string, required: true)
  attr(:name, :string, required: true)
  attr(:query, :any, required: true)
  attr(:results, :list, required: true)
  attr(:participants_map, :map, required: true)

  # The desktop search's own events and param shape (`search[query]`), so
  # `SearchHooks` runs the search; the results are `@search_results`. Mounted
  # with the page, so `SearchFocus` focuses the field on open.
  defp search_page(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-col pb-2" data-role={@prefix <> "-page"} data-page="search">
      <form
        id={@prefix <> "-search-form"}
        role="search"
        phx-change="search_submit"
        phx-submit="search_submit"
        class={pick(@surface, "relative px-4 pb-2", "relative px-2 pb-2")}
      >
        <span
          class={
            pick(
              @surface,
              "hero-magnifying-glass pointer-events-none absolute left-7 top-1/2 size-4 -translate-y-1/2 text-subtle",
              "hero-magnifying-glass pointer-events-none absolute left-5 top-1/2 size-4 -translate-y-1/2 text-subtle"
            )
          }
          aria-hidden="true"
        >
        </span>
        <input
          id={@prefix <> "-search-input"}
          type="search"
          name="search[query]"
          value={@query}
          phx-hook="SearchFocus"
          data-search-intent="true"
          data-blur-on-scroll={@prefix <> "-search-results"}
          phx-debounce="250"
          maxlength="200"
          placeholder={"Search in " <> @name}
          autocomplete="off"
          enterkeyhint="search"
          aria-label={"Search messages in " <> @name}
          class={
            pick(
              @surface,
              "h-11 w-full rounded-lg border border-edge bg-base-200 pl-9 pr-3 text-base placeholder:text-subtle focus:border-primary focus:outline-none",
              "h-9 w-full rounded-field border border-edge bg-base-100 pl-9 pr-3 text-sm placeholder:text-subtle focus:border-primary focus:outline-none"
            )
          }
        />
      </form>
      <div id={@prefix <> "-search-results"} class="flex flex-col">
        <p
          :if={!present?(@query)}
          class={pick(@surface, "px-4 py-3 text-sm text-subtle", "px-2 py-3 text-sm text-subtle")}
        >
          Type to search this space's messages.
        </p>
        <p
          :if={present?(@query) and @results == []}
          class={pick(@surface, "px-4 py-3 text-sm text-subtle", "px-2 py-3 text-sm text-subtle")}
          data-role={@prefix <> "-search-empty"}
        >
          No messages match.
        </p>
        <button
          :for={result <- @results}
          type="button"
          data-role={@prefix <> "-search-result"}
          data-message-id={result.id}
          phx-click={
            lead(@surface)
            |> JS.push("search_open_result",
              value: %{"message-id" => result.id, "from" => "space_sheet"}
            )
          }
          class={item_class(@surface)}
        >
          <span class="flex min-w-0 items-center gap-2 text-xs text-subtle">
            <span class="truncate">
              {PresenceHooks.sender_name(@participants_map, result.participant_id)}
            </span>
            <.local_time id={"#{@prefix}-search-time-#{result.id}"} timestamp={result.inserted_at} />
          </span>
          <span class="min-w-0 truncate text-sm text-base-content">{search_headline(result)}</span>
        </button>
      </div>
    </div>
    """
  end

  # ── Pinned ────────────────────────────────────────────────────────────

  attr(:surface, :atom, required: true)
  attr(:prefix, :string, required: true)
  attr(:pins, :list, required: true)
  attr(:archived?, :boolean, required: true)

  # A row is the message (tap jumps to it through `search_open_result`) and a
  # visible Unpin beside it, firing `pin_toggle` as the drawer's Unpin does,
  # with the same archived-space gate. Body colour, not an error colour:
  # unpinning removes nothing anyone wrote.
  defp pinned_page(assigns) do
    ~H"""
    <div class="flex flex-col pb-2" data-role={@prefix <> "-page"} data-page="pinned">
      <p
        :if={@pins == []}
        class={pick(@surface, "px-4 py-3 text-sm text-subtle", "px-2 py-3 text-sm text-subtle")}
        data-role={@prefix <> "-pins-empty"}
      >
        Nothing pinned yet. Long-press a message to pin it.
      </p>
      <div
        :for={pin <- @pins}
        class="flex min-w-0 items-center"
        data-role={@prefix <> "-pin"}
        data-message-id={pin.message_id}
      >
        <button
          type="button"
          data-role={@prefix <> "-pin-open"}
          phx-click={
            lead(@surface)
            |> JS.push("search_open_result",
              value: %{"message-id" => pin.message_id, "from" => "space_sheet"}
            )
          }
          class={
            pick(
              @surface,
              "flex min-h-11 min-w-0 flex-1 flex-col gap-0.5 px-4 py-2 text-left active:bg-base-200 focus-visible-ring",
              DetailsPanel.paint(:pin_open)
            )
          }
        >
          <span class="min-w-0 truncate text-sm text-base-content">{excerpt(pin.content)}</span>
          <span class="flex min-w-0 items-center gap-2 text-xs text-subtle">
            <span class="truncate">{pin.author || "Unknown"}</span>
            <.local_time id={"#{@prefix}-pin-time-#{pin.pin_id}"} timestamp={pin.inserted_at} />
          </span>
        </button>
        <button
          :if={!@archived?}
          type="button"
          data-role={@prefix <> "-unpin"}
          phx-click="pin_toggle"
          phx-value-message-id={pin.message_id}
          phx-value-space-id={pin.space_id}
          class={
            pick(
              @surface,
              "flex min-h-11 shrink-0 items-center px-4 text-sm text-base-content active:bg-base-200 focus-visible-ring",
              DetailsPanel.paint(:unpin)
            )
          }
        >
          Unpin
        </button>
      </div>
    </div>
    """
  end

  # ── Threads ───────────────────────────────────────────────────────────

  attr(:surface, :atom, required: true)
  attr(:prefix, :string, required: true)
  attr(:threads, :list, required: true)

  # A row fires `space_sheet_open_thread`, not `open_inline_thread`: that one
  # opens in place and never scrolls (and `toggle_inline_thread` would
  # collapse a thread that is already open). `SpaceSheetHooks` scrolls to the parent (or anchors the
  # window on it when it is not loaded) and expands the thread if it is shut.
  defp threads_page(assigns) do
    ~H"""
    <div class="flex flex-col pb-2" data-role={@prefix <> "-page"} data-page="threads">
      <p
        :if={@threads == []}
        class={pick(@surface, "px-4 py-3 text-sm text-subtle", "px-2 py-3 text-sm text-subtle")}
        data-role={@prefix <> "-threads-empty"}
      >
        No threads yet.
      </p>
      <button
        :for={thread <- @threads}
        type="button"
        data-role={@prefix <> "-thread"}
        data-message-id={thread.parent_message_id}
        phx-click={
          lead(@surface)
          |> JS.push("space_sheet_open_thread", value: %{"message-id" => thread.parent_message_id})
        }
        class={item_class(@surface)}
      >
        <span class="min-w-0 truncate text-sm text-base-content">
          {excerpt(thread.excerpt) || "Message deleted"}
        </span>
        <span class="min-w-0 truncate text-xs text-subtle">
          {replies(thread.reply_count)} · {thread.author || "Unknown"}
        </span>
      </button>
    </div>
    """
  end

  defp replies(1), do: "1 reply"
  defp replies(n), do: "#{n} replies"

  # One line of a message body: whitespace collapsed; the row truncates it.
  defp excerpt(nil), do: nil
  defp excerpt(content), do: content |> String.split() |> Enum.join(" ")

  # The Space page and the Links & files segments share the strip and the
  # visible name line; every other page is pushed, with a back arrow.
  defp strip_page?(nil), do: true
  defp strip_page?(:space), do: true
  defp strip_page?({:links, _seg}), do: true
  defp strip_page?(_page), do: false

  # ── Segment strip (stage 4) ───────────────────────────────────────────

  @segment_tabs [
    {"all", "All"},
    {"canvas", "Canvases"},
    {"file", "Files"},
    {"site", "Sites"},
    {"video", "Videos"},
    {"space", "Space"}
  ]

  attr(:surface, :atom, required: true)
  attr(:prefix, :string, required: true)
  attr(:page, :any, required: true)

  # Prototype v3's strip (master-mobile.html:666-671): All, Canvases, Files,
  # Sites, Videos, Space. `role="tablist"`; scrolls sideways at 375px. The
  # selected tab is the one with the base-content border and the base-200
  # fill; the others carry a --subtle border, measured at 3:1 on base-100.
  defp segment_strip(assigns) do
    assigns = assign(assigns, :tabs, @segment_tabs)

    ~H"""
    <div
      role="tablist"
      aria-label="Space sections"
      id={pick(@surface, nil, @prefix <> "-segs")}
      class={
        pick(@surface, "flex gap-2 overflow-x-auto px-4 pb-2", "flex flex-wrap gap-1.5 px-1 pb-2")
      }
      data-role={@prefix <> "-segments"}
    >
      <button
        :for={{key, label} <- @tabs}
        type="button"
        role="tab"
        aria-selected={to_string(segment_selected?(@page, key))}
        data-seg={key}
        phx-click={segment_click(@surface, key)}
        class={segment_class(@surface, segment_selected?(@page, key))}
      >
        {label}
      </button>
    </div>
    """
  end

  defp segment_selected?(:space, "space"), do: true
  defp segment_selected?({:links, seg}, key), do: Atom.to_string(seg) == key
  defp segment_selected?(_page, _key), do: false

  defp segment_click(surface, "space"), do: JS.push(page_event(surface), value: %{page: "space"})

  defp segment_click(surface, seg),
    do: JS.push(page_event(surface), value: %{page: "links", seg: seg})

  # Sheet: the base-content border and base-200 fill (prototype v3). Panel:
  # master-desktop.html `.seg` L75-76, a 28px pill, base-300 when selected
  # (its border transparent over the fill: base-300 is a fill token),
  # an --edge hairline and --subtle label otherwise.
  defp segment_class(:sheet, selected?) do
    [
      "h-8 shrink-0 rounded-full border px-3 text-sm text-base-content active:bg-base-200 focus-visible-ring",
      if(selected?,
        do: "border-base-content bg-base-200 font-medium",
        else: "border-subtle"
      )
    ]
  end

  defp segment_class(:panel, selected?) do
    [
      "h-7 shrink-0 rounded-full border px-3 text-sm focus-visible-ring",
      if(selected?,
        do: "border-transparent bg-base-300 text-base-content",
        else: DetailsPanel.paint(:seg_rest)
      )
    ]
  end

  # ── Links & files (stage 4) ───────────────────────────────────────────

  attr(:surface, :atom, required: true)
  attr(:prefix, :string, required: true)
  attr(:seg, :atom, required: true)
  attr(:canvases, :list, required: true)
  attr(:files, :list, required: true)
  attr(:links, :list, required: true)

  # `All` groups Canvases / Files / Hosted sites / Videos (prototype order,
  # master-mobile.html:983-987); a single segment lists its one type. File,
  # video and link rows are plain external `<a>` with NO phx-click: a
  # `JS.push` on a link that leaves the page never reaches the server. Only a
  # canvas row, which opens in-app, is a button.
  defp links_page(assigns) do
    files = Enum.reject(assigns.files, &video?/1)

    videos =
      Enum.map(Enum.filter(assigns.files, &video?/1), &{:file, &1}) ++
        Enum.map(Enum.filter(assigns.links, &(&1.kind == :video)), &{:link, &1})

    groups =
      [
        {:canvas, "Canvases", Enum.map(assigns.canvases, &{:canvas, &1})},
        {:file, "Files", Enum.map(files, &{:file, &1})},
        {:site, "Hosted sites",
         Enum.map(Enum.filter(assigns.links, &(&1.kind == :site)), &{:link, &1})},
        {:video, "Videos", videos}
      ]
      |> Enum.filter(fn {key, _label, items} ->
        items != [] and (assigns.seg == :all or assigns.seg == key)
      end)

    assigns = assign(assigns, groups: groups, all?: assigns.seg == :all)

    ~H"""
    <div
      class="flex flex-col pb-2"
      data-role={@prefix <> "-page"}
      data-page="links"
      data-seg={@seg}
    >
      <p
        :if={@groups == []}
        class={
          pick(@surface, "px-4 py-3 text-sm text-subtle", "px-2 py-6 text-center text-sm text-subtle")
        }
        data-role={@prefix <> "-links-empty"}
      >
        Nothing shared here yet.
      </p>
      <section :for={{key, label, items} <- @groups} data-group={key}>
        <p
          :if={@all?}
          class={
            pick(
              @surface,
              "px-4 pb-1 pt-3 text-xs font-medium uppercase tracking-wide text-subtle",
              "px-2 pb-1 pt-3 text-xs font-semibold uppercase tracking-[.08em] text-subtle"
            )
          }
        >
          {label}
        </p>
        <.link_row :for={item <- items} surface={@surface} prefix={@prefix} item={item} />
      </section>
    </div>
    """
  end

  defp video?(%{content_type: "video/" <> _}), do: true
  defp video?(_file), do: false

  attr(:surface, :atom, required: true)
  attr(:prefix, :string, required: true)
  attr(:item, :any, required: true)

  defp link_row(%{item: {:canvas, canvas}} = assigns) do
    assigns = assign(assigns, :canvas, canvas)

    ~H"""
    <button
      type="button"
      data-role={@prefix <> "-link-row"}
      data-kind="canvas"
      data-canvas-id={@canvas.id}
      phx-click={
        lead(@surface)
        |> JS.push("canvas_open_mobile", value: %{"canvas-id" => @canvas.id})
      }
      class={row_class(@surface)}
    >
      <span class="hero-puzzle-piece size-5 shrink-0" aria-hidden="true"></span>
      <span class="flex min-w-0 flex-1 flex-col">
        <span class={link_label_class(@surface)}>{@canvas.title || "Untitled canvas"}</span>
        <span class="min-w-0 truncate text-xs text-subtle">
          <.local_time
            id={"#{@prefix}-canvas-time-#{@canvas.id}"}
            timestamp={@canvas.updated_at || @canvas.inserted_at}
          />
        </span>
      </span>
    </button>
    """
  end

  defp link_row(%{item: {:file, file}} = assigns) do
    assigns = assign(assigns, :file, file)

    ~H"""
    <a
      href={attachment_url(@file)}
      target="_blank"
      rel="noopener noreferrer"
      data-role={@prefix <> "-link-row"}
      data-kind={if video?(@file), do: "video", else: "file"}
      class={row_class(@surface)}
    >
      <span class={[file_icon(@file), "size-5 shrink-0"]} aria-hidden="true"></span>
      <span class="flex min-w-0 flex-1 flex-col">
        <span class={link_label_class(@surface)}>{@file.filename}</span>
        <span class="flex min-w-0 items-center gap-1 truncate text-xs text-subtle">
          <span class="truncate">{@file.author || "Unknown"}</span>
          <span aria-hidden="true">·</span>
          <.local_time id={"#{@prefix}-file-time-#{@file.id}"} timestamp={@file.inserted_at} />
          <span aria-hidden="true">·</span>
          <span class="shrink-0">{format_bytes(@file.byte_size)}</span>
        </span>
      </span>
    </a>
    """
  end

  defp link_row(%{item: {:link, link}} = assigns) do
    assigns = assign(assigns, :link, link)

    ~H"""
    <a
      href={@link.url}
      target="_blank"
      rel="noopener noreferrer"
      data-role={@prefix <> "-link-row"}
      data-kind={@link.kind}
      class={row_class(@surface)}
    >
      <span
        class={[
          if(@link.kind == :video, do: "hero-play-circle", else: "hero-globe-alt"),
          "size-5 shrink-0"
        ]}
        aria-hidden="true"
      >
      </span>
      <span class="flex min-w-0 flex-1 flex-col">
        <span class={link_label_class(@surface)}>{link_title(@link.url)}</span>
        <span class="flex min-w-0 items-center gap-1 truncate text-xs text-subtle">
          <span class="truncate">{@link.author || "Unknown"}</span>
          <span aria-hidden="true">·</span>
          <.local_time
            id={"#{@prefix}-link-time-#{:erlang.phash2(@link.url)}"}
            timestamp={@link.inserted_at}
          />
        </span>
      </span>
    </a>
    """
  end

  defp row_class(:sheet),
    do:
      "flex min-h-11 w-full items-center gap-3 px-4 py-2 text-left text-base-content active:bg-base-200 focus-visible-ring"

  defp row_class(:panel), do: DetailsPanel.paint(:link_row)

  defp link_label_class(:sheet), do: "min-w-0 truncate text-base"
  defp link_label_class(:panel), do: "min-w-0 truncate text-sm"

  # A two-line item (a search result, a thread).
  defp item_class(:sheet),
    do:
      "flex min-h-11 w-full flex-col gap-0.5 px-4 py-2 text-left active:bg-base-200 focus-visible-ring"

  defp item_class(:panel), do: DetailsPanel.paint(:item)

  defp file_icon(%{content_type: "video/" <> _}), do: "hero-film"
  defp file_icon(%{content_type: "image/" <> _}), do: "hero-photo"
  defp file_icon(_file), do: "hero-document"

  # host + path, without the scheme; the row truncates it.
  defp link_title(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) ->
        host <> if path in [nil, "/"], do: "", else: path

      _ ->
        url
    end
  end

  # ── Scope ─────────────────────────────────────────────────────────────

  attr(:surface, :atom, required: true)
  attr(:prefix, :string, required: true)
  attr(:label, :string, required: true)
  attr(:on?, :boolean, required: true)
  attr(:value, :string, required: true)

  # One switch, firing the header pill's `scope_filter` with the pill's
  # `phx-value-scope` payload (`scope_value/1`). A plain `phx-click` and
  # `phx-value-scope`, not `JS.push`: `phx-value-scope` is the one attribute
  # the masking assertions name as the filter's argument, and a JS.push
  # would put the same string into `phx-click` instead.
  defp scope_page(assigns) do
    ~H"""
    <div class="flex flex-col pb-2" data-role={@prefix <> "-page"} data-page="scope">
      <button
        type="button"
        role="switch"
        aria-checked={to_string(@on?)}
        phx-click="scope_filter"
        phx-value-scope={@value}
        data-role={@prefix <> "-scope-switch"}
        class={
          pick(
            @surface,
            "flex min-h-11 w-full items-center gap-3 px-4 py-2 text-left active:bg-base-200 focus-visible-ring",
            DetailsPanel.paint(:switch)
          )
        }
      >
        <span class={
          pick(
            @surface,
            "min-w-0 flex-1 truncate text-base text-base-content",
            "min-w-0 flex-1 truncate text-sm text-base-content"
          )
        }>
          Filter to {@label} scope
        </span>
        <span
          data-role={@prefix <> "-scope-track"}
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
    </div>
    """
  end

  # The org name the header pill showed, masked exactly as the pill masked
  # it: `SidebarMask.label_for_bucket/3` on the org's NAME when masking is
  # on. A Scope row that printed the org name would be the leak task 01a00c66
  # exists to prevent.
  defp scope_label(%{active_space_scope: nil}), do: nil

  defp scope_label(assigns) do
    org_name = assigns.active_space_org && assigns.active_space_org.name

    if assigns.mask_names? do
      SidebarMask.label_for_bucket(
        SidebarMask.context(
          assigns.sidebar_sections,
          assigns.mask_names?,
          assigns.revealed_section_ids
        ),
        assigns.sidebar_sections,
        org_name
      )
    else
      org_name
    end
  end

  defp scope_preview(nil, _on?), do: nil
  defp scope_preview(label, true), do: label <> " · filter on"
  defp scope_preview(label, false), do: label <> " · filter off"

  # The pill's payload: `value || scope`, where `value` is the org slug only
  # while unmasked.
  defp scope_value(assigns) do
    value = if !assigns.mask_names? && assigns.active_space_org, do: assigns.active_space_org.slug
    to_string(value || assigns.active_space_scope)
  end

  attr(:surface, :atom, required: true)
  attr(:role, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:preview, :string, default: nil)
  attr(:preview_body, :boolean, default: false)
  attr(:click, :any, required: true)

  # An action row. Sheet: at least 44px, pressed base-200, body label,
  # subtle preview that truncates before the label does. Panel
  # (master-desktop.html `.opt` L125-129): a compact desktop row,
  # `DetailsPanel.paint(:opt)` on base-200, the meta right-aligned in xs.
  defp sheet_row(%{surface: :panel} = assigns) do
    ~H"""
    <button type="button" phx-click={@click} data-role={@role} class={DetailsPanel.paint(:opt)}>
      <span class={[@icon, "size-4 shrink-0"]} aria-hidden="true"></span>
      <span class="min-w-0 flex-1 truncate">{@label}</span>
      <span
        :if={@preview}
        class={[
          "ml-auto min-w-0 max-w-[50%] truncate text-xs",
          if(@preview_body, do: "text-base-content", else: "text-subtle")
        ]}
      >
        {@preview}
      </span>
    </button>
    """
  end

  defp sheet_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@click}
      data-role={@role}
      class="flex min-h-11 w-full items-center gap-3 px-4 py-2 text-left text-base-content active:bg-base-200 focus-visible-ring"
    >
      <span class={[@icon, "size-5 shrink-0"]} aria-hidden="true"></span>
      <span class="shrink-0 text-base">{@label}</span>
      <span
        :if={@preview}
        class={[
          "ml-auto min-w-0 truncate text-sm",
          if(@preview_body, do: "text-base-content", else: "text-subtle")
        ]}
      >
        {@preview}
      </span>
    </button>
    """
  end

  # A count, or nothing at zero: a "0" is never shown.
  defp count_preview([]), do: nil
  defp count_preview(list), do: Integer.to_string(length(list))

  # A wrapper, not a qualified call, for the same reason as
  # `Partials.Conversation`'s.
  defp space_mask(assigns), do: ChatLive.space_mask(assigns)
end
