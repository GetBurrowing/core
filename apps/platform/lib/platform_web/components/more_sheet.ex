defmodule PlatformWeb.Components.MoreSheet do
  @moduledoc """
  Mobile-only bottom sheet for the surfaces the bottom bar does not carry.

  Triggered by the `phx-click="open_more_sheet"` button on the More tab in
  `<.bottom_rail>`.

  ## Rows (task 01a1557a-807f stage 2)

  One list, no headings (Saru: it is a list), from
  `IconRail.more_sheet_rows/2`: Inbox, Email, Files, Skills, Org memory,
  Agents, Experiments, Changelog, then every extension row the actor may see.
  Canvases opens the Files browser filtered to canvases
  (`/files?tab=browse&type=canvas`, rung 16). Games holds a place in
  `IconRail.more_sheet_order/0` and renders nothing until rung 21 adds a
  page. A module the actor
  may not open, or one switched off (Email with Mail off), is absent and
  leaves no gap. Every row is one component, built-in or extension:
  a whole-width link that closes the sheet and navigates in one tap.

  Row links navigate, and the tap itself closes the sheet (task 01a166be-b5b9
  stage 2): `assets/js/lib/nav_pending.js` marks the tapped row and the More
  tab `data-nav-pending` in the click, and app.css slides the panel down
  (180ms after 80ms) with the row still filled, while the More tab carries
  the pending cue until the destination mounts. The server's `@more_open` is
  untouched; the destination's mount renders the sheet closed. If the
  navigation fails, the marks come off, the sheet is back as it was and a
  toast says so (`data-nav-label` is the toast's name for the row).

    * Inbox carries its unread count (`data-role="more-sheet-inbox-badge"`,
      the `IconRail.badge_text/1` grammar).
    * The row for the page you are on (`IconRail.more_sheet_current_key/2`,
      the rails' own longest-prefix matcher) carries `aria-current="page"`,
      `more-sheet-row--current` and a check.

  ## Settings, pinned

  After a divider (the footer's top border), in the sheet's `:actions` footer (outside the scrolling
  body, so it stays in view): the viewer's avatar, "Settings" and
  "<name> · profile, appearance, admin". It opens `/settings`, which now
  carries what the sheet used to: Admin, Prompts, Usage and sign out. It is
  current on /settings, /control/usage, /admin and below, /admin/prompts.

  ## Dismissal (task 01a1557a-807f stage 4)

  Five ways out, each returning focus to More (the Sheet hook restores the
  element focused before it opened): the scrim, a downward swipe past 60px
  (`swipe_dismiss`), Escape, the handle (`handle_close`: the handle is the
  sheet's Close button, so the header X is omitted and the title "More" is
  visually hidden), and More tapped again (`bottom_rail/1` sends
  `close_more_sheet` while the sheet is open).

  `lg:hidden`: the desktop icon rail does this job at lg and up.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.Components.Sheet
  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.AvatarComponents, only: [human_avatar: 1]

  alias PlatformWeb.Components.IconRail

  attr(:open, :boolean, default: false, doc: "whether the sheet is shown")

  attr(:root_user, :boolean,
    default: false,
    doc: "legacy filter flag, consulted only when no `access_scope` is given"
  )

  attr(:access_scope, :any,
    default: nil,
    doc:
      "the actor's `%Platform.Access.Scope{}`; when set every row is filtered through " <>
        "`Platform.Access.module_access?/3` (task 01a1386d-fb6e stage 1)"
  )

  attr(:inbox_unread_count, :integer,
    default: 0,
    doc: "the viewer's unread inbox count; above 0 renders a badge on the Inbox row"
  )

  attr(:current_path, :string,
    default: nil,
    doc: "the current request path; marks the current row"
  )

  attr(:current_user, :any,
    default: nil,
    doc: "the viewer's display name (the shell's `@current_user`) or a map with `:name`"
  )

  attr(:user, :any,
    default: nil,
    doc: "the viewer's `%User{}` record (avatar and id); optional"
  )

  def more_sheet(assigns) do
    rows = IconRail.more_sheet_rows(assigns[:access_scope], Map.get(assigns, :root_user, false))

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:current_key, IconRail.more_sheet_current_key(rows, assigns[:current_path]))
      |> assign(:inbox_badge, IconRail.badge_text(assigns[:inbox_unread_count]))
      |> assign(:name, display_name(assigns[:current_user], assigns[:user]))
      |> assign(:avatar_url, Map.get(assigns[:user] || %{}, :avatar_url))
      |> assign(:avatar_seed, Map.get(assigns[:user] || %{}, :id))

    ~H"""
    <.sheet
      id="more-sheet"
      open={@open}
      placement={:bottom}
      on_close="close_more_sheet"
      class="more-sheet lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>More</:title>

      <nav class="more-sheet-list" aria-label="More destinations">
        <.link
          :for={dest <- @rows}
          navigate={dest.path}
          class={[
            "more-sheet-row focus-visible-ring",
            dest.key == @current_key && "more-sheet-row--current"
          ]}
          data-destination={dest.key}
          data-nav-label={dest.label}
          aria-current={if dest.key == @current_key, do: "page"}
          aria-label={
            if dest.key == :inbox and @inbox_badge,
              do: "#{dest.label}, #{@inbox_unread_count} unread",
              else: dest.label
          }
        >
          <.icon
            name={Map.get(dest, :hero_icon) || "hero-puzzle-piece"}
            class="more-sheet-icon size-5"
          />
          <span class="min-w-0 truncate">{dest.label}</span>
          <span
            :if={dest.key == :inbox and @inbox_badge}
            class="badge badge-primary badge-sm shrink-0 text-xs font-medium tabular-nums"
            data-role="more-sheet-inbox-badge"
          >
            {@inbox_badge}
          </span>
          <.icon
            :if={dest.key == @current_key}
            name="hero-check"
            class="more-sheet-check ml-auto size-5 shrink-0"
          />
        </.link>
      </nav>

      <:actions>
        <%!-- The divider is the footer's own top border (`.sheet-actions`). --%>
        <.link
          navigate={~p"/settings"}
          class={[
            "more-sheet-settings focus-visible-ring w-full",
            @current_key == :settings && "more-sheet-row--current"
          ]}
          data-destination="settings"
          data-nav-label="Settings"
          aria-current={if @current_key == :settings, do: "page"}
        >
          <.human_avatar name={@name} avatar_url={@avatar_url} seed={@avatar_seed} size="sm" />
          <span class="min-w-0 flex-1">
            <span class="block truncate text-[15px]">Settings</span>
            <span class="block truncate text-xs text-subtle" data-role="more-sheet-settings-subtitle">
              {@name} · profile, appearance, admin
            </span>
          </span>
          <.icon
            :if={@current_key == :settings}
            name="hero-check"
            class="more-sheet-check size-5 shrink-0"
          />
          <.icon
            :if={@current_key != :settings}
            name="hero-chevron-right"
            class="size-4 shrink-0 text-subtle"
          />
        </.link>
      </:actions>
    </.sheet>
    """
  end

  defp display_name(name, _user) when is_binary(name) and name != "", do: name
  defp display_name(%{name: name}, _user) when is_binary(name) and name != "", do: name
  defp display_name(_, %{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_, _), do: "Account"
end
