defmodule Platform.Social.ToolsTest do
  @moduledoc """
  The six `social` tools through `ToolArguments.dispatch/3`, the door both
  federation transports use, so core's extension fallback (and its
  `:agent_home_org` seam) is in the path of every case.
  """
  use Platform.DataCase, async: true

  import Platform.SocialFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Social
  alias Platform.Social.{Clip, Post, ToolDefinitions}

  @home "https://www.youtube.com/@htc"
  @sentence ToolDefinitions.human_approves()

  setup do
    org_a = org_id!()
    org_b = org_id!()

    {:ok, profile} =
      Social.create_profile(org_a, %{
        name: "HTC",
        home_url: @home,
        voice_notes: "warm",
        default_hashtags: ["#htc"],
        space_id: channel!(org_a).id
      })

    {:ok, acc1} = Social.create_account(org_a, profile, %{platform: "x", handle: "@htc"})
    {:ok, acc2} = Social.create_account(org_a, profile, %{platform: "linkedin"})
    {:ok, post} = Social.create_post(org_a, acc1, %{body: "A's post", status: "needs_approval"})

    {:ok, clip} =
      Social.create_clip(org_a, profile, %{
        source_url: "https://www.youtube.com/watch?v=abc",
        start_s: 1.0,
        end_s: 2.0
      })

    {:ok, profile_b} =
      Social.create_profile(org_b, %{name: "B show", space_id: channel!(org_b).id})

    %{
      org_a: org_a,
      org_b: org_b,
      profile: profile,
      profile_b: profile_b,
      acc1: acc1,
      acc2: acc2,
      post: post,
      clip: clip,
      a: %{agent_id: pinned_agent!(org_a).id},
      b: %{agent_id: pinned_agent!(org_b).id},
      unpinned: %{agent_id: agent!().id},
      user: user!()
    }
  end

  defp call(tool, args, ctx), do: ToolArguments.dispatch(tool, args, ctx)

  defp snapshot(ctx) do
    {Repo.get!(Social.Profile, ctx.profile.id), Repo.get!(Post, ctx.post.id),
     Repo.get!(Clip, ctx.clip.id), Repo.aggregate(Post, :count), Repo.aggregate(Clip, :count)}
  end

  describe "social_profile_list" do
    test "an org A agent sees A's profile with an accounts summary and a list envelope", ctx do
      assert {:ok, %{profiles: [p], total: 1, has_more: false}} =
               call("social_profile_list", %{}, ctx.a)

      assert p.id == ctx.profile.id
      assert Enum.map(p.accounts, & &1.id) == [ctx.acc1.id, ctx.acc2.id]
      refute Enum.any?(p.accounts, &Map.has_key?(&1, :secret_slug))

      assert {:ok, %{profiles: [_]}} =
               call("social_profile_list", %{"org_id" => ctx.org_a}, ctx.a)
    end

    test "an org B agent sees no A profile and its org_id=A filter is unauthorized", ctx do
      assert {:ok, %{profiles: profiles}} = call("social_profile_list", %{}, ctx.b)
      assert Enum.map(profiles, & &1.id) == [ctx.profile_b.id]

      assert {:error, %{code: :unauthorized, recoverable: false}} =
               call("social_profile_list", %{"org_id" => ctx.org_a}, ctx.b)
    end

    test "an unpinned agent resolves to :root (core's rule) and may filter by any org", ctx do
      assert {:ok, %{profiles: [p]}} =
               call("social_profile_list", %{"org_id" => ctx.org_a}, ctx.unpinned)

      assert p.id == ctx.profile.id
    end
  end

  describe "social_profile_get" do
    test "returns accounts, home_url, voice notes and hashtags, never a secret", ctx do
      assert {:ok, p} = call("social_profile_get", %{"profile_id" => ctx.profile.id}, ctx.a)
      assert {p.home_url, p.voice_notes, p.default_hashtags} == {@home, "warm", ["#htc"]}

      for account <- p.accounts do
        assert Map.keys(account) |> Enum.sort() ==
                 [:approval_mode, :handle, :id, :platform, :status]
      end
    end

    test "org B gets not_found for A's profile, same as a missing id", ctx do
      assert {:error, %{code: :not_found} = e1} =
               call("social_profile_get", %{"profile_id" => ctx.profile.id}, ctx.b)

      assert {:error, %{code: :not_found} = e2} =
               call("social_profile_get", %{"profile_id" => Ecto.UUID.generate()}, ctx.b)

      assert e1 == e2
    end
  end

  describe "social_draft_create" do
    test "lands in needs_approval, one per account, home_url appended once", ctx do
      assert {:ok, %{posts: posts, count: 2}} =
               call(
                 "social_draft_create",
                 %{
                   "profile_id" => ctx.profile.id,
                   "account_ids" => [ctx.acc1.id, ctx.acc2.id],
                   "body" => "Out now"
                 },
                 ctx.a
               )

      for p <- posts do
        assert p.status == "needs_approval"
        assert p.link_url == @home
        assert p.body == "Out now\n" <> @home
      end
    end

    test "status past needs_approval or an approver field is refused with the human sentence",
         ctx do
      before = snapshot(ctx)

      for status <- ~w(approved scheduled published failed) do
        assert {:error, %{code: :status_not_allowed, error: error}} =
                 call(
                   "social_draft_create",
                   %{
                     "profile_id" => ctx.profile.id,
                     "account_ids" => [ctx.acc1.id],
                     "status" => status
                   },
                   ctx.a
                 )

        assert error =~ @sentence
      end

      assert {:error, %{code: :field_not_allowed, error: error}} =
               call(
                 "social_draft_create",
                 %{
                   "profile_id" => ctx.profile.id,
                   "account_ids" => [ctx.acc1.id],
                   "approved_by_user_id" => ctx.user.id
                 },
                 ctx.a
               )

      assert error =~ "approved_by_user_id"
      assert error =~ @sentence
      assert snapshot(ctx) == before
    end

    test "org B cannot draft on A's profile, even naming org A; nothing is written", ctx do
      before = snapshot(ctx)

      assert {:error, %{code: :not_found}} =
               call(
                 "social_draft_create",
                 %{
                   "profile_id" => ctx.profile.id,
                   "account_ids" => [ctx.acc1.id],
                   "org_id" => ctx.org_a
                 },
                 ctx.b
               )

      assert snapshot(ctx) == before
    end

    test "a missing required argument is refused by the argument gate", ctx do
      assert {:error, %{}} =
               call("social_draft_create", %{"profile_id" => ctx.profile.id}, ctx.a)
    end
  end

  describe "social_draft_update" do
    test "edits a needs_approval post", ctx do
      assert {:ok, %{post: %{body: "edited", status: "needs_approval"}}} =
               call("social_draft_update", %{"post_id" => ctx.post.id, "body" => "edited"}, ctx.a)
    end

    test "an approved post is post_locked and byte-identical afterwards", ctx do
      make_approver!(ctx.org_a, ctx.profile, ctx.user)
      {:ok, _} = Social.approve_post(ctx.org_a, ctx.post, ctx.user.id)
      before = Repo.get!(Post, ctx.post.id)

      assert {:error, %{code: :post_locked, error: error, recoverable: false}} =
               call("social_draft_update", %{"post_id" => ctx.post.id, "body" => "x"}, ctx.a)

      assert error =~ @sentence
      assert Repo.get!(Post, ctx.post.id) == before
    end

    test "status approved or draft on a needs_approval post is refused", ctx do
      before = Repo.get!(Post, ctx.post.id)

      for status <- ~w(approved draft) do
        assert {:error, %{code: :status_not_allowed}} =
                 call(
                   "social_draft_update",
                   %{"post_id" => ctx.post.id, "status" => status},
                   ctx.a
                 )
      end

      assert Repo.get!(Post, ctx.post.id) == before
    end

    test "org B gets not_found and A's post is unchanged", ctx do
      before = snapshot(ctx)

      assert {:error, %{code: :not_found}} =
               call("social_draft_update", %{"post_id" => ctx.post.id, "body" => "pwned"}, ctx.b)

      assert snapshot(ctx) == before
    end
  end

  describe "social_post_list" do
    test "lists a profile's posts with status, error and rejection fields, enveloped", ctx do
      Repo.update_all(from(p in Post, where: p.id == ^ctx.post.id),
        set: [rejection_reason: "off brand", rejected_at: DateTime.utc_now()]
      )

      assert {:ok, %{posts: [p], total: 1, has_more: false}} =
               call("social_post_list", %{"profile_id" => ctx.profile.id}, ctx.a)

      assert p.rejection_reason == "off brand"
      assert Map.has_key?(p, :error) and Map.has_key?(p, :rejected_at)

      assert {:ok, %{posts: [], total: 0}} =
               call(
                 "social_post_list",
                 %{"profile_id" => ctx.profile.id, "status" => "published"},
                 ctx.a
               )
    end

    test "pages with a real total", ctx do
      for _ <- 1..2, do: Social.create_post(ctx.org_a, ctx.acc2, %{body: "more"})

      assert {:ok, %{posts: [_], total: 3, has_more: true, limit: 1, offset: 0}} =
               call("social_post_list", %{"profile_id" => ctx.profile.id, "limit" => 1}, ctx.a)

      assert {:ok, %{posts: [_], total: 3, has_more: false}} =
               call(
                 "social_post_list",
                 %{"profile_id" => ctx.profile.id, "limit" => 1, "offset" => 2},
                 ctx.a
               )
    end

    test "org B gets not_found", ctx do
      assert {:error, %{code: :not_found}} =
               call("social_post_list", %{"profile_id" => ctx.profile.id}, ctx.b)
    end

    test "carries the refusal fields and honours refused: true (task 01a165f1)", ctx do
      approver = user!()
      refused = approved_post!(ctx.org_a, ctx.acc2, %{body: "refused"}, approver)
      _approved = approved_post!(ctx.org_a, ctx.acc2, %{body: "fine"}, approver)
      at = DateTime.utc_now()
      retry_after = DateTime.add(at, 600, :second)

      Repo.update_all(from(p in Post, where: p.id == ^refused.id),
        set: [refused_reason: "rate_limited", refused_at: at, retry_after: retry_after]
      )

      assert {:ok, %{posts: all, total: 3}} =
               call("social_post_list", %{"profile_id" => ctx.profile.id}, ctx.a)

      assert Enum.all?(
               all,
               &Enum.all?([:refused_reason, :refused_at, :retry_after], fn k ->
                 Map.has_key?(&1, k)
               end)
             )

      assert {:ok, %{posts: [p], total: 1}} =
               call(
                 "social_post_list",
                 %{"profile_id" => ctx.profile.id, "refused" => true},
                 ctx.a
               )

      assert {p.id, p.refused_reason, p.refused_at, p.retry_after} ==
               {refused.id, "rate_limited", at, retry_after}

      assert {:ok, %{total: 3}} =
               call(
                 "social_post_list",
                 %{"profile_id" => ctx.profile.id, "refused" => false},
                 ctx.a
               )
    end
  end

  describe "social_clip_propose" do
    @clip %{"source_url" => "https://youtu.be/abc123", "start_s" => 10, "end_s" => 40}

    test "creates a candidate clip", ctx do
      args =
        Map.merge(@clip, %{"profile_id" => ctx.profile.id, "caption" => "c", "speaker" => "s"})

      assert {:ok, %{clip: clip}} = call("social_clip_propose", args, ctx.a)
      assert {clip.status, clip.profile_id, clip.caption} == {"candidate", ctx.profile.id, "c"}
    end

    test "an invalid range is invalid_range; org B is not_found; no row either way", ctx do
      before = snapshot(ctx)

      assert {:error, %{code: :invalid_range}} =
               call(
                 "social_clip_propose",
                 Map.merge(@clip, %{"profile_id" => ctx.profile.id, "end_s" => 10}),
                 ctx.a
               )

      assert {:error, %{code: :not_found}} =
               call("social_clip_propose", Map.put(@clip, "profile_id", ctx.profile.id), ctx.b)

      assert snapshot(ctx) == before
    end
  end

  describe "who may call" do
    test "no agent, or an agent_id with no agents row, is no_agent (never :root)", ctx do
      for context <- [%{}, %{agent_id: Ecto.UUID.generate()}, %{agent_id: "nope"}] do
        assert {:error, %{code: :no_agent}} = call("social_profile_list", %{}, context)

        assert {:error, %{code: :no_agent}} =
                 call("social_profile_get", %{"profile_id" => ctx.profile.id}, context)
      end
    end

    test "an invented social_* name is Social's unknown_tool, naming no publish tool", ctx do
      for name <- ~w(social_post_publish social_post_approve) do
        assert {:error, %{code: :unknown_tool, error: error}} = call(name, %{}, ctx.a)
        assert error =~ "There is no publish or approve tool"
      end
    end
  end

  # ── Social 6/7: social_task_request ──────────────────────────────────

  describe "social_task_request" do
    setup do
      w = Platform.SocialBridgeFixtures.bridge_world!()
      join!(w.space.id, :agent, w.agent.id)
      seg = Platform.SocialBridgeFixtures.segment_id()
      Platform.SocialBridgeFixtures.candidate!(w.meeting, seg)
      %{w: w, seg: seg, g: %{agent_id: w.agent.id, space_id: w.space.id}}
    end

    defp ask_args(w, seg, extra \\ %{}) do
      Map.merge(
        %{
          "profile_id" => w.profile.id,
          "platforms" => ["linkedin", "x"],
          "ask" => "clip the doomsday clock bit",
          "meeting_id" => w.meeting.id,
          "segment_ids" => [seg]
        },
        extra
      )
    end

    defp bridge_snapshot(w), do: Platform.SocialBridgeFixtures.snapshot(w)

    test "files the task, assigned to the caller, and the hint names it", %{w: w, seg: seg, g: g} do
      assert {:ok, result} = call("social_task_request", ask_args(w, seg), g)
      assert result.created
      assert result.status == "planning"
      assert result.profile_id == w.profile.id
      assert result.platforms == ["linkedin", "x"]
      assert result.hint =~ "social_draft_create task_id=#{result.task_id}"
      assert result.hint =~ @sentence

      task = Platform.Tasks.get_task_record(result.task_id)
      assert task.phase_assignees["execution"]["assignee_id"] == w.agent.id

      assert Platform.Social.TaskBridge.request_for_task(task.id).requested_in_space_id ==
               w.space.id

      assert {:ok, %{created: false, task_id: same}} =
               call("social_task_request", ask_args(w, seg), g)

      assert same == result.task_id
    end

    test "a space the caller is not in is not recorded", %{w: w, seg: seg} do
      other = channel!(w.org_id)
      ctx = %{agent_id: w.agent.id, space_id: other.id}
      assert {:ok, %{task_id: id}} = call("social_task_request", ask_args(w, seg), ctx)
      assert is_nil(Platform.Social.TaskBridge.request_for_task(id).requested_in_space_id)
    end

    test "an episode url and times file a task", %{w: w, g: g} do
      args = %{
        "profile_id" => w.profile.id,
        "platforms" => ["x"],
        "ask" => "post the episode to X",
        "episode_url" => "https://youtu.be/abc",
        "start_s" => 10,
        "end_s" => 70
      }

      assert {:ok, %{created: true}} = call("social_task_request", args, g)
    end

    test "every refusal is an envelope and writes nothing", %{w: w, seg: seg, g: g} do
      alias Platform.SocialBridgeFixtures, as: F
      off = F.segment_id()
      ret = F.segment_id()
      filing = F.segment_id()
      F.candidate!(w.meeting, off, %{classified_intent: "off_topic"})
      F.closed_candidate!(w.meeting, ret, :retracted)
      F.candidate!(w.meeting, filing, %{state: :acting})

      {:ok, bare} = Social.create_profile(w.org_id, %{name: "Bare #{unique()}"})
      {:ok, _} = Social.create_account(w.org_id, bare, %{platform: "x"})

      {:ok, m2} =
        Platform.Meetings.create_meeting(%{project_id: project!(w.org_id).id, name: "M2"})

      cases = [
        {%{"episode_url" => "https://youtu.be/a"}, :invalid_refs, true},
        {%{"profile_id" => F.segment_id()}, :not_found, false},
        {%{"profile_id" => bare.id, "platforms" => ["x"]}, :profile_has_no_project, false},
        {%{"platforms" => ["tiktok"]}, :no_account_for_platform, true},
        {%{"meeting_id" => m2.id}, :meeting_not_found, false},
        {%{"segment_ids" => [F.segment_id()]}, :segment_unclassified, true},
        {%{"segment_ids" => [seg, off]}, :segment_off_topic, false},
        {%{"segment_ids" => [ret]}, :segment_retracted, false},
        {%{"segment_ids" => [filing]}, :segment_being_filed, true}
      ]

      for {extra, code, recoverable} <- cases do
        before = bridge_snapshot(w)
        assert {:error, envelope} = call("social_task_request", ask_args(w, seg, extra), g)
        assert envelope.code == code, "#{inspect(extra)}: #{inspect(envelope)}"
        assert envelope.recoverable == recoverable
        assert is_binary(envelope.error) and is_binary(envelope.suggestion)
        assert bridge_snapshot(w) == before
      end

      # Paired success on the same fixture.
      assert {:ok, %{created: true}} = call("social_task_request", ask_args(w, seg), g)
    end

    test "no agent is refused", %{w: w, seg: seg} do
      for ctx <- [%{}, %{agent_id: Platform.SocialBridgeFixtures.segment_id()}] do
        assert {:error, %{code: :no_agent}} = call("social_task_request", ask_args(w, seg), ctx)
      end
    end

    test "an assignee that cannot read the project is refused", %{w: w, seg: seg} do
      outsider = pinned_agent!(org_id!())
      before = bridge_snapshot(w)

      # Only reachable when the scope is wider than the agent's own home org
      # (core's seam always sets them equal), so this calls Tools directly.
      assert {:error, %{code: :assignee_cannot_read, recoverable: false}} =
               Platform.Social.Tools.execute("social_task_request", ask_args(w, seg), %{
                 agent_id: outsider.id,
                 agent_home_org: :root
               })

      assert bridge_snapshot(w) == before
    end

    test "a client org_id never widens the scope", %{w: w, seg: seg, g: g} do
      wb = Platform.SocialBridgeFixtures.bridge_world!()
      segb = Platform.SocialBridgeFixtures.segment_id()
      Platform.SocialBridgeFixtures.candidate!(wb.meeting, segb)

      args =
        ask_args(wb, segb, %{"org_id" => wb.org_id})

      assert {:error, %{code: :not_found}} = call("social_task_request", args, g)

      assert {:ok, %{created: true}} =
               call("social_task_request", ask_args(w, seg, %{"org_id" => wb.org_id}), g)
    end

    test "a draft citing the social task on another profile is task_profile_mismatch",
         %{w: w, seg: seg, g: g} do
      {:ok, %{task_id: task_id}} = call("social_task_request", ask_args(w, seg), g)
      {:ok, p2} = Social.create_profile(w.org_id, %{name: "P2 #{unique()}", space_id: w.space.id})
      {:ok, a2} = Social.create_account(w.org_id, p2, %{platform: "x"})
      posts = Repo.aggregate(Post, :count)

      assert {:error, %{code: :task_profile_mismatch, recoverable: false}} =
               call(
                 "social_draft_create",
                 %{
                   "profile_id" => p2.id,
                   "account_ids" => [a2.id],
                   "body" => "hi",
                   "task_id" => task_id
                 },
                 g
               )

      assert Repo.aggregate(Post, :count) == posts

      assert {:ok, %{count: 1}} =
               call(
                 "social_draft_create",
                 %{
                   "profile_id" => w.profile.id,
                   "account_ids" => [w.x.id],
                   "body" => "hi",
                   "task_id" => task_id
                 },
                 g
               )
    end
  end

  # Task 01a165ec stage 2.
  describe "cover fields" do
    setup ctx do
      %{
        video: media_file!(ctx.org_a, "video/mp4"),
        png: media_file!(ctx.org_a, "image/png"),
        pdf: media_file!(ctx.org_a, "application/pdf")
      }
    end

    test "the draft tools document both fields and the row lists them" do
      for name <- ~w(social_draft_create social_draft_update) do
        tool = Enum.find(ToolDefinitions.definitions(), &(&1.name == name))
        assert %{type: "string"} = tool.parameters.cover_file_id
        assert %{type: "integer"} = tool.parameters.cover_offset_ms
        assert tool.returns =~ "cover_file_id, cover_offset_ms, cover_error"
      end
    end

    test "create and update round-trip both fields", ctx do
      assert {:ok, %{posts: [post]}} =
               call(
                 "social_draft_create",
                 %{
                   "profile_id" => ctx.profile.id,
                   "account_ids" => [ctx.acc1.id],
                   "body" => "clip",
                   "media_file_ids" => [ctx.video.id],
                   "cover_file_id" => ctx.png.id
                 },
                 ctx.a
               )

      assert {post.cover_file_id, post.cover_offset_ms, post.cover_error} ==
               {ctx.png.id, nil, nil}

      {:ok, _} =
        Social.update_post(ctx.org_a, post.id, %{
          media_meta: %{ctx.video.id => %{"duration_s" => 10}}
        })

      assert {:ok, %{post: %{cover_file_id: nil, cover_offset_ms: 9_000}}} =
               call(
                 "social_draft_update",
                 %{"post_id" => post.id, "cover_offset_ms" => 9_000},
                 ctx.a
               )
    end

    test "surface the cover refusals as invalid_argument with the message", ctx do
      assert {:error, %{code: :invalid_argument, error: error}} =
               call(
                 "social_draft_create",
                 %{
                   "profile_id" => ctx.profile.id,
                   "account_ids" => [ctx.acc1.id],
                   "media_file_ids" => [ctx.video.id],
                   "cover_file_id" => ctx.pdf.id
                 },
                 ctx.a
               )

      assert error =~ "cover_file_id cover must be a JPG or PNG image"

      assert {:error, %{code: :invalid_argument, error: error}} =
               call(
                 "social_draft_update",
                 %{"post_id" => ctx.post.id, "cover_offset_ms" => 0},
                 ctx.a
               )

      assert error =~ "cover_offset_ms a cover applies only to a video post"
    end
  end
end
