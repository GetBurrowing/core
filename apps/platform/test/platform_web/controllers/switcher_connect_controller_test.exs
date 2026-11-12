defmodule PlatformWeb.SwitcherConnectControllerTest do
  @moduledoc """
  Task 01a1ccd4 stage 2: the consent hop on install B,
  `GET|POST /switcher/connect?origin=<A>`, and the sign-in return path that
  brings a signed-out visitor back to it.
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Switcher
  alias Platform.Switcher.BadgeKey

  @a "https://a.example"

  defp member! do
    user = create_user!()

    org =
      Enum.find(Platform.Tenancy.list_orgs(), &(&1.slug == "acme")) ||
        hd(Platform.Tenancy.list_orgs())

    plain_member!(user, org)
    user
  end

  defp signed_in(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp query(html, selector), do: html |> LazyHTML.from_document() |> LazyHTML.query(selector)

  defp text(html, selector),
    do:
      html |> query(selector) |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  describe "GET /switcher/connect" do
    test "signed in: the consent page in the canvas copy", %{conn: conn} do
      user = member!()
      conn = conn |> signed_in(user) |> get(~p"/switcher/connect?origin=#{@a}")
      html = html_response(conn, 200)
      name = Platform.Branding.app_name()

      assert text(html, "[data-role=switcher-consent-title]") ==
               "Show your unread from #{name} in a.example's switcher on this browser?"

      assert html =~ "a.example will get a count of your unread here, and nothing else:"

      assert text(html, "[data-role=switcher-consent-points]") ==
               "No messages, names or spaces It can't sign in as you or act for you " <>
                 "Only on this browser. Turn it off any time in Manage installs"

      assert text(html, "[data-role=switcher-consent-signed-in]") ==
               "Signed in to #{name} as #{user.name}"

      assert text(html, "[data-role=switcher-consent-allow]") == "Allow"
      assert text(html, "[data-role=switcher-consent-cancel]") == "Cancel"

      [form] = query(html, "#switcher-consent-form") |> Enum.to_list()
      assert LazyHTML.attribute(form, "method") == ["post"]
      assert html |> query("#switcher-consent-form input[name=_csrf_token]") |> Enum.count() == 1

      assert html |> query("input[name=origin]") |> LazyHTML.attribute("value") == [@a]

      # Cancel returns to A without a key.
      [cancel] =
        html |> query("[data-role=switcher-consent-cancel]") |> LazyHTML.attribute("href")

      assert %URI{scheme: "https", host: "a.example", path: "/switcher/connected", fragment: f} =
               URI.parse(cancel)

      frag = URI.decode_query(f)
      refute Map.has_key?(frag, "key")
      assert frag["name"] == name
      # B's own host (with its port when not the scheme's default).
      %URI{host: host, port: port} = PlatformWeb.Endpoint.struct_url()
      assert frag["host"] in [host, "#{host}:#{port}"]
      if port not in [80, 443], do: assert(frag["host"] == "#{host}:#{port}")

      # Showing the page mints nothing.
      assert Platform.Repo.aggregate(BadgeKey, :count) == 0
    end

    test "a bad origin renders an error and never redirects", %{conn: conn} do
      user = member!()

      for bad <- [
            "//evil.example",
            "https://evil.example/steal",
            "https://evil.example/#x",
            "http://evil.example",
            "javascript:alert(1)",
            "/\\evil.example",
            "https://user@evil.example",
            ""
          ] do
        conn = conn |> signed_in(user) |> get(~p"/switcher/connect?#{[origin: bad]}")
        assert html_response(conn, 400) =~ "This link doesn't work", inspect(bad)
        assert get_resp_header(conn, "location") == [], inspect(bad)
        refute conn.resp_body =~ "evil.example", inspect(bad)
      end

      conn = conn |> signed_in(user) |> get(~p"/switcher/connect")
      assert conn.status == 400
      assert get_resp_header(conn, "location") == []
    end

    test "signed out: goes to this install's own sign-in, remembering the path", %{conn: conn} do
      conn = get(conn, ~p"/switcher/connect?origin=#{@a}")
      assert redirected_to(conn, 302) == "/auth/login"

      assert get_session(conn, :return_to) ==
               "/switcher/connect?origin=" <> URI.encode_www_form(@a)
    end
  end

  describe "POST /switcher/connect (Allow)" do
    test "mints a key bound to A and hands it over in the fragment", %{conn: conn} do
      user = member!()
      conn = conn |> signed_in(user) |> post(~p"/switcher/connect", %{"origin" => @a})

      location = redirected_to(conn, 302)
      uri = URI.parse(location)

      assert {uri.scheme, uri.host, uri.path, uri.query} ==
               {"https", "a.example", "/switcher/connected", nil}

      frag = URI.decode_query(uri.fragment)
      assert frag |> Map.keys() |> Enum.sort() == ["host", "key", "name"]
      assert frag["name"] == Platform.Branding.app_name()
      assert {:ok, %{id: user_id}, %BadgeKey{bound_origin: @a}} = Switcher.verify(frag["key"], @a)
      assert user_id == user.id
    end

    test "a bad origin mints nothing and never redirects", %{conn: conn} do
      user = member!()

      for bad <- ["//evil.example", "https://evil.example/x", "http://evil.example", nil] do
        conn = conn |> signed_in(user) |> post(~p"/switcher/connect", %{"origin" => bad})
        assert conn.status == 400, inspect(bad)
        assert get_resp_header(conn, "location") == []
      end

      assert Platform.Repo.aggregate(BadgeKey, :count) == 0
    end

    test "signed out: no key and no redirect off-site", %{conn: conn} do
      conn = post(conn, ~p"/switcher/connect", %{"origin" => @a})
      assert redirected_to(conn, 302) == "/auth/login"
      assert Platform.Repo.aggregate(BadgeKey, :count) == 0
    end
  end
end
