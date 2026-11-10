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

  test "someone else's sub with a new email is refused, and nothing changes", %{conn: conn} do
    {:ok, victim} =
      Accounts.find_or_create_from_oidc(%{
        sub: "taken-sub",
        email: "victim@example.test",
        name: "V"
      })

    conn = post_link(conn, %{"email" => "attacker@example.test", "sub" => "taken-sub"})
    assert %{"error" => "identity_in_use"} = json_response(conn, 409)

    assert Accounts.get_user(victim.id).email == "victim@example.test"
    assert Accounts.list_users(include_archived: true, query: "attacker@example.test") == []
  end

  test "closed for good once a root admin has signed in", %{conn: conn} do
    {:ok, owner} =
      Accounts.find_or_create_from_oidc(%{
        sub: "owner-sub",
        email: "owner@example.test",
        name: "O"
      })

    membership!(owner, "admin")
    # Open before the owner's first sign-in.
    assert %{"url" => _} = json_response(post_link(conn, %{"email" => "owner@example.test"}), 200)

    {:ok, _} =
      Platform.Audit.record(%{
        event_type: "platform.auth.callback",
        actor_id: owner.id,
        actor_type: "user",
        resource_type: "session",
        resource_id: owner.id,
        action: "success"
      })

    for body <- [
          %{"email" => "owner@example.test"},
          %{"email" => "new@example.test", "sub" => "fresh-sub"}
        ] do
      conn = post_link(build_conn(), body)
      assert %{"error" => "handover_closed"} = json_response(conn, 410)
    end

    assert Accounts.list_users(include_archived: true, query: "new@example.test") == []
  end

  test "a member's sign-in does not close it; the owner's hand-over mark does", %{conn: conn} do
    {:ok, member} =
      Accounts.find_or_create_from_oidc(%{sub: "m-sub", email: "member@example.test", name: "M"})

    membership!(member, "member")

    {:ok, _} =
      Platform.Audit.record(%{
        event_type: "platform.auth.callback",
        actor_id: member.id,
        actor_type: "user",
        resource_type: "session",
        resource_id: member.id,
        action: "success"
      })

    assert %{"url" => _} =
             json_response(post_link(conn, %{"email" => "member@example.test"}), 200)

    {:ok, owner} =
      Accounts.find_or_create_from_oidc(%{sub: "o-sub", email: "owner@example.test", name: "O"})

    membership!(owner, "admin")
    :ok = Platform.Onboarding.OwnerHandover.complete(owner)
    assert post_link(build_conn(), %{"email" => "member@example.test"}).status == 410
  end

  # `find_or_create_from_oidc` already seats the user in the root org as a
  # member; this sets the role the test needs.
  defp membership!(user, role) do
    membership =
      Platform.Repo.get_by!(Platform.Tenancy.OrgMembership,
        user_id: user.id,
        org_id: Platform.TenancyFixtures.acme_org_id()
      )

    membership
    |> Ecto.Changeset.change(role: role)
    |> Platform.Repo.update!()
  end

  test "a missing email is 400", %{conn: conn} do
    assert post_link(conn, %{}).status == 400
  end
end
