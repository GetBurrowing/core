defmodule PlatformWeb.ChatLive.Partials.DetailsPanel do
  @moduledoc """
  The desktop details panel (Burrow redesign 22 stage 3; master-desktop.html
  `#details` L603, CSS L59-63): the space sheet's sections in a right-hand
  aside at lg. `DetailsPanelHooks` owns `@details_panel`.

  One set of section markup serves both surfaces:
  `Partials.SpaceSheet.sections/1` renders here with `surface={:panel}` and
  `prefix="details"`, and inside the phone sheet with `surface={:sheet}`
  and `prefix="space-sheet"`. Every id and data-role is prefixed, so the
  sheet and the panel can both be in the DOM with no id twice.

  ## Layout

  Closed, the aside is not rendered at all and the conversation takes the
  width. Open, it is a flex sibling AFTER the conversation column, so it
  PUSHES the main pane (masters' grid column 4; the direction canvas's
  overlay is overruled): 320px, 280px at or below 1100px, base-200 with the
  left `--edge` hairline. `hidden lg:flex`: the phone never sees it (it has
  the sheet).

  ## Header (`.dhead`, L604)

  52px, bottom hairline: the space name through `SpaceSheet.display_name/1`
  (all three masking attrs; a masked space shows its mask) and the 34px
  round close button, "Close details".

  ## Paint

  `paint/1` holds the panel's row classes, the ones `sections/1` uses on
  the panel surface. They live here rather than in `space_sheet.ex` because
  that file is the phone sheet's and its contrast guard holds it to no
  hover utility. Desktop rows: label base-content, meta `--subtle` xs,
  `lg:hover:bg-base-300` on base-200 (pairs measured in
  `desktop_shell_contrast_guard_test.exs`).

  ## State hook

  `details_panel_state/1` is the always-rendered hidden node the
  `DetailsPanelState` hook mounts on: restore on mount (at >= 1280px only),
  the per-viewer write on `details:changed`, Escape and F6. See
  `assets/js/hooks/details_panel_state.js`.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias PlatformWeb.ChatLive.MembersComponent
  alias PlatformWeb.ChatLive.Partials.AgentsSheet
  alias PlatformWeb.ChatLive.Partials.SpaceSheet

  attr(:details_panel, :any, required: true)
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
  attr(:details_pins, :list, required: true)
  attr(:details_threads, :list, required: true)
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
  attr(:details_files, :any, default: nil)
  attr(:details_links, :any, default: nil)
  # The desktop Members and Agents popovers (Burrow redesign 22 stage 4),
  # anchored under their panel rows: open flags and what they render.
  attr(:agents_sheet_open, :boolean, default: false)
  attr(:show_members, :boolean, default: false)
  attr(:current_user_record, :any, default: nil)

  @doc "The panel. The caller gates it on `@active_space && !@embedded`; closed renders nothing."
  def details_panel(assigns) do
    assigns = assign(assigns, :name, SpaceSheet.display_name(assigns))

    ~H"""
    <aside
      :if={@details_panel != nil}
      id="details-panel"
      aria-label="Details"
      tabindex="-1"
      class="hidden min-h-0 min-w-0 flex-col overflow-hidden bg-base-200 lg:flex lg:w-[320px] lg:max-[1100px]:w-[280px] lg:flex-none lg:border-l lg:border-edge"
    >
      <div class="flex h-[52px] flex-none items-center gap-1.5 border-b border-edge px-3">
        <b class="min-w-0 flex-1 truncate font-semibold text-base-content" data-role="details-title">
          {@name}
        </b>
        <button
          type="button"
          id="details-close"
          phx-click={JS.push("details_close")}
          aria-label="Close details"
          class={paint(:close)}
        >
          <span class="hero-x-mark size-5" aria-hidden="true"></span>
        </button>
      </div>
      <div class="min-h-0 flex-1 overflow-y-auto p-2" data-role="details-body">
        <SpaceSheet.sections
          surface={:panel}
          prefix="details"
          page={@details_panel}
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
          page_pins={@details_pins}
          page_threads={@details_threads}
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
          page_files={@details_files}
          page_links={@details_links}
        >
          <:members_popover>
            <.live_component
              module={MembersComponent}
              id="chat-members-popover"
              surface={:popover}
              open={@show_members}
              space={@active_space}
              space_name={
                PlatformWeb.ChatLive.RenderHelpers.space_header_name(
                  @active_space,
                  @space_participants,
                  @user_id,
                  PlatformWeb.ChatLive.space_mask(assigns)
                )
              }
              current_user_id={@user_id}
              viewer={@current_user_record}
            />
          </:members_popover>
          <:agents_popover>
            <AgentsSheet.agents_sheet
              surface={:popover}
              open={@agents_sheet_open}
              state={@agent_attention}
              active_space={@active_space}
            />
          </:agents_popover>
        </SpaceSheet.sections>
      </div>
    </aside>
    """
  end

  attr(:user_id, :any, required: true)
  attr(:open, :boolean, required: true)

  @doc """
  The hidden, always-rendered node the `DetailsPanelState` hook mounts on.
  `data-user-id` keys the remembered open per viewer; `data-open` is the
  server's state, which the hook reads before restoring.
  """
  def details_panel_state(assigns) do
    ~H"""
    <div
      id="details-panel-state"
      class="hidden"
      phx-hook="DetailsPanelState"
      data-user-id={@user_id}
      data-open={to_string(@open)}
    >
    </div>
    """
  end

  @doc """
  The Space segment's "Promote to channel" row (Burrow redesign 22 stage 4;
  not in canvas): a group conversation's existing `#promote-to-channel-form`,
  moved from the old desktop header with its `promote_to_channel` event and
  `ButtonLoading` hook. `SpaceSheet.sections/1` renders it on the panel for
  a group (not a 1:1 DM) only.
  """
  def promote_row(assigns) do
    ~H"""
    <form
      id="promote-to-channel-form"
      phx-hook="ButtonLoading"
      phx-submit="promote_to_channel"
      data-role="details-promote"
      class="flex min-h-9 w-full items-center gap-2 rounded-field px-2 py-1.5 text-sm text-base-content"
    >
      <span class="hero-hashtag size-4 shrink-0" aria-hidden="true"></span>
      <input
        name="name"
        type="text"
        aria-label="Channel name"
        placeholder="Channel name…"
        class="input input-bordered input-xs min-w-0 flex-1"
        required
      />
      <button type="submit" class={paint(:promote)}>
        Promote to channel
      </button>
    </form>
    """
  end

  @doc """
  The panel surface's classes for `SpaceSheet.sections/1`, by role. Tokens
  only; hover is `lg:hover:` (a desktop-only surface).
  """
  def paint(:close),
    do:
      "flex size-[34px] flex-none items-center justify-center rounded-full text-subtle lg:hover:bg-base-300 lg:hover:text-base-content focus-visible-ring"

  def paint(:back),
    do:
      "flex size-8 shrink-0 items-center justify-center rounded-full text-subtle lg:hover:bg-base-300 lg:hover:text-base-content focus-visible-ring"

  def paint(:opt),
    do:
      "flex min-h-9 w-full items-center gap-2 rounded-field px-2 py-1.5 text-left text-sm text-base-content lg:hover:bg-base-300 focus-visible-ring"

  def paint(:item),
    do:
      "flex min-h-9 w-full flex-col gap-0.5 rounded-field px-2 py-1.5 text-left lg:hover:bg-base-300 focus-visible-ring"

  def paint(:link_row),
    do:
      "flex min-h-9 w-full items-center gap-2 rounded-field px-2 py-1.5 text-left text-base-content lg:hover:bg-base-300 focus-visible-ring"

  def paint(:pin_open),
    do:
      "flex min-h-9 min-w-0 flex-1 flex-col gap-0.5 rounded-field px-2 py-1.5 text-left lg:hover:bg-base-300 focus-visible-ring"

  def paint(:unpin),
    do:
      "flex min-h-9 shrink-0 items-center rounded-field px-2 text-xs text-base-content lg:hover:bg-base-300 focus-visible-ring"

  def paint(:switch),
    do:
      "flex min-h-9 w-full items-center gap-2 rounded-field px-2 py-1.5 text-left lg:hover:bg-base-300 focus-visible-ring"

  def paint(:promote),
    do:
      "flex h-7 shrink-0 items-center whitespace-nowrap rounded-full border border-edge px-2.5 text-xs text-base-content lg:hover:bg-base-300 focus-visible-ring"

  def paint(:seg_rest), do: "border-edge text-subtle lg:hover:text-base-content"
end
