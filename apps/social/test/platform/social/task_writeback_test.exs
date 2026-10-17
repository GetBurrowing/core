defmodule Platform.Social.TaskWritebackTest do
  @moduledoc """
  Social 6/7 stage 2: the task records its post URLs once every linked
  draft is terminal. `async: false`: the Fake's call log is global, and
  the concurrency test shares the sandbox connection.
  """
  use Platform.DataCase, async: false

  import Platform.SocialBridgeFixtures
  import Platform.SocialApprovalFixtures, only: [live_card!: 1]

  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Approvals, Post, Publishing, RateLimit, TaskBridge}
  alias Platform.Social.Publisher.Fake
  alias Platform.Tasks

  setup do
    Fake.reset()
    RateLimit.reset()
    w = bridge_world!()
    seg = segment_id()
    candidate!(w.meeting, seg)
    {:ok, %{task: task, request: req}} = TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg]))
    %{w: w, task: task, req: req}
  end

  defp drafts!(w, task, accounts) do
    {:ok, posts} =
      AgentDrafts.create_agent_drafts(w.scope, w.profile.id, %{
        "account_ids" => Enum.map(accounts, & &1.id),
        "body" => "the doomsday clock bit",
        "task_id" => task.id
      })

    posts
  end

  defp approve!(w, post) do
    {:ok, %{post: post}} = Approvals.decide_approve(live_card!(post).canvas_id, w.approver)
    post
  end

  defp publish!(post, url) do
    {:ok, %Post{status: "published"} = post} =
      Publishing.apply_outcome(post, %{kind: :published, external_url: url})

    post
  end

  defp reject!(w, post, reason) do
    {:ok, %{post: post}} =
      Approvals.decide_reject(live_card!(post).canvas_id, w.approver, reason)

    post
  end

  defp task(task), do: Tasks.get_task_record(task.id)
  defp result(task), do: task(task).metadata["social"]["result"]
  defp blocks(task), do: length(String.split(task(task).description, "<!-- social:posts -->")) - 1

  describe "settlement" do
    test "one of two published: no write; both: one write with both URLs", %{w: w, task: t} do
      [l, x] = drafts!(w, t, [w.linkedin, w.x])
      l = w |> approve!(l) |> publish!("https://linkedin.example.test/p/1")
      before = task(t)

      assert TaskBridge.post_changed(l.id) == :not_settled
      assert is_nil(result(t))
      assert task(t).updated_at == before.updated_at
      refute task(t).description =~ "social:posts"

      x = w |> approve!(x) |> publish!("https://x.example.test/p/2")
      after_write = task(t)

      assert %{"posts" => posts, "settled_at" => _} = result(t)
      assert Enum.map(posts, & &1["post_id"]) == Enum.sort([l.id, x.id])
      assert Enum.all?(posts, &(&1["outcome"] == "published"))
      refute Enum.any?(posts, &Map.has_key?(&1, "stats"))

      assert Enum.sort(Enum.map(posts, & &1["external_url"])) ==
               ["https://linkedin.example.test/p/1", "https://x.example.test/p/2"]

      assert after_write.description =~ "- LINKEDIN @bridge: https://linkedin.example.test/p/1"
      assert after_write.description =~ "- X @bridge_x: https://x.example.test/p/2"
      assert blocks(t) == 1
      assert after_write.status == before.status
      assert TaskBridge.request_for_task(t.id).settled_digest
    end

    test "a webhook replay leaves the task untouched", %{w: w, task: t} do
      [l, x] = drafts!(w, t, [w.linkedin, w.x])
      l = w |> approve!(l) |> publish!("https://linkedin.example.test/p/1")
      w |> approve!(x) |> publish!("https://x.example.test/p/2")
      settled = task(t)

      assert {:ok, :noop} =
               Publishing.apply_outcome(l, %{kind: :published, external_url: "https://other"})

      assert TaskBridge.post_changed(l.id) == :noop
      assert TaskBridge.post_changed(x.id) == :noop
      assert task(t).updated_at == settled.updated_at
      assert task(t).metadata == settled.metadata
    end

    test "published + rejected records both outcomes", %{w: w, task: t} do
      [l, x] = drafts!(w, t, [w.linkedin, w.x])
      w |> approve!(l) |> publish!("https://linkedin.example.test/p/1")
      assert is_nil(result(t))

      reject!(w, x, "too salesy")

      outcomes = Map.new(result(t)["posts"], &{&1["post_id"], &1})
      assert outcomes[l.id]["outcome"] == "published"
      assert outcomes[x.id]["outcome"] == "rejected"
      assert outcomes[x.id]["rejection_reason"] == "too salesy"
      assert task(t).description =~ "- X @bridge_x: rejected: too salesy"
      assert blocks(t) == 1
    end

    test "reject then redraft is not settled; the later publish writes once more", %{
      w: w,
      task: t
    } do
      [l, x] = drafts!(w, t, [w.linkedin, w.x])
      w |> approve!(l) |> publish!("https://linkedin.example.test/p/1")
      reject!(w, x, "too salesy")
      first = task(t)
      first_digest = TaskBridge.request_for_task(t.id).settled_digest

      {:ok, redrafted} =
        AgentDrafts.update_agent_draft(w.scope, x.id, %{
          "body" => "calmer",
          "status" => "needs_approval"
        })

      assert redrafted.rejected_at
      assert TaskBridge.post_changed(x.id) == :not_settled
      assert task(t).updated_at == first.updated_at

      w |> approve!(redrafted) |> publish!("https://x.example.test/p/2")
      second = task(t)

      assert DateTime.compare(second.updated_at, first.updated_at) == :gt
      assert TaskBridge.request_for_task(t.id).settled_digest != first_digest
      assert Enum.all?(result(t)["posts"], &(&1["outcome"] == "published"))
      assert blocks(t) == 1
      assert TaskBridge.post_changed(x.id) == :noop
      assert task(t).updated_at == second.updated_at
    end

    test "a failed publish is terminal", %{w: w, task: t} do
      [l, x] = drafts!(w, t, [w.linkedin, w.x])
      w |> approve!(l) |> publish!("https://linkedin.example.test/p/1")
      Fake.fail_next(:publish, "vendor said no")
      assert %Post{status: "failed"} = approve!(w, x)

      outcomes = Map.new(result(t)["posts"], &{&1["post_id"], &1})
      assert outcomes[x.id]["outcome"] == "failed"
      assert outcomes[x.id]["error"] == "vendor said no"
      assert task(t).description =~ "- X @bridge_x: failed: vendor said no"
    end

    test "a draft_only post is manual and does not block", %{w: w, task: t} do
      {:ok, d} =
        Social.create_account(w.org_id, w.profile, %{
          platform: "linkedin",
          handle: "@drafts",
          approval_mode: "draft_only"
        })

      [l, dp] = drafts!(w, t, [w.linkedin, d])
      assert is_nil(result(t))
      w |> approve!(l) |> publish!("https://linkedin.example.test/p/1")

      outcomes = Map.new(result(t)["posts"], &{&1["post_id"], &1})
      assert outcomes[dp.id]["outcome"] == "manual"
      assert task(t).description =~ "- LINKEDIN @drafts: draft only, to post by hand"
    end

    test "a task whose only drafts are draft_only settles when they are drafted", %{w: w} do
      {:ok, d} =
        Social.create_account(w.org_id, w.profile, %{
          platform: "linkedin",
          handle: "@drafts",
          approval_mode: "draft_only"
        })

      seg = segment_id()
      candidate!(w.meeting, seg)

      {:ok, %{task: t}} =
        TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg], %{"platforms" => ["linkedin"]}))

      [dp] = drafts!(w, t, [d])
      assert [%{"post_id" => id, "outcome" => "manual"}] = result(t)["posts"]
      assert id == dp.id
    end
  end

  describe "replay and concurrency safety" do
    test "two concurrent settlements write once, with identical metadata", %{w: w, task: t} do
      [l, x] = drafts!(w, t, [w.linkedin, w.x])
      l = approve!(w, l)
      x = approve!(w, x)

      # Publish both WITHOUT the hook, so the settlement is still owed.
      for {p, url} <- [{l, "https://l.example.test/1"}, {x, "https://x.example.test/2"}] do
        p |> Ecto.Changeset.change(status: "published", external_url: url) |> Repo.update!()
      end

      before = task(t)

      results =
        [l.id, x.id]
        |> Enum.map(fn id -> Task.async(fn -> TaskBridge.post_changed(id) end) end)
        |> Task.await_many(10_000)

      assert Enum.sort(results) == [:noop, :settled]
      after_write = task(t)
      assert DateTime.compare(after_write.updated_at, before.updated_at) == :gt
      assert TaskBridge.post_changed(l.id) == :noop
      assert task(t).metadata == after_write.metadata
      assert blocks(t) == 1
    end

    test "a post with no task, or a task with no request row, is :noop", %{w: w} do
      {:ok, [loose]} =
        AgentDrafts.create_agent_drafts(w.scope, w.profile.id, %{
          "account_ids" => [w.x.id],
          "body" => "no task"
        })

      assert TaskBridge.post_changed(loose.id) == :noop

      {:ok, plain} = Tasks.create_task(%{project_id: w.project.id, title: "Plain"})

      {:ok, [linked]} =
        AgentDrafts.create_agent_drafts(w.scope, w.profile.id, %{
          "account_ids" => [w.x.id],
          "body" => "plain task",
          "task_id" => plain.id
        })

      assert TaskBridge.post_changed(linked.id) == :noop
      assert TaskBridge.post_changed(segment_id()) == :noop
      assert TaskBridge.post_changed("nope") == :noop
      assert task(plain).metadata == plain.metadata
    end

    test "existing metadata keys survive the merge", %{w: w, task: t} do
      {:ok, _} =
        Tasks.update_task(task(t), %{metadata: Map.put(task(t).metadata, "keep", "me")})

      [l] = drafts!(w, t, [w.linkedin])
      w |> approve!(l) |> publish!("https://linkedin.example.test/p/1")

      meta = task(t).metadata
      assert meta["keep"] == "me"
      assert meta["source"] == "social.request"
      assert meta["social"]["profile_id"] == w.profile.id
      assert meta["social"]["request_id"]
      assert meta["social"]["result"]
    end

    test "a human edit that deletes a marker never yields two blocks", %{w: w, task: t} do
      [l, x] = drafts!(w, t, [w.linkedin, w.x])
      w |> approve!(l) |> publish!("https://linkedin.example.test/p/1")
      reject!(w, x, "too salesy")

      edited = String.replace(task(t).description, "<!-- /social:posts -->", "")
      {:ok, _} = Tasks.update_task(task(t), %{description: edited <> "\nhuman note"})

      {:ok, redrafted} =
        AgentDrafts.update_agent_draft(w.scope, x.id, %{"status" => "needs_approval"})

      w |> approve!(redrafted) |> publish!("https://x.example.test/p/2")

      desc = task(t).description
      assert blocks(t) == 1
      assert length(String.split(desc, "<!-- /social:posts -->")) == 2
      assert desc =~ "human note"
      assert desc =~ "- X @bridge_x: https://x.example.test/p/2"
    end
  end

  describe "put_block/2" do
    test "replaces in place, drops copies, appends when absent" do
      block = "<!-- social:posts -->\n- X: new\n<!-- /social:posts -->"
      old = "<!-- social:posts -->\n- X: old\n<!-- /social:posts -->"

      assert TaskBridge.put_block("intro\n\n#{old}\n\noutro", block) ==
               "intro\n\n#{block}\n\noutro"

      assert TaskBridge.put_block("a #{old} b #{old} c", block) == "a #{block} b  c"
      assert TaskBridge.put_block(nil, block) == block <> "\n"
      assert TaskBridge.put_block("text\n", block) == "text\n\n" <> block <> "\n"

      assert TaskBridge.put_block("text <!-- social:posts --> stale", block) ==
               "text  stale\n\n" <> block <> "\n"
    end
  end

  test "post_changed is called from exactly the pinned sites" do
    lib = Path.expand("../../../lib", __DIR__)

    calls =
      for path <- Path.wildcard(Path.join(lib, "**/*.ex")),
          line <- path |> File.read!() |> String.split("\n"),
          line =~ "TaskBridge.post_changed(",
          do: Path.relative_to(path, lib)

    # platform/social.ex: remove_account/4 reports its cancelled posts (01a14ac6).
    assert Enum.sort(calls) == [
             "platform/social.ex",
             "platform/social/agent_drafts.ex",
             "platform/social/approvals.ex",
             "platform/social/publishing.ex"
           ]

    publishing = File.read!(Path.join(lib, "platform/social/publishing.ex"))
    # publish_post/2 step (h), cancel_post/2 and apply_outcome/2.
    assert length(Regex.scan(~r/^\s+terminal_written\(result, /m, publishing)) == 3
  end
end
