defmodule PlatformWeb.SocialLiveInviteReturnTest do
  @moduledoc """
  The invite return in the Social tab (task 01a14ce1, stage 2): the vendor
  sends the invitee back to `/m/social?invite_connect=<nonce>&profileId=&accountId=`
  and SocialLive completes it through the SAME `Platform.Social.complete_connect/4`,
  authorized by the invite (the invitee is not an approver). Zernio traffic
  goes to a `Req.Test` stub ONLY. `async: false`: publisher config and the
  install-level key are global.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, ConnectInvite, Profile, Secrets}
  alias Platform.Social.Publisher.Zernio

  @key "zernio-live-invite-test-key-not-real"
  @profile_ref "zprof_live_invite_1"

  setup do
    previous = Application.get_env(:social, :publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
    Application.put_env(:social, :publisher, Zernio)

    org_id = org_id!()
    {:ok, profile} = Social.create_profile(org_id, %{name: "Invite Brand #{unique()}"})
    approver = make_approver!(org_id, profile, user!())
    invitee = member!(user!(), org_id)
    bystander = member!(user!(), org_id)

    profile =
      Profile
      |> Repo.get!(profile.id)
      |> Ecto.Changeset.change(provider_profile_ref: @profile_ref)
      |> Repo.update!()

    {:ok, _} = Secrets.put_zernio_api_key(@key, approver)
    {:ok, invite, token} = Social.create_invite(org_id, profile, approver.id, "linkedin")

    test = self()

    Req.Test.stub(Zernio, fn conn ->
      send(test, {:zernio_request, conn.method, conn.request_path, conn.query_string})

      body =
        if String.starts_with?(conn.request_path, "/api/v1/connect/"),
          do: %{"authUrl" => "https://zernio.test/oauth"},
          else: %{
            "accounts" => [
              %{
                "_id" => "zacct_person",
                "platform" => "linkedin",
                "profileId" => %{"_id" => @profile_ref},
                "username" => "the-person",
                "isActive" => true
              }
            ]
          }

      conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)
    end)

    {:ok, _url} = Social.start_invite_connect(token, invitee.id, base_url: "https://b.test")
    assert_received {:zernio_request, "GET", "/api/v1/connect/linkedin", query}
    redirect = URI.decode_query(query)["redirect_url"]
    %{"invite_connect" => nonce} = URI.decode_query(URI.parse(redirect).query)

    %{invite: invite, token: token, nonce: nonce, invitee: invitee, bystander: bystander}
  end

  defp land(conn, user, nonce) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)

    {:ok, view, _html} =
      live(
        conn,
        "/m/social?invite_connect=#{nonce}&profileId=#{@profile_ref}&accountId=zacct_person"
      )

    find_live_child(view, "ext-page-social")
  end

  test "the invitee lands, the account connects and they own it", %{conn: conn} = ctx do
    child = land(conn, ctx.invitee, ctx.nonce)
    assert has_element?(child, "[data-role='social-invite-landing'][data-state='success']")

    invite = Repo.get!(ConnectInvite, ctx.invite.id)
    assert invite.used_by_user_id == ctx.invitee.id

    assert %Account{owner_user_id: owner, status: "connected"} =
             Repo.get!(Account, invite.account_id)

    assert owner == ctx.invitee.id
  end

  test "another member landing with the invitee's nonce is refused, nothing written",
       %{conn: conn} = ctx do
    child = land(conn, ctx.bystander, ctx.nonce)

    assert has_element?(
             child,
             "[data-role='social-invite-message']",
             "can't finish this connection"
           )

    refute_received {:zernio_request, _, _, _}

    invite = Repo.get!(ConnectInvite, ctx.invite.id)
    assert invite.used_at == nil

    assert %Account{owner_user_id: nil, status: nil} = Repo.get!(Account, invite.account_id)
  end
end
