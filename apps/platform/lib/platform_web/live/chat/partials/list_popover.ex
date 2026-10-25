defmodule PlatformWeb.ChatLive.Partials.ListPopover do
  @moduledoc """
  The desktop list pane's header popover (Burrow redesign 22 stage 2;
  master-desktop.html L716-718, `.pop` CSS L120-131).

  The Chat list's three header buttons (`#list-search`, `#list-new`,
  `#list-more`) set ONE assign, `@list_sheet` (`ChatListHooks`). Below lg it
  opens the phone's bottom sheet, which keeps `lg:hidden` and is unchanged.
  At lg the same assign opens THIS popover, anchored under the buttons
  (`hidden lg:flex`), firing the same events: `list_search`,
  `new_channel_open`, `new_conversation_open`, `toggle_mask_names`,
  `toggle_archived_section`. No second state, so the two can never disagree
  about what is open.

  Every id and data-role here is `chat-list-pop-*`: the sheet and the
  popover are both in the DOM while one is open, and the phone tests select
  the sheet's own roles.

  ## What only the desktop has

  The Options popover adds three rows the phone sheet does not carry, all on
  existing events:

    * "Show hidden" (`toggle_hidden_drawer`) lists the channels the reader
      hid, each with Unhide (`unhide_channel`). The desktop channel rail that
      used to hold this drawer is deleted, so this is the one unhide path.
    * "Mark all read" (`mark_all_read`), moved here from that rail's header
      menu.
    * "Appearance" flips light and dark through the sidebar mode row's own
      `ModeToggle` hook (stage 1). The right-hand text names the mode a click
      turns on, as the sidebar row does.

  ## Dismissal

  `phx-click-away` and Escape push `close_list_sheet`. LiveView dispatches
  click-away only to a VISIBLE element, so below lg (where this is
  `display: none`) a tap inside the phone sheet never closes it.

  Paint: base-100 popover, `border-edge`, `shadow-lg`; labels
  `text-base-content`, meta `text-subtle`; rows fill base-200 on hover (lg
  only). Measured in `desktop_shell_contrast_guard_test.exs`.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias PlatformWeb.ChatLive.Partials.ChatList

  attr(:sheet, :any, required: true)
  attr(:external?, :boolean, required: true)
  attr(:query, :string, required: true)
  attr(:results, :map, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:archived_channels, :list, required: true)
  attr(:restricted_channel_ids, :any, required: true)
  attr(:list_private_ids, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:list_excerpts, :map, required: true)
  attr(:list_identities, :map, required: true)
  attr(:mask_assigns, :map, required: true)
  attr(:mask_names?, :boolean, required: true)
  attr(:archived_open, :boolean, required: true)
  attr(:hidden_drawer_open, :boolean, required: true)
  attr(:hidden_channels, :list, required: true)
  attr(:resolved_mode, :string, required: true)

  @titles %{search: "Search", new: "New", options: "Chat list"}

  def list_popover(assigns) do
    open? =
      Map.has_key?(@titles, assigns.sheet) and
        not (assigns.external? and assigns.sheet == :options)

    assigns =
      assigns
      |> assign(:open?, open?)
      |> assign(:title, Map.get(@titles, assigns.sheet))

    ~H"""
    <div
      :if={@open?}
      id="chat-list-popover"
      data-role="chat-list-popover"
      data-sheet={@sheet}
      role="dialog"
      aria-labelledby="chat-list-popover-title"
      phx-click-away={JS.push("close_list_sheet")}
      phx-window-keydown={JS.push("close_list_sheet")}
      phx-key="escape"
      class="absolute right-2 top-full z-50 mt-1 hidden max-h-[70vh] w-[264px] flex-col rounded-box border border-edge bg-base-100 p-1.5 text-base-content shadow-lg lg:flex"
    >
      <h2
        id="chat-list-popover-title"
        class="px-2 pt-1.5 pb-1 text-xs font-semibold uppercase tracking-wider text-subtle"
      >
        {@title}
      </h2>

      <ChatList.search_body
        :if={@sheet == :search}
        prefix="chat-list-pop-search"
        form_class="relative mb-1"
        icon_class="hero-magnifying-glass pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-subtle"
        input_class="h-[30px] w-full rounded-field border border-edge bg-base-200 pl-8 pr-2 text-sm placeholder:text-subtle focus:border-primary focus:outline-none"
        results_class="min-h-0 overflow-y-auto"
        pressed="lg:hover:bg-base-200"
        query={@query}
        results={@results}
        channels={@channels}
        dm_conversations={@dm_conversations}
        archived_channels={@archived_channels}
        restricted_channel_ids={@restricted_channel_ids}
        list_private_ids={@list_private_ids}
        unread_counts={@unread_counts}
        list_excerpts={@list_excerpts}
        list_identities={@list_identities}
        mask_assigns={@mask_assigns}
      />

      <div :if={@sheet == :new} class="flex flex-col">
        <.pop_action
          :if={!@external?}
          role="chat-list-pop-new-channel"
          click={JS.push("close_list_sheet") |> JS.push("new_channel_open")}
          icon="hero-hashtag"
          label="New channel"
          meta="name, people, your agent"
        />
        <.pop_action
          role="chat-list-pop-new-conversation"
          click={JS.push("close_list_sheet") |> JS.push("new_conversation_open")}
          icon="hero-chat-bubble-left-right"
          label="New conversation"
          meta="DM a person or agent"
        />
      </div>

      <div :if={@sheet == :options} class="flex min-h-0 flex-col overflow-y-auto">
        <.pop_switch
          role="chat-list-pop-option-mask"
          js={JS.push("toggle_mask_names", value: %{masked: to_string(!@mask_names?)})}
          on?={@mask_names?}
          label="Mask names"
          meta="for screen sharing"
        />
        <.pop_switch
          role="chat-list-pop-option-archived"
          js={JS.push("toggle_archived_section")}
          on?={@archived_open}
          label="Show archived"
          meta={nil}
        />
        <.pop_switch
          role="chat-list-pop-option-hidden"
          js={JS.push("toggle_hidden_drawer")}
          on?={@hidden_drawer_open}
          label="Show hidden"
          meta={hidden_meta(@hidden_channels)}
          controls="chat-list-pop-hidden"
        />
        <ul
          :if={@hidden_drawer_open}
          id="chat-list-pop-hidden"
          data-role="chat-list-pop-hidden"
          class="flex flex-col pb-1"
          role="list"
        >
          <li
            :if={@hidden_channels == []}
            data-role="chat-list-pop-hidden-empty"
            class="px-2 py-1.5 text-xs text-subtle"
          >
            No hidden channels.
          </li>
          <li
            :for={space <- @hidden_channels}
            data-role="chat-list-pop-hidden-row"
            data-space-id={space.id}
            class="flex min-h-[34px] items-center gap-2 rounded-field pl-4 pr-1"
          >
            <span class="hero-hashtag size-4 shrink-0 text-subtle" aria-hidden="true"></span>
            <span class="min-w-0 flex-1 truncate text-sm">
              {PlatformWeb.ChatLive.masked_space_name(@mask_assigns, space.name)}
            </span>
            <button
              type="button"
              phx-click="unhide_channel"
              phx-value-id={space.id}
              data-role="chat-list-pop-unhide"
              data-space-id={space.id}
              aria-label={"Unhide #{PlatformWeb.ChatLive.masked_space_name(@mask_assigns, space.name)}"}
              class="btn btn-ghost btn-xs focus-visible-ring"
            >
              Unhide
            </button>
          </li>
        </ul>
        <button
          type="button"
          phx-click="mark_all_read"
          data-role="chat-list-pop-mark-all-read"
          class="flex min-h-[34px] w-full items-center gap-2 rounded-field px-2 py-1.5 text-left text-sm lg:hover:bg-base-200 focus-visible-ring"
        >
          <span class="hero-check-circle size-4 shrink-0 text-subtle" aria-hidden="true"></span>
          <span class="min-w-0 flex-1">Mark all read</span>
        </button>
        <%!-- The sidebar mode row's hook (stage 1): `[data-mode-label]` gets
             the mode a click turns on; there are no `[data-mode-icon]`s. --%>
        <button
          id="chat-list-pop-appearance"
          type="button"
          phx-hook="ModeToggle"
          data-resolved={@resolved_mode}
          data-role="chat-list-pop-appearance"
          class="flex min-h-[34px] w-full items-center gap-2 rounded-field px-2 py-1.5 text-left text-sm lg:hover:bg-base-200 focus-visible-ring"
        >
          <span class="hero-swatch size-4 shrink-0 text-subtle" aria-hidden="true"></span>
          <span class="min-w-0 flex-1">Appearance</span>
          <span data-mode-label class="shrink-0 text-xs text-subtle">
            {PlatformWeb.Components.Sidebar.mode_label(@resolved_mode)}
          </span>
        </button>
      </div>
    </div>
    """
  end

  defp hidden_meta([]), do: nil
  defp hidden_meta([_]), do: "1 channel"
  defp hidden_meta(list), do: "#{length(list)} channels"

  attr(:role, :string, required: true)
  attr(:click, :any, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:meta, :string, required: true)

  defp pop_action(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@click}
      data-role={@role}
      class="flex min-h-[34px] w-full items-center gap-2 rounded-field px-2 py-1.5 text-left lg:hover:bg-base-200 focus-visible-ring"
    >
      <span class={[@icon, "size-4 shrink-0 text-subtle"]} aria-hidden="true"></span>
      <span class="min-w-0 flex-1">
        <span class="block text-sm text-base-content">{@label}</span>
        <span class="block text-xs text-subtle">{@meta}</span>
      </span>
    </button>
    """
  end

  attr(:role, :string, required: true)
  attr(:js, :any, required: true)
  attr(:on?, :boolean, required: true)
  attr(:label, :string, required: true)
  attr(:meta, :any, required: true)
  attr(:controls, :string, default: nil)

  # `role="switch"` with `aria-checked`, the whole row the control; the
  # phone sheet's track at the popover's size. On = bg-primary.
  defp pop_switch(assigns) do
    ~H"""
    <button
      type="button"
      role="switch"
      aria-checked={to_string(@on?)}
      aria-controls={@controls}
      phx-click={@js}
      data-role={@role}
      class="flex min-h-[34px] w-full items-center gap-2 rounded-field px-2 py-1.5 text-left lg:hover:bg-base-200 focus-visible-ring"
    >
      <span class="min-w-0 flex-1">
        <span class="block text-sm text-base-content">{@label}</span>
        <span :if={@meta} class="block text-xs text-subtle">{@meta}</span>
      </span>
      <span
        data-role="chat-list-pop-switch-track"
        class={[
          "relative inline-flex h-5 w-8 shrink-0 items-center rounded-full",
          if(@on?, do: "bg-primary", else: "bg-base-300")
        ]}
        aria-hidden="true"
      >
        <span class={[
          "absolute size-4 rounded-full border border-edge bg-base-100",
          if(@on?, do: "left-[0.875rem]", else: "left-0.5")
        ]}>
        </span>
      </span>
    </button>
    """
  end
end
