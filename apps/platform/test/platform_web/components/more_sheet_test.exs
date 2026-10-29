defmodule PlatformWeb.Components.MoreSheetTest.IconlessExtension do
  @moduledoc false
  # An extension whose rail item carries no hero_icon (Saru rule 5 fallback).
  # No canvas kinds: the More sheet's Games row asks the kind registry
  # (`Browser.games_enabled?/0`), which reads every extension's kinds.
  def canvas_kinds, do: []

  def rail_items,
    do: [
      %{
        key: :iconless,
        label: "Iconless",
        path: "/m/iconless",
        cluster: :working,
        root_only?: false
      }
    ]
end

defmodule PlatformWeb.Components.MoreSheetTest.GamesExtension.Kinds.GameStream do
  @moduledoc false
  # A test-only `game_stream` kind, so `Platform.Files.Browser.games_enabled?/0`
  # is true while the extension below is registered. Core never names the
  # real Play modules (extension_boundary_test.exs).
  use Platform.Chat.Canvas.Kind

  @impl true
  def describe, do: "Test-only game_stream kind."

  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}}

  attr :node, :map, required: true
  attr :viewer, :any, default: nil

  @impl true
  def render(assigns), do: ~H""
end

defmodule PlatformWeb.Components.MoreSheetTest.GamesExtension do
  @moduledoc false
  @behaviour Platform.Extension

  @impl true
  def canvas_kinds, do: [PlatformWeb.Components.MoreSheetTest.GamesExtension.Kinds.GameStream]
  @impl true
  def mcp_tool_bundles, do: []
  @impl true
  def runtime_channel_events, do: []
  @impl true
  def handle_runtime_event(_event, _runtime_id, _payload), do: :ok
  @impl true
  def runtime_disconnected(_runtime_id), do: :ok
  @impl true
  def live_hooks, do: []
  @impl true
  def experiment_surfaces, do: []
  @impl true
  def experiment_metrics, do: %{}
  @impl true
  def migrations_path, do: nil
  @impl true
  def routes, do: []
  @impl true
  def inbox_kinds, do: []
  @impl true
  def live_pages, do: []
end

