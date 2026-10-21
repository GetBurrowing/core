defmodule Platform.Social.ConnectInviteTest do
  @moduledoc """
  Connect invites (task 01a14ce1, stage 2): `create_invite/5`,
  `cancel_invite/3`, `list_pending_invites/2`, `get_invite_for/2`,
  `start_invite_connect/3` and the invite branch of `complete_connect/4`.

  The invitee is an org member who is NOT a profile approver: the invite is
  the authorization. Every refusal must write nothing and send nothing, so
  each refusal test snapshots every account and invite row of the profile
  and asserts the `Req.Test` stub saw zero requests.

  `async: false`: the publisher config and the install-level Zernio key are
  global. Zernio traffic goes to a `Req.Test` stub ONLY.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Social
  alias Platform.Social.{Account, ConnectInvite, Profile, Secrets}
  alias Platform.Social.Publisher.Zernio

  @key "zernio-invite-test-key-not-real"
  @profile_ref "zprof_invite_1"
  @base "https://burrow.test"

  setup do
    previous = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, Zernio)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)

    org_id = org_id!()
    {:ok, profile} = Social.create_profile(org_id, %{name: "Invite #{unique()}"})
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

    %{
      org_id: org_id,
      profile: profile,
      approver: approver,
      invitee: invitee,
      bystander: bystander,
      invite: invite,
      token: token
    }
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp entry(ref, platform \\ "linkedin") do
    %{
      "_id" => ref,
      "platform" => platform,
      "profileId" => %{"_id" => @profile_ref, "name" => "Brand"},
      "username" => "person-#{ref}",
      "isActive" => true
    }
  end

  # Every request is reported: {method, path, query params}.
  defp stub_zernio(entries) do
    test = self()

    Req.Test.stub(Zernio, fn conn ->
      query = URI.decode_query(conn.query_string)
      send(test, {:zernio_request, conn.method, conn.request_path, query})

      body =
        if String.starts_with?(conn.request_path, "/api/v1/connect/"),
          do: %{"authUrl" => "https://zernio.test/oauth/linkedin?state=s"},
          else: %{"accounts" => entries, "hasAnalyticsAccess" => false}

      conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:zernio_request, method, path, query} -> requests([{method, path, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp start!(ctx, user) do
    assert {:ok, "https://zernio.test/oauth/linkedin" <> _} =
             Social.start_invite_connect(ctx.token, user.id, base_url: @base)

    [{"GET", "/api/v1/connect/linkedin", query}] = requests()
    redirect = URI.parse(query["redirect_url"])
    assert redirect.path == "/m/social"
    %{"invite_connect" => nonce} = URI.decode_query(redirect.query)
    {nonce, query["redirect_url"]}
  end

  defp finish(ctx, nonce, user, ref \\ "zacct_person") do
    Social.complete_connect(ctx.org_id, ctx.profile, {:invite, nonce, user.id}, %{
      account_ref: ref
    })
  end

  defp invite(ctx), do: Repo.get!(ConnectInvite, ctx.invite.id)

  defp snapshot(ctx) do
    accounts =
      Repo.all(from(a in Account, where: a.profile_id == ^ctx.profile.id, order_by: a.id))

    invites =
      Repo.all(from(i in ConnectInvite, where: i.profile_id == ^ctx.profile.id, order_by: i.id))

    {accounts, invites}
  end

  defp assert_nothing_happened(ctx, before) do
    assert snapshot(ctx) == before
    assert requests() == []
  end

  defp expire!(%ConnectInvite{} = invite, field) do
    invite
    |> Ecto.Changeset.change([{field, DateTime.add(DateTime.utc_now(), -60, :second)}])
    |> Repo.update!()
  end

  defp archive!(user) do
    user |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()
  end

  # ── create / list / cancel ─────────────────────────────────────────

  describe "create_invite/5" do
    test "stores only the sha256 of the token and returns the raw token once", ctx do
      row = invite(ctx)
      assert row.token_hash == :crypto.hash(:sha256, ctx.token)
      assert byte_size(Base.url_decode64!(ctx.token, padding: false)) == 32
      refute row |> Map.from_struct() |> Map.values() |> Enum.member?(ctx.token)
      assert row.org_id == ctx.org_id
      assert row.created_by_user_id == ctx.approver.id
      assert row.account_id == nil
      assert requests() == []
    end

    test "expires after the configured ttl (7 days) or the given one", ctx do
      days = DateTime.diff(invite(ctx).expires_at, invite(ctx).inserted_at, :day)
      assert days in 6..7

      {:ok, short, _} =
        Social.create_invite(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin", 1)

      assert DateTime.diff(short.expires_at, DateTime.utc_now(), :hour) in 23..24
    end

    test "a non-approver, an agent or an unsupported platform is refused with no row", ctx do
      count = Repo.aggregate(ConnectInvite, :count)

      assert {:error, :not_an_approver} =
               Social.create_invite(ctx.org_id, ctx.profile, ctx.invitee.id, "linkedin")

      assert {:error, :not_a_human} =
               Social.create_invite(ctx.org_id, ctx.profile, agent!().id, "linkedin")

      assert {:error, :unsupported_platform} =
               Social.create_invite(ctx.org_id, ctx.profile, ctx.approver.id, "myspace")

      assert Repo.aggregate(ConnectInvite, :count) == count
    end
  end

  describe "list_pending_invites/2 and cancel_invite/3" do
    test "lists live invites only; cancel is approver-only", ctx do
      assert [%{id: id}] = Social.list_pending_invites(ctx.org_id, ctx.profile)
      assert id == ctx.invite.id

      assert {:error, :not_an_approver} =
               Social.cancel_invite(ctx.org_id, ctx.invite, ctx.invitee.id)

      assert invite(ctx).cancelled_at == nil

      assert {:error, :not_found} = Social.cancel_invite(org_id!(), ctx.invite, ctx.approver.id)

      assert {:ok, %ConnectInvite{cancelled_at: %DateTime{}}} =
               Social.cancel_invite(ctx.org_id, ctx.invite.id, ctx.approver.id)

      assert Social.list_pending_invites(ctx.org_id, ctx.profile) == []
    end
  end

  # ── the happy path ─────────────────────────────────────────────────

  describe "start_invite_connect/3 + complete_connect/4 {:invite, ...}" do
    test "the invitee connects their own account and becomes its owner; the invite is used",
         ctx do
      stub_zernio([entry("zacct_person")])
      assert {:ok, _invite} = Social.get_invite_for(ctx.token, ctx.invitee.id)

      {nonce, redirect_url} = start!(ctx, ctx.invitee)
      started = invite(ctx)
      assert started.started_by_user_id == ctx.invitee.id
      assert started.connect_nonce_hash == :crypto.hash(:sha256, nonce)
      assert %Account{owner_user_id: nil, status: nil} = Repo.get!(Account, started.account_id)

      assert {:ok, %Account{id: account_id} = account, :connected} =
               finish(ctx, nonce, ctx.invitee)

      assert account_id == started.account_id
      assert account.owner_user_id == ctx.invitee.id
      assert account.status == "connected"
      assert account.provider_account_ref == "zacct_person"
      assert Repo.get!(Account, account_id).owner_user_id == ctx.invitee.id

      used = invite(ctx)
      assert %DateTime{} = used.used_at
      assert used.used_by_user_id == ctx.invitee.id
      assert used.connect_nonce_hash == nil
      assert [{"GET", "/api/v1/accounts", _}] = requests()

      # The raw invite token never went to the vendor.
      refute redirect_url =~ ctx.token
      assert redirect_url =~ "invite_connect="
    end

    test "the token never appears in any request the vendor receives", ctx do
      stub_zernio([entry("zacct_person")])
      assert {:ok, _} = Social.start_invite_connect(ctx.token, ctx.invitee.id, base_url: @base)
      [{"GET", _, %{"redirect_url" => redirect_url}}] = sent = requests()
      %{"invite_connect" => nonce} = URI.decode_query(URI.parse(redirect_url).query)
      assert {:ok, _, :connected} = finish(ctx, nonce, ctx.invitee)
      sent = sent ++ requests()

      assert length(sent) == 2
      refute inspect(sent) =~ ctx.token
      refute inspect(sent) =~ Base.encode16(invite(ctx).token_hash, case: :lower)
    end
  end

  # ── refusals: zero writes, zero requests ───────────────────────────

  describe "refused before anything is written or sent" do
    setup ctx do
      stub_zernio([entry("zacct_person")])
      ctx
    end

    test "a used invite is single-use: a second start is :used", ctx do
      {nonce, _} = start!(ctx, ctx.invitee)
      assert {:ok, _, :connected} = finish(ctx, nonce, ctx.invitee)
      _ = requests()
      before = snapshot(ctx)

      assert {:error, :used} = Social.start_invite_connect(ctx.token, ctx.invitee.id)
      assert {:error, :used} = Social.start_invite_connect(ctx.token, ctx.bystander.id)
      assert {:error, :used} = Social.get_invite_for(ctx.token, ctx.invitee.id)
      assert_nothing_happened(ctx, before)
    end

    test "an expired invite is refused at start", ctx do
      expire!(ctx.invite, :expires_at)
      before = snapshot(ctx)

      assert {:error, :expired} = Social.start_invite_connect(ctx.token, ctx.invitee.id)
      assert {:error, :expired} = Social.get_invite_for(ctx.token, ctx.invitee.id)
      assert_nothing_happened(ctx, before)
    end

    test "an invite that expires after the start is refused at the return", ctx do
      {nonce, _} = start!(ctx, ctx.invitee)
      expire!(invite(ctx), :expires_at)
      before = snapshot(ctx)

      assert {:error, :expired} = finish(ctx, nonce, ctx.invitee)
      assert_nothing_happened(ctx, before)
    end

    test "an expired connect nonce is refused at the return", ctx do
      {nonce, _} = start!(ctx, ctx.invitee)
      expire!(invite(ctx), :connect_nonce_expires_at)
      before = snapshot(ctx)

      assert {:error, :expired} = finish(ctx, nonce, ctx.invitee)
      assert_nothing_happened(ctx, before)
    end

    test "a cancelled invite is refused at start and at the return", ctx do
      {nonce, _} = start!(ctx, ctx.invitee)
      {:ok, _} = Social.cancel_invite(ctx.org_id, ctx.invite, ctx.approver.id)
      before = snapshot(ctx)

      assert {:error, :cancelled} = Social.start_invite_connect(ctx.token, ctx.invitee.id)
      assert {:error, :cancelled} = finish(ctx, nonce, ctx.invitee)
      assert_nothing_happened(ctx, before)
    end

    test "a forged token or nonce is :not_found", ctx do
      before = snapshot(ctx)
      forged = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      assert {:error, :not_found} = Social.start_invite_connect(forged, ctx.invitee.id)
      assert {:error, :not_found} = Social.start_invite_connect(nil, ctx.invitee.id)
      assert {:error, :not_found} = Social.get_invite_for("", ctx.invitee.id)
      assert {:error, :not_found} = finish(ctx, forged, ctx.invitee)
      # The shared token is not a connect nonce.
      assert {:error, :not_found} = finish(ctx, ctx.token, ctx.invitee)
      assert_nothing_happened(ctx, before)
    end

    test "another org's user cannot use the token, nor return to another org's profile", ctx do
      outsider_org = org_id!()
      outsider = member!(user!(), outsider_org)
      before = snapshot(ctx)

      assert {:error, :approver_no_access} =
               Social.start_invite_connect(ctx.token, outsider.id)

      assert_nothing_happened(ctx, before)

      {nonce, _} = start!(ctx, ctx.invitee)
      {:ok, other} = Social.create_profile(outsider_org, %{name: "Other #{unique()}"})
      before = snapshot(ctx)

      assert {:error, :not_found} =
               Social.complete_connect(outsider_org, other, {:invite, nonce, ctx.invitee.id}, %{
                 account_ref: "zacct_person"
               })

      assert_nothing_happened(ctx, before)
    end

    test "an agent is refused", ctx do
      agent = agent!()
      before = snapshot(ctx)
      assert {:error, :not_a_human} = Social.start_invite_connect(ctx.token, agent.id)
      assert {:error, :not_a_human} = Social.get_invite_for(ctx.token, agent.id)
      assert_nothing_happened(ctx, before)
    end

    test "an archived user is refused at start and at the return", ctx do
      {nonce, _} = start!(ctx, ctx.invitee)
      archive!(ctx.invitee)
      before = snapshot(ctx)

      assert {:error, :approver_archived} =
               Social.start_invite_connect(ctx.token, ctx.invitee.id)

      assert {:error, :approver_archived} = finish(ctx, nonce, ctx.invitee)
      assert_nothing_happened(ctx, before)
    end

    test "a different signed-in member returning with B's nonce is :not_the_inviter", ctx do
      {nonce, _} = start!(ctx, ctx.invitee)
      before = snapshot(ctx)

      assert {:error, :not_the_inviter} = finish(ctx, nonce, ctx.bystander)
      # Not even the approver who created the invite may finish B's connect.
      assert {:error, :not_the_inviter} = finish(ctx, nonce, ctx.approver)
      assert_nothing_happened(ctx, before)

      row = invite(ctx)
      assert row.used_at == nil
      assert row.started_by_user_id == ctx.invitee.id

      assert %Account{owner_user_id: nil, status: nil, provider_account_ref: nil} =
               Repo.get!(Account, row.account_id)
    end
  end

  # ── nonce replacement, binding, failure, concurrency ───────────────

  describe "the invite's own row and nonce" do
    setup ctx do
      stub_zernio([entry("zacct_person")])
      ctx
    end

    test "a second start mints a fresh nonce on the same row; the old nonce is refused", ctx do
      {old, _} = start!(ctx, ctx.invitee)
      first_account = invite(ctx).account_id
      {new, _} = start!(ctx, ctx.invitee)
      assert old != new
      assert invite(ctx).account_id == first_account
      before = snapshot(ctx)

      assert {:error, :not_found} = finish(ctx, old, ctx.invitee)
      assert_nothing_happened(ctx, before)

      assert {:ok, %Account{id: ^first_account}, :connected} = finish(ctx, new, ctx.invitee)
    end

    test "a second start by someone else takes the connect over; the first starter is refused",
         ctx do
      {first, _} = start!(ctx, ctx.invitee)
      {second, _} = start!(ctx, ctx.bystander)
      before = snapshot(ctx)

      assert {:error, :not_found} = finish(ctx, first, ctx.invitee)
      assert {:error, :not_the_inviter} = finish(ctx, second, ctx.invitee)
      assert_nothing_happened(ctx, before)
    end

    test "the invite fills ITS OWN row, never an older pending row", ctx do
      {:ok, older} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "linkedin"})

      {nonce, _} = start!(ctx, ctx.invitee)
      bound = invite(ctx).account_id
      assert bound != older.id

      assert {:ok, %Account{id: ^bound}, :connected} = finish(ctx, nonce, ctx.invitee)

      assert %Account{status: nil, provider_account_ref: nil, owner_user_id: nil} =
               Repo.get!(Account, older.id)

      assert %Account{status: "connected", owner_user_id: owner} = Repo.get!(Account, bound)
      assert owner == ctx.invitee.id
    end

    test "an approver's add or return never takes the invite's row", ctx do
      {_nonce, _} = start!(ctx, ctx.invitee)
      bound = invite(ctx).account_id

      assert {:ok, %Account{id: added}, _} =
               Social.add_account(ctx.org_id, ctx.profile, ctx.approver.id, "linkedin")

      assert added != bound

      stub_zernio([entry("zacct_brand")])

      assert {:ok, %Account{id: ^added}, :connected} =
               Social.complete_connect(ctx.org_id, ctx.profile, {:approver, ctx.approver.id}, %{
                 account_ref: "zacct_brand"
               })

      assert %Account{status: nil} = Repo.get!(Account, bound)
    end

    test "a failed vendor return leaves the invite valid", ctx do
      {nonce, _} = start!(ctx, ctx.invitee)
      stub_zernio([])
      before = snapshot(ctx)

      assert {:error, :not_listed} = finish(ctx, nonce, ctx.invitee)
      assert snapshot(ctx) == before
      assert invite(ctx).used_at == nil
      assert {:ok, _} = Social.get_invite_for(ctx.token, ctx.invitee.id)

      stub_zernio([entry("zacct_person")])
      assert {:ok, _, :connected} = finish(ctx, nonce, ctx.invitee)
    end

    test "two concurrent returns: exactly one wins", ctx do
      {nonce, _} = start!(ctx, ctx.invitee)

      results =
        1..2
        |> Enum.map(fn _ -> Task.async(fn -> finish(ctx, nonce, ctx.invitee) end) end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert [{:ok, %Account{}, :connected}] = Enum.filter(results, &match?({:ok, _, _}, &1))
      assert [{:error, _}] = Enum.filter(results, &match?({:error, _}, &1))

      assert [%Account{owner_user_id: owner}] =
               Repo.all(from(a in Account, where: a.provider_account_ref == "zacct_person"))

      assert owner == ctx.invitee.id
    end

    test "the approver path still requires an approver", ctx do
      {:ok, _} = Social.create_account(ctx.org_id, ctx.profile, %{platform: "x"})
      before = snapshot(ctx)

      assert {:error, :not_an_approver} =
               Social.complete_connect(ctx.org_id, ctx.profile, {:approver, ctx.invitee.id}, %{
                 account_ref: "zacct_person"
               })

      assert_nothing_happened(ctx, before)
    end
  end

  # ── stage 4: the landing page's reads and Try again ─────────────────

  describe "invite_landing_for/2 (stage 4)" do
    test "a live invite answers with its profile; a dead one still names its state", ctx do
      assert {:ok, %ConnectInvite{}, %Profile{id: id}} =
               Social.invite_landing_for(ctx.token, ctx.invitee.id)

      assert id == ctx.profile.id

      {:ok, _} = Social.cancel_invite(ctx.org_id, ctx.invite, ctx.approver.id)

      assert {:error, :cancelled, %ConnectInvite{}, %Profile{}} =
               Social.invite_landing_for(ctx.token, ctx.invitee.id)
    end

    test "forged or another org's user answers with nothing to show", ctx do
      assert {:error, :not_found} =
               Social.invite_landing_for("forged-token-value", ctx.invitee.id)

      outsider = member!(user!(), org_id!())
      assert {:error, _} = Social.invite_landing_for(ctx.token, outsider.id)
    end
  end

  describe "restart_invite_connect/3 (stage 4)" do
    test "the starter gets a fresh nonce; the old one is refused from then on", ctx do
      stub_zernio([entry("zacct_person")])
      {nonce, _} = start!(ctx, ctx.invitee)

      assert {:ok, "https://zernio.test/oauth/linkedin" <> _} =
               Social.restart_invite_connect(nonce, ctx.invitee.id, base_url: @base)

      [{"GET", "/api/v1/connect/linkedin", query}] = requests()
      %{"invite_connect" => fresh} = URI.decode_query(URI.parse(query["redirect_url"]).query)
      assert fresh != nonce
      refute query["redirect_url"] =~ ctx.token

      assert {:error, :not_found} = Social.restart_invite_connect(nonce, ctx.invitee.id)
    end

    test "anyone but the starter is refused, nothing written, nothing sent", ctx do
      stub_zernio([entry("zacct_person")])
      {nonce, _} = start!(ctx, ctx.invitee)
      before = snapshot(ctx)

      assert {:error, :not_the_inviter} =
               Social.restart_invite_connect(nonce, ctx.bystander.id, base_url: @base)

      assert_nothing_happened(ctx, before)
    end

    test "a cancelled invite cannot be restarted", ctx do
      stub_zernio([entry("zacct_person")])
      {nonce, _} = start!(ctx, ctx.invitee)
      {:ok, _} = Social.cancel_invite(ctx.org_id, ctx.invite, ctx.approver.id)
      before = snapshot(ctx)

      assert {:error, :cancelled} = Social.restart_invite_connect(nonce, ctx.invitee.id)
      assert_nothing_happened(ctx, before)
    end
  end
end
