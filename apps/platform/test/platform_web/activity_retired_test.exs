defmodule PlatformWeb.ActivityRetiredTest do
  @moduledoc """
  The Activity page is retired (task 01a1557a-7a71-7000-8580-75565039bffe,
  Burrow redesign 4, stage 4): no route, no LiveView, no rail tile.

  What did NOT go, and why it is held here: the `activity` access module, its
  `activity.read` permission and the registry's `:activity` rail entry. They
  gate /changelog (`PlatformWeb.ModuleGate` maps ChangelogLive to
  `{:activity, nil}`, and `Platform.Access.module_access?/3` fails CLOSED when
  `Registry.rail_entry(:activity)` is missing), so deleting them along with the
  page would lock every user out of the changelog. The last test is that trap.
  """
  use PlatformWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Platform.Access.Registry
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.IconRail

  defp member! do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "activity-retired-#{n}@example.com",
        name: "Activity Retired #{n}",
        oidc_sub: "oidc-activity-retired-#{n}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp authed(conn, user), do: init_test_session(conn, current_user_id: user.id)

  test "GET /activity as a signed-in member is a 404", %{conn: conn} do
    user = member!()

    # Positive control on the same conn shape: a live route answers 200.
    assert conn |> authed(user) |> get("/tasks") |> html_response(200)

    # The router's not-found path answers 404 itself (no raised error).
    assert build_conn() |> authed(user) |> get("/activity") |> response(404)
  end

  test "neither rail renders an Activity tile" do
    assigns = %{}

    desktop =
      rendered_to_string(~H"""
      <PlatformWeb.Components.Sidebar.sidebar current_path="/chat" root_user={true} />
      """)

    mobile =
      rendered_to_string(~H"""
      <IconRail.bottom_rail current_path="/chat" root_user={true} />
      """)

    # Control: the rails render tiles at all, so an absence means something.
    assert desktop =~ ~s(data-destination="chat")
    assert mobile =~ ~s(data-destination="chat")

    refute desktop =~ ~s(data-destination="activity")
    refute mobile =~ ~s(data-destination="activity")
    refute Enum.any?(IconRail.destinations(root_user: true), &(&1.key == :activity))
  end

  test "/changelog still mounts for a member: the activity module and rail entry stay", %{
    conn: conn
  } do
    assert Registry.rail_entry(:activity), "the :activity rail entry gates /changelog; keep it"

    user = member!()
    assert {:ok, _view, _html} = conn |> authed(user) |> live("/changelog")
  end
end
