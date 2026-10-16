defmodule Platform.Social.TaskBridgeAcceptanceTest do
  @moduledoc """
  Social 6/7's "Done when", one describe per line, every refusal paired with
  its success on the same fixture. Through the doors production uses:
  `ToolArguments.dispatch/3` for the agent's tools, the approval card's
  decide path for the human, and the signed webhook route for the vendor.
  `async: false`: the Fake's call log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.SocialFixtures
  import Platform.SocialBridgeFixtures
  import Platform.SocialApprovalFixtures, only: [live_card!: 1]

  alias Platform.Federation.ToolArguments
  alias Platform.Meetings.Candidates
  alias Platform.Repo
  alias Platform.Social.{Approvals, Post, RateLimit, Secrets, TaskBridge}
  alias Platform.Social.Publisher.Fake
  alias Platform.Tasks

  @secret "bridge-acceptance-secret-not-real"

  setup do
    Fake.reset()
    RateLimit.reset()
    w = bridge_world!()
    join!(w.space.id, :agent, w.agent.id)
    join!(w.space.id, :user, w.approver.id)

    {:ok, _} =
      Platform.Vault.put(Secrets.webhook_slug(w.profile.id), :custom, @secret,
        scope: Secrets.scope(w.profile.id),
        provider: "social"
      )

    %{w: w, g: %{agent_id: w.agent.id, space_id: w.space.id}}
  end

  defp deliver(conn, profile_id, events) do
    body = Fake.webhook_body(events)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header(Fake.signature_header(), Fake.sign(body, @secret))
    |> post("/api/ext/social/webhooks/#{profile_id}", body)
  end

  defp ask(w, segs) do
    %{
      "profile_id" => w.profile.id,
      "platforms" => ["linkedin", "x"],
      "ask" => "clip the doomsday clock bit",
      "meeting_id" => w.meeting.id,
      "segment_ids" => segs
    }
  end

  describe "(a) meeting segment -> task -> agent drafts -> human approves -> publishes -> the task shows the post URLs" do
    test "the whole loop", %{conn: conn, w: w, g: g} do
      seg = segment_id()
      c = candidate!(w.meeting, seg)

      # 1. The agent files the ask.
      assert {:ok, %{task_id: task_id, created: true, status: "planning"}} =
               ToolArguments.dispatch("social_task_request", ask(w, [seg]), g)

      task = Tasks.get_task_record(task_id)
      assert task.project_id == w.project.id
      assert task.kind == "ops"

      for phase <- ~w(planning execution review),
          do: assert(task.phase_assignees[phase]["assignee_id"] == w.agent.id)

      assert task.metadata["social"]["profile_id"] == w.profile.id
      assert task.metadata["social"]["platforms"] == ["linkedin", "x"]

      assert task.metadata["social"]["refs"] == %{
               "meeting_id" => w.meeting.id,
               "segment_ids" => [seg]
             }

      assert %{closed_reason: :duplicate, closed_note: note} = Candidates.get(c.id)
      assert note == "filed as social task #{task_id}"

      # Paired refusal: an agent pinned to another org files nothing.
      g2 = pinned_agent!(org_id!())
      tasks = length(Tasks.list_tasks_by_project(w.project.id))

      assert {:error, %{code: :not_found}} =
               ToolArguments.dispatch("social_task_request", ask(w, [seg]), %{agent_id: g2.id})

      assert length(Tasks.list_tasks_by_project(w.project.id)) == tasks

      # 2. The agent drafts, linking each draft to the task.
      assert {:ok, %{count: 2, posts: posts}} =
               ToolArguments.dispatch(
                 "social_draft_create",
                 %{
                   "profile_id" => w.profile.id,
                   "account_ids" => [w.linkedin.id, w.x.id],
                   "body" => "The doomsday clock bit",
                   "task_id" => task_id
                 },
                 g
               )

      assert Enum.all?(posts, &(&1.status == "needs_approval" and &1.task_id == task_id))

      # 3. The human approves each card; the Fake schedules both.
      for p <- posts do
        post = Repo.get!(Post, p.id)

        assert {:ok, %{post: %{status: "scheduled"}}} =
                 Approvals.decide_approve(live_card!(post).canvas_id, w.approver)
      end

      assert length(Fake.calls(:publish)) == 2
      before_hook = Tasks.get_task_record(task_id)
      assert is_nil(before_hook.metadata["social"]["result"])

      # 4. The vendor reports each publish through the signed webhook.
      [first, second] = Enum.map(posts, &Repo.get!(Post, &1.id))
      url = fn post -> "https://social.example.test/#{post.id}" end

      event = fn post ->
        %{
          event_id: "evt-#{post.id}",
          external_id: post.external_id,
          kind: "published",
          external_url: url.(post)
        }
      end

      assert conn |> deliver(w.profile.id, [event.(first)]) |> response(200)
      assert is_nil(Tasks.get_task_record(task_id).metadata["social"]["result"])

      assert build_conn() |> deliver(w.profile.id, [event.(second)]) |> response(200)
      settled = Tasks.get_task_record(task_id)

      # 5. The task shows the URLs, in metadata and in the description.
      assert Enum.sort(
               Enum.map(settled.metadata["social"]["result"]["posts"], & &1["external_url"])
             ) ==
               Enum.sort([url.(first), url.(second)])

      assert Enum.all?(
               settled.metadata["social"]["result"]["posts"],
               &(&1["outcome"] == "published")
             )

      assert length(String.split(settled.description, "<!-- social:posts -->")) == 2
      assert settled.status == before_hook.status

      assert {:ok, via_mcp} = ToolArguments.dispatch("task_get", %{"task_id" => task_id}, g)
      desc = via_mcp |> Jason.encode!() |> Jason.decode!() |> Map.fetch!("description")
      assert desc =~ url.(first)
      assert desc =~ url.(second)

      # A replayed delivery writes nothing.
      assert build_conn() |> deliver(w.profile.id, [event.(second)]) |> response(200)
      assert Tasks.get_task_record(task_id).updated_at == settled.updated_at
      assert length(Fake.calls(:publish)) == 2
    end
  end

  describe "(b) no social task from a segment classed off-topic or retracted" do
    test "each guarded segment is refused, nothing changes, and a routable one files", %{
      w: w,
      g: g
    } do
      [off, dem, ret, veto, thr, none, ok] = for _ <- 1..7, do: segment_id()
      candidate!(w.meeting, off, %{classified_intent: "off_topic"})
      candidate!(w.meeting, dem, %{classified_intent: "off_topic", demoted_from: "task_create"})
      closed_candidate!(w.meeting, ret, :retracted, %{transcript_chunk_ids: [ret, thr]})
      closed_candidate!(w.meeting, veto, :vetoed)
      ok_candidate = candidate!(w.meeting, ok)

      before = snapshot(w)

      for {segs, code, named} <- [
            {[off], :segment_off_topic, off},
            {[dem], :segment_off_topic, dem},
            {[ret], :segment_retracted, ret},
            {[veto], :segment_retracted, veto},
            {[thr], :segment_retracted, thr},
            {[none], :segment_unclassified, none},
            {[ok, off], :segment_off_topic, off}
          ] do
        assert {:error, %{code: ^code} = envelope} =
                 ToolArguments.dispatch("social_task_request", ask(w, segs), g)

        assert envelope.error =~ named
        refute envelope.error =~ ok
        assert envelope.recoverable == (code == :segment_unclassified)
      end

      assert snapshot(w) == before
      assert Candidates.get(ok_candidate.id).state == :heard

      assert {:ok, %{created: true}} =
               ToolArguments.dispatch("social_task_request", ask(w, [ok]), g)

      assert Candidates.get(ok_candidate.id).closed_reason == :duplicate
      assert TaskBridge.request_for_task(hd(Tasks.list_tasks_by_project(w.project.id)).id)
    end
  end
end
