defmodule PlatformWeb.ExtensionPageLiveTest do
  @moduledoc """
  The `live_pages/0` reader at `/m/:prefix` (`PlatformWeb.ExtensionPageLive`).

  POSITIVE CONTROL: `Platform.FixtureExtension` claims `fixture`, and its
  page must render inside core's shell for a member. With no extension
  registered (this project's own build), and for an unclaimed prefix or an
  external user, the route is a 404.

  NOT async: every case writes `:platform, :extensions` (global app env).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.FixtureExtension
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ExtensionPageLive

  defp user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "ext-page-#{label}-#{n}@example.com",
      name: "Ext page #{label} #{n}",
      oidc_sub: "ext-page-#{label}-#{n}"
    })
    |> Repo.insert!()
  end

  defp member!(user, org_id, external \\ false) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: "member",
      external: external
    })
    |> Repo.insert!()

    user
  end

  defp login(conn, user), do: init_test_session(conn, current_user_id: user.id)

  setup do
    org_id =
      Platform.TenancyFixtures.tenant_org_id("ext-page-#{System.unique_integer([:positive])}")

    %{org_id: org_id, member: member!(user!("member"), org_id)}
  end

  describe "with the fixture extension registered" do
    setup do
      FixtureExtension.register()
      :ok
    end

    test "/m/fixture renders the fixture page inside the shell, given only the user id",
         %{conn: conn, member: member} do
      {:ok, view, html} = live(login(conn, member), "/m/fixture")

      # The shell: core's rail is on the page around the nested LiveView.
      assert html =~ "data-bottom-rail"
      assert has_element?(view, "#ext-page-fixture-host")

      child = find_live_child(view, "ext-page-fixture")
      assert child
      assert has_element?(child, "[data-role='fixture-page'][data-user-id='#{member.id}']")
      # LiveView merges the signed-in conn's own session into every
      # LiveView's; what CORE adds on top is exactly one key, the user id.
      [keys] =
        child
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-role='fixture-page']")
        |> LazyHTML.attribute("data-session-keys")

      assert String.split(keys, ",") -- ["_csrf_token", "current_user_id"] == ["user_id"]
      assert page_title(view) =~ "Fixture page"
      # The shell's top bar names the page, not the generic host module.
      assert html =~ "Fixture page"
      refute html =~ "ExtensionPage"
    end

    test "an unclaimed prefix is a 404", %{conn: conn, member: member} do
      assert_error_sent(404, fn -> get(login(conn, member), "/m/nope") end)
    end

    test "an external user never reaches the page", %{conn: conn, org_id: org_id} do
      ext = user!("ext") |> member!(org_id, true)

      # The external-scope plug answers first over HTTP (403); the page's own
      # check is the second layer, exercised directly below.
      conn = get(login(conn, ext), "/m/fixture")
      assert conn.status in [403, 404]
      refute conn.resp_body =~ "fixture-page"

      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user_record: ext}}

      assert_raise ExtensionPageLive.NotFoundError, fn ->
        ExtensionPageLive.mount(%{"prefix" => "fixture"}, %{}, socket)
      end
    end

    test "the page's own check refuses a missing user and an unclaimed prefix", %{member: member} do
      for {prefix, user} <- [{"fixture", nil}, {"nope", member}] do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user_record: user}}

        assert_raise ExtensionPageLive.NotFoundError, fn ->
          ExtensionPageLive.mount(%{"prefix" => prefix}, %{}, socket)
        end
      end
    end
  end

  describe "with no extension registered" do
    setup do
      FixtureExtension.register([])
      :ok
    end

    test "every /m/<prefix> is a 404", %{conn: conn, member: member} do
      assert_error_sent(404, fn -> get(login(conn, member), "/m/fixture") end)
    end
  end
end
