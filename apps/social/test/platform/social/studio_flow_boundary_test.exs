defmodule Platform.Social.StudioFlowBoundaryTest do
  @moduledoc """
  Social Studio slice A: the flow boundary (items a to g).

  A Studio post is planned inside Burrow and never sent. These tests run with
  `Publisher.Fake` configured as the real publisher would be
  (`config :social, :publisher`), and assert the Fake received ZERO calls on
  every send-side path: the DB CHECK is a second line of defence, because it
  cannot undo an external send that already happened.

  Two tiers:

    * states a Studio row can really hold (`approved`, `planned`), and
    * forged states (`drop_boundary_check!/0`, then a vendor id, a publish
      timer or status `scheduled`), which prove each CODE refusal on its own,
      with the CHECK out of the picture.

  The Fake's call log is a global ETS table, so this file is `async: false`.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{ClipPublish, Post, PostEvent, PostEvents, PublishRetry, Publishing}
  alias Platform.Social.{RateLimit, Secrets, WebhookPlug}
  alias Platform.Social.Publisher.Fake

  @secret "studio-boundary-secret-not-real"

  setup do
    Fake.reset()
    RateLimit.reset()
    w = studio_world!()
    # The adapter is the Fake, exactly as production would have a real one.
    assert Application.get_env(:social, :publisher) == Fake
    %{w: w}
  end

  defp row(post), do: Repo.get!(Post, post.id)
  defp event_count, do: Repo.aggregate(PostEvent, :count)

  defp assert_inert(post, before) do
    assert row(post) == before
    assert Fake.calls() == []
  end

  describe "publish and retry" do
    test "publish_post refuses an approved and a planned Studio post, writing nothing", %{w: w} do
      for status <- ~w(approved planned) do
        post = studio_post!(w, w.x, status)
        before = row(post)
        events = event_count()

        assert {:error, :studio_post} = Publishing.publish_post(w.org_id, post.id)

        assert row(post) == before
        assert event_count() == events
        assert Fake.calls() == []
      end
    end

    test "publishable?/1 is false for a Studio post that has a live approver, true for legacy",
         %{w: w} do
      studio = studio_post!(w, w.x, "approved")
      assert is_binary(studio.approved_by_user_id)
      refute Publishing.publishable?(studio)

      legacy = approved_post!(w.org_id, w.x, %{body: "legacy"}, w.approver)
      assert Publishing.publishable?(legacy)
    end

    test "legacy posts still publish through the same function (control)", %{w: w} do
      legacy = approved_post!(w.org_id, w.x, %{body: "legacy"}, w.approver)
      assert {:ok, %Post{status: "scheduled"}} = Publishing.publish_post(w.org_id, legacy.id)
      assert [{:publish, _, _}] = Fake.calls(:publish)
    end

    test "retry_publish refuses before the approver check, for an approver and a stranger",
         %{w: w} do
      post =
        w |> studio_post!(w.x, "approved") |> force!(refused_reason: "publisher_not_configured")

      before = row(post)
      stranger = user!()

      for actor <- [w.approver.id, stranger.id, w.agent.id] do
        assert {:error, :studio_post} = Publishing.retry_publish(w.org_id, post.id, actor)
      end

      assert_inert(post, before)
    end

    test "a clip post retry inherits the refusal", %{w: w} do
      clip = pending_clip!(w)

      post =
        w
        |> studio_post!(w.x, "approved")
        |> force!(clip_id: clip.id, refused_reason: "rate_limited")

      before = row(post)

      assert {:error, :studio_post} = Social.retry_post(w.org_id, post.id, w.approver.id)
      assert_inert(post, before)
    end
  end

  describe "vendor cancel, status read and outcomes, CHECK removed" do
    setup %{w: w} do
      drop_boundary_check!()
      forged = w |> studio_post!(w.x, "approved") |> forge_sent!("scheduled")
      %{forged: forged}
    end

    test "cancel_post refuses a Studio post before the publisher is consulted", %{
      w: w,
      forged: forged
    } do
      before = row(forged)
      assert {:error, :studio_post} = Publishing.cancel_post(w.org_id, forged.id)
      assert_inert(forged, before)
    end

    test "refresh_status refuses a Studio post before the publisher is consulted", %{
      w: w,
      forged: forged
    } do
      before = row(forged)
      assert {:error, :studio_post} = Publishing.refresh_status(w.org_id, forged.id)
      assert_inert(forged, before)
    end

    test "apply_outcome refuses every outcome kind on a forged Studio post", %{forged: forged} do
      before = row(forged)
      events = event_count()

      for kind <- [:published, :failed, :ignored] do
        assert {:error, :studio_post} =
                 Publishing.apply_outcome(forged, %{kind: kind, external_url: "https://x.test/p"})
      end

      assert_inert(forged, before)
      assert event_count() == events
    end

    test "legacy cancel_post still reaches the vendor (control)", %{w: w} do
      legacy = approved_post!(w.org_id, w.x, %{body: "legacy"}, w.approver)
      {:ok, scheduled} = Publishing.publish_post(w.org_id, legacy.id)
      Fake.reset()

      assert {:ok, %Post{status: "failed"}} = Publishing.cancel_post(w.org_id, scheduled.id)
      assert [{:delete, _, _}] = Fake.calls(:delete)
    end
  end

  describe "apply_outcome on a real Studio state" do
    test "approved and planned posts are refused, not transitioned", %{w: w} do
      for status <- ~w(approved planned), kind <- [:published, :failed] do
        post = studio_post!(w, w.x, status)
        before = row(post)

        assert {:error, :studio_post} = Publishing.apply_outcome(post, %{kind: kind})
        assert_inert(post, before)
      end
    end
  end

  describe "inbound webhook" do
    setup %{w: w} do
      {:ok, _} =
        Platform.Vault.put(Secrets.webhook_slug(w.profile.id), :custom, @secret,
          scope: Secrets.scope(w.profile.id),
          provider: "social"
        )

      :ok
    end

    defp deliver(profile_id, external_id, kind) do
      payload =
        Fake.webhook_body([%{event_id: "evt-#{unique()}", external_id: external_id, kind: kind}])

      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header(Fake.signature_header(), Fake.sign(payload, @secret))
      |> post("/api/ext/social/webhooks/#{profile_id}", payload)
    end

    test "an event naming a forged Studio post's vendor id changes nothing", %{w: w} do
      drop_boundary_check!()
      forged = w |> studio_post!(w.x, "approved") |> forge_sent!("scheduled", "ext-studio-1")
      before = row(forged)

      for kind <- ["published", "failed"] do
        conn = deliver(w.profile.id, "ext-studio-1", kind)
        assert %{"ok" => true, "applied" => 0} = json_response(conn, 200)
      end

      assert row(forged) == before
      assert send_calls() == []
    end

    test "the event lookup never returns a Studio post, and still finds a legacy one", %{w: w} do
      drop_boundary_check!()
      forged = w |> studio_post!(w.x, "approved") |> forge_sent!("scheduled", "ext-studio-2")
      assert WebhookPlug.post_for_event(w.profile, forged.external_id) == nil

      legacy = approved_post!(w.org_id, w.x, %{body: "legacy"}, w.approver)
      {:ok, legacy} = Publishing.publish_post(w.org_id, legacy.id)
      assert %Post{id: id} = WebhookPlug.post_for_event(w.profile, legacy.external_id)
      assert id == legacy.id
    end
  end

  describe "background sweeps" do
    test "PublishRetry.due never lists a Studio post and a sweep makes no call", %{w: w} do
      post =
        w
        |> studio_post!(w.x, "approved")
        |> force!(
          refused_reason: "rate_limited",
          refused_at: DateTime.utc_now(),
          retry_after: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      before = row(post)
      assert PublishRetry.due(DateTime.utc_now()) == []

      name = :"studio_retry_#{unique()}"
      pid = start_supervised!({PublishRetry, name: name, interval_ms: :infinity})
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

      assert PublishRetry.sweep_now(name) == []
      assert_inert(post, before)
    end

    test "PublishRetry.due still lists a legacy rate-limited post (control)", %{w: w} do
      legacy = approved_post!(w.org_id, w.x, %{body: "legacy"}, w.approver)

      legacy =
        force!(legacy,
          refused_reason: "rate_limited",
          refused_at: DateTime.utc_now(),
          retry_after: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      assert [{org, id}] = PublishRetry.due(DateTime.utc_now())
      assert {org, id} == {w.org_id, legacy.id}
    end

    test "ClipPublish never lists, claims or sweeps a Studio post (CHECK removed)", %{w: w} do
      drop_boundary_check!()
      clip = pending_clip!(w)
      now = DateTime.utc_now()

      due =
        w
        |> studio_post!(w.x, "approved")
        |> force!(clip_id: clip.id, publish_after: DateTime.add(now, -5, :second))

      waiting =
        w
        |> studio_post!(w.x, "approved")
        |> force!(clip_id: clip.id, publish_after: DateTime.add(now, 600, :second))

      before_due = row(due)
      before_waiting = row(waiting)

      assert ClipPublish.due(now) == []
      assert ClipPublish.next_due(now) == nil
      assert {:ok, :skipped} = ClipPublish.publish_due(w.org_id, due.id, now)

      name = :"studio_clip_publish_#{unique()}"

      pid =
        start_supervised!({ClipPublish, name: name, interval_ms: :infinity, boot_sweep: false})

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      assert ClipPublish.sweep_now(name, now) == []

      assert_inert(due, before_due)
      assert row(waiting) == before_waiting
    end

    test "ClipPublish.due still lists a legacy clip post (control)", %{w: w} do
      clip = pending_clip!(w)
      now = DateTime.utc_now()

      legacy =
        w.org_id
        |> approved_post!(w.x, %{body: "legacy"}, w.approver)
        |> force!(clip_id: clip.id, publish_after: DateTime.add(now, -5, :second))

      assert [{org, id}] = ClipPublish.due(now)
      assert {org, id} == {w.org_id, legacy.id}
    end
  end

  describe "account removal" do
    test "removal succeeds, leaves Studio rows unchanged and cancels only legacy posts", %{w: w} do
      studio =
        for status <- ~w(draft needs_approval approved planned),
            do: studio_post!(w, w.x, status)

      before = Enum.map(studio, &row/1)

      {:ok, legacy} =
        Social.create_post(w.org_id, w.x, %{body: "legacy", status: "needs_approval"})

      assert {:ok, %{cancelled: 1, shared: 0}} =
               Social.removal_preview(w.org_id, w.profile, w.x.id)

      assert {:ok, archived, %{cancelled: 1, shared: 0}} =
               Social.remove_account(w.org_id, w.profile, w.approver.id, w.x.id)

      assert archived.archived_at
      assert Enum.map(studio, &row/1) == before
      assert row(legacy).status == "failed"
      assert Fake.calls() == []
    end
  end

  describe "database second line" do
    defp set!(post, fields) do
      # Its own savepoint, so a refused write leaves the sandbox usable.
      Repo.transaction(fn ->
        Repo.update_all(from(p in Post, where: p.id == ^post.id), set: fields)
      end)
    end

    defp constraint_of(fun) do
      error = assert_raise Postgrex.Error, fun
      error.postgres.constraint
    end

    test "a Studio row cannot take a vendor id, a publish timer or a sent status", %{w: w} do
      for status <- ~w(draft needs_approval approved planned) do
        post = studio_post!(w, w.x, status)

        for fields <- [
              [external_id: "ext-1"],
              [external_url: "https://x.test/p"],
              [analytics_external_id: "an-1"],
              [publish_after: DateTime.utc_now()],
              [status: "scheduled"],
              [status: "published"],
              [status: "failed"]
            ] do
          # Give every row an approver so the approver CHECK (which sorts
          # first) is not what answers: only the boundary CHECK is under test.
          fields =
            if Keyword.has_key?(fields, :status),
              do: fields ++ [approved_by_user_id: w.approver.id, approved_at: DateTime.utc_now()],
              else: fields

          assert constraint_of(fn -> set!(post, fields) end) ==
                   "social_posts_studio_boundary_check",
                 "#{status} accepted #{inspect(fields)}"
        end
      end
    end

    test "status planned is refused on a legacy post", %{w: w} do
      legacy = approved_post!(w.org_id, w.x, %{body: "legacy"}, w.approver)

      assert constraint_of(fn -> set!(legacy, status: "planned") end) ==
               "social_posts_planned_only_studio_check"
    end
  end

  describe "legacy functions refuse Studio rows" do
    test "approve_post, update_post, delete_post, set_cover, set_platform_options", %{w: w} do
      post = studio_post!(w, w.x, "needs_approval")
      before = row(post)
      events = event_count()

      assert {:error, :studio_post} = Social.approve_post(w.org_id, post, w.approver.id)

      assert {:error, :studio_post} =
               Social.approve_post(w.org_id, post, w.approver.id, lock: true)

      assert {:error, :studio_post} = Social.update_post(w.org_id, post, %{body: "legacy edit"})
      assert {:error, :studio_post} = Social.delete_post(w.org_id, post)
      assert {:error, :studio_post} = Social.set_cover(w.org_id, w.approver.id, post.id, :clear)

      assert {:error, :studio_post} =
               Social.set_platform_options(w.org_id, w.approver.id, post.id, %{})

      assert row(post) == before
      assert event_count() == events
      assert Fake.calls() == []
    end

    test "update_post cannot smuggle flow or a version in", %{w: w} do
      {:ok, legacy} = Social.create_post(w.org_id, w.x, %{body: "legacy"})

      {:ok, updated} =
        Social.update_post(w.org_id, legacy, %{body: "edited", flow: "studio", version: 9})

      assert {updated.flow, updated.version} == {"legacy", 1}
    end

    test "delete_profile refuses while Studio posts exist, and works without them", %{w: w} do
      post = studio_post!(w, w.x, "draft")

      assert {:error, :has_studio_posts} = Social.delete_profile(w.org_id, w.profile)
      assert Repo.get(Social.Profile, w.profile.id)
      assert row(post)

      {:ok, plain} = Social.create_profile(w.org_id, %{name: "Plain #{unique()}"})
      assert {:ok, _} = Social.delete_profile(w.org_id, plain)
    end

    test "the legacy card decisions refuse a Studio post and never publish", %{w: w} do
      alias Platform.Social.{ApprovalCard, Approvals}
      # A card pointing at a post that is then marked Studio: the decision
      # paths must refuse it on the locked row, before approve or publish.
      {:ok, legacy} =
        Social.create_post(w.org_id, w.x, %{body: "carded", status: "needs_approval"})

      card = Repo.one!(from(c in ApprovalCard, where: c.post_id == ^legacy.id))
      Repo.update_all(from(p in Post, where: p.id == ^legacy.id), set: [flow: "studio"])
      before = row(legacy)
      fp = Approvals.fingerprint(before)

      assert {:error, :studio_post} = Approvals.decide_approve(card.canvas_id, w.approver, fp)

      assert {:error, :studio_post} =
               Approvals.decide_approve_at(
                 card.canvas_id,
                 w.approver,
                 fp,
                 DateTime.add(DateTime.utc_now(), 3_600, :second)
               )

      assert {:error, :studio_post} =
               Approvals.decide_edit(card.canvas_id, w.approver, %{body: "x"}, fp)

      assert {:error, :studio_post} =
               Approvals.decide_reject(card.canvas_id, w.approver, "no", fp)

      assert row(legacy) == before
      assert Fake.calls() == []
    end

    test "a Studio post never gets an approval card", %{w: w} do
      alias Platform.Social.{ApprovalCard, Approvals}
      post = studio_post!(w, w.x, "needs_approval")

      assert {:error, :studio_post} = Approvals.request_approval(post)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Social.needs_approval_written(post) == post
        end)

      # Refused silently: no fan-out was attempted, so none "failed".
      refute log =~ "approval fan-out"
      assert Repo.aggregate(from(c in ApprovalCard, where: c.post_id == ^post.id), :count) == 0
    end
  end

  describe "event log" do
    test "events written for a studio create carry version and account", %{w: w} do
      post = studio_post!(w, w.x, "needs_approval")
      events = PostEvents.list_for_post(post.id)
      assert Enum.map(events, & &1.action) == ["created", "submitted"]
      assert Enum.all?(events, &(&1.post_version == 1 and &1.account_id == w.x.id))
    end
  end
end
