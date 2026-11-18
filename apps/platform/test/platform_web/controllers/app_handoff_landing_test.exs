defmodule PlatformWeb.AppHandoffLandingTest do
  @moduledoc """
  Task 01a1e58b stage 1: does the session `GET /auth/app/handoff` writes
  survive the redirect chain that follows it?

  The native app's web view relaunches with `POST /api/app/handoff`
  (bearer) and loads the returned URL. Each test here drives that real
  chain: the handoff response, then every 302 `Location` until a non-302,
  with `recycle/1` between hops so each request carries exactly the
  `Set-Cookie` the previous response sent, and no session set up by hand.

  `GET / 302` alone proves nothing: on a gaming install
  `PlatformWeb.Plugs.GamingLanding` sends `/` to `/play` whether or not
  anyone is signed in, and elsewhere `PageController.home/2` answers 302
  too. These tests assert where the chain ENDS and who it is signed in as.
  """
  # async: false: (c) changes the global `:session_cookie_domain` env and
  # (b) changes the install's branding row.
  use PlatformWeb.ConnCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Mobile
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @max_hops 10

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp app_token!(user) do
    {verifier, challenge} = pkce()
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, %{token: token}} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})
    token
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp member!(overrides \\ %{}) do
    user = create_user!(overrides)
    plain_member!(user, Tenancy.get_org_by_slug!("acme"))
    user
  end

  # POST /api/app/handoff with the bearer, then GET the returned handoff
  # path in a FRESH conn: the web view's cookie store holds nothing yet.
  defp handoff!(user) do
    %{"handoff_url" => handoff_url} =
      build_conn() |> bearer(app_token!(user)) |> post("/api/app/handoff") |> json_response(200)

    %URI{path: path, query: query} = URI.parse(handoff_url)
    get(build_conn(), path <> "?" <> query)
  end

  # Follow every 302 from `conn`, recycling cookies between hops. Returns
  # the final conn and the list of Locations visited, in order.
  defp follow(conn, hops \\ [])

  defp follow(_conn, hops) when length(hops) > @max_hops,
    do: flunk("more than #{@max_hops} redirects: #{inspect(Enum.reverse(hops))}")

  defp follow(%Plug.Conn{status: 302} = conn, hops) do
    location = redirected_to(conn, 302)
    refute String.starts_with?(location, "/auth/login"), "the chain reached #{location}"
    conn |> recycle() |> get(location) |> follow([location | hops])
  end

  defp follow(conn, hops), do: {conn, Enum.reverse(hops)}

  defp set_cookie!(conn) do
    case Enum.filter(get_resp_header(conn, "set-cookie"), &(&1 =~ ~r/^_platform_session=/)) do
      [cookie] -> cookie
      other -> flunk("expected one _platform_session Set-Cookie, got #{length(other)}")
    end
  end

  # Attribute names (and SameSite/Domain values) only; the cookie value is
  # never part of a failure message.
  defp cookie_attrs(cookie) do
    cookie
    |> String.split(";")
    |> tl()
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn attr ->
      case String.split(attr, "=", parts: 2) do
        [name, value] -> {String.downcase(name), value}
        [name] -> {String.downcase(name), true}
      end
    end)
    |> Map.new()
  end

  # RequireAuth ran on the final hop and found this user: its access scope
  # names the user as actor. (A LiveView's dead render overwrites
  # `:current_user` with an assign of its own, so that key is no longer the
  # RequireAuth one by the time the test reads it.)
  defp assert_signed_in(conn, user) do
    assert get_session(conn, :current_user_id) == user.id
    assert %Scope{actor: %User{id: actor_id}} = conn.assigns[:access_scope]
    assert actor_id == user.id
  end

  describe "(a) default install" do
    test "the handoff chain lands on /chat signed in, never /auth/login" do
      user = member!()

      {conn, hops} = user |> handoff!() |> follow()

      assert hops == ["/", "/chat"]
      assert conn.status == 200
      assert_signed_in(conn, user)
    end

    test "a first-run member lands on /start signed in" do
      user = member!(%{preferences: %{}})

      {conn, hops} = user |> handoff!() |> follow()

      assert hops == ["/", "/start"]
      assert conn.status == 200
      assert_signed_in(conn, user)
    end
  end

  describe "(b) gaming install" do
    setup do
      previous = Application.get_env(:platform, :game_publications)
      acme = Tenancy.get_org_by_slug!("acme")

      # A published game, so a signed-OUT /play renders "Sign in with Burrow"
      # (gaming_shell.ex renders that link only when games exist).
      Application.put_env(:platform, :game_publications, [
        %{
          "slug" => "handoff-game",
          "published" => true,
          "org_id" => acme.id,
          "title" => "Handoff game",
          "summary" => "A game for the handoff test.",
          "current_version" => "one",
          "releases" => [
            %{
              "version" => "one",
              "attachment_id" => Ecto.UUID.generate(),
              "sha256" => String.duplicate("a", 64),
              "byte_size" => 1
            }
          ]
        }
      ])

      on_exit(fn -> Application.put_env(:platform, :game_publications, previous || []) end)

      admin =
        Repo.insert!(
          User.changeset(%User{}, %{
            name: "Handoff admin",
            email: "handoff-admin-#{System.unique_integer([:positive])}@example.net",
            oidc_sub: "handoff-admin-#{System.unique_integer([:positive])}"
          })
        )

      Repo.insert!(
        OrgMembership.changeset(%OrgMembership{}, %{
          user_id: admin.id,
          org_id: acme.id,
          role: "admin"
        })
      )

      {:ok, _} = Platform.Branding.update_identity(admin, %{experience: "gaming"})
      assert Platform.Gaming.enabled?()
      :ok
    end

    test "the handoff chain lands in the signed-in game studio" do
      user = member!()

      {conn, hops} = user |> handoff!() |> follow()

      assert hops == ["/", "/play", "/studio"]
      body = html_response(conn, 200)
      doc = LazyHTML.from_document(body)
      assert Enum.count(LazyHTML.query(doc, "#game-studio")) == 1
      refute body =~ "Sign in with Burrow"
    end

    test "control: a signed-out /play shows the sign-in link, not the persona" do
      {conn, hops} = build_conn() |> get("/") |> follow()

      assert hops == ["/play"]
      body = html_response(conn, 200)
      assert Enum.count(LazyHTML.query(LazyHTML.from_document(body), "#gaming-persona")) == 0
      assert body =~ "Sign in with Burrow"
    end
  end

  describe "(c) the handoff response's session cookie" do
    setup do
      previous = Application.get_env(:platform, :session_cookie_domain)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:platform, :session_cookie_domain, previous),
          else: Application.delete_env(:platform, :session_cookie_domain)
      end)

      :ok
    end

    test "is host-only, HttpOnly and SameSite=Lax when no domain is configured" do
      Application.delete_env(:platform, :session_cookie_domain)

      attrs = member!() |> handoff!() |> set_cookie!() |> cookie_attrs()

      assert attrs["httponly"] == true
      assert String.downcase(attrs["samesite"]) == "lax"
      refute Map.has_key?(attrs, "domain")
    end

    test "carries the configured Domain when one is set" do
      Application.put_env(:platform, :session_cookie_domain, ".example.net")

      attrs = member!() |> handoff!() |> set_cookie!() |> cookie_attrs()

      assert attrs["domain"] == ".example.net"
      assert attrs["httponly"] == true
      assert String.downcase(attrs["samesite"]) == "lax"
    end
  end
end
