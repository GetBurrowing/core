defmodule PlatformWeb.Components.MoreSheet do
  @moduledoc """
  Mobile-only bottom sheet for the surfaces the bottom bar does not carry.

  Triggered by the `phx-click="open_more_sheet"` button on the More tab in
  `<.bottom_rail>`.

  ## Rows (task 01a1557a-807f stage 2)

  One list, no headings (Saru: it is a list), from
  `IconRail.more_sheet_rows/2`: Voice and Tasks (they left the bar for the
  sheet, task 01a18d9f stage 5), then every extension row the actor may see
  (Social), then Email, Files, Skills, Org memory, Agents, Experiments,
  Changelog. Inbox and Calendar are tabs in the bar, not rows here.
  Canvases opens the Files browser filtered to canvases
  (`/files?tab=browse&type=canvas`, rung 16). Games, after Canvases, opens
  the Files browser filtered to games (`/files?tab=browse&type=game`, rung
  21), and is present only while the game_stream kind is registered. A
  module the actor
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

    * The row for the page you are on (`IconRail.more_sheet_current_key/2`,
      the rails' own longest-prefix matcher) carries `aria-current="page"`,
      `more-sheet-row--current` and a check.

  ## Fit and the scroll cue

  Rows are 44px, the touch-target floor, so every row a root admin with
  Mail on sees fits above the bar, with Settings pinned, in Safari's visible
  390x664 and at 375x667. On a shorter screen the list scrolls, and a fade
  with a chevron (`data-role="more-sheet-cue"`, just before the last row)
  pins to the bottom of the list until the last row scrolls over it. CSS
  only (app.css `.more-sheet-cue`).

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

  ## The page (task 01a1fc7f stage 2)

  The rows and the Settings link are `more_entries/1`, which this sheet calls
  for its body and its footer. `/more` (`PlatformWeb.MoreLive`, the open
  iPhone Duo's More tab) renders the same component as a page, without the
  sheet's chrome. The sheet's HTML is pinned to its pre-refactor markup in
  more_sheet_test.exs (`MoreSheetEqualityTest`).
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.Components.Sheet
  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.AvatarComponents, only: [human_avatar: 1]

  alias PlatformWeb.Components.IconRail

  attr(:gaming, :boolean, default: false)

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
    assigns = entries_assigns(assigns)

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

      <.more_entries part={:rows} variant={:sheet} entries={@entries} />

      <:actions>
        <%!-- The divider is the footer's own top border (`.sheet-actions`). --%>
        <.more_entries part={:settings} variant={:sheet} entries={@entries} />
      </:actions>
    </.sheet>
    """
  end

  @doc """
  The More destinations: the rows list and the Settings link (task 01a1fc7f
  stage 2). One body for both presentations, so the sheet and the `/more`
  page (`PlatformWeb.MoreLive`, the open iPhone Duo's More tab) can never
  show different rows.

    * `part`: `:all` (the rows, then Settings after a divider; the page),
      `:rows` (the sheet body) or `:settings` (the sheet's pinned footer).
    * `variant`: `:sheet` renders exactly what the sheet always did (the
      scroll cue before the last row, single-line labels). `:page` drops the
      scroll cue (sheet chrome) and lets a label wrap to two lines instead of
      truncating.

  Takes the same inputs as `more_sheet/1`, or `entries`, the precomputed
  map `more_sheet/1` builds once and hands to both of its calls.
  """
  attr(:part, :atom, default: :all, values: [:all, :rows, :settings])
  attr(:variant, :atom, default: :page, values: [:page, :sheet])
  attr(:entries, :map, default: nil, doc: "precomputed by `more_sheet/1`; internal")
  attr(:gaming, :boolean, default: false)
  attr(:root_user, :boolean, default: false)
  attr(:access_scope, :any, default: nil)
  attr(:current_path, :string, default: nil)
  attr(:current_user, :any, default: nil)
  attr(:user, :any, default: nil)

  def more_entries(assigns) do
    entries = assigns[:entries] || entries_assigns(assigns).entries

    assigns
    |> assign(entries)
    |> assign(:label_class, label_class(assigns.variant))
    |> render_part()
  end

  # One template per part, so the sheet's two calls render exactly the markup
  # they always inlined, with no sibling whitespace from the other part.
  defp render_part(%{part: :rows} = assigns), do: more_rows(assigns)
  defp render_part(%{part: :settings} = assigns), do: more_settings_link(assigns)

  defp render_part(assigns) do
    ~H"""
    <.more_rows {assigns} />
    <div
      class="more-page-settings mt-1 border-t border-edge pt-1"
      data-role="more-page-settings"
    >
      <.more_settings_link {assigns} />
    </div>
    """
  end

  defp more_rows(assigns) do
    ~H"""
    <nav class="more-sheet-list" aria-label="More destinations">
      <%= for {dest, index} <- Enum.with_index(@rows) do %>
        <%!-- The scroll cue sits just before the last row, which covers it
             once it is in view (app.css `.more-sheet-cue`). The page has
             none: it is sheet chrome. --%>
        <div
          :if={@variant == :sheet and index == @last_index}
          class="more-sheet-cue flex items-end justify-center bg-gradient-to-t from-base-100 pb-1 text-subtle"
          data-role="more-sheet-cue"
          aria-hidden="true"
        >
          <.icon name="hero-chevron-down" class="size-4" />
        </div>
        <.link
          navigate={dest.path}
          class={[
            "more-sheet-row focus-visible-ring",
            dest.key == @current_key && "more-sheet-row--current"
          ]}
          data-destination={dest.key}
          data-nav-label={dest.label}
          aria-current={if dest.key == @current_key, do: "page"}
          aria-label={dest.label}
        >
          <.icon
            name={Map.get(dest, :hero_icon) || "hero-puzzle-piece"}
            class="more-sheet-icon size-5"
          />
          <span class={["min-w-0", @label_class]}>{dest.label}</span>
          <.icon
            :if={dest.key == @current_key}
            name="hero-check"
            class="more-sheet-check ml-auto size-5 shrink-0"
          />
        </.link>
      <% end %>
    </nav>
    """
  end

  defp more_settings_link(assigns) do
    ~H"""
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
        <span class={["block", @label_class, "text-[15px]"]}>Settings</span>
        <span
          class={["block", @label_class, "text-xs text-subtle"]}
          data-role="more-sheet-settings-subtitle"
        >
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
    """
  end

  # The sheet's labels stay on one line (its fit budget, above); the page's
  # may wrap to two rather than be cut (design canvas 01a1fc82, Type).
  defp label_class(:sheet), do: "truncate"
  defp label_class(_page), do: "line-clamp-2 break-words"

  # Everything both presentations render from, computed once per render.
  defp entries_assigns(assigns) do
    rows =
      if assigns[:gaming],
        do:
          IconRail.gaming_more_sheet_rows(
            assigns[:access_scope],
            Map.get(assigns, :root_user, false)
          ),
        else:
          IconRail.more_sheet_rows(assigns[:access_scope], Map.get(assigns, :root_user, false))

    entries = %{
      rows: rows,
      last_index: length(rows) - 1,
      current_key:
        IconRail.more_sheet_current_key(rows, IconRail.nav_path(assigns[:current_path])),
      name: display_name(assigns[:current_user], assigns[:user]),
      avatar_url: Map.get(assigns[:user] || %{}, :avatar_url),
      avatar_seed: Map.get(assigns[:user] || %{}, :id)
    }

    assign(assigns, :entries, entries)
  end

  defp display_name(name, _user) when is_binary(name) and name != "", do: name
  defp display_name(%{name: name}, _user) when is_binary(name) and name != "", do: name
  defp display_name(_, %{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(_, _), do: "Account"
end
