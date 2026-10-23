defmodule PlatformWeb.SocialLiveInviteLandingTest do
  @moduledoc """
  Task 01a14ce1, stage 4: the Connections owner line, the approver's invite
  control (dialog, pending rows, cancel) and the invitee landing page on
  `/m/social?invite=<token>`, in every state. Every event is re-authorized
  server-side, so the forged-event tests drive handlers through
  `render_hook/3`, which the DOM cannot prevent. Zernio traffic goes to a
  `Req.Test` stub ONLY. `async: false`: publisher config and the
  install-level key are global.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{ConnectInvite, Profile, Secrets}
  alias Platform.Social.Publisher.Zernio

  @key "zernio-landing-test-key-not-real"
  @profile_ref "zprof_landing_1"

  setup do
    previous = Application.get_env(:social, :publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
    Application.put_env(:social, :publisher, Zernio)

    org_id = org_id!()
    {:ok, profile} = Social.create_profile(org_id, %{name: "Acme #{unique()}"})
    approver = make_approver!(org_id, profile, user!())
    invitee = member!(user!(), org_id)
    bystander = member!(user!(), org_id)

    profile =
      Profile
      |> Repo.get!(profile.id)
      |> Ecto.Changeset.change(provider_profile_ref: @profile_ref)
      |> Repo.update!()

    {:ok, _} = Secrets.put_zernio_api_key(@key, approver)

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

    %{
      org_id: org_id,
      profile: profile,
      approver: approver,
      invitee: invitee,
      bystander: bystander
    }
  end

  defp child(conn, user, path) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, path)
    find_live_child(view, "ext-page-social")
  end

  defp connections(conn, user) do
    c = child(conn, user, "/m/social")
    c |> element("[data-role='social-tab-button'][data-tab='connections']") |> render_click()
    c
  end

  defp invite!(ctx, attrs \\ []) do
    {:ok, invite, token} =
      Social.create_invite(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin")

    if attrs != [] do
      invite |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end

    {Repo.get!(ConnectInvite, invite.id), token}
  end

  defp landing, do: "[data-role='social-invite-landing']"
  defp state?(c, state), do: has_element?(c, landing() <> "[data-state='#{state}']")

  defp invites, do: Repo.aggregate(ConnectInvite, :count)

  # ── Connections: owner line ──────────────────────────────────────────

  describe "owner line" do
    test "an owned account shows Owner: <name>; an unowned one shows nothing",
         %{conn: conn} = ctx do
      {:ok, owned} =
        Social.create_account(ctx.org_id, ctx.profile, %{
          platform: "linkedin",
          handle: "employee-one"
        })

      {:ok, _} = Social.set_account_owner(ctx.org_id, owned, ctx.invitee.id)

      {:ok, unowned} =
        Social.create_account(ctx.org_id, ctx.profile, %{platform: "youtube", handle: "brand"})

      c = connections(conn, ctx.approver)

      assert has_element?(
               c,
               "#accounts-#{owned.id} [data-role='social-account-owner']",
               "Owner: #{ctx.invitee.name}"
             )

      refute has_element?(c, "#accounts-#{unowned.id} [data-role='social-account-owner']")
    end
  end

  # ── Connections: invite control ──────────────────────────────────────

  describe "invite control" do
    test "an approver sees Invite someone to connect, as a secondary button",
         %{conn: conn} = ctx do
      c = connections(conn, ctx.approver)
      assert has_element?(c, "[data-role='social-invite-open'].btn-secondary")
      refute has_element?(c, "[data-role='social-invite-open'].btn-primary")
    end

    test "a non-approver member does not see the invite button", %{conn: conn} = ctx do
      c = connections(conn, ctx.bystander)
      assert has_element?(c, "[data-pane='connections']")
      refute has_element?(c, "[data-role='social-invite-open']")
    end

    test "the dialog creates a single-use link and the pending row appears",
         %{conn: conn} = ctx do
      c = connections(conn, ctx.approver)
      c |> element("[data-role='social-invite-open']") |> render_click()

      assert has_element?(c, "[data-role='social-invite-dialog'][data-step='form']")
      assert has_element?(c, "[data-role='social-invite-platform'] option[selected]", "LinkedIn")
      assert has_element?(c, "[data-role='social-invite-ttl'] option[selected]", "7 days")

      c
      |> form("#social-invite-form", invite: %{platform: "linkedin", ttl_days: "7"})
      |> render_submit()

      assert has_element?(c, "[data-role='social-invite-dialog'][data-step='created']")

      [url] =
        c
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#social-invite-url")
        |> LazyHTML.attribute("value")

      %{"invite" => token} = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

      assert {:ok, invite} = Social.get_invite_for(token, ctx.invitee.id)

      assert DateTime.diff(invite.expires_at, DateTime.utc_now()) in (7 * 86_400 - 60)..(7 *
                                                                                           86_400)

      expires = Calendar.strftime(invite.expires_at, "%b %-d")

      assert has_element?(
               c,
               "[data-role='social-invite-terms']",
               "Single use. Works for a signed-in Burrow user. Expires #{expires}."
             )

      assert has_element?(c, "#social-invite-url.font-mono[readonly]")
      assert has_element?(c, "[data-role='social-invite-copy'][data-clipboard-text='#{url}']")
      assert has_element?(c, "#invites-#{invite.id}", "Invite for LinkedIn")

      # Closing drops the URL: it is not re-rendered anywhere.
      c |> element("[data-role='social-invite-dialog'] .modal-backdrop") |> render_click()
      refute render(c) =~ token
    end

    test "a pending invite expiring within 24h is marked warning; used and expired drop off",
         %{conn: conn} = ctx do
      {soon, _} = invite!(ctx, expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))
      {later, _} = invite!(ctx)
      {used, _} = invite!(ctx, used_at: DateTime.utc_now())
      {gone, _} = invite!(ctx, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))

      c = connections(conn, ctx.approver)

      assert has_element?(
               c,
               "#invites-#{soon.id} [data-role='social-invite-expiry'].text-warning"
             )

      refute has_element?(c, "#invites-#{later.id} .text-warning")
      refute has_element?(c, "#invites-#{used.id}")
      refute has_element?(c, "#invites-#{gone.id}")
    end

    test "Cancel removes the row and the link stops working", %{conn: conn} = ctx do
      {invite, token} = invite!(ctx)
      c = connections(conn, ctx.approver)

      c |> element("#invites-#{invite.id} [data-role='social-invite-cancel']") |> render_click()

      refute has_element?(c, "#invites-#{invite.id}")
      assert {:error, :cancelled} = Social.get_invite_for(token, ctx.invitee.id)
    end

    test "a non-approver sees no pending invites", %{conn: conn} = ctx do
      {invite, _} = invite!(ctx)
      c = connections(conn, ctx.bystander)
      refute has_element?(c, "#invites-#{invite.id}")
    end

    test "a forged create_invite from a non-approver is refused and writes nothing",
         %{conn: conn} = ctx do
      c = connections(conn, ctx.bystander)
      before = invites()

      render_hook(c, "open_invite", %{})
      refute has_element?(c, "[data-role='social-invite-dialog']")

      render_hook(c, "create_invite", %{
        "invite" => %{"platform" => "linkedin", "ttl_days" => "7"}
      })

      assert invites() == before
      refute has_element?(c, "[data-role='social-invite-url']")
      assert has_element?(c, "[data-role='social-notice']", "Only an approver")
    end

    test "a forged cancel_invite from a non-approver leaves the invite live",
         %{conn: conn} = ctx do
      {invite, token} = invite!(ctx)
      c = connections(conn, ctx.bystander)

      render_hook(c, "cancel_invite", %{"id" => invite.id})

      assert {:ok, _} = Social.get_invite_for(token, ctx.invitee.id)
    end

    test "an approver removed after the page loaded cannot create an invite",
         %{conn: conn} = ctx do
      c = connections(conn, ctx.approver)
      {:ok, _} = Social.update_profile(ctx.org_id, ctx.profile, %{approver_user_ids: []})
      before = invites()

      render_hook(c, "create_invite", %{
        "invite" => %{"platform" => "linkedin", "ttl_days" => "7"}
      })

      assert invites() == before
    end

    test "an expiry outside the offered options is refused", %{conn: conn} = ctx do
      c = connections(conn, ctx.approver)
      before = invites()

      render_hook(c, "create_invite", %{
        "invite" => %{"platform" => "linkedin", "ttl_days" => "365"}
      })

      assert invites() == before
    end
  end

  # ── Landing page ─────────────────────────────────────────────────────

  describe "landing page" do
    test "default: brand headline, inviter and expiry, three bullets, Continue and Not now",
         %{conn: conn} = ctx do
      {invite, token} = invite!(ctx)
      c = child(conn, ctx.invitee, "/m/social?invite=#{token}")

      assert state?(c, "ready")
      refute has_element?(c, "[data-role='social-tabs']")

      assert has_element?(
               c,
               "h1.text-2xl.font-semibold[data-role='social-invite-headline']",
               "Connect your LinkedIn to #{ctx.profile.name}"
             )

      expires = Calendar.strftime(invite.expires_at, "%b %-d")

      assert has_element?(
               c,
               "[data-role='social-invite-meta']",
               "#{ctx.approver.name} invited you. Link expires #{expires}."
             )

      assert has_element?(c, "li.font-semibold", "Nothing posts until you approve it.")
      assert has_element?(c, "[data-role='social-invite-continue'].btn-primary")
      assert has_element?(c, "[data-role='social-invite-not-now'].btn-ghost")
      refute render(c) =~ token
    end

    test "Continue starts the vendor connect for the viewer; only a nonce goes to the vendor",
         %{conn: conn} = ctx do
      {invite, token} = invite!(ctx)
      c = child(conn, ctx.invitee, "/m/social?invite=#{token}")

      assert {:error, {:redirect, %{to: "https://zernio.test/oauth"}}} =
               c |> element("[data-role='social-invite-continue']") |> render_click()

      assert_received {:zernio_request, "GET", "/api/v1/connect/linkedin", query}
      refute query =~ token
      redirect = URI.decode_query(query)["redirect_url"]
      assert %{"invite_connect" => _nonce} = URI.decode_query(URI.parse(redirect).query)

      assert Repo.get!(ConnectInvite, invite.id).started_by_user_id == ctx.invitee.id
    end

    test "Continue re-checks the invite: cancelled after render, no request and no redirect",
         %{conn: conn} = ctx do
      {invite, token} = invite!(ctx)
      c = child(conn, ctx.invitee, "/m/social?invite=#{token}")
      {:ok, _} = Social.cancel_invite(ctx.org_id, invite, ctx.approver.id)

      c |> element("[data-role='social-invite-continue']") |> render_click()

      refute_received {:zernio_request, _, _, _}
      assert state?(c, "cancelled")
      refute has_element?(c, "[data-role='social-invite-continue']")
    end

    test "expired: a warning card naming the date and the inviter, and no button",
         %{conn: conn} = ctx do
      at = DateTime.add(DateTime.utc_now(), -3600, :second)
      {_invite, token} = invite!(ctx, expires_at: at)
      c = child(conn, ctx.invitee, "/m/social?invite=#{token}")

      assert state?(c, "expired")

      assert has_element?(
               c,
               ".alert-warning[data-role='social-invite-message']",
               "This invite expired on #{Calendar.strftime(at, "%b %-d")}. Ask #{ctx.approver.name} for a new one."
             )

      refute has_element?(c, "[data-role='social-invite-continue']")
      refute has_element?(c, landing() <> " button")
    end

    test "a forged Continue on an expired invite sends nothing", %{conn: conn} = ctx do
      {_invite, token} = invite!(ctx, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      c = child(conn, ctx.invitee, "/m/social?invite=#{token}")

      render_hook(c, "invite_continue", %{})

      refute_received {:zernio_request, _, _, _}
      assert state?(c, "expired")
    end

    test "used by the viewer: already used, with a link to the account", %{conn: conn} = ctx do
      {_invite, token} =
        invite!(ctx, used_at: DateTime.utc_now(), used_by_user_id: ctx.invitee.id)

      c = child(conn, ctx.invitee, "/m/social?invite=#{token}")

      assert state?(c, "used")

      assert has_element?(
               c,
               "[data-role='social-invite-message']",
               "This invite was already used."
             )

      assert has_element?(c, "[data-role='social-invite-account-link']")
      refute has_element?(c, "[data-role='social-invite-continue']")
    end

    test "used by someone else: already used, no link", %{conn: conn} = ctx do
      {_invite, token} =
        invite!(ctx, used_at: DateTime.utc_now(), used_by_user_id: ctx.bystander.id)

      c = child(conn, ctx.invitee, "/m/social?invite=#{token}")

      assert state?(c, "used")
      refute has_element?(c, "[data-role='social-invite-account-link']")
      refute has_element?(c, landing() <> " button")
    end

    test "the account link opens that profile's Connections", %{conn: conn} = ctx do
      c =
        child(
          conn,
          ctx.invitee,
          "/m/social?tab=connections&profile=#{ctx.profile.id}"
        )

      assert has_element?(c, "[data-role='social-tab-body'][data-tab='connections']")
    end

    test "cancelled: plain message, no button", %{conn: conn} = ctx do
      {_invite, token} = invite!(ctx, cancelled_at: DateTime.utc_now())
      c = child(conn, ctx.invitee, "/m/social?invite=#{token}")

      assert state?(c, "cancelled")
      assert has_element?(c, "[data-role='social-invite-message']", "This invite was cancelled.")
      refute has_element?(c, landing() <> " button")
    end

    test "forged token: not valid, no button and nothing about the brand", %{conn: conn} = ctx do
      c = child(conn, ctx.invitee, "/m/social?invite=#{String.duplicate("A", 43)}")

      assert state?(c, "invalid")

      assert has_element?(
               c,
               "[data-role='social-invite-message']",
               "This invite link isn't valid."
             )

      refute render(c) =~ ctx.profile.name
      refute has_element?(c, landing() <> " button")
    end

    test "another org's user holding a real token sees not valid", %{conn: conn} = ctx do
      {_invite, token} = invite!(ctx)
      outsider = member!(user!(), org_id!())
      c = child(conn, outsider, "/m/social?invite=#{token}")

      assert state?(c, "invalid")
      refute render(c) =~ ctx.profile.name
    end

    test "signed out: Sign in to continue" do
      {:ok, view, _html} =
        live_isolated(build_conn(), PlatformWeb.SocialLive,
          session: %{"user_id" => nil, "query" => %{"invite" => String.duplicate("A", 43)}}
        )

      assert has_element?(view, "[data-state='signed_out']")
      assert has_element?(view, "a.btn-primary[href='/auth/login']", "Sign in to continue")
    end
  end

  # ── Landing page: the vendor return ──────────────────────────────────

  describe "vendor return" do
    setup ctx do
      {invite, token} = invite!(ctx)
      {:ok, _url} = Social.start_invite_connect(token, ctx.invitee.id, base_url: "https://b.test")
      assert_received {:zernio_request, "GET", "/api/v1/connect/linkedin", query}
      redirect = URI.decode_query(query)["redirect_url"]
      %{"invite_connect" => nonce} = URI.decode_query(URI.parse(redirect).query)
      %{invite: invite, nonce: nonce}
    end

    test "success: connected to the brand, with a link to the owner's DM", %{conn: conn} = ctx do
      c =
        child(
          conn,
          ctx.invitee,
          "/m/social?invite_connect=#{ctx.nonce}&profileId=#{@profile_ref}&accountId=zacct_person"
        )

      assert state?(c, "success")

      assert has_element?(
               c,
               "[data-role='social-invite-message']",
               "Your LinkedIn is connected to #{ctx.profile.name}. Drafts will come to your DM."
             )

      {:ok, dm} = Platform.Social.Approvals.owner_dm(ctx.org_id, ctx.invitee.id)

      assert has_element?(
               c,
               "[data-role='social-invite-dm-link'][href='/chat/#{Platform.Chat.space_path_segment(dm)}']"
             )
    end

    test "cancelled at the vendor: plain message, Try again restarts with a fresh nonce",
         %{conn: conn} = ctx do
      c =
        child(conn, ctx.invitee, "/m/social?invite_connect=#{ctx.nonce}&error=access_denied")

      assert state?(c, "failed")
      assert has_element?(c, "[data-role='social-invite-retry'].btn-primary", "Try again")
      before = Repo.get!(ConnectInvite, ctx.invite.id).connect_nonce_hash

      assert {:error, {:redirect, %{to: "https://zernio.test/oauth"}}} =
               c |> element("[data-role='social-invite-retry']") |> render_click()

      invite = Repo.get!(ConnectInvite, ctx.invite.id)
      assert invite.used_at == nil
      assert invite.connect_nonce_hash != before
    end

    test "another user replaying the failed return gets no Try again and sends nothing",
         %{conn: conn} = ctx do
      c =
        child(conn, ctx.bystander, "/m/social?invite_connect=#{ctx.nonce}&error=access_denied")

      assert state?(c, "invalid")
      refute has_element?(c, "[data-role='social-invite-retry']")

      render_hook(c, "invite_retry", %{})
      refute_received {:zernio_request, _, _, _}
    end
  end
end
