defmodule PlatformWeb.UserAccessLiveTest do
  @moduledoc """
  Coverage for the User Access admin surface (task 019f671f Stage 6).

  Exercises the LV surface end-to-end:

    * `:ensure_admin` gate keeps non-admins out (regression on the
      `PlatformWeb.LiveAuth` hook installed on the `:admin` live_session).
    * Default view drops archived users; archived count is present.
    * Toggle reveals archived rows and the count is honest.
    * `archive` on another user flips all three archive columns.
    * `archive` on self is refused server-side AND rendered `disabled`
      client-side; DB row unchanged.
    * `unarchive` clears all three columns.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "user-access-#{n}@example.com",
          name: "User Access #{n}",
          oidc_sub: "oidc-user-access-#{n}"
        },
        overrides
      )

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  defp promote_to_admin!(user) do
    acme = Tenancy.get_org_by_slug!("acme")
    create_membership!(user, acme, "admin")
    user
  end

  defp authenticated_conn(conn, user) do
    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  defp reload(%User{id: id}), do: Repo.get(User, id)

  describe "admin gate" do
    test "non-admin (member) is redirected away from /admin/users", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "member")

      assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/users")
    end

    test "user with no memberships is redirected away", %{conn: conn} do
      user = create_user!()

      assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
               conn |> authenticated_conn(user) |> live(~p"/admin/users")
    end
  end

  describe "default view (archived hidden)" do
    test "admin sees active users and NOT archived users", %{conn: conn} do
      admin = create_user!(%{name: "Admin AA"}) |> promote_to_admin!()
      _active = create_user!(%{name: "Active BB"})
      archived = create_user!(%{name: "Archived CC"})
      {:ok, _} = Accounts.archive_user(archived, actor: admin)

      {:ok, view, html} = conn |> authenticated_conn(admin) |> live(~p"/admin/users")

      assert html =~ "Active BB"
      assert html =~ "Admin AA"
      # Selector-based check: the archived user's row is not rendered.
      refute has_element?(view, ~s(tr[data-user-id="#{archived.id}"]))
      # Toggle badge reports 1 archived (the CC row).
      assert html =~ "Show archived (1)"
    end
  end

  describe "toggle_show_archived" do
    test "reveals archived rows and updates the toggle copy + count", %{conn: conn} do
      admin = create_user!(%{name: "Admin DD"}) |> promote_to_admin!()
      _active = create_user!(%{name: "Active EE"})
      archived_a = create_user!(%{name: "Archived FF"})
      archived_b = create_user!(%{name: "Archived GG"})
      {:ok, _} = Accounts.archive_user(archived_a, actor: admin)
      {:ok, _} = Accounts.archive_user(archived_b, actor: admin)

      {:ok, view, html} = conn |> authenticated_conn(admin) |> live(~p"/admin/users")
      # Neither archived row is present before the toggle.
      refute has_element?(view, ~s(tr[data-user-id="#{archived_a.id}"]))
      refute has_element?(view, ~s(tr[data-user-id="#{archived_b.id}"]))
      assert html =~ "Show archived (2)"

      html_after =
        view
        |> element(~s(button[data-role="toggle-show-archived"]))
        |> render_click()

      # After toggling, both archived rows render.
      assert has_element?(view, ~s(tr[data-user-id="#{archived_a.id}"][data-archived="true"]))
      assert has_element?(view, ~s(tr[data-user-id="#{archived_b.id}"][data-archived="true"]))
      # Toggle flips to "Hide archived" with the same true count.
      assert html_after =~ "Hide archived (2)"
    end
  end

  describe "archive event" do
    test "archives another user and stamps actor + timestamp", %{conn: conn} do
      admin = create_user!(%{name: "Admin HH"}) |> promote_to_admin!()
      target = create_user!(%{name: "Target II"})

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live(~p"/admin/users")
      # Row is present pre-archive.
      assert has_element?(view, ~s(tr[data-user-id="#{target.id}"][data-archived="false"]))

      view
      |> element(~s(button[phx-click="archive"][phx-value-id="#{target.id}"]))
      |> render_click()

      # Row disappears from the default (active-only) view. Use the
      # selector rather than a text refute — the flash "Archived Target
      # II." would spuriously match the row's display name otherwise.
      refute has_element?(view, ~s(tr[data-user-id="#{target.id}"]))

      # DB row shows all three archive columns set.
      reloaded = reload(target)
      assert %DateTime{} = reloaded.archived_at
      assert reloaded.archived_by_user_id == admin.id
    end

    test "refuses to archive self even if the event fires server-side", %{conn: conn} do
      admin = create_user!(%{name: "Admin JJ"}) |> promote_to_admin!()

      {:ok, view, html} = conn |> authenticated_conn(admin) |> live(~p"/admin/users")

      # DOM renders the self-row button `disabled` with the guard title.
      # The apostrophe is HTML-escaped in the attribute value.
      assert html =~ "You can&#39;t archive yourself"

      assert has_element?(
               view,
               ~s(button[data-role="archive"][data-disabled-reason="self"][disabled])
             )

      # Even if a crafted client dispatches the event with the admin's own
      # id, the server guard flashes an error and does NOT mutate the row.
      result = render_hook(view, "archive", %{"id" => admin.id})

      assert result =~ "You can&#39;t archive yourself"

      reloaded = reload(admin)
      assert is_nil(reloaded.archived_at)
      assert is_nil(reloaded.archived_by_user_id)
    end
  end

  describe "unarchive event" do
    test "clears archived_at, archived_by_user_id, archived_reason", %{conn: conn} do
      admin = create_user!(%{name: "Admin KK"}) |> promote_to_admin!()
      target = create_user!(%{name: "Target LL"})
      {:ok, _} = Accounts.archive_user(target, actor: admin, reason: "left the team")

      # Confirm precondition: all three columns set.
      pre = reload(target)
      assert %DateTime{} = pre.archived_at
      assert pre.archived_by_user_id == admin.id
      assert pre.archived_reason == "left the team"

      # Land on the archived view so the Unarchive button is rendered.
      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live(~p"/admin/users")

      _ =
        view
        |> element(~s(button[data-role="toggle-show-archived"]))
        |> render_click()

      html_after =
        view
        |> element(~s(button[phx-click="unarchive"][phx-value-id="#{target.id}"]))
        |> render_click()

      # After unarchive, still-visible-because-toggle-is-on view shows
      # the row with a Status of "Active" (no "Archived" badge for it).
      assert html_after =~ "Target LL"

      post = reload(target)
      assert is_nil(post.archived_at)
      assert is_nil(post.archived_by_user_id)
      assert is_nil(post.archived_reason)
    end
  end
end
