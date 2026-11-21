defmodule PlatformWeb.MoreLiveTest do
  @moduledoc """
  `/more` (task 01a1fc7f stage 2): the More sheet's rows as a page in the
  content area, the open iPhone Duo's More tab.

  The page must show exactly the sheet's destinations for the same actor, so
  each case compares the rows inside `#more-page` with the rows of the
  (closed) shell sheet rendered on the same response, for a root admin and a
  plain member.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.{ModuleGate, MoreLive}

  defp user!(role) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "more-#{n}@example.com",
        name: "More User #{n}",
        oidc_sub: "more-#{n}",
        preferences: %{"first_run_goal" => "existing"}
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: role})
    |> Repo.insert!()

    user
  end

  defp authed(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp query(html, selector), do: html |> LazyHTML.from_document() |> LazyHTML.query(selector)

  defp keys(html, selector), do: html |> query(selector) |> LazyHTML.attribute("data-destination")

  defp page_keys(html), do: keys(html, "#more-page [data-destination]")
  defp sheet_keys(html), do: keys(html, "#more-sheet [data-destination]")

  for role <- ["admin", "member"] do
    test "#{role}: the page shows exactly the sheet's destinations, Settings last" do
      {:ok, view, _html} = live(authed(user!(unquote(role))), "/more")
      html = render(view)

      page = page_keys(html)
      assert page != []
      assert page == sheet_keys(html)
      assert List.last(page) == "settings"
      assert "files" in page
    end
  end

  test "the admin sees more rows than the member, and the page follows the scope" do
    {:ok, admin_view, _} = live(authed(user!("admin")), "/more")
    {:ok, member_view, _} = live(authed(user!("member")), "/more")

    admin = page_keys(render(admin_view))
    member = page_keys(render(member_view))

    # The member's rows are a subset of the admin's.
    assert member -- admin == []
    assert length(admin) >= length(member)
  end

  test "a tab root: one h1 More, no back control, rows are links" do
    {:ok, view, _} = live(authed(user!("member")), "/more")
    html = render(view)

    assert html |> query("#more-page h1") |> Enum.map(&String.trim(LazyHTML.text(&1))) == ["More"]
    assert html |> query("#more-page [data-native-back]") |> Enum.count() == 0
    assert html |> query(~s(#more-page [phx-click="open_more_sheet"])) |> Enum.count() == 0

    rows = query(html, "#more-page [data-destination]")
    assert Enum.all?(rows, &(LazyHTML.tag(&1) == ["a"]))

    assert html |> query("#more-page a[data-destination=settings]") |> LazyHTML.attribute("href") ==
             ["/settings"]
  end

  test "no sheet chrome inside main: no #more-sheet, handle, scrim, close or scroll cue" do
    {:ok, view, _} = live(authed(user!("member")), "/more")
    html = render(view)

    for selector <- [
          "#more-sheet",
          ".sheet-handle",
          ".sheet-handle-button",
          ".sheet-backdrop",
          "[data-swipe-dismiss]",
          "[data-role=more-sheet-cue]"
        ] do
      assert html |> query("main[data-scroll-container] #{selector}") |> Enum.count() == 0,
             selector
    end

    # Positive control: the shell's closed sheet is still on the page, outside main.
    assert html |> query("#more-sheet") |> Enum.count() == 1
    assert html |> query("main[data-scroll-container] #more-page") |> Enum.count() == 1
  end

  test "More is the selected tab, here and on the native bridge" do
    {:ok, view, _} = live(authed(user!("member")), "/more")
    html = render(view)

    assert html
           |> query(~s(#bottom-nav [data-destination="more"].bottom-nav-tab--active))
           |> Enum.count() == 1

    assert html |> query("#native-tab-bridge") |> LazyHTML.attribute("data-active-key") == [
             "more"
           ]

    assert html |> query("#tab-switch-cache") |> LazyHTML.attribute("data-current") == ["more"]
  end

  test "labels may wrap: the page's labels clamp to two lines, never truncate" do
    {:ok, view, _} = live(authed(user!("member")), "/more")
    html = render(view)

    classes =
      html |> query("#more-page .more-sheet-row span.min-w-0") |> LazyHTML.attribute("class")

    assert classes != []
    assert Enum.all?(classes, &(&1 =~ "line-clamp-2"))
    refute Enum.any?(classes, &(&1 =~ "truncate"))
  end

  test "ungated, like Settings" do
    assert MoreLive in ModuleGate.ungated_views()
  end
end
