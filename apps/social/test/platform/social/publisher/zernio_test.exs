defmodule Platform.Social.Publisher.ZernioTest do
  @moduledoc """
  The Zernio adapter against `Req.Test` stubs ONLY: no test reaches the
  network, and the keys here are test strings stored in the test Vault.

  The stubs assert method, path, Bearer header and body mapping. The
  no-credential cases install a stub that FAILS the test if it is hit, so
  "no request is sent" is checked, not assumed. The last describe runs the
  stage-2 publish path with this adapter selected, proving the adapters swap
  by config alone.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Social.{Post, Publishing, RateLimit}
  alias Platform.Social.Publisher.Zernio

  @key "zernio-test-key-not-real"
  @secret "zernio-webhook-secret-not-real"

  setup do
    RateLimit.reset()
    org_id = org_id!()
    %{org_id: org_id}
  end

  defp account!(org_id, platform, attrs \\ %{}) do
    {profile, account} =
      social_account!(org_id, platform, Map.merge(%{provider_account_ref: "zacct_1"}, attrs))

    {:ok, profile} =
      Platform.Social.update_profile(org_id, profile, %{provider_profile_ref: "zprof_1"})

    {profile, account}
  end

  # The install-level key (task 01a14722): one row at the Zernio slug and
  # `{:integration, nil}`, whatever account is publishing. A second call (a
  # loop over platforms) rotates that row, since a second put cannot exist.
  defp put_key!(_account \\ nil) do
    case Platform.Vault.put("social:zernio:api_key", :api_key, @key,
           scope: {:integration, nil},
           provider: "social"
         ) do
      {:ok, cred} ->
        cred

      {:error, %Ecto.Changeset{}} ->
        {:ok, cred} =
          Platform.Vault.rotate("social:zernio:api_key", @key,
            scope: {:integration, nil},
            accessor: {:integration, nil}
          )

        cred
    end
  end

  defp request(platform, overrides \\ %{}) do
    Map.merge(
      %{
        body: "hello world",
        link_url: nil,
        scheduled_at: nil,
        media: [],
        is_aigc: false,
        ai_disclosure: nil,
        platform: platform,
        idempotency_key: "post-123"
      },
      overrides
    )
  end

  defp capture_post(response_status \\ 201, response \\ %{"post" => %{"_id" => "zp_1"}}) do
    test = self()

    Req.Test.stub(Zernio, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:zernio, conn.method, conn.request_path, conn.req_headers, Jason.decode!(raw)})
      conn |> Plug.Conn.put_status(response_status) |> Req.Test.json(response)
    end)
  end

  defp refuse_any_request do
    Req.Test.stub(Zernio, fn _conn -> flunk("a request reached Zernio without credentials") end)
  end

  describe "publish/2 request mapping" do
    test "linkedin: POST /v1/posts with Bearer, Idempotency-Key and publishNow", ctx do
      {_, account} = account!(ctx.org_id, "linkedin")
      put_key!(account)
      capture_post()

      assert {:ok, %{external_id: "zp_1", status: :scheduled, external_url: nil}} =
               Zernio.publish(account, request("linkedin", %{link_url: "https://example.test/a"}))

      assert_received {:zernio, "POST", "/api/v1/posts", headers, body}
      assert {"authorization", "Bearer " <> @key} in headers
      assert {"idempotency-key", "post-123"} in headers
      assert body["content"] == "hello world\n\nhttps://example.test/a"
      assert body["publishNow"] == true
      refute Map.has_key?(body, "scheduledFor")
      refute Map.has_key?(body, "tiktokSettings")

      assert [
               %{
                 "platform" => "linkedin",
                 "accountId" => "zacct_1",
                 "platformSpecificData" => %{}
               }
             ] =
               body["platforms"]
    end

    test "x maps to twitter, carries madeWithAi and scheduledFor", ctx do
      {_, account} = account!(ctx.org_id, "x")
      put_key!(account)
      capture_post()
      at = ~U[2026-11-01 12:00:00.000000Z]

      assert {:ok, _} = Zernio.publish(account, request("x", %{is_aigc: true, scheduled_at: at}))
      assert_received {:zernio, "POST", _, _, body}

      assert [%{"platform" => "twitter", "platformSpecificData" => %{"madeWithAi" => true}}] =
               body["platforms"]

      assert body["scheduledFor"] == DateTime.to_iso8601(at)
      refute Map.has_key?(body, "publishNow")
    end

    test "instagram and youtube AI flags", ctx do
      for {platform, field} <- [
            {"instagram", "isAiGenerated"},
            {"youtube", "containsSyntheticMedia"}
          ] do
        # One live row per vendor account id (the unique index, task 01a14807).
        {_, account} =
          account!(ctx.org_id, platform, %{provider_account_ref: "zacct_#{platform}"})

        put_key!(account)
        capture_post()

        assert {:ok, _} = Zernio.publish(account, request(platform, %{is_aigc: true}))
        assert_received {:zernio, "POST", _, _, body}

        assert [%{"platform" => ^platform, "platformSpecificData" => %{^field => true}}] =
                 body["platforms"]
      end
    end

    test "tiktok sends the required tiktokSettings and its AI flag, and media items", ctx do
      {_, account} = account!(ctx.org_id, "tiktok")
      put_key!(account)
      capture_post()

      media = [
        %{
          url: "https://cdn.example.test/v.mp4",
          content_type: "video/mp4",
          byte_size: 9,
          duration_s: 30
        }
      ]

      assert {:ok, _} = Zernio.publish(account, request("tiktok", %{is_aigc: true, media: media}))
      assert_received {:zernio, "POST", _, _, body}

      assert body["tiktokSettings"] == %{
               "privacy_level" => "PUBLIC_TO_EVERYONE",
               "allow_comment" => true,
               "allow_duet" => true,
               "allow_stitch" => true,
               "content_preview_confirmed" => true,
               "express_consent_given" => true,
               "video_made_with_ai" => true
             }

      assert body["mediaItems"] == [
               %{"type" => "video", "url" => "https://cdn.example.test/v.mp4"}
             ]
    end

    test "media without a fetchable URL is refused before any request", ctx do
      {_, account} = account!(ctx.org_id, "tiktok")
      put_key!(account)
      refuse_any_request()
      media = [%{url: nil, content_type: "video/mp4", byte_size: 9, duration_s: 30}]

      assert {:error, :media_url_unavailable} =
               Zernio.publish(account, request("tiktok", %{media: media}))
    end
  end

  describe "publish/2 responses" do
    setup ctx do
      {_, account} = account!(ctx.org_id, "linkedin")
      put_key!(account)
      %{account: account}
    end

    test "201 with post._id, and a root _id, map to scheduled", ctx do
      capture_post(201, %{"post" => %{"_id" => "zp_nested", "status" => "scheduled"}})

      assert {:ok, %{external_id: "zp_nested", status: :scheduled}} =
               Zernio.publish(ctx.account, request("linkedin"))

      capture_post(200, %{"_id" => "zp_root"})

      assert {:ok, %{external_id: "zp_root", status: :scheduled}} =
               Zernio.publish(ctx.account, request("linkedin"))
    end

    test "a published response carries the platform URL", ctx do
      capture_post(201, %{
        "post" => %{
          "_id" => "zp_live",
          "status" => "published",
          "platforms" => [
            %{"accountId" => "zacct_1", "platformPostUrl" => "https://li.example.test/1"}
          ]
        }
      })

      assert {:ok, %{status: :published, external_url: "https://li.example.test/1"}} =
               Zernio.publish(ctx.account, request("linkedin"))
    end

    test "409, 429, 401 and 500 map to errors", ctx do
      capture_post(409, %{"existingPostId" => "zp_old"})

      assert {:error, {:duplicate_content, "zp_old"}} =
               Zernio.publish(ctx.account, request("linkedin"))

      capture_post(429, %{"error" => "slow down"})
      assert {:error, :rate_limited} = Zernio.publish(ctx.account, request("linkedin"))

      capture_post(401, %{})
      assert {:error, :credentials_rejected} = Zernio.publish(ctx.account, request("linkedin"))

      capture_post(422, %{"error" => "content too long"})

      assert {:error, "Zernio refused the request (HTTP 422): content too long"} =
               Zernio.publish(ctx.account, request("linkedin"))

      capture_post(500, %{})

      assert {:error, "Zernio is unavailable (HTTP 500)"} =
               Zernio.publish(ctx.account, request("linkedin"))
    end
  end

  describe "connect_url/2, status/2, delete/2" do
    test "connect_url returns the authUrl; x is twitter", ctx do
      {profile, account} = account!(ctx.org_id, "x")
      put_key!(account)
      test = self()

      Req.Test.stub(Zernio, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        send(
          test,
          {:connect, conn.method, conn.request_path, conn.query_params, conn.req_headers}
        )

        Req.Test.json(conn, %{"authUrl" => "https://auth.example.test/start"})
      end)

      assert {:ok, "https://auth.example.test/start"} =
               Zernio.connect_url(account,
                 redirect_url: "https://suite.example.test/cb",
                 profile: profile
               )

      assert_received {:connect, "GET", "/api/v1/connect/twitter", params, headers}

      assert params == %{
               "profileId" => "zprof_1",
               "redirect_url" => "https://suite.example.test/cb"
             }

      assert {"authorization", "Bearer " <> @key} in headers
    end

    test "connect_url without a linked vendor profile sends nothing", ctx do
      {_, account} = account!(ctx.org_id, "linkedin")
      put_key!(account)
      refuse_any_request()

      assert {:error, :profile_not_linked} =
               Zernio.connect_url(account, redirect_url: "x", profile: nil)
    end

    test "connect_url keeps Zernio's reason on a 402 and a 403; a 401 is the key", ctx do
      {profile, account} = account!(ctx.org_id, "instagram")
      put_key!(account)

      connect = fn status, body ->
        Req.Test.stub(Zernio, fn conn ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
        end)

        Zernio.connect_url(account,
          redirect_url: "https://suite.example.test/cb",
          profile: profile
        )
      end

      assert {:error, "Zernio refused the request (HTTP 402): Add a payment method."} =
               connect.(402, %{
                 "error" => "Add a payment method.",
                 "code" => "PAYMENT_REQUIRED",
                 "reason" => "free_tier_exceeded"
               })

      assert {:error, "Zernio refused the request (HTTP 403): No access to profile"} =
               connect.(403, %{"error" => "No access to profile"})

      assert {:error, :credentials_rejected} = connect.(401, %{"error" => "Invalid API key"})
    end

    test "status/2 maps published, failed, partial, cancelled and scheduled", ctx do
      {_, account} = account!(ctx.org_id, "linkedin")
      put_key!(account)

      cases = [
        {%{
           "status" => "published",
           "platforms" => [%{"platformPostUrl" => "https://li.example.test/2"}]
         }, %{status: :published, external_url: "https://li.example.test/2", error: nil}},
        {%{"status" => "failed", "platforms" => [%{"errorMessage" => "token expired"}]},
         %{status: :failed, external_url: nil, error: "token expired"}},
        {%{
           "status" => "partial",
           "platforms" => [
             %{"platformPostId" => "123", "platformPostUrl" => "https://li.example.test/3"}
           ]
         }, %{status: :published, external_url: "https://li.example.test/3", error: nil}},
        {%{"status" => "cancelled", "platforms" => [%{}]},
         %{status: :failed, external_url: nil, error: "cancelled at vendor"}},
        {%{"status" => "publishing"}, %{status: :scheduled, external_url: nil, error: nil}}
      ]

      for {post, expected} <- cases do
        Req.Test.stub(Zernio, fn conn ->
          assert conn.method == "GET"
          assert conn.request_path == "/api/v1/posts/zp_9"
          Req.Test.json(conn, %{"post" => post})
        end)

        assert {:ok, ^expected} = Zernio.status(account, "zp_9")
      end
    end

    test "delete/2 sends DELETE /v1/posts/:id", ctx do
      {_, account} = account!(ctx.org_id, "linkedin")
      put_key!(account)
      test = self()

      Req.Test.stub(Zernio, fn conn ->
        send(test, {:delete, conn.method, conn.request_path})
        Req.Test.json(conn, %{"deleted" => true})
      end)

      assert :ok = Zernio.delete(account, "zp_9")
      assert_received {:delete, "DELETE", "/api/v1/posts/zp_9"}
    end

    test "status and delete carry the install key as a Bearer header", ctx do
      {_, account} = account!(ctx.org_id, "linkedin")
      put_key!()
      test = self()

      Req.Test.stub(Zernio, fn conn ->
        send(test, {:auth, conn.method, Plug.Conn.get_req_header(conn, "authorization")})

        case conn.method do
          "GET" -> Req.Test.json(conn, %{"post" => %{"status" => "scheduled"}})
          "DELETE" -> Req.Test.json(conn, %{"deleted" => true})
        end
      end)

      assert {:ok, _} = Zernio.status(account, "zp_9")
      assert_received {:auth, "GET", ["Bearer zernio-test-key-not-real"]}
      assert :ok = Zernio.delete(account, "zp_9")
      assert_received {:auth, "DELETE", ["Bearer zernio-test-key-not-real"]}
    end

    test "one install key serves two accounts in different orgs", ctx do
      {_, a1} = account!(ctx.org_id, "linkedin")
      {_, a2} = account!(org_id!(), "x", %{provider_account_ref: "zacct_2"})
      put_key!()
      test = self()

      Req.Test.stub(Zernio, fn conn ->
        send(test, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"deleted" => true})
      end)

      assert :ok = Zernio.delete(a1, "zp_1")
      assert :ok = Zernio.delete(a2, "zp_2")
      assert_received {:auth, ["Bearer zernio-test-key-not-real"]}
      assert_received {:auth, ["Bearer zernio-test-key-not-real"]}
    end

    test "a key stored only at the old per-account slug and scope sends nothing", ctx do
      {profile, account} = account!(ctx.org_id, "linkedin")

      {:ok, _} =
        Platform.Vault.put(account.secret_slug, :api_key, @key,
          scope: {:integration, account.id},
          provider: "social"
        )

      refuse_any_request()
      assert_no_request_sent(account, profile)
    end

    test "the install slug at the account's scope (not nil) sends nothing", ctx do
      {profile, account} = account!(ctx.org_id, "linkedin")

      {:ok, _} =
        Platform.Vault.put("social:zernio:api_key", :api_key, @key,
          scope: {:integration, account.id},
          provider: "social"
        )

      refuse_any_request()
      assert_no_request_sent(account, profile)
    end

    for {label, value} <- [{"empty", ""}, {"whitespace", "   \n\t "}] do
      test "an #{label} key is refused at entry and sends nothing", ctx do
        {profile, account} = account!(ctx.org_id, "linkedin")
        refuse_any_request()

        assert {:error, :blank} =
                 Platform.Social.Secrets.put_zernio_api_key(unquote(value), user!())

        assert_no_request_sent(account, profile)
      end
    end

    test "with no Vault key, no callback sends a request", ctx do
      {profile, account} = account!(ctx.org_id, "linkedin")
      refuse_any_request()
      assert_no_request_sent(account, profile)
    end
  end

  # Every callback, each failing closed before Req runs (the stub flunks on any call).
  defp assert_no_request_sent(account, profile) do
    assert {:error, :credentials_unavailable} = Zernio.publish(account, request("linkedin"))
    assert {:error, :credentials_unavailable} = Zernio.status(account, "zp_1")
    assert {:error, :credentials_unavailable} = Zernio.delete(account, "zp_1")

    assert {:error, :credentials_unavailable} =
             Zernio.connect_url(account,
               redirect_url: "https://suite.example.test/cb",
               profile: profile
             )
  end

  describe "ensure_profile/1 and platforms/0" do
    defp bare_profile!(org_id) do
      {:ok, profile} = Platform.Social.create_profile(org_id, %{name: "Brand #{unique()}"})
      assert profile.provider_profile_ref == nil
      profile
    end

    defp stub_profiles(status, response) do
      test = self()

      Req.Test.stub(Zernio, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          test,
          {:profiles, conn.method, conn.request_path, conn.req_headers, Jason.decode!(raw)}
        )

        conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
      end)
    end

    test "POST /v1/profiles with name, externalId, Idempotency-Key and Bearer; 201 answers profile._id",
         ctx do
      profile = bare_profile!(ctx.org_id)
      put_key!()
      stub_profiles(201, %{"message" => "created", "profile" => %{"_id" => "zprof_new"}})

      assert {:ok, "zprof_new"} = Zernio.ensure_profile(profile)

      assert_received {:profiles, "POST", "/api/v1/profiles", headers, body}
      assert body == %{"name" => profile.name, "externalId" => profile.id}
      assert {"idempotency-key", profile.id} in headers
      assert {"authorization", "Bearer " <> @key} in headers
    end

    test "a root _id is accepted (ASSUMPTION fallback)", ctx do
      profile = bare_profile!(ctx.org_id)
      put_key!()
      stub_profiles(201, %{"_id" => "zprof_root"})
      assert {:ok, "zprof_root"} = Zernio.ensure_profile(profile)
    end

    test "a 2xx with no id is :unexpected_response", ctx do
      profile = bare_profile!(ctx.org_id)
      put_key!()
      stub_profiles(201, %{"message" => "created"})
      assert {:error, :unexpected_response} = Zernio.ensure_profile(profile)
    end

    test "an existing provider_profile_ref is answered with no request", ctx do
      {profile, _account} = account!(ctx.org_id, "linkedin")
      put_key!()
      refuse_any_request()
      assert {:ok, "zprof_1"} = Zernio.ensure_profile(profile)
    end

    test "with no Vault key, nothing is sent", ctx do
      profile = bare_profile!(ctx.org_id)
      refuse_any_request()
      assert {:error, :credentials_unavailable} = Zernio.ensure_profile(profile)
    end

    test "a 409 name conflict is :profile_name_taken and the existing id is NOT adopted", ctx do
      profile = bare_profile!(ctx.org_id)
      put_key!()

      stub_profiles(409, %{
        "error" => "A profile with this name already exists",
        "details" => %{"existingProfileId" => "zprof_someone_else"}
      })

      assert {:error, {:profile_name_taken, name}} = Zernio.ensure_profile(profile)
      assert name == profile.name
    end

    test "a 409 externalId conflict with an existing id adopts it", ctx do
      profile = bare_profile!(ctx.org_id)
      put_key!()

      stub_profiles(409, %{
        "code" => "profile_external_id_conflict",
        "details" => %{"existingProfileId" => "zprof_ours"}
      })

      assert {:ok, "zprof_ours"} = Zernio.ensure_profile(profile)
    end

    test "a 409 externalId conflict without an id is :profile_conflict", ctx do
      profile = bare_profile!(ctx.org_id)
      put_key!()
      stub_profiles(409, %{"code" => "profile_external_id_conflict"})
      assert {:error, :profile_conflict} = Zernio.ensure_profile(profile)
    end

    test "401 is :credentials_rejected and 500 is an error", ctx do
      profile = bare_profile!(ctx.org_id)
      put_key!()

      stub_profiles(401, %{"error" => "bad key"})
      assert {:error, :credentials_rejected} = Zernio.ensure_profile(profile)

      stub_profiles(500, %{"error" => "boom"})
      assert {:error, "Zernio is unavailable (HTTP 500)"} = Zernio.ensure_profile(profile)
    end

    test "platforms/0 is every mapped platform in Account.platforms/0 order" do
      assert Zernio.platforms() == Platform.Social.Account.platforms()
    end
  end

  describe "list_accounts/1" do
    defp stub_accounts(status, response) do
      test = self()

      Req.Test.stub(Zernio, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        send(
          test,
          {:accounts, conn.method, conn.request_path, conn.query_params, conn.req_headers}
        )

        conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
      end)
    end

    defp linked_profile!(org_id) do
      {profile, _account} = account!(org_id, "linkedin")
      profile
    end

    test "GET /v1/accounts with profileId only (no page/limit) and Bearer", ctx do
      profile = linked_profile!(ctx.org_id)
      put_key!()
      stub_accounts(200, %{"accounts" => [], "hasAnalyticsAccess" => false})

      assert {:ok, []} = Zernio.list_accounts(profile)

      assert_received {:accounts, "GET", "/api/v1/accounts", params, headers}
      assert params == %{"profileId" => "zprof_1"}
      refute Map.has_key?(params, "page")
      refute Map.has_key?(params, "limit")
      assert {"authorization", "Bearer " <> @key} in headers
    end

    test "a profile with no vendor ref is :profile_not_linked and sends nothing", ctx do
      {:ok, profile} = Platform.Social.create_profile(ctx.org_id, %{name: "Bare #{unique()}"})
      put_key!()
      refuse_any_request()
      assert {:error, :profile_not_linked} = Zernio.list_accounts(profile)
    end

    test "with no Vault key, nothing is sent", ctx do
      profile = linked_profile!(ctx.org_id)
      refuse_any_request()
      assert {:error, :credentials_unavailable} = Zernio.list_accounts(profile)
    end

    test "maps entries: object and string profileId, twitter to x, unknown dropped, isActive",
         ctx do
      profile = linked_profile!(ctx.org_id)
      put_key!()

      stub_accounts(200, %{
        "hasAnalyticsAccess" => false,
        "accounts" => [
          %{
            "_id" => "zacct_li",
            "platform" => "linkedin",
            "profileId" => %{"_id" => "zprof_1", "name" => "Brand", "slug" => "brand"},
            "username" => "brand-li",
            "displayName" => "Brand",
            "isActive" => true
          },
          %{
            "_id" => "zacct_tw",
            "platform" => "twitter",
            "profileId" => "zprof_1",
            "username" => "brand_x",
            "isActive" => false
          },
          %{
            "_id" => "zacct_pin",
            "platform" => "pinterest",
            "profileId" => "zprof_1",
            "isActive" => true
          }
        ]
      })

      assert {:ok, accounts} = Zernio.list_accounts(profile)

      assert accounts == [
               %{
                 ref: "zacct_li",
                 platform: "linkedin",
                 profile_ref: "zprof_1",
                 username: "brand-li",
                 active?: true
               },
               %{
                 ref: "zacct_tw",
                 platform: "x",
                 profile_ref: "zprof_1",
                 username: "brand_x",
                 active?: false
               }
             ]
    end

    test "401 is :credentials_rejected, 503 is an error, a 2xx without accounts is :unexpected_response",
         ctx do
      profile = linked_profile!(ctx.org_id)
      put_key!()

      stub_accounts(401, %{"error" => "bad key"})
      assert {:error, :credentials_rejected} = Zernio.list_accounts(profile)

      stub_accounts(503, %{"error" => "down"})
      assert {:error, "Zernio is unavailable (HTTP 503)"} = Zernio.list_accounts(profile)

      stub_accounts(200, %{"hasAnalyticsAccess" => false})
      assert {:error, :unexpected_response} = Zernio.list_accounts(profile)
    end

    test "publish/2 sends a listed ref verbatim as platforms[0].accountId", ctx do
      profile = linked_profile!(ctx.org_id)
      put_key!()

      stub_accounts(200, %{
        "accounts" => [
          %{
            "_id" => "66f0c0ffee0000000000abcd",
            "platform" => "twitter",
            "profileId" => "zprof_1"
          }
        ]
      })

      assert {:ok, [%{ref: ref, platform: "x"}]} = Zernio.list_accounts(profile)

      {:ok, account} =
        Platform.Social.create_account(ctx.org_id, profile, %{
          platform: "x",
          provider_account_ref: ref
        })

      capture_post()
      assert {:ok, _} = Zernio.publish(account, request("x"))
      assert_received {:zernio, "POST", "/api/v1/posts", _headers, body}

      assert [%{"platform" => "twitter", "accountId" => "66f0c0ffee0000000000abcd"}] =
               body["platforms"]
    end
  end

  describe "disconnect_account/1" do
    # The key is entered the way a human enters it (Secrets.put_zernio_api_key/2).
    @disconnect_key "zk_test_9f3a"

    defp put_human_key! do
      assert {:ok, _} = Platform.Social.Secrets.put_zernio_api_key(@disconnect_key, user!())
    end

    # Records every request and answers `status`; the tests count what arrived.
    defp stub_disconnect(status, response) do
      test = self()

      Req.Test.stub(Zernio, fn conn ->
        send(test, {:disconnect, conn.method, conn.request_path, conn.req_headers})
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
      end)
    end

    defp disconnect_requests(acc \\ []) do
      receive do
        {:disconnect, _, _, _} = msg -> disconnect_requests([msg | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "200 is :ok after exactly one DELETE /v1/accounts/<ref> with the Vault key", ctx do
      {_profile, account} = account!(ctx.org_id, "linkedin", %{provider_account_ref: "zacct_9"})
      put_human_key!()
      stub_disconnect(200, %{"message" => "Account disconnected successfully"})

      assert :ok = Zernio.disconnect_account(account)

      assert [{:disconnect, "DELETE", "/api/v1/accounts/zacct_9", headers}] =
               disconnect_requests()

      assert {"authorization", "Bearer " <> @disconnect_key} in headers
    end

    test "404 (already disconnected) is :ok", ctx do
      {_profile, account} = account!(ctx.org_id, "linkedin")
      put_human_key!()
      stub_disconnect(404, %{"error" => "Account not found"})

      assert :ok = Zernio.disconnect_account(account)
      assert [{:disconnect, "DELETE", "/api/v1/accounts/zacct_1", _}] = disconnect_requests()
    end

    test "503 is an error", ctx do
      {_profile, account} = account!(ctx.org_id, "linkedin")
      put_human_key!()
      stub_disconnect(503, %{"error" => "down"})

      assert {:error, _} = Zernio.disconnect_account(account)
    end

    test "401 is the credentials error", ctx do
      {_profile, account} = account!(ctx.org_id, "linkedin")
      put_human_key!()
      stub_disconnect(401, %{"error" => "Unauthorized"})

      assert {:error, :credentials_rejected} = Zernio.disconnect_account(account)
    end

    test "with no Vault key, it errors and sends nothing", ctx do
      {_profile, account} = account!(ctx.org_id, "linkedin")
      stub_disconnect(200, %{"message" => "Account disconnected successfully"})

      assert {:error, :credentials_unavailable} = Zernio.disconnect_account(account)
      assert disconnect_requests() == []
    end

    for {label, ref} <- [{"nil", nil}, {"blank", "  "}] do
      test "a #{label} provider_account_ref is :not_connected and sends nothing", ctx do
        {_profile, account} =
          account!(ctx.org_id, "linkedin", %{provider_account_ref: unquote(ref)})

        put_human_key!()
        stub_disconnect(200, %{"message" => "Account disconnected successfully"})

        assert {:error, :not_connected} = Zernio.disconnect_account(account)
        assert disconnect_requests() == []
      end
    end
  end

  describe "verify_webhook/2" do
    defp sign(body, secret),
      do: :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    defp envelope(event, platforms) do
      Jason.encode!(%{
        id: "evt_1",
        event: event,
        timestamp: "2026-10-15T00:00:00Z",
        post: %{_id: "zp_1", platforms: platforms}
      })
    end

    test "a body signed with :crypto.mac is accepted and normalized" do
      body =
        envelope("post.published", [
          %{platformPostId: "1", publishedUrl: "https://li.example.test/9"}
        ])

      assert {:ok, [event]} =
               Zernio.verify_webhook(
                 %{raw_body: body, headers: %{"x-zernio-signature" => sign(body, @secret)}},
                 @secret
               )

      assert event == %{
               event_id: "evt_1",
               external_id: "zp_1",
               kind: :published,
               external_url: "https://li.example.test/9",
               error: nil
             }
    end

    test "the legacy X-Late-Signature header works" do
      body = envelope("post.failed", [%{error: "media too large", errorCategory: "media"}])

      assert {:ok, [%{kind: :failed, error: "media too large (media)"}]} =
               Zernio.verify_webhook(
                 %{raw_body: body, headers: %{"x-late-signature" => sign(body, @secret)}},
                 @secret
               )
    end

    test "a bad signature, a wrong secret, a tampered body or no header is refused" do
      body = envelope("post.published", [%{publishedUrl: "https://li.example.test/9"}])
      good = sign(body, @secret)
      tampered = String.replace(body, "li.example.test/9", "li.example.test/8")

      for {raw, headers} <- [
            {body, %{"x-zernio-signature" => "00" <> String.slice(good, 2..-1//1)}},
            {body, %{"x-zernio-signature" => sign(body, "other-secret")}},
            {tampered, %{"x-zernio-signature" => good}},
            {body, %{}}
          ] do
        assert {:error, :invalid_signature} =
                 Zernio.verify_webhook(%{raw_body: raw, headers: headers}, @secret)
      end
    end

    test "partial, cancelled and other events" do
      for {event, platforms, expected} <- [
            {"post.partial", [%{platformPostId: "1", publishedUrl: "https://li.example.test/p"}],
             {:published, nil}},
            {"post.partial", [%{error: "nope"}], {:failed, "nope"}},
            {"post.cancelled", [%{}], {:failed, "cancelled at vendor"}},
            {"post.tiktok.url_resolved", [%{}], {:ignored, nil}},
            {"account.connected", [], {:ignored, nil}}
          ] do
        body = envelope(event, platforms)
        {kind, error} = expected

        assert {:ok, [%{kind: ^kind, error: ^error}]} =
                 Zernio.verify_webhook(
                   %{raw_body: body, headers: %{"x-zernio-signature" => sign(body, @secret)}},
                   @secret
                 )
      end
    end
  end

  describe "swappable: the stage-2 publish path with Zernio selected" do
    setup do
      previous = Application.get_env(:social, :publisher)
      Application.put_env(:social, :publisher, Zernio)
      on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
      :ok
    end

    test "an approved post is scheduled via Zernio, then published by apply_outcome", ctx do
      {_, account} = account!(ctx.org_id, "linkedin")
      put_key!(account)
      post = approved_post!(ctx.org_id, account, %{body: "via zernio"})
      capture_post(201, %{"post" => %{"_id" => "zp_swap"}})

      assert {:ok, %Post{status: "scheduled", external_id: "zp_swap"}} =
               Publishing.publish_post(ctx.org_id, post.id)

      assert_received {:zernio, "POST", "/api/v1/posts", headers, %{"content" => "via zernio"}}
      assert {"idempotency-key", post.id} in headers

      assert {:ok, %Post{status: "published"}} =
               Publishing.apply_outcome(Repo.get!(Post, post.id), %{
                 kind: :published,
                 external_url: "https://li.example.test/s",
                 error: nil
               })
    end

    test "the guard still refuses before any request; a missing key fails the post closed", ctx do
      {_, account} = account!(ctx.org_id, "linkedin")
      refuse_any_request()

      {:ok, draft} = Platform.Social.create_post(ctx.org_id, account, %{body: "draft"})
      assert {:error, :not_approved} = Publishing.publish_post(ctx.org_id, draft.id)

      post = approved_post!(ctx.org_id, account)

      assert {:error, {:publish_failed, :credentials_unavailable}} =
               Publishing.publish_post(ctx.org_id, post.id)

      assert %{status: "failed", error: "the account's credentials are unavailable"} =
               Repo.get!(Post, post.id)
    end
  end

  describe "HTTP client discipline" do
    test ":httpc, HTTPoison and Tesla appear nowhere under apps/social/lib" do
      lib = Path.expand("../../../../lib", __DIR__)
      files = Path.wildcard(Path.join(lib, "**/*.ex"))
      assert files != []

      offenders =
        for path <- files,
            source = File.read!(path),
            pattern <- [":httpc", "HTTPoison", "Tesla"],
            String.contains?(source, pattern),
            do: {Path.relative_to(path, lib), pattern}

      assert offenders == []
    end
  end
end
