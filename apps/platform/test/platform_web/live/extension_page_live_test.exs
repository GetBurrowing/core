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

  defp fixture_session(child) do
    node =
      child
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='fixture-page']")

    [keys] = LazyHTML.attribute(node, "data-session-keys")
    [query] = LazyHTML.attribute(node, "data-query")
    %{keys: String.split(keys, ","), query: Jason.decode!(query)}
  end

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

      # With no query string there is no "query" key at all.
      assert String.split(keys, ",") -- ["_csrf_token", "current_user_id"] == ["user_id"]
      assert page_title(view) =~ "Fixture page"
      # The shell's top bar names the page, not the generic host module.
      assert html =~ "Fixture page"
      refute html =~ "ExtensionPage"
    end

    test "a query string adds exactly one key, query, forwarded verbatim",
         %{conn: conn, member: member} do
      {:ok, view, _html} =
        live(login(conn, member), "/m/fixture?connected=linkedin&profileId=p_1&accountId=a-2")

      child = find_live_child(view, "ext-page-fixture")
      %{keys: keys, query: query} = fixture_session(child)

      assert keys -- ["_csrf_token", "current_user_id"] == ["query", "user_id"]

      assert query == %{
               "connected" => "linkedin",
               "profileId" => "p_1",
               "accountId" => "a-2"
             }
    end

    test "prefix, list params, oversized values and oversized keys are dropped",
         %{conn: conn, member: member} do
      long_value = String.duplicate("v", 513)
      long_key = String.duplicate("k", 65)

      url =
        "/m/fixture?keep=ok&prefix=evil&list[]=a&list[]=b&nested[x]=y" <>
          "&big=#{long_value}&#{long_key}=v&edge=#{String.duplicate("e", 512)}"

      {:ok, view, _html} = live(login(conn, member), url)
      %{query: query} = view |> find_live_child("ext-page-fixture") |> fixture_session()

      assert query == %{"keep" => "ok", "edge" => String.duplicate("e", 512)}
    end

    test "only list or oversized params forward nothing: no query key", %{
      conn: conn,
      member: member
    } do
      {:ok, view, _html} =
        live(login(conn, member), "/m/fixture?list[]=a&big=#{String.duplicate("v", 600)}")

      %{keys: keys, query: query} =
        view |> find_live_child("ext-page-fixture") |> fixture_session()

      assert keys -- ["_csrf_token", "current_user_id"] == ["user_id"]
      assert query == nil
    end

    test "at most 16 keys are forwarded", %{conn: conn, member: member} do
      url =
        "/m/fixture?" <> Enum.map_join(1..20, "&", &"k#{String.pad_leading("#{&1}", 2, "0")}=v")

      {:ok, view, _html} = live(login(conn, member), url)
      %{query: query} = view |> find_live_child("ext-page-fixture") |> fixture_session()

      assert map_size(query) == 16
    end

    test "an external user with a query string still never reaches the page",
         %{conn: conn, org_id: org_id} do
      ext = user!("ext-q") |> member!(org_id, true)
      conn = get(login(conn, ext), "/m/fixture?connected=linkedin")
      assert conn.status in [403, 404]
      refute conn.resp_body =~ "fixture-page"

      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user_record: ext}}

      assert_raise ExtensionPageLive.NotFoundError, fn ->
        ExtensionPageLive.mount(%{"prefix" => "fixture", "connected" => "linkedin"}, %{}, socket)
      end
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
