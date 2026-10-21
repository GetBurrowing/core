defmodule PlatformWeb.Components.MoreSheetTest.IconlessExtension do
  @moduledoc false
  # An extension whose rail item carries no hero_icon (Saru rule 5 fallback).
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

defmodule PlatformWeb.Components.MoreSheetTest do
  @moduledoc """
  The More sheet's rows, order, copy and states (task 01a1557a-807f stage 2).

  One ordered list (`IconRail.more_sheet_order/0`) of module rows, extension
  rows after Changelog, no headings, and Settings pinned in the footer. Paint
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
               ~w(inbox email files skills context agents experiments changelog fixture)

      footer = html |> doc() |> LazyHTML.query(".sheet-actions [data-destination=settings]")
      assert Enum.count(footer) == 1
      # The Settings row is not in the scrolling list.
      refute html
             |> doc()
             |> LazyHTML.query(".sheet-body [data-destination=settings]")
             |> Enum.any?()
    end

    test "the order list reserves Canvases and Games, which render nothing (no page yet)" do
      assert IconRail.more_sheet_order() ==
               [
                 :inbox,
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
      refute "canvases" in keys
      refute "games" in keys
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
