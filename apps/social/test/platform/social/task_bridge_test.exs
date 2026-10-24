defmodule Platform.Social.TaskBridgeTest do
  use Platform.DataCase, async: true

  import Platform.SocialFixtures
  import Platform.SocialBridgeFixtures

  alias Platform.Meetings.Candidates
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, TaskBridge, TaskRequest}
  alias Platform.Tasks

  setup do
    %{w: bridge_world!()}
  end

  defp refuses(w, expected, fun) do
    before = snapshot(w)
    assert fun.() == expected
    assert snapshot(w) == before
  end

  describe "the happy path" do
    test "a routable segment becomes a planning ops task assigned to the agent", %{w: w} do
      seg = segment_id()
      c = candidate!(w.meeting, seg)

      assert {:ok, %{task: task, request: req, created: true, adopted: false}} =
               TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg]))

      assert task.project_id == w.project.id
      assert task.kind == "ops"
      assert task.auto_approve_plan
      assert task.status == "planning"
      assert task.title == "Social: clip the doomsday clock bit"

      for phase <- ~w(planning execution review) do
        assert task.phase_assignees[phase] == %{
                 "assignee_type" => "agent",
                 "assignee_id" => w.agent.id
               }
      end

      assert task.metadata["source"] == "social.request"

      assert task.metadata["social"] == %{
               "profile_id" => w.profile.id,
               "platforms" => ["linkedin", "x"],
               "refs" => %{"meeting_id" => w.meeting.id, "segment_ids" => [seg]},
               "request_id" => req.id
             }

      assert task.description =~ "social_draft_create task_id=#{task.id}"
      assert task.description =~ "Platforms: linkedin, x"

      assert req.task_id == task.id
      assert req.profile_id == w.profile.id
      assert req.requested_by_agent_id == w.agent.id
      assert req.requested_in_space_id == w.space.id
      assert is_nil(req.settled_digest)

      closed = Candidates.get(c.id)
      assert closed.state == :closed
      assert closed.closed_reason == :duplicate
      assert closed.closed_note == "filed as social task #{task.id}"
    end

    test "an episode url and times file a task without touching candidates", %{w: w} do
      c = candidate!(w.meeting, segment_id())

      attrs = %{
        "profile_id" => w.profile.id,
        "platforms" => ["x"],
        "ask" => "post the episode to X",
        "refs" => %{"episode_url" => "https://youtu.be/abc", "start_s" => 12, "end_s" => 40.5}
      }

      assert {:ok, %{task: task, created: true}} = TaskBridge.request(w.scope, w.ctx, attrs)

      assert task.metadata["social"]["refs"] == %{
               "episode_url" => "https://youtu.be/abc",
               "start_s" => 12.0,
               "end_s" => 40.5
             }

      assert task.description =~ "from 12s to 40.5s"
      assert Candidates.get(c.id) == c
    end

    test "a threaded segment's card is closed as duplicate", %{w: w} do
      own = segment_id()
      threaded = segment_id()
      c = candidate!(w.meeting, own, %{transcript_chunk_ids: [own, threaded]})

      assert {:ok, %{task: task}} = TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [threaded]))
      assert %{closed_reason: :duplicate, closed_note: note} = Candidates.get(c.id)
      assert note == "filed as social task #{task.id}"
    end

    test "a repeat of the same ask is idempotent and writes nothing", %{w: w} do
      seg = segment_id()
      candidate!(w.meeting, seg)

      assert {:ok, %{task: task, created: true}} =
               TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg]))

      before = snapshot(w)

      # Different wording and platform order: same refs and platforms.
      assert {:ok, %{task: again, created: false}} =
               TaskBridge.request(
                 w.scope,
                 w.ctx,
                 meeting_ask(w, [seg], %{"ask" => "clip it!", "platforms" => ["x", "linkedin"]})
               )

      assert again.id == task.id
      assert snapshot(w) == before
    end
  end

  describe "the live pipeline" do
    test "a graduated candidate's task is adopted, not duplicated", %{w: w} do
      {:ok, filed} =
        Tasks.create_task(%{
          project_id: w.project.id,
          title: "Clip the bit",
          metadata: %{"source" => "meetings.candidate", "keep" => "me"}
        })

      seg = segment_id()
      g = graduated_candidate!(w.meeting, seg, filed)
      open = candidate!(w.meeting, seg)
      tasks_before = length(Tasks.list_tasks_by_project(w.project.id))

      assert {:ok, %{task: task, request: req, created: false, adopted: true}} =
               TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg]))

      assert task.id == filed.id
      assert length(Tasks.list_tasks_by_project(w.project.id)) == tasks_before
      assert task.metadata["source"] == "meetings.candidate"
      assert task.metadata["keep"] == "me"
      assert task.metadata["social"]["request_id"] == req.id
      assert req.adopted_candidate_id == g.id
      assert task.phase_assignees["planning"]["assignee_id"] == w.agent.id
      assert Candidates.get(open.id).closed_reason == :duplicate
      assert Candidates.get(g.id).closed_reason == :done
    end

    test "an adopted task keeps its own planner", %{w: w} do
      other = pinned_agent!(w.org_id)
      {:ok, filed} = Tasks.create_task(%{project_id: w.project.id, title: "Clip"})

      {:ok, filed} =
        Tasks.set_phase_assignees(filed, %{
          "planning" => %{"assignee_type" => "agent", "assignee_id" => other.id}
        })

      seg = segment_id()
      graduated_candidate!(w.meeting, seg, filed)

      assert {:ok, %{task: task, adopted: true}} =
               TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg]))

      assert task.phase_assignees["planning"]["assignee_id"] == other.id
    end

    test "a candidate still being filed is refused, recoverably", %{w: w} do
      seg = segment_id()
      candidate!(w.meeting, seg, %{state: :acting})

      refuses(w, {:error, :segment_being_filed}, fn ->
        TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg]))
      end)
    end
  end

  describe "segment guard refusals" do
    test "off-topic, demoted, retracted, vetoed, unclassified each write nothing", %{w: w} do
      off = segment_id()
      dem = segment_id()
      ret = segment_id()
      veto = segment_id()
      none = segment_id()
      ok = segment_id()
      candidate!(w.meeting, off, %{classified_intent: "off_topic"})
      candidate!(w.meeting, dem, %{classified_intent: "off_topic", demoted_from: "task_create"})
      closed_candidate!(w.meeting, ret, :retracted)
      closed_candidate!(w.meeting, veto, :vetoed)
      candidate!(w.meeting, ok)

      for {segs, expected} <- [
            {[off], {:error, :segment_off_topic, [off]}},
            {[dem], {:error, :segment_off_topic, [dem]}},
            {[ret], {:error, :segment_retracted, [ret]}},
            {[veto], {:error, :segment_retracted, [veto]}},
            {[none], {:error, :segment_unclassified, [none]}},
            {[ok, off], {:error, :segment_off_topic, [off]}}
          ] do
        refuses(w, expected, fn -> TaskBridge.request(w.scope, w.ctx, meeting_ask(w, segs)) end)
      end

      # Paired success on the same fixture: the routable segment files.
      assert {:ok, %{created: true}} = TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [ok]))
    end
  end

  describe "input and scope refusals" do
    setup %{w: w} do
      seg = segment_id()
      candidate!(w.meeting, seg)
      %{seg: seg}
    end

    test "refs must be exactly one well-formed kind", %{w: w, seg: seg} do
      ep = %{"episode_url" => "https://youtu.be/a", "start_s" => 1, "end_s" => 2}
      mt = %{"meeting_id" => w.meeting.id, "segment_ids" => [seg]}

      for refs <- [
            nil,
            %{},
            Map.merge(ep, mt),
            %{"meeting_id" => w.meeting.id},
            %{mt | "segment_ids" => []},
            %{mt | "segment_ids" => Enum.map(1..51, fn _ -> segment_id() end)},
            %{mt | "segment_ids" => [1]},
            %{ep | "episode_url" => "ftp://youtu.be/a"},
            %{ep | "episode_url" => "not a url"},
            %{ep | "end_s" => 1},
            %{ep | "start_s" => -1},
            %{ep | "start_s" => "1"}
          ] do
        refuses(w, {:error, :invalid_refs}, fn ->
          TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg], %{"refs" => refs}))
        end)
      end
    end

    test "ask and platforms are required", %{w: w, seg: seg} do
      for ask <- [nil, "  ", String.duplicate("a", TaskBridge.max_ask() + 1)] do
        refuses(w, {:error, :invalid_ask}, fn ->
          TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg], %{"ask" => ask}))
        end)
      end

      for platforms <- [nil, [], "x", [nil]] do
        refuses(w, {:error, :invalid_platforms}, fn ->
          TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg], %{"platforms" => platforms}))
        end)
      end
    end

    test "a missing or out-of-scope profile is not_found", %{w: w, seg: seg} do
      refuses(w, {:error, :not_found}, fn ->
        TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg], %{"profile_id" => segment_id()}))
      end)

      # An agent pinned to org B: its scope cannot see O's profile.
      org_b = org_id!()
      gb = pinned_agent!(org_b)

      refuses(w, {:error, :not_found}, fn ->
        TaskBridge.request({:tenant, org_b}, %{agent_id: gb.id}, meeting_ask(w, [seg]))
      end)
    end

    test "a profile with no project is refused", %{w: w, seg: seg} do
      {:ok, bare} =
        Social.create_profile(w.org_id, %{
          name: "Bare #{unique()}",
          space_id: w.space.id,
          project_id: nil
        })

      {:ok, _} = Social.create_account(w.org_id, bare, %{platform: "x"})

      refuses(w, {:error, :profile_has_no_project}, fn ->
        TaskBridge.request(
          w.scope,
          w.ctx,
          meeting_ask(w, [seg], %{"profile_id" => bare.id, "platforms" => ["x"]})
        )
      end)
    end

    test "every platform needs a live account on the profile", %{w: w, seg: seg} do
      {:ok, tiktok} = Social.create_account(w.org_id, w.profile, %{platform: "tiktok"})
      {:ok, _} = Social.archive_account(w.org_id, tiktok)

      refuses(w, {:error, :no_account_for_platform, ["myspace", "tiktok"]}, fn ->
        TaskBridge.request(
          w.scope,
          w.ctx,
          meeting_ask(w, [seg], %{"platforms" => ["x", "tiktok", "myspace"]})
        )
      end)
    end

    test "a meeting outside the profile's project reads as not found", %{w: w, seg: seg} do
      {:ok, m2} =
        Platform.Meetings.create_meeting(%{project_id: project!(w.org_id).id, name: "Elsewhere"})

      seg2 = segment_id()
      candidate!(m2, seg2)
      mb = meeting!(org_id!())

      for meeting_id <- [m2.id, mb.id, segment_id(), "not-a-uuid"] do
        refuses(w, {:error, :meeting_not_found}, fn ->
          TaskBridge.request(
            w.scope,
            w.ctx,
            meeting_ask(w, [seg2], %{
              "refs" => %{"meeting_id" => meeting_id, "segment_ids" => [seg2]}
            })
          )
        end)
      end

      assert {:ok, _} = TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg]))
    end

    test "the requesting agent must exist", %{w: w, seg: seg} do
      for ctx <- [%{}, %{agent_id: segment_id()}, %{agent_id: "nope"}] do
        refuses(w, {:error, :no_agent}, fn ->
          TaskBridge.request(w.scope, ctx, meeting_ask(w, [seg]))
        end)
      end
    end

    test "an agent that cannot read the project is never assigned", %{w: w, seg: seg} do
      outsider = pinned_agent!(org_id!())

      refuses(w, {:error, :assignee_cannot_read}, fn ->
        TaskBridge.request(:root, %{agent_id: outsider.id}, meeting_ask(w, [seg]))
      end)

      # The same call with a reader succeeds.
      assert {:ok, %{created: true}} =
               TaskBridge.request(:root, %{agent_id: w.agent.id}, meeting_ask(w, [seg]))
    end

    test "a space id that is not a space is not recorded", %{w: w, seg: seg} do
      assert {:ok, %{request: req}} =
               TaskBridge.request(
                 w.scope,
                 %{agent_id: w.agent.id, space_id: segment_id()},
                 meeting_ask(w, [seg])
               )

      assert is_nil(req.requested_in_space_id)
    end
  end

  describe "the draft link check" do
    setup %{w: w} do
      seg = segment_id()
      candidate!(w.meeting, seg)
      {:ok, %{task: task}} = TaskBridge.request(w.scope, w.ctx, meeting_ask(w, [seg]))

      {:ok, p2} =
        Social.create_profile(w.org_id, %{
          name: "Second #{unique()}",
          project_id: w.project.id,
          space_id: w.space.id
        })

      {:ok, a2} = Social.create_account(w.org_id, p2, %{platform: "x"})
      %{task: task, p2: p2, a2: a2}
    end

    test "a draft for the social task's own profile links", %{w: w, task: task} do
      assert {:ok, [post]} =
               AgentDrafts.create_agent_drafts(w.scope, w.profile.id, %{
                 "account_ids" => [w.linkedin.id],
                 "body" => "doomsday",
                 "task_id" => task.id
               })

      assert post.task_id == task.id
    end

    test "a draft on another profile is task_profile_mismatch", %{
      w: w,
      task: task,
      p2: p2,
      a2: a2
    } do
      posts_before = Social.list_posts(w.scope)

      assert {:error, :task_profile_mismatch} =
               AgentDrafts.create_agent_drafts(w.scope, p2.id, %{
                 "account_ids" => [a2.id],
                 "body" => "doomsday",
                 "task_id" => task.id
               })

      assert Social.list_posts(w.scope) == posts_before

      {:ok, [post]} =
        AgentDrafts.create_agent_drafts(w.scope, p2.id, %{
          "account_ids" => [a2.id],
          "body" => "unrelated",
          "status" => "draft"
        })

      assert {:error, :task_profile_mismatch} =
               AgentDrafts.update_agent_draft(w.scope, post.id, %{"task_id" => task.id})

      assert Social.get_post(w.scope, post.id).task_id == nil
    end

    test "a task with no request row keeps member 4's rule", %{w: w, p2: p2, a2: a2} do
      {:ok, plain} = Tasks.create_task(%{project_id: w.project.id, title: "Plain"})
      refute TaskBridge.request_for_task(plain.id)

      assert {:ok, [post]} =
               AgentDrafts.create_agent_drafts(w.scope, p2.id, %{
                 "account_ids" => [a2.id],
                 "body" => "fine",
                 "task_id" => plain.id
               })

      assert post.task_id == plain.id
    end
  end

  test "the request changeset never casts the settlement fields" do
    cs =
      TaskRequest.changeset(%TaskRequest{}, %{
        settled_digest: "x",
        settled_at: DateTime.utc_now()
      })

    refute Map.has_key?(cs.changes, :settled_digest)
    refute Map.has_key?(cs.changes, :settled_at)
  end
end
