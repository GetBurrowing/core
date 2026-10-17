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
        {_, account} = account!(ctx.org_id, platform)
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
      {_, a2} = account!(org_id!(), "x")
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
