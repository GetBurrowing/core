defmodule PlatformWeb.Components.IconRailTest do
  @moduledoc """
  The canonical destination list and the phone tab bar (`bottom_rail/1`).
  The desktop icon rail these tests also covered was deleted by Burrow
  redesign 22 stage 1; its replacement, the desktop sidebar, is pinned in
  `sidebar_test.exs`.
  """

  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.IconRail

  defp render_bottom_rail(assigns) do
    assigns =
      Map.merge(
        %{
          current_path: "/chat",
          root_user: false
        },
        assigns
      )

    assigns = Map.merge(%{more_open: false, inbox_unread_count: 0}, assigns)

    rendered_to_string(~H"""
    <.bottom_rail
      current_path={@current_path}
      root_user={@root_user}
      more_open={@more_open}
      inbox_unread_count={@inbox_unread_count}
    />
    """)
  end

  describe "destinations/1" do
    test "UI copy: Org memory and Agents (task 01a1557a-807f stage 2 renames)" do
      by_key = Map.new(destinations(root_user: true), &{&1.key, &1})
      assert by_key[:context].label == "Org memory"
      assert by_key[:agents].label == "Agents"
      # Renames are UI copy only: keys and routes stay.
      assert by_key[:context].path == "/org_memory"
      assert by_key[:agents].path == "/control"
    end

    test "Changelog is a More-sheet destination" do
      dest = Enum.find(destinations(root_user: true), &(&1.key == :changelog))
      assert %{cluster: :sheet, path: "/changelog", hero_icon: "hero-newspaper"} = dest
      assert :changelog in Enum.map(more_sheet_rows(nil, true), & &1.key)
    end

    test "returns 13 destinations for a non-Acme user (Admin + Prompts filtered out)" do
      # Count bumped from 7 → 8 when ADR-0042 stage 5 added the Files
      # destination (working cluster, root_only?: false), 8 → 9 when
      # task 019fe6ba added Experiments, 9 → 10 when task 019fea0d added
      # Pipeline, and back 10 → 9 when task 019fed1e removed Pipeline again
      # (it moved to an admin-only cog in the Tasks header), 10 → 9 when
      # task 01a1557a-7a71 stage 4 retired Activity, and 9 -> 10 when task
      # 01a1557a-807f stage 2 added the More-sheet-only Changelog, and 10 -> 11
      # when task 01a1557a-b5f9 stage 3 added the More-sheet-only Canvases,
      # and 11 -> 12 when task 01a1557a-eab7 stage 2 added Voice.
      # Any future destination addition should bump the matching guard below.
      list = destinations(root_user: false)
      assert length(list) == 13
      refute Enum.any?(list, &(&1.key == :admin))
      # Prompts is also root_only?: true as of 2026-05-20 (admin-only access
      # at the route level; previously rendered for members but redirected
      # on click — bug fixed by filtering root_only? in all clusters).
      refute Enum.any?(list, &(&1.key == :prompts))
      # Files (ADR-0042 stage 5) is visible to every authenticated user.
      assert Enum.any?(list, &(&1.key == :files))
    end

    test "returns all 15 destinations for an Acme user (Admin + Prompts included)" do
      # 13 -> 14 when task 01a1557a-eab7 stage 2 added Voice.
      list = destinations(root_user: true)
      assert length(list) == 15
      assert Enum.any?(list, &(&1.key == :admin))
      assert Enum.any?(list, &(&1.key == :prompts))
      assert Enum.any?(list, &(&1.key == :files))
    end

    test "Canvases is a More-sheet-only destination: sheet cluster, the filtered browser" do
      dest = destinations(root_user: false) |> Enum.find(&(&1.key == :canvases))

      assert %{cluster: :sheet, path: "/files?tab=browse&type=canvas", label: "Canvases"} = dest
      refute dest.root_only?
      # Games still has no destination (rung 21).
      refute Enum.any?(destinations(root_user: true), &(&1.key == :games))
    end

    test "the matcher: Canvases only on its exact URL, Files on every other /files URL" do
      list = destinations(root_user: true)

      assert active_destination_key(list, "/files?tab=browse&type=canvas") == :canvases
      assert active_destination_key(list, "/files?tab=browse") == :files
      assert active_destination_key(list, "/files") == :files
      assert active_destination_key(list, "/files/abc") == :files
      assert active_destination_key(list, "/filesystem") == nil
    end

    test "Experiments is a member-visible destination pointing at /control/experiments" do
      # Reachability guard for task 019fe6ba: `/control/experiments` sits in
      # `live_session :authenticated`, so a NON-admin member must see the nav
      # entry. Asserting against the root_user: false list is the whole
      # point — a root_only? regression here restores the original defect
      # (the page reachable only by typing the URL).
      dest =
        destinations(root_user: false)
        |> Enum.find(&(&1.key == :experiments))

      assert dest, "Experiments must appear for a non-Acme member"
      assert dest.path == "/control/experiments"
      assert dest.cluster == :working
      refute dest.root_only?
    end

    test "the rail offers no Pipeline destination at all" do
      # Task 019fed1e REVERSES task 019fea0d's entry: pipeline is a Tasks
      # concern reached from the admin-only cog in the Tasks header, not a
      # shell destination, and its route moved to `/admin/pipeline`.
      #
      # NOTE THE LIST. This asserts against the UNFILTERED
      # `destinations(root_user: true)`. Against the member list a
      # re-added entry marked `root_only?: true` is filtered out, so the
      # refute would pass while the tile was back in the rail for admins —
      # the filtered list hides exactly the state under test.
      list = destinations(root_user: true)

      assert list != [], "no destinations at all — this guard would be vacuous"
      refute Enum.any?(list, &(&1.key == :pipeline))
      refute Enum.any?(list, &String.contains?(&1.path, "/control/pipeline"))
    end

    test "every /control destination in the rail is member-visible" do
      # The class-level guard rather than one test per page. Both /control
      # surfaces shipped unreachable, one after the other, because "route
      # added" was treated as "shipped". This fails if a future /control tile
      # is added as root_only? while its route stays in :authenticated.
      #
      # NOTE the list this iterates. Written first against
      # `destinations(root_user: false)`, this test was VACUOUS: setting a
      # /control entry to root_only?: true filters it OUT of that list, so the
      # loop never saw it and the refute never fired — the guard could not
      # fail for the exact regression it exists to catch. Proven by mutation:
      # flipping :pipeline to root_only?: true left this test green.
      # It must iterate the UNFILTERED list, where a hidden entry is still
      # present and can be inspected.
      control_dests =
        destinations(root_user: true)
        |> Enum.filter(&String.starts_with?(&1.path, "/control"))

      assert control_dests != [], "no /control destinations found — this guard would be vacuous"

      for dest <- control_dests do
        refute dest.root_only?,
               "#{dest.key} points at #{dest.path} but is hidden from non-Acme members"
      end
    end

    test "every entry has the required keys" do
      for dest <- destinations(root_user: true) do
        assert is_atom(dest.key)
        assert is_binary(dest.label)
        assert is_binary(dest.path)
        assert is_binary(dest.hero_icon)
        assert String.starts_with?(dest.hero_icon, "hero-")
        assert dest.cluster in [:live, :working, :admin, :sheet]
        assert is_boolean(dest.root_only?)
      end
    end

    test "root_only? entries are Prompts and Admin, in canonical order" do
      # Ordered assertion: if anyone adds another root_only? entry without
      # updating this list, the test fails immediately. Canonical order is
      # the position in canonical_destinations/0 (Prompts is in the working
      # cluster between Context+Memory and Meetings; Admin is the last entry
      # in the admin cluster).
      acme_only = destinations(root_user: true) |> Enum.filter(& &1.root_only?)
      assert Enum.map(acme_only, & &1.key) == [:prompts, :admin]
    end

    test "cluster assignment" do
      # Live = Chat / Tasks / Inbox (Activity retired, task 01a1557a-7a71 stage 4)
      # Working = Skills / Context / Prompts / Meetings (Memory tabs under Context per Robin 2026-05-18)
      # Admin = Admin
      by_key =
        destinations(root_user: true)
        |> Enum.into(%{}, fn dest -> {dest.key, dest.cluster} end)

      assert by_key[:chat] == :live
      assert by_key[:tasks] == :live
      assert by_key[:inbox] == :live
      refute Map.has_key?(by_key, :activity)

      assert by_key[:skills] == :working
      assert by_key[:context] == :working
      assert by_key[:prompts] == :working
      assert by_key[:meetings] == :working
      assert by_key[:calendar] == :working

      refute Map.has_key?(by_key, :memory)

      assert by_key[:admin] == :admin
    end
  end

  describe "bottom_rail/1 mobile wrapper" do
    test "renders the bottom-nav wrapper with lg:hidden" do
      html = render_bottom_rail(%{})
      assert html =~ "bottom-nav"
      assert html =~ "lg:hidden"
      assert html =~ ~s(data-bottom-rail)
    end

    test "carries role=navigation and aria-label on the mobile wrapper" do
      html = render_bottom_rail(%{})
      assert html =~ ~s(role="navigation")
      assert html =~ ~s(aria-label="Main navigation")
    end

    # Task 01a18d9f stage 5 (the product lead, 2026-10-30): at most four link tabs on the
    # phone, Chat, Calendar, Meetings and Inbox; Tasks and Voice move to More.
    test "mobile_tab_keys/0 is exactly Chat, Calendar, Meetings, Inbox" do
      assert mobile_tab_keys() == [:chat, :calendar, :meetings, :inbox]
    end

    test "renders exactly four link tabs plus More, in order: Chat, Calendar, Meetings, Inbox, More" do
      html = render_bottom_rail(%{})
      assert bar_keys(html) == ["chat", "calendar", "meetings", "inbox", "more"]
      doc = LazyHTML.from_fragment(html)
      assert doc |> LazyHTML.query("[data-bottom-rail] a.bottom-nav-tab") |> Enum.count() == 4

      assert doc |> LazyHTML.query("[data-bottom-rail] button.bottom-nav-tab") |> Enum.count() ==
               1
    end

    test "Voice, Tasks and Activity are not in the bar" do
      doc = LazyHTML.from_fragment(render_bottom_rail(%{}))

      for key <- ["voice", "tasks", "activity"] do
        assert doc
               |> LazyHTML.query(~s([data-bottom-rail] [data-destination="#{key}"]))
               |> Enum.count() == 0
      end
    end

    test "More tab is a button firing phx-click=open_more_sheet, a dialog trigger" do
      html = render_bottom_rail(%{})
      assert html =~ ~s(phx-click="open_more_sheet")
      [more] = more_button(html)
      assert LazyHTML.attribute(more, "aria-label") == ["More"]
      assert LazyHTML.attribute(more, "aria-haspopup") == ["dialog"]
      assert LazyHTML.attribute(more, "aria-expanded") == ["false"]
    end

    test "tab count is invariant to root_user (Admin lives in More sheet)" do
      acme = render_bottom_rail(%{root_user: true})
      non_acme = render_bottom_rail(%{root_user: false})

      assert count_data_destination_matches(acme) == 5
      assert count_data_destination_matches(non_acme) == 5
    end
  end

  describe "bottom_rail/1 icons" do
    test "inactive tabs render the outline icon, the active tab the -solid one" do
      html = render_bottom_rail(%{current_path: "/calendar"})

      assert icon_for(html, "calendar") == "hero-calendar-solid"
      assert icon_for(html, "chat") == "hero-chat-bubble-oval-left-ellipsis"
      assert icon_for(html, "meetings") == "hero-video-camera"
      assert icon_for(html, "inbox") == "hero-inbox"
      assert icon_for(html, "more") == "hero-ellipsis-horizontal"
    end

    test "More's icon goes solid when More is active" do
      html = render_bottom_rail(%{more_open: true})
      assert icon_for(html, "more") == "hero-ellipsis-horizontal-solid"
      assert icon_for(html, "chat") == "hero-chat-bubble-oval-left-ellipsis"
    end

    test "the shared destinations' hero_icon is untouched (the More sheet keeps it)" do
      by_key = Map.new(destinations(root_user: true), &{&1.key, &1.hero_icon})
      assert by_key[:chat] == "hero-chat-bubble-left-right"
      assert by_key[:tasks] == "hero-rectangle-stack"
      assert by_key[:meetings] == "hero-video-camera"
    end
  end

  describe "bottom_rail/1 active state" do
    test "applies .bottom-nav-tab--active only to the tile whose path matches current_path" do
      html = render_bottom_rail(%{current_path: "/inbox"})
      assert active_keys(html) == ["inbox"]
    end

    test "/calendar and its subpages light Calendar" do
      for path <- ["/calendar", "/calendar/booking", "/calendar/settings"] do
        assert active_keys(render_bottom_rail(%{current_path: path})) == ["calendar"], path
      end
    end

    test "/tasks and /voice, now More-sheet rows, light More" do
      for path <- ["/tasks", "/tasks/123", "/voice"] do
        assert active_keys(render_bottom_rail(%{current_path: path})) == ["more"], path
      end
    end

    test "active mobile tile carries aria-current=page" do
      html = render_bottom_rail(%{current_path: "/meetings/standup-abc"})
      assert active_keys(html) == ["meetings"]

      assert html =~ ~r/data-destination="meetings"[^>]*aria-current="page"/s or
               html =~ ~r/aria-current="page"[^>]*data-destination="meetings"/s
    end

    test "every mobile tab carries an aria-label" do
      html = render_bottom_rail(%{})

      for label <- ["Chat", "Calendar", "Meetings", "Inbox", "More"] do
        assert html =~ ~s(aria-label="#{label}"),
               "expected aria-label=#{inspect(label)} on mobile bottom-rail"
      end
    end

    test "a nested chat route (/chat/:slug) lights the Chat tab" do
      # On mobile this is the user's only 'where am I' cue inside a conversation.
      html = render_bottom_rail(%{current_path: "/chat/some-space"})
      assert active_keys(html) == ["chat"]
    end

    test "more_open lights More, and only More, with aria-expanded=true" do
      html = render_bottom_rail(%{current_path: "/chat", more_open: true})
      assert active_keys(html) == ["more"]
      [more] = more_button(html)
      assert LazyHTML.attribute(more, "aria-expanded") == ["true"]
      refute html =~ ~s(aria-current="page")
    end

    test "a More-sheet page (/skills) lights More" do
      html = render_bottom_rail(%{current_path: "/skills"})
      assert active_keys(html) == ["more"]
    end

    test "/changelog, a sheet-only row, lights More" do
      assert active_keys(render_bottom_rail(%{current_path: "/changelog"})) == ["more"]
    end

    test "/settings and the pages it carries light More" do
      for path <- ["/settings", "/control/usage", "/admin", "/admin/prompts", "/access"] do
        assert active_keys(render_bottom_rail(%{current_path: path, root_user: true})) == ["more"],
               path
      end
    end

    test "More sends close_more_sheet while the sheet is open, open_more_sheet otherwise" do
      for {open?, event} <- [{true, "close_more_sheet"}, {false, "open_more_sheet"}] do
        [more] = more_button(render_bottom_rail(%{more_open: open?}))
        assert LazyHTML.attribute(more, "phx-click") == [event]
      end
    end

    test "/tasks/pipeline, linked from the Settings Admin sheet, stays under Tasks (in More)" do
      assert active_keys(render_bottom_rail(%{current_path: "/tasks/pipeline", root_user: true})) ==
               ["more"]
    end

    test "a path nothing lists lights nothing" do
      assert active_keys(render_bottom_rail(%{current_path: "/nowhere"})) == []
    end

    test "the More button never carries aria-current (it is a sheet trigger, not a route)" do
      html = render_bottom_rail(%{current_path: "/skills", more_open: true})
      refute html =~ ~r/data-destination="more"[^>]*aria-current/s
    end
  end

  describe "bottom_rail/1 Inbox unread dot (task 01a18d9f stage 5)" do
    test "present on the Inbox tab at 1 unread, with the Inbox aria-label naming it" do
      html = render_bottom_rail(%{inbox_unread_count: 1})
      doc = LazyHTML.from_fragment(html)

      assert doc
             |> LazyHTML.query(
               ~s([data-destination="inbox"] .bottom-nav-dot[data-role="inbox-unread-dot"])
             )
             |> Enum.count() == 1

      inbox = LazyHTML.query(doc, ~s([data-bottom-rail] a[data-destination="inbox"]))
      assert LazyHTML.attribute(inbox, "aria-label") == ["Inbox, unread"]
      [more] = more_button(html)
      assert LazyHTML.attribute(more, "aria-label") == ["More"]
      # The dot carries no count, and never reuses the desktop rail's role.
      refute html =~ "inbox-badge"
      refute html =~ "more-unread-dot"
    end

    test "absent from the DOM at 0" do
      html = render_bottom_rail(%{inbox_unread_count: 0})
      refute html =~ "inbox-unread-dot"
      refute html =~ "bottom-nav-dot"
    end
  end

  defp bar_keys(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-bottom-rail] [data-destination]")
    |> LazyHTML.attribute("data-destination")
  end

  defp active_keys(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-bottom-rail] .bottom-nav-tab--active")
    |> LazyHTML.attribute("data-destination")
  end

  defp more_button(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-bottom-rail] button[data-destination="more"]))
    |> Enum.to_list()
  end

  defp icon_for(html, key) do
    [class] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-bottom-rail] [data-destination="#{key}"] .bottom-nav-icon))
      |> LazyHTML.attribute("class")

    class |> String.split() |> Enum.find(&String.starts_with?(&1, "hero-"))
  end

  defp count_data_destination_matches(html) do
    Regex.scan(~r/data-destination="[^"]+"/, html) |> length()
  end

  # Badge labels. The desktop sidebar (PlatformWeb.Components.Sidebar) and
  # ShellLive's AppBadge read these; the rendered badges are pinned in
  # sidebar_test.exs.
  describe "badge labels" do
    # Task 01a00066 stage 4 pins the badge's LOOK as unchanged: the count is
    # filtered upstream (`Inbox.reachable_unread_count/1`), so `badge_text/1`
    # keeps exactly one cap at 99. A second cap introduced for external users
    # would detonate here.
    test "badge_text/1 caps at 99+ and has NO second cap" do
      assert badge_text(99) == "99"
      assert badge_text(100) == "99+"
      assert badge_text(1_000) == "99+"
      assert badge_text(10_000) == "99+"

      # Exactly one threshold in 1..250: the value stops changing after 99.
      distinct = 1..250 |> Enum.map(&badge_text/1) |> Enum.uniq()
      assert Enum.count(distinct) == 100
      assert List.last(distinct) == "99+"

      # Nothing below the cap is rewritten, and 0 still renders no badge.
      assert badge_text(1) == "1"
      assert badge_text(0) == nil
    end

    test "chat_badge_text/1 caps at 99+ and has NO second cap below it" do
      assert chat_badge_text(0) == nil
      assert chat_badge_text(-1) == nil
      assert chat_badge_text(1) == "1"

      # The old cap's boundary. 9 is an ordinary number now.
      assert chat_badge_text(8) == "8"
      assert chat_badge_text(9) == "9"

      # Mid-range, which is what proves there is no second cap between 9 and 99.
      assert chat_badge_text(40) == "40"

      assert chat_badge_text(99) == "99"
      assert chat_badge_text(100) == "99+"
      assert chat_badge_text(1_000) == "99+"

      # Exactly 100 distinct labels in 1..250: "1".."99" and then "99+".
      distinct = 1..250 |> Enum.map(&chat_badge_text/1) |> Enum.uniq()
      assert Enum.count(distinct) == 100
      assert List.last(distinct) == "99+"
    end

    # Both caps are 99+, so the two functions agree at every input and the
    # obvious next move is to collapse them into one. This test is what stops
    # that refactor moving Inbox by accident: `badge_text/1` also feeds
    # ShellLive's `AppBadge` document-title label, so its contract has to be
    # pinned independently of Chat's.
    test "badge_text/1 is unmoved at the inputs chat_badge_text/1 changed on" do
      assert badge_text(0) == nil
      assert badge_text(40) == "40"
      assert badge_text(99) == "99"
      assert badge_text(100) == "99+"
      assert badge_text(150) == "99+"
    end
  end
