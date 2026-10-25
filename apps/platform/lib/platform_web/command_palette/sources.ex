defmodule PlatformWeb.CommandPalette.Sources do
  @moduledoc """
  Every jump target the desktop command palette may offer the viewer (Burrow
  redesign 23, stage 1). Data only: no UI, no ranking (`PlatformWeb.CommandPalette.Rank`
  orders what this returns).

  `load/1` returns `%{id, kind, label, icon, path, terms}` maps in this order,
  which is also the empty-query order and the ranker's last tiebreaker:

    1. `"module"`: the sidebar's rows, `PlatformWeb.Components.Sidebar.rows/2`
       (tab rows, then More rows), then Settings, each with the destination's
       own icon and path.
    2. `"space"`: the reader's live channels, `PlatformWeb.ChatLive.ReadScope.channels/1`.
    3. `"direct"`: DMs and groups, `ReadScope.conversations/2`, labelled by
       `PlatformWeb.ChatLive.ChatListData.load_identities/1` (the list row's name).
    4. `"canvas"`: `Platform.Chat.list_canvas_groups/2` over the space and
       direct ids above, 50 per space, most recently updated first.
    5. `"settings"`: Profile, Appearance, Notifications, and Admin only when
       `PlatformWeb.SettingsLive.visible_admin_rows/1` is non-empty. Their
       paths open the matching sheet through `/settings?sheet=`.
    6. `"archived"`: `ReadScope.archived_channels/2`, `[]` for a guest.

  ## Access

  Only what the viewer's own list and sidebar can see, through the same
  scoped reads those surfaces use; this module writes no query of its own.
  The read-scope is `ReadScope.resolve/3`'s, as ChatLive mounts with, so a
  guest gets only their allowlisted channels, no archived channels, no
  Agents space (`Platform.Chat.Sidebar.reject_agents_space/2`, the list
  pane's own rule), no module their Scope denies and no Admin item.

  ## Masking

  With `mask_names?` on, a channel label (live or archived) is
  `PlatformWeb.ChatLive.masked_space_name/2`, the placeholder the list pane
  shows, over a fresh `Platform.Chat.Sidebar.resolve_for_user/2` with nothing
  revealed. Ranking matches the label as built here, so a masked channel never
  matches its real name. DM names and canvas titles are NOT masked, matching
  the coverage `Platform.Chat.SidebarMask` documents (canvases are out of its
  scope; DM rows carry people, not org names).
  """

  alias Platform.Chat
  alias Platform.Chat.Sidebar, as: ChatSidebar
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.ChatListData
  alias PlatformWeb.ChatLive.ReadScope
  alias PlatformWeb.Components.IconRail
  alias PlatformWeb.Components.Sidebar

  @canvas_limit 50

  @type item :: %{
          id: String.t(),
          kind: String.t(),
          label: String.t(),
          icon: String.t(),
          path: String.t(),
          terms: [String.t()]
        }

  @doc "Every jump target for the viewer, in palette order. See the moduledoc."
  @spec load(map()) :: [item()]
  def load(%{access_scope: access_scope, user_id: user_id} = viewer) do
    {scope, guest?} = ReadScope.resolve(access_scope, user_id, false)
    mask = mask_assigns(user_id, viewer[:mask_names?] == true)

    channels = channels(scope, guest?)
    conversations = ReadScope.conversations(user_id, scope)
    archived = ReadScope.archived_channels(ReadScope.fenced_scope(access_scope), guest?)

    modules(access_scope, viewer[:root_user] == true) ++
      Enum.map(channels, &channel_item(&1, "space", "hero-hashtag", mask)) ++
      direct_items(conversations, user_id) ++
      canvas_items(Enum.map(channels ++ conversations, & &1.id), access_scope) ++
      settings_items(access_scope) ++
      Enum.map(archived, &channel_item(&1, "archived", "hero-archive-box", mask))
  end

  defp modules(access_scope, root_user) do
    {tabs, more} = Sidebar.rows(access_scope, root_user)

    Enum.map(tabs, &module_item(&1, IconRail.tab_icon(&1.key, false))) ++
      Enum.map(more, &module_item(&1, Map.get(&1, :hero_icon) || "hero-puzzle-piece")) ++
      [module_item(%{key: :settings, label: "Settings", path: "/settings"}, "hero-cog-6-tooth")]
  end

  defp module_item(dest, icon),
    do: item("module:#{dest.key}", "module", dest.label, icon, dest.path, [])

  # The list pane never shows a guest the Agents space (its Agents row is
  # internal), so neither does the palette.
  defp channels(scope, true),
    do:
      scope
      |> ReadScope.channels()
      |> ChatSidebar.reject_agents_space(ChatSidebar.agents_rail_block())

  defp channels(scope, false), do: ReadScope.channels(scope)

  defp channel_item(space, kind, icon, mask) do
    label = ChatLive.masked_space_name(mask, space.name || "")
    item("#{kind}:#{space.id}", kind, label, icon, space_path(space), [])
  end

  # The list pane's href (`ChatLive.space_nav_target/1`): a sub-org space links
  # by id, so a masked channel's real slug never reaches the link target.
  defp space_path(space), do: "/chat/#{ChatLive.space_nav_target(space)}"

  # Sections are only read when something will be masked.
  defp mask_assigns(user_id, masked?) do
    %{
      sidebar_sections: if(masked?, do: ChatSidebar.resolve_for_user(user_id, []), else: []),
      mask_names?: masked?,
      revealed_section_ids: MapSet.new()
    }
  end

  defp direct_items(conversations, user_id) do
    names = ChatListData.load_identities(%{user_id: user_id, dm_conversations: conversations})

    Enum.map(conversations, fn space ->
      icon = if space.kind == "group", do: "hero-user-group", else: "hero-user"
      label = get_in(names, [space.id, :name]) || space.name || ""
      item("direct:#{space.id}", "direct", label, icon, space_path(space), [])
    end)
  end

  defp canvas_items(space_ids, access_scope) do
    space_ids
    |> Enum.uniq()
    |> Chat.list_canvas_groups(
      limit: @canvas_limit,
      order: :updated_desc,
      access_scope: access_scope
    )
    |> Enum.flat_map(& &1.rows)
    |> Enum.map(fn canvas ->
      item(
        "canvas:#{canvas.id}",
        "canvas",
        canvas.title || "",
        "hero-rectangle-group",
        "/canvases/#{canvas.id}",
        []
      )
    end)
  end

  defp settings_items(access_scope) do
    admin_rows = PlatformWeb.SettingsLive.visible_admin_rows(access_scope)

    [
      item("settings:profile", "settings", "Profile", "hero-user-circle", "/settings", [
        "account",
        "profile"
      ]),
      item(
        "settings:appearance",
        "settings",
        "Appearance",
        "hero-swatch",
        "/settings?sheet=appearance",
        ["theme", "dark", "light", "colour", "color"]
      ),
      item(
        "settings:notifications",
        "settings",
        "Notifications",
        "hero-bell",
        "/settings?sheet=notifications",
        ["notify", "alerts"]
      )
    ] ++
      if admin_rows == [],
        do: [],
        else: [
          item(
            "settings:admin",
            "settings",
            "Admin",
            "hero-shield-check",
            "/settings?sheet=admin",
            Enum.map(admin_rows, & &1.label)
          )
        ]
  end

  defp item(id, kind, label, icon, path, terms),
    do: %{id: id, kind: kind, label: label, icon: icon, path: path, terms: terms}
end
