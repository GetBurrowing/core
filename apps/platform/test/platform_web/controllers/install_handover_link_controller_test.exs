defmodule PlatformWeb.InstallHandoverLinkControllerTest do
  @moduledoc """
  `POST /api/install/handover-link`: bearer-authenticated with the install's
  STATIC_API_KEY, returns the owner's durable link. An unknown email is a 404
  unless the installer also sends the pocket-id `sub`, in which case the
  Burrow user is created the way an invite creates it.
  """
  # async: false: sets the API key in the application env.
  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.SignIn.DurableLink

  @key "install-test-key-0123456789"

  setup do
    prev = Application.fetch_env(:platform, :sign_in_admin_api_key)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:platform, :sign_in_admin_api_key, v)
        :error -> Application.delete_env(:platform, :sign_in_admin_api_key)
      end
    end)

    Application.put_env(:platform, :sign_in_admin_api_key, @key)
    :ok
  end

  defp post_link(conn, body, key \\ @key) do
    conn = if key, do: put_req_header(conn, "authorization", "Bearer " <> key), else: conn
    post(conn, "/api/install/handover-link", body)
  end

  defp token_of(url) do
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("token")
  end

  test "requires the bearer key", %{conn: conn} do
    for key <- [nil, "wrong-key", ""] do
      conn = post_link(conn, %{"email" => "owner@example.test", "sub" => "s"}, key)
      assert conn.status == 404
    end

    # A blank configured key authorises nobody, not even a blank bearer.
    Application.put_env(:platform, :sign_in_admin_api_key, "")
    assert post_link(conn, %{"email" => "a@example.test"}, "").status == 404
  end

  test "an unknown email with no sub is 404 and creates nothing", %{conn: conn} do
    conn = post_link(conn, %{"email" => "nobody@example.test"})
    assert conn.status == 404
    assert %{"error" => "no_such_user"} = json_response(conn, 404)
    assert Accounts.list_users(include_archived: true, query: "nobody@example.test") == []
  end

  test "a known email returns a URL that verifies for that user", %{conn: conn} do
    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        sub: "known-sub",
        email: "known@example.test",
        name: "Known"
      })

    conn = post_link(conn, %{"email" => " Known@Example.test "})
    assert %{"url" => url} = json_response(conn, 200)
    assert url =~ "/auth/link?token="
    assert {:ok, %{user_id: id, purpose: :handover}} = url |> token_of() |> DurableLink.verify()
    assert id == user.id
  end

  test "an unknown email with a sub creates the user, and the link verifies", %{conn: conn} do
    conn = post_link(conn, %{"email" => "owner@example.test", "sub" => "pocket-owner-1"})
    assert %{"url" => url} = json_response(conn, 200)
    assert {:ok, %{user: user}} = url |> token_of() |> DurableLink.verify()
    assert user.oidc_sub == "pocket-owner-1"
    assert user.email == "owner@example.test"

    # Asking again finds the same user rather than creating another.
    again = post_link(build_conn(), %{"email" => "owner@example.test", "sub" => "pocket-owner-1"})
    assert %{"url" => url2} = json_response(again, 200)
    assert {:ok, %{user_id: same}} = url2 |> token_of() |> DurableLink.verify()
    assert same == user.id
  end

  test "an archived user gets 409 and no URL", %{conn: conn} do
    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{sub: "gone-sub", email: "gone@example.test", name: "G"})

    {:ok, _} = Accounts.archive_user(user)
    conn = post_link(conn, %{"email" => "gone@example.test"})
    assert %{"error" => "user_archived"} = json_response(conn, 409)
  end

  test "a missing email is 400", %{conn: conn} do
    assert post_link(conn, %{}).status == 400
  end
end