defmodule PlatformWeb.Components.MoreSheetTest do
  @moduledoc """
  The More sheet's rows, order, copy and states (task 01a1557a-807f stage 2).

  One ordered list (`IconRail.more_sheet_order/0`) of module rows, extension
  rows right after Inbox, no headings, and Settings pinned in the footer. Paint
  is stage 3 and dismissal stage 4; neither is asserted here.

  async: false — flips `:mail_enabled` and `:extensions`.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.MoreSheet

  alias PlatformWeb.Components.IconRail

  defp put_env(key, value) do
    previous = Application.fetch_env(:platform, key)
    Application.put_env(:platform, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:platform, key, v)
        :error -> Application.delete_env(:platform, key)
      end
    end)
  end

  defp render_more_sheet(assigns) do
    assigns =
      Map.merge(
        %{
          open: true,
          root_user: false,
          current_user: nil,
          current_path: nil,
          inbox_unread_count: 0
        },
        assigns
      )

    rendered_to_string(~H"""
    <.more_sheet
      open={@open}
      root_user={@root_user}
      current_user={@current_user}
      current_path={@current_path}
      inbox_unread_count={@inbox_unread_count}
    />
    """)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  # Encoded LiveView JS is a JSON list of [kind, args] commands.
  defp encoded_js?(value) do
    case Jason.decode(value || "") do
      {:ok, [_ | _] = cmds} -> Enum.all?(cmds, &match?([kind, %{}] when is_binary(kind), &1))
      _ -> false
    end
  end

  defp row_keys(html) do
    html
    |> doc()
    |> LazyHTML.query(".more-sheet-list .more-sheet-row[data-destination]")
    |> LazyHTML.attribute("data-destination")
  end

  defp current_keys(html) do
    html
    |> doc()
    |> LazyHTML.query(~s([aria-current="page"]))
    |> LazyHTML.attribute("data-destination")
  end

  describe "order" do
    test "root admin, Mail on, fixture extension: the exact row sequence, Settings in the footer" do
      put_env(:mail_enabled, true)
      Platform.FixtureExtension.register()
      html = render_more_sheet(%{root_user: true})

      assert row_keys(html) ==
               ~w(inbox fixture calendar email files canvases skills context agents experiments changelog)

      footer = html |> doc() |> LazyHTML.query(".sheet-actions [data-destination=settings]")
      assert Enum.count(footer) == 1
      # The Settings row is not in the scrolling list.
      refute html
             |> doc()
             |> LazyHTML.query(".sheet-body [data-destination=settings]")
             |> Enum.any?()
    end

    test "the order list holds Canvases (a row, after Files) and Games (a row only with games)" do
      assert IconRail.more_sheet_order() ==
               [
                 :inbox,
                 :calendar,
                 :email,
                 :files,
                 :canvases,
                 :games,
                 :skills,
                 :context,
                 :agents,
                 :experiments,
                 :changelog
               ]

      keys = row_keys(render_more_sheet(%{root_user: true}))
      # Rung 16 stage 3: Canvases renders, directly after Files.
      assert Enum.take(Enum.drop_while(keys, &(&1 != "files")), 2) == ["files", "canvases"]
      # Rung 21: no game_stream kind registered, so no Games row and no gap.
      refute "games" in keys
      assert Enum.take(Enum.drop_while(keys, &(&1 != "canvases")), 2) == ["canvases", "skills"]
    end

    test "with games enabled, Games sits after Canvases and before Skills, linking the browser" do
      Platform.FixtureExtension.register([__MODULE__.GamesExtension])
      assert Platform.Files.Browser.games_enabled?()

      html = render_more_sheet(%{root_user: false})
      keys = row_keys(html)
      assert Enum.take(Enum.drop_while(keys, &(&1 != "canvases")), 3) == ~w(canvases games skills)

      [row] =
        html
        |> doc()
        |> LazyHTML.query(~s(.more-sheet-list [data-destination="games"]))
        |> Enum.to_list()

      assert LazyHTML.attribute(row, "href") == ["/files?tab=browse&type=game"]
      assert row |> LazyHTML.text() |> String.trim() == "Games"
      assert row |> LazyHTML.query(".hero-puzzle-piece") |> Enum.count() == 1
      refute row |> LazyHTML.attribute("phx-click") |> Enum.any?(& &1)
    end

    test "Games is current on the All-games view, and Canvases is not" do
      Platform.FixtureExtension.register([__MODULE__.GamesExtension])

      html = render_more_sheet(%{root_user: true, current_path: "/files?tab=browse&type=game"})
      assert current_keys(html) == ["games"]

      current =
        html |> doc() |> LazyHTML.query(~s([data-destination="games"][aria-current="page"]))

      assert current |> LazyHTML.query(".hero-check") |> Enum.count() == 1

      # Positive control: on the All-canvases view Canvases is current instead.
      html = render_more_sheet(%{root_user: true, current_path: "/files?tab=browse&type=canvas"})
      assert current_keys(html) == ["canvases"]
    end

    test "Canvases links the browser filtered to canvases, with no phx-click" do
      html = render_more_sheet(%{root_user: false})

      [row] =
        html
        |> doc()
        |> LazyHTML.query(~s(.more-sheet-list [data-destination="canvases"]))
        |> Enum.to_list()

      assert LazyHTML.attribute(row, "href") == ["/files?tab=browse&type=canvas"]
      assert LazyHTML.attribute(row, "data-phx-link") == ["redirect"]
      refute row |> LazyHTML.attribute("phx-click") |> Enum.any?(& &1)
    end

    test "Mail off: no Email row and no gap" do
      put_env(:mail_enabled, false)
      keys = row_keys(render_more_sheet(%{root_user: true}))
      refute "email" in keys
      assert Enum.take(keys, 2) == ["inbox", "files"]
    end

    test "no bar tab, no Admin, no Prompts, no Activity row; no headings" do
      html = render_more_sheet(%{root_user: true})
      keys = row_keys(html)

      for key <- ~w(chat tasks meetings admin prompts activity), do: refute(key in keys, key)
      refute html =~ "more-sheet-section-label"
      refute html =~ ">Working<"
      refute html =~ ">Admin<"
    end

    test "an extension row without a hero_icon falls back to hero-puzzle-piece" do
      Platform.FixtureExtension.register([PlatformWeb.Components.MoreSheetTest.IconlessExtension])
      html = render_more_sheet(%{root_user: true})
      row = html |> doc() |> LazyHTML.query(~s(.more-sheet-row[data-destination="iconless"]))
      assert Enum.count(row) == 1
      assert row |> LazyHTML.query(".hero-puzzle-piece") |> Enum.count() == 1
    end
  end

  describe "rows" do
    # Every row is a redirect link and carries no phx-click: the navigation
    # remounts the shell with the sheet closed. A JS.push close on these
    # links was measured never to reach the server (0 of 45 taps), so the
    # remount is the close (task 01a1557a-807f deploy).
    test "every row is a redirect link with no phx-click; the remount closes the sheet" do
      rows = render_more_sheet(%{root_user: true}) |> doc() |> LazyHTML.query(".more-sheet-row")
      assert Enum.count(rows) > 0

      assert LazyHTML.attribute(rows, "phx-click") == []
      assert Enum.uniq(LazyHTML.attribute(rows, "data-phx-link")) == ["redirect"]
    end

    # Task 01a1557a-807f stage 5. On a live link LiveView runs the element's
    # phx-click through liveSocket.execJS/3, which needs encoded JS: a bare
    # event name throws `TypeError: this[kind] is not a function` and pushes
    # nothing. Every live link in the sheet, rows and Settings, in a sheet
    # with a current row and an extension row, must carry encoded JS or none.
    test "no live link in the sheet carries a bare-string phx-click" do
      put_env(:mail_enabled, true)
      Platform.FixtureExtension.register()
      html = render_more_sheet(%{root_user: true, current_path: "/files"})

      links = html |> doc() |> LazyHTML.query("[data-phx-link]")
      # Positive control: the query sees every row and the Settings link.
      assert Enum.count(links) == length(row_keys(html)) + 1

      bare =
        for link <- Enum.to_list(links),
            click = link |> LazyHTML.attribute("phx-click") |> List.first(),
            click != nil and not encoded_js?(click),
            do: {LazyHTML.attribute(link, "data-destination"), click}

      assert bare == []
    end

    test "Inbox carries the count badge with the rail's grammar, after a truncating label" do
      for {n, text} <- [{1, "1"}, {99, "99"}, {150, "99+"}] do
        badge =
          render_more_sheet(%{inbox_unread_count: n})
          |> doc()
          |> LazyHTML.query(~s([data-destination="inbox"] [data-role="more-sheet-inbox-badge"]))

        assert Enum.count(badge) == 1
        assert badge |> LazyHTML.text() |> String.trim() == text
        assert badge |> LazyHTML.attribute("class") |> hd() =~ "shrink-0"
      end

      label =
        render_more_sheet(%{})
        |> doc()
        |> LazyHTML.query(~s([data-destination="inbox"] span.truncate))

      assert label |> LazyHTML.attribute("class") |> hd() =~ "min-w-0"
    end

    test "the badge is primary (stage 3 paint) and the sheet root carries more-sheet" do
      html = render_more_sheet(%{inbox_unread_count: 3})

      [class] =
        html
        |> doc()
        |> LazyHTML.query(~s([data-role="more-sheet-inbox-badge"]))
        |> LazyHTML.attribute("class")

      assert class =~ "badge-primary"
      refute class =~ "badge-error"

      root = html |> doc() |> LazyHTML.query("#more-sheet")

      assert root
             |> LazyHTML.attribute("class")
             |> hd()
             |> String.split()
             |> Enum.member?("more-sheet")
    end

    test "the handle is the sheet's Close button and the sheet opts into swipe" do
      doc = render_more_sheet(%{}) |> doc()
      button = LazyHTML.query(doc, "#more-sheet button.sheet-handle-button")
      assert LazyHTML.attribute(button, "aria-label") == ["Close"]
      assert LazyHTML.attribute(button, "phx-click") == ["close_more_sheet"]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#more-sheet"), "data-swipe-dismiss") == [
               "true"
             ]

      assert doc |> LazyHTML.query("#more-sheet .sheet-close-button") |> Enum.count() == 0
    end

    test "Settings sits in the footer, outside the scrolling body" do
      html = render_more_sheet(%{})

      assert html
             |> doc()
             |> LazyHTML.query(".sheet-body [data-destination=settings]")
             |> Enum.count() == 0

      assert html
             |> doc()
             |> LazyHTML.query("footer.sheet-actions [data-destination=settings]")
             |> Enum.count() == 1
    end

    test "no badge at 0" do
      badge =
        render_more_sheet(%{inbox_unread_count: 0})
        |> doc()
        |> LazyHTML.query(~s([data-role="more-sheet-inbox-badge"]))

      assert Enum.count(badge) == 0
    end
  end

  describe "Settings row" do
    test "links to /settings with the name and the master's subtitle shape in text-subtle" do
      html = render_more_sheet(%{current_user: "Robin"})
      row = html |> doc() |> LazyHTML.query("[data-destination=settings]")

      assert LazyHTML.attribute(row, "href") == ["/settings"]

      assert LazyHTML.attribute(row, "phx-click") == []
      assert LazyHTML.attribute(row, "data-phx-link") == ["redirect"]

      assert row |> LazyHTML.text() =~ "Settings"

      subtitle = row |> LazyHTML.query("[data-role=more-sheet-settings-subtitle]")
      assert subtitle |> LazyHTML.text() |> String.trim() == "Robin · profile, appearance, admin"
      assert subtitle |> LazyHTML.attribute("class") |> hd() =~ "text-subtle"
      assert subtitle |> LazyHTML.attribute("class") |> hd() =~ "truncate"
    end

    test "the sheet carries no sign-out link (it moved to /settings)" do
      html = render_more_sheet(%{current_user: "Robin", root_user: true})
      refute html =~ "/auth/logout"
      refute html =~ "Sign out"
      refute html =~ "more-sheet-profile"
    end
  end

  describe "current row" do
    test "the row whose path wins the rails' longest-prefix match is current" do
      cases = [
        {"/files", "files"},
        {"/files/abc", "files"},
        # Rung 16 stage 3: FilesLive passes the All-canvases view through in
        # one canonical form; every other /files URL keeps Files current.
        {"/files?tab=browse&type=canvas", "canvases"},
        {"/files?tab=browse", "files"},
        {"/files?tab=browse&type=doc", "files"},
        {"/control/experiments", "experiments"},
        {"/control/experiments/x", "experiments"},
        {"/control", "agents"},
        {"/control/some-agent", "agents"},
        {"/control/usage", "settings"},
        {"/settings", "settings"},
        {"/admin", "settings"},
        {"/admin/users", "settings"},
        {"/admin/prompts", "settings"},
        {"/changelog", "changelog"}
      ]

      for {path, key} <- cases do
        html = render_more_sheet(%{root_user: true, current_path: path})
        assert current_keys(html) == [key], path

        current =
          html |> doc() |> LazyHTML.query(~s([data-destination="#{key}"][aria-current="page"]))

        assert current |> LazyHTML.attribute("class") |> hd() =~ "more-sheet-row--current", path
        assert current |> LazyHTML.query(".hero-check") |> Enum.count() == 1, path
      end
    end

    test "no row is current on a bar page" do
      for path <- ["/chat", "/tasks", "/meetings"] do
        html = render_more_sheet(%{root_user: true, current_path: path})
        assert current_keys(html) == [], path
        refute html =~ "hero-check", path
      end
    end
  end

  # An iPhone's visible sheet (Safari's 390x664 on a 390x844 phone, 375x667
  # on an SE) is 100dvh - 48px - the bar's clearance: 544px. With 52px rows
  # the last two rows sat below it and nothing said the list scrolls. Rows
  # are now exactly the 44px touch-target floor (taller and ten rows no
  # longer fit, shorter and they are not a touch target), and a scroll cue
  # covers shorter screens. Measured in headless Chrome against the built
  # CSS when this landed; these pin the inputs to that measurement.
  describe "fits an iPhone, with a scroll cue when it cannot" do
    @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)

    defp more_rule(selector) do
      rules =
        @app_css_path
        |> File.read!()
        |> Platform.Design.CssRules.rules()
        |> Enum.filter(&(&1.selector == selector and &1.at == []))

      case rules do
        [rule] -> rule.body
        other -> flunk("expected one `#{selector}` rule, found #{length(other)}")
      end
    end

    defp px(body, property) do
      case Regex.run(~r/(?:^|[;{\s])#{property}:\s*(-?\d+)px;/, body) do
        [_, n] -> String.to_integer(n)
        nil -> flunk("no `#{property}: <n>px` in #{inspect(body)}")
      end
    end

    test "rows and the Settings row are a 44px touch target, and no taller" do
      for selector <- [".more-sheet-row", ".more-sheet-settings"] do
        assert px(more_rule(selector), "min-height") == 44, selector
      end

      refute more_rule(".more-sheet-row") =~ ~r/(?:^|[;\s])height:/
    end

    test "the cue renders once, hidden from AT, just before the last row" do
      put_env(:mail_enabled, true)
      html = render_more_sheet(%{root_user: true})

      cue = html |> doc() |> LazyHTML.query(~s(.more-sheet-list [data-role="more-sheet-cue"]))
      assert Enum.count(cue) == 1
      assert LazyHTML.attribute(cue, "aria-hidden") == ["true"]

      # Its next sibling is the last row, the one that covers it at the end.
      assert html
             |> doc()
             |> LazyHTML.query(
               ~s(.more-sheet-list > [data-role="more-sheet-cue"] + .more-sheet-row:last-child)
             )
             |> LazyHTML.attribute("data-destination") == ["changelog"]

      # It is not a row: the row list is unchanged by it.
      refute "more-sheet-cue" in row_keys(html)
    end

    test "the cue sticks to the list's bottom, takes no space, and the last row covers it" do
      cue = more_rule(".more-sheet-cue")
      assert cue =~ ~r/position:\s*sticky;/
      assert cue =~ ~r/(?:^|[;\s])bottom:\s*0;/
      assert px(cue, "margin-bottom") == -px(cue, "height")
      assert cue =~ ~r/pointer-events:\s*none;/
      # Shorter than a row, so the last row hides all of it.
      assert px(cue, "height") < px(more_rule(".more-sheet-row"), "min-height")

      assert more_rule(".more-sheet-row:last-child") =~
               ~r/background-color:\s*var\(--color-base-100\);/
    end
  end
end

defmodule PlatformWeb.Components.MoreSheetScopeTest do
  @moduledoc """
  The More sheet through real Scopes (task 01a1557a-807f stage 2): members,
  guests, and the Changelog row against `activity.read`.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.MoreSheet
  alias PlatformWeb.ModuleGate

  defp user!(role, org_id, external? \\ false) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "more-sheet-#{n}@example.com",
        name: "More Sheet #{n}",
        oidc_sub: "more-sheet-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: role,
      external: external?
    })
    |> Repo.insert!()

    user
  end

  defp scope(user), do: Scope.for_user(Platform.Accounts.get_user(user.id))

  defp keys(scope) do
    assigns = %{scope: scope}

    rendered_to_string(~H"""
    <MoreSheet.more_sheet open={true} access_scope={@scope} current_user="X" />
    """)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".more-sheet-list .more-sheet-row[data-destination]")
    |> LazyHTML.attribute("data-destination")
  end

  test "a member has no Prompts or Admin row; a root admin has neither either (both on /settings)" do
    for user <- [user!("member", acme_org_id()), user!("admin", acme_org_id())] do
      ks = keys(scope(user))
      assert "files" in ks
      refute "admin" in ks
      refute "prompts" in ks
    end
  end

  test "a guest Scope gets only what Scope admits: no module row" do
    guest = user!("member", tenant_org_id("more-sheet-guest"), true)
    s = scope(guest)
    assert Scope.guest?(s)
    assert keys(s) == []
  end

  test "Changelog is present exactly when /changelog would mount" do
    member = user!("member", acme_org_id())
    with_read = scope(member)

    assert ModuleGate.mounts?(with_read, PlatformWeb.ChangelogLive)
    assert "changelog" in keys(with_read)

    {:ok, _} =
      Grants.deny(%{
        principal: {:user, member.id},
        permission: "activity",
        resource: {:module, acme_org_id()}
      })

    without = scope(member)
    refute ModuleGate.mounts?(without, PlatformWeb.ChangelogLive)
    refute "changelog" in keys(without)
    # Positive control: the lock removed Changelog and nothing else it should not.
    assert "files" in keys(without)
  end
end