end

defmodule PlatformWeb.Components.IconRailMailFlagTest do
  @moduledoc """
  The Email destination is gated by `Platform.Mail.Config.enabled?/0` (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 4): flag off, no Email tile
  anywhere the list reaches (the desktop sidebar's More group, the bar); flag
  on, one Email row.

  A separate module because it flips `:mail_enabled` in application env,
  which the async `IconRailTest` above must never observe.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.IconRail

  defp with_mail(enabled) do
    previous = Application.fetch_env(:platform, :mail_enabled)
    Application.put_env(:platform, :mail_enabled, enabled)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mail_enabled, value)
        :error -> Application.delete_env(:platform, :mail_enabled)
      end
    end)
  end

  defp render_rail(root_user) do
    assigns = %{root_user: root_user}

    rendered_to_string(~H"""
    <PlatformWeb.Components.Sidebar.sidebar current_path="/chat" root_user={@root_user} />
    <.bottom_rail current_path="/chat" />
    """)
  end

  test "flag off: no Email destination in the list or the rendered rails" do
    with_mail(false)

    for acme? <- [false, true] do
      refute Enum.any?(destinations(root_user: acme?), &(&1.key == :email))
      html = render_rail(acme?)
      # Positive control: the rail rendered its other Working tiles.
      assert html =~ ~s(data-destination="meetings")
      refute html =~ ~s(data-destination="email")
      refute html =~ ~s(href="/email")
    end
  end

  test "flag on: exactly one Email destination, in Working, for members and Acme users" do
    with_mail(true)

    for acme? <- [false, true] do
      assert [email] = Enum.filter(destinations(root_user: acme?), &(&1.key == :email))
      assert email.cluster == :working
      assert email.path == "/email"
      assert email.hero_icon == "hero-envelope"
      refute email.root_only?

      html = render_rail(acme?)
      doc = LazyHTML.from_fragment(html)
      assert doc |> LazyHTML.query(~s([data-destination="email"])) |> Enum.count() == 1
    end
  end

  test "enabled?/1 treats an entry without a predicate as on" do
    assert enabled?(%{key: :chat})
    assert enabled?(%{key: :x, enabled?: fn -> true end})
    refute enabled?(%{key: :x, enabled?: fn -> false end})
  end
end

defmodule PlatformWeb.Components.IconRailExtensionMoreTest.SocialStub do
  @moduledoc false
  # Stands in for the Social module's extension, which the platform suite does
  # not load: one rail item at Social's real path.
  # No canvas kinds: the More sheet's Games row asks the kind registry
  # (`Browser.games_enabled?/0`), which reads every extension's kinds.
  def canvas_kinds, do: []

  def rail_items,
    do: [
      %{
        key: :social,
        label: "Social",
        path: "/m/social",
        hero_icon: "hero-megaphone",
        cluster: :working,
        root_only?: false
      }
    ]
end

defmodule PlatformWeb.Components.IconRailExtensionMoreTest do
  @moduledoc """
  An extension's page is a More-sheet row, so the bar lights More on it
  (task 01a1557a-807f stage 2). async: false — swaps `:extensions`.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.IconRail

  test "/m/social lights More once Social's rail item is installed" do
    assigns = %{}

    render = fn ->
      rendered_to_string(~H"""
      <.bottom_rail current_path="/m/social" root_user={false} />
      """)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-bottom-rail] .bottom-nav-tab--active")
      |> LazyHTML.attribute("data-destination")
    end

    Platform.FixtureExtension.register([])
    # Control: with no extension, nothing lists /m/social.
    assert render.() == []

    Platform.FixtureExtension.register([__MODULE__.SocialStub])
    assert render.() == ["more"]
  end
end
