defmodule Platform.Social.HealthTest do
  @moduledoc """
  Social authoring 9/11 (task 01a16c51-9cc5): `Platform.Social.Health`'s
  deterministic account and profile health, and the approvers' disconnect
  alert: once per disconnect (deduped on the account), re-armed on
  reconnect, fired from a Fake auth failure and from the webhook.
  `async: false`: the Fake's log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Inbox.Item
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Health, Post, Publishing, Secrets}
  alias Platform.Social.Publisher.Fake

  @secret "health-webhook-secret-not-real"

  setup do
    Fake.reset()
    Platform.Social.RateLimit.reset()
    ctx = approval_fixture()

    {:ok, a} =
      Social.update_account(ctx.org_id, ctx.a, %{
        status: "connected",
        provider_account_ref: "acc_#{unique()}"
      })

    Map.put(ctx, :a, a)
  end

  defp alerts(account) do
    Repo.all(
      from(i in Item,
        where: i.source_id == ^account.id and i.kind == "social_account_disconnected",
        order_by: [asc: i.inserted_at]
      )
    )
  end

  defp health_of(account),
    do: Health.account(account, Map.get(Health.facts([account]), account.id))

  defp refused!(ctx, account, days_ago) do
    post = approved_post!(ctx.org_id, account, %{body: "refused one"}, ctx.h1)

    {:ok, post} =
      post
      |> Post.refusal_changeset("media_rejected", "The video is longer than 90 seconds.", nil)
      |> Repo.update()

    at = DateTime.add(DateTime.utc_now(), -days_ago, :day)
    Repo.update_all(from(p in Post, where: p.id == ^post.id), set: [updated_at: at])
    Repo.get!(Post, post.id)
  end

  describe "account/2 and profile/1" do
    test "connected, pending and refused-yesterday order down, warn, ok with their reasons",
         ctx do
      {:ok, connected} =
        Social.create_account(ctx.org_id, ctx.profile, %{
          platform: "x",
          handle: "@aaa_connected",
          status: "connected",
          provider_account_ref: "acc_#{unique()}"
        })

      {:ok, pending} =
        Social.create_account(ctx.org_id, ctx.profile, %{
          platform: "tiktok",
          handle: "@bbb_pending"
        })

      refused = refused!(ctx, ctx.a, 1)

      accounts = [connected, pending, ctx.a]
      facts = Health.facts(accounts)

      %{state: state, accounts: rows} =
        accounts |> Enum.map(&{&1, Health.account(&1, facts[&1.id])}) |> Health.profile()

      assert state == :down

      assert [{^pending, down}, {a, warn}, {^connected, ok}] = rows
      assert a.id == ctx.a.id

      assert down.state == :down

      assert [%{code: :not_connected, fix: :connect, text: "Not connected yet." <> _}] =
               down.reasons

      assert warn.state == :warn
      assert [%{code: :refused, fix: {:retry, post_id}, text: text}] = warn.reasons
      assert post_id == refused.id
      assert text == "Last publish was not sent: The video is longer than 90 seconds."
      assert warn.last_failure.id == refused.id

      assert ok.state == :ok
      assert ok.reasons == []
    end

    test "a failure older than 7 days, and a cancelled post, do not count", ctx do
      refused!(ctx, ctx.a, 8)

      post = approved_post!(ctx.org_id, ctx.a, %{body: "cancelled"}, ctx.h1)

      Repo.update_all(from(p in Post, where: p.id == ^post.id),
        set: [status: "failed", error: "cancelled before publishing"]
      )

      assert %{state: :ok, reasons: [], failure_count: 0} = health_of(ctx.a)
    end

    test "disconnected and personal Instagram are down and warn; draft-only is info, still ok",
         ctx do
      {:ok, ig} =
        Social.create_account(ctx.org_id, ctx.profile, %{
          platform: "instagram",
          handle: "@ig",
          status: "connected",
          provider_account_ref: "acc_#{unique()}",
          platform_account_type: "personal"
        })

      assert %{state: :warn, reasons: [%{code: :personal_instagram, fix: :connect}]} =
               health_of(ig)

      {:ok, gone} = Social.update_account(ctx.org_id, ig, %{status: "reauth_needed"})
      assert %{state: :down, reasons: [%{code: :disconnected} | _]} = health_of(gone)

      {:ok, drafts} =
        Social.update_account(ctx.org_id, ctx.d, %{
          status: "connected",
          provider_account_ref: "acc_#{unique()}"
        })

      assert %{state: :ok, reasons: [%{code: :draft_only, tone: :info, fix: nil}]} =
               health_of(drafts)
    end

    test "last published is the newest published post, with its URL", ctx do
      old = approved_post!(ctx.org_id, ctx.a, %{body: "old"}, ctx.h1)
      new = approved_post!(ctx.org_id, ctx.a, %{body: "new"}, ctx.h1)
      two_days = DateTime.add(DateTime.utc_now(), -2, :day)
      five_days = DateTime.add(DateTime.utc_now(), -5, :day)

      Repo.update_all(from(p in Post, where: p.id == ^old.id),
        set: [status: "published", published_at: five_days, external_url: "https://e.test/old"]
      )

      Repo.update_all(from(p in Post, where: p.id == ^new.id),
        set: [status: "published", published_at: two_days, external_url: "https://e.test/new"]
      )

      health = health_of(ctx.a)
      assert health.last_published_url == "https://e.test/new"
      assert DateTime.compare(health.last_published_at, two_days) == :eq
    end

    test "an empty profile is ok, not down" do
      assert Health.profile([]) == %{state: :ok, accounts: []}
      assert Health.by_profile([]) == %{}
    end
  end

  describe "the disconnect alert" do
    test "a Fake auth failure emits exactly one row per approver; a second failure emits none",
         ctx do
      first = approved_post!(ctx.org_id, ctx.a, %{body: "first"}, ctx.h1)
      Fake.fail_next(:publish, :account_disconnected)

      assert {:error, {:publish_failed, :account_disconnected}} =
               Publishing.publish_post(ctx.org_id, first.id)

      account = Repo.get!(Account, ctx.a.id)
      assert account.status == "reauth_needed"
      assert %DateTime{} = account.disconnect_alerted_at

      rows = alerts(account)
      assert Enum.sort(Enum.map(rows, & &1.user_id)) == Enum.sort([ctx.h1.id, ctx.h2.id])
      refute Enum.any?(rows, &(&1.user_id == ctx.n.id))

      for row <- rows do
        assert row.title == "LinkedIn @htc_official on #{ctx.profile.name} disconnected"
        assert row.url == "/m/social?profile=#{ctx.profile.id}&tab=connections"
        assert row.body =~ "reconnect it in Connections"
      end

      # A second auth failure (the account is still marked): no new row.
      assert {:ok, :already_alerted} = Health.account_disconnected(account, "again")
      assert length(alerts(account)) == 2
      assert Repo.get!(Account, ctx.a.id).disconnect_alerted_at == account.disconnect_alerted_at
    end

    test "an ordinary publish failure alerts nobody and leaves the account connected", ctx do
      post = approved_post!(ctx.org_id, ctx.a, %{body: "x"}, ctx.h1)
      Fake.fail_next(:publish, "The video is too long")
      assert {:error, {:publish_failed, _}} = Publishing.publish_post(ctx.org_id, post.id)

      assert Repo.get!(Account, ctx.a.id).status == "connected"
      assert alerts(ctx.a) == []
    end

    test "notify_user_ids, when set, narrows the recipients", ctx do
      {:ok, _profile} =
        Social.update_profile(ctx.org_id, ctx.profile, %{notify_user_ids: [ctx.h2.id]})

      assert {:ok, :alerted, [h2]} = Health.account_disconnected(ctx.a, nil)
      assert h2 == ctx.h2.id
      assert Enum.map(alerts(ctx.a), & &1.user_id) == [ctx.h2.id]
    end

    test "reconnecting re-arms it: the next disconnect alerts again", ctx do
      assert {:ok, :alerted, _} = Health.account_disconnected(ctx.a, "token expired")
      assert {:ok, :already_alerted} = Health.account_disconnected(ctx.a, "token expired")
      assert length(alerts(ctx.a)) == 2

      # The approver's Reconnect (OAuth return) on the same vendor ref.
      Fake.put_next(
        :list_accounts,
        {:ok,
         [
           %{
             ref: ctx.a.provider_account_ref,
             platform: "linkedin",
             profile_ref: "prof_1",
             username: "@htc_official",
             active?: true
           }
         ]}
      )

      {:ok, profile} =
        Social.update_profile(ctx.org_id, ctx.profile, %{provider_profile_ref: "prof_1"})

      assert {:ok, reconnected, :connected} =
               Social.complete_connect(ctx.org_id, profile, {:approver, ctx.h1.id}, %{
                 account_ref: ctx.a.provider_account_ref
               })

      assert reconnected.status == "connected"
      assert is_nil(Repo.get!(Account, ctx.a.id).disconnect_alerted_at)

      assert {:ok, :alerted, _} = Health.account_disconnected(ctx.a, "token expired")
      assert length(alerts(ctx.a)) == 4
    end

    test "a status write back to connected re-arms it too", ctx do
      assert {:ok, :alerted, _} = Health.account_disconnected(ctx.a, nil)
      gone = Repo.get!(Account, ctx.a.id)
      {:ok, back} = Social.update_account(ctx.org_id, gone, %{status: "connected"})
      assert is_nil(back.disconnect_alerted_at)
      assert {:ok, :alerted, _} = Health.account_disconnected(ctx.a, nil)
    end

    test "a never-connected or archived account is not alerted", ctx do
      {:ok, pending} =
        Social.create_account(ctx.org_id, ctx.profile, %{platform: "x", handle: "@p"})

      assert {:error, :not_found} = Health.account_disconnected(pending, nil)
      assert alerts(pending) == []
    end
  end

  describe "the webhook" do
    setup ctx do
      {:ok, _} =
        Platform.Vault.put(Secrets.webhook_slug(ctx.profile.id), :custom, @secret,
          scope: Secrets.scope(ctx.profile.id),
          provider: "social"
        )

      :ok
    end

    defp deliver(conn, profile_id, events) do
      body = Fake.webhook_body(events)

      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header(Fake.signature_header(), Fake.sign(body, @secret))
      |> post("/api/ext/social/webhooks/#{profile_id}", body)
    end

    test "account_disconnected alerts once; a replay alerts nobody; account_connected re-arms",
         %{conn: conn} = ctx do
      event = %{
        event_id: "evt-#{unique()}",
        kind: "account_disconnected",
        account_ref: ctx.a.provider_account_ref,
        error: "Token revoked by the user"
      }

      assert %{"applied" => 1} = conn |> deliver(ctx.profile.id, [event]) |> json_response(200)
      assert Repo.get!(Account, ctx.a.id).status == "reauth_needed"
      assert [row, _] = alerts(ctx.a)
      assert row.body == "Token revoked by the user."

      assert %{"applied" => 0} =
               build_conn() |> deliver(ctx.profile.id, [event]) |> json_response(200)

      assert length(alerts(ctx.a)) == 2

      connected = %{
        event_id: "evt-#{unique()}",
        kind: "account_connected",
        account_ref: ctx.a.provider_account_ref
      }

      assert %{"applied" => 1} =
               build_conn() |> deliver(ctx.profile.id, [connected]) |> json_response(200)

      account = Repo.get!(Account, ctx.a.id)
      assert account.status == "connected"
      assert is_nil(account.disconnect_alerted_at)
    end

    test "another profile's account ref changes nothing", %{conn: conn} = ctx do
      {other, other_account} =
        social_account!(ctx.org_id, "x", %{status: "connected", provider_account_ref: "acc_other"})

      _ = other

      event = %{
        event_id: "evt-#{unique()}",
        kind: "account_disconnected",
        account_ref: other_account.provider_account_ref
      }

      assert %{"applied" => 0} = conn |> deliver(ctx.profile.id, [event]) |> json_response(200)
      assert Repo.get!(Account, other_account.id).status == "connected"
    end

    test "a post failure flagged auth marks the account and alerts once", %{conn: conn} = ctx do
      post = approved_post!(ctx.org_id, ctx.a, %{body: "scheduled"}, ctx.h1)
      {:ok, scheduled} = Publishing.publish_post(ctx.org_id, post.id)

      event = %{
        event_id: "evt-#{unique()}",
        external_id: scheduled.external_id,
        kind: "failed",
        error: "Instagram access token has expired.",
        auth: true
      }

      assert %{"applied" => 1} = conn |> deliver(ctx.profile.id, [event]) |> json_response(200)
      assert Repo.get!(Account, ctx.a.id).status == "reauth_needed"
      assert length(alerts(ctx.a)) == 2
    end
  end

  describe "Zernio's account events (OpenAPI v1.350.1)" do
    defp zernio_events(payload) do
      body = Jason.encode!(payload)
      sig = :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)

      Platform.Social.Publisher.Zernio.verify_webhook(
        %{raw_body: body, headers: %{"x-zernio-signature" => sig}},
        @secret
      )
    end

    test "account.disconnected and account.connected normalize to account events" do
      assert {:ok, [%{kind: :account_disconnected, account_ref: "za_1", error: "Token expired"}]} =
               zernio_events(%{
                 id: "evt_9",
                 event: "account.disconnected",
                 timestamp: "2026-10-24T00:00:00Z",
                 account: %{
                   accountId: "za_1",
                   profileId: "zp",
                   platform: "instagram",
                   username: "u",
                   disconnectionType: "unintentional",
                   reason: "Token expired"
                 }
               })

      assert {:ok, [%{kind: :account_connected, account_ref: "za_1"}]} =
               zernio_events(%{
                 id: "evt_10",
                 event: "account.connected",
                 account: %{accountId: "za_1", profileId: "zp", platform: "x", username: "u"}
               })
    end

    test "post.failed with errorCategory auth_expired is flagged auth" do
      assert {:ok, [%{kind: :failed, auth?: true}]} =
               zernio_events(%{
                 id: "evt_11",
                 event: "post.failed",
                 post: %{
                   _id: "zp_1",
                   platforms: [%{error: "token expired", errorCategory: "auth_expired"}]
                 }
               })

      assert {:ok, [%{kind: :failed, auth?: false}]} =
               zernio_events(%{
                 id: "evt_12",
                 event: "post.failed",
                 post: %{
                   _id: "zp_1",
                   platforms: [%{error: "too long", errorCategory: "user_content"}]
                 }
               })
    end
  end
end
