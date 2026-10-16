defmodule Platform.Social.WebhookTest do
  @moduledoc """
  The signed status webhook end to end, through core's real router and the
  generic `/api/ext/<prefix>` seam, with the Fake publisher's signature.

  Every refusal asserts the post row is BYTE-IDENTICAL afterwards
  (`updated_at` included), not merely that the status is unchanged.
  Not async: the Fake's call log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social.{Post, Publishing, Secrets}
  alias Platform.Social.Publisher.Fake

  @secret "webhook-test-secret-not-real"

  setup do
    Fake.reset()
    Platform.Social.RateLimit.reset()
    org_id = org_id!()
    {profile, account} = social_account!(org_id, "linkedin")
    put_secret!(profile.id, @secret)
    post = approved_post!(org_id, account, %{body: "ship it"})
    {:ok, scheduled} = Publishing.publish_post(org_id, post.id)
    %{org_id: org_id, profile: profile, account: account, post: scheduled}
  end

  defp put_secret!(profile_id, value) do
    {:ok, _} =
      Platform.Vault.put(Secrets.webhook_slug(profile_id), :custom, value,
        scope: Secrets.scope(profile_id),
        provider: "social"
      )
  end

  defp body(external_id, kind, extra \\ %{}) do
    Fake.webhook_body([
      Map.merge(%{event_id: "evt-#{unique()}", external_id: external_id, kind: kind}, extra)
    ])
  end

  defp deliver(conn, profile_id, body, signature) do
    conn = put_req_header(conn, "content-type", "application/json")

    conn =
      if signature, do: put_req_header(conn, Fake.signature_header(), signature), else: conn

    post(conn, "/api/ext/social/webhooks/#{profile_id}", body)
  end

  defp row(post), do: Repo.get!(Post, post.id)

  describe "refusals: 401 and the row unchanged" do
    test "bad signature, missing header, wrong secret, tampered body", ctx do
      before = row(ctx.post)
      good = body(ctx.post.external_id, "published", %{external_url: "https://example.test/p/1"})
      <<first, rest::binary>> = good
      tampered = <<first>> <> String.replace(rest, "p/1", "p/2")

      for {payload, sig} <- [
            {good, "deadbeef"},
            {good, nil},
            {good, Fake.sign(good, "the-wrong-secret")},
            {tampered, Fake.sign(good, @secret)}
          ] do
        conn = deliver(build_conn(), ctx.profile.id, payload, sig)
        assert json_response(conn, 401) == %{"error" => "unauthorized"}
        assert row(ctx.post) == before
      end
    end

    test "no Vault secret for the profile", ctx do
      {other_profile, other_account} = social_account!(ctx.org_id, "linkedin")
      other = approved_post!(ctx.org_id, other_account)
      {:ok, other} = Publishing.publish_post(ctx.org_id, other.id)
      before = row(other)
      payload = body(other.external_id, "published")

      conn = deliver(build_conn(), other_profile.id, payload, Fake.sign(payload, @secret))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert row(other) == before
    end

    test "an unknown or malformed profile id answers the same 401", ctx do
      payload = body(ctx.post.external_id, "published")
      sig = Fake.sign(payload, @secret)

      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        assert json_response(deliver(build_conn(), id, payload, sig), 401) ==
                 %{"error" => "unauthorized"}
      end
    end

    test "anything but POST /webhooks/:profile_id is a 404", ctx do
      assert json_response(get(build_conn(), "/api/ext/social/webhooks/#{ctx.profile.id}"), 404)
      assert json_response(post(build_conn(), "/api/ext/social/other", %{}), 404)
    end
  end

  describe "verified deliveries" do
    test "published sets external_url; a replay is a 200 and changes nothing", ctx do
      payload =
        body(ctx.post.external_id, "published", %{external_url: "https://example.test/p/1"})

      sig = Fake.sign(payload, @secret)

      assert %{"ok" => true, "applied" => 1} =
               json_response(deliver(build_conn(), ctx.profile.id, payload, sig), 200)

      published = row(ctx.post)
      assert published.status == "published"
      assert published.external_url == "https://example.test/p/1"
      assert published.approved_by_user_id == ctx.post.approved_by_user_id
      assert published.approved_at == ctx.post.approved_at

      assert %{"applied" => 0} =
               json_response(deliver(build_conn(), ctx.profile.id, payload, sig), 200)

      assert row(ctx.post) == published

      # A later failed delivery does not regress a published post.
      failed = body(ctx.post.external_id, "failed", %{error: "late failure"})

      assert json_response(
               deliver(build_conn(), ctx.profile.id, failed, Fake.sign(failed, @secret)),
               200
             )

      assert row(ctx.post) == published
    end

    test "failed sets the error", ctx do
      payload = body(ctx.post.external_id, "failed", %{error: "media rejected by platform"})

      assert json_response(
               deliver(build_conn(), ctx.profile.id, payload, Fake.sign(payload, @secret)),
               200
             )

      assert %{status: "failed", error: "media rejected by platform"} = row(ctx.post)
    end

    test "a delivery naming another profile's post does not change it", ctx do
      {q_profile, q_account} = social_account!(ctx.org_id, "linkedin")
      put_secret!(q_profile.id, "q-secret-not-real")
      q_post = approved_post!(ctx.org_id, q_account)
      {:ok, q_post} = Publishing.publish_post(ctx.org_id, q_post.id)
      before = row(q_post)

      payload = body(q_post.external_id, "published", %{external_url: "https://example.test/q"})

      assert %{"applied" => 0} =
               json_response(
                 deliver(build_conn(), ctx.profile.id, payload, Fake.sign(payload, @secret)),
                 200
               )

      assert row(q_post) == before
    end

    test "a valid delivery for a draft post does not change it", ctx do
      {:ok, draft} = Platform.Social.create_post(ctx.org_id, ctx.account, %{body: "d"})

      {1, _} =
        Repo.update_all(from(p in Post, where: p.id == ^draft.id),
          set: [external_id: "fake_draft"]
        )

      before = row(draft)
      payload = body("fake_draft", "published", %{external_url: "https://example.test/d"})

      assert %{"applied" => 0} =
               json_response(
                 deliver(build_conn(), ctx.profile.id, payload, Fake.sign(payload, @secret)),
                 200
               )

      assert row(draft) == before
    end

    test "unknown external ids and ignored kinds are a 200 that changes nothing", ctx do
      before = row(ctx.post)

      payload =
        Fake.webhook_body([
          %{event_id: "e1", external_id: "fake_unknown", kind: "published"},
          %{event_id: "e2", external_id: ctx.post.external_id, kind: "boosted"}
        ])

      assert %{"applied" => 0} =
               json_response(
                 deliver(build_conn(), ctx.profile.id, payload, Fake.sign(payload, @secret)),
                 200
               )

      assert row(ctx.post) == before
    end
  end
end
