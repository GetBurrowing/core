defmodule Platform.Social.ClipToolsTest do
  @moduledoc """
  The two Social 5/7 tools, `social_clip_render` and `social_clip_list`,
  and `social_clip_propose`'s file-source arguments, through
  `ToolArguments.dispatch/3` (the door both transports use). Another org's
  clip or profile is not_found.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.Clip
  alias Platform.Social.Renderer.Fake

  setup do
    Fake.reset()
    world = render_world!()
    other = render_world!()
    Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(world.profile.id))
    Map.merge(world, %{other: other, ctx: %{agent_id: world.agent.id}})
  end

  defp call(tool, args, ctx), do: ToolArguments.dispatch(tool, args, ctx)

  describe "social_clip_propose with a file source" do
    test "creates a candidate with requested times, crop and platforms", w do
      assert {:ok, %{clip: clip}} =
               call(
                 "social_clip_propose",
                 %{
                   "profile_id" => w.profile.id,
                   "source_file_id" => w.video.id,
                   "transcript_file_id" => w.transcript.id,
                   "start_s" => 2.0,
                   "end_s" => 14.0,
                   "crop_x" => 0.3,
                   "platforms" => ["tiktok"]
                 },
                 w.ctx
               )

      assert clip.status == "candidate"
      assert {clip.source_file_id, clip.transcript_file_id} == {w.video.id, w.transcript.id}
      assert {clip.requested_start_s, clip.requested_end_s} == {2.0, 14.0}
      assert {clip.crop_x, clip.platforms} == {0.3, ["tiktok"]}
      assert clip.source_url == nil
    end

    test "refusals: both kinds, missing transcript, other project, bad crop, bad platform", w do
      base = %{
        "profile_id" => w.profile.id,
        "source_file_id" => w.video.id,
        "transcript_file_id" => w.transcript.id,
        "start_s" => 2.0,
        "end_s" => 14.0
      }

      before = Repo.aggregate(Clip, :count)

      for {args, code} <- [
            {Map.put(base, "source_url", "https://youtu.be/x"), :invalid_source},
            {Map.delete(base, "transcript_file_id"), :invalid_source},
            {Map.put(base, "source_file_id", w.other.video.id), :source_not_in_project},
            {Map.put(base, "crop_x", 1.5), :invalid_argument},
            {Map.put(base, "platforms", ["instagram"]), :invalid_argument}
          ] do
        assert {:error, %{code: ^code}} = call("social_clip_propose", args, w.ctx)
      end

      assert Repo.aggregate(Clip, :count) == before
    end

    test "the definition takes the new arguments; source_url is optional now" do
      tool =
        Enum.find(
          Platform.Social.ToolDefinitions.definitions(),
          &(&1.name == "social_clip_propose")
        )

      for p <- ~w(source_file_id transcript_file_id crop_x platforms source_url)a do
        assert Map.has_key?(tool.parameters, p)
        refute tool.parameters[p].required
      end
    end
  end

  describe "social_clip_render" do
    test "queues and returns rendering; the clip ends rendered", w do
      clip = file_clip!(w, 2.0, 14.0)

      assert {:ok, %{clip: %{id: id, status: "rendering", platforms: ["tiktok", "x"]}}} =
               call("social_clip_render", %{"clip_id" => clip.id}, w.ctx)

      assert_receive {:social_clip, %Clip{id: ^id, status: "rendered"}}, 5_000
    end

    test "another org's clip is not_found; nothing changes", w do
      theirs = file_clip!(w.other, 2.0, 14.0)

      assert {:error, %{code: :not_found}} =
               call("social_clip_render", %{"clip_id" => theirs.id}, w.ctx)

      assert Repo.get!(Clip, theirs.id).status == "candidate"
    end

    test "rendered without force is already_rendered; force renders again", w do
      clip = file_clip!(w, 2.0, 14.0)
      {:ok, _} = call("social_clip_render", %{"clip_id" => clip.id}, w.ctx)
      id = clip.id
      assert_receive {:social_clip, %Clip{id: ^id, status: "rendered"}}, 5_000

      assert {:error, %{code: :already_rendered}} =
               call("social_clip_render", %{"clip_id" => clip.id}, w.ctx)

      assert {:ok, %{clip: %{status: "rendering"}}} =
               call("social_clip_render", %{"clip_id" => clip.id, "force" => true}, w.ctx)

      assert_receive {:social_clip, %Clip{id: ^id, status: "rendered"}}, 5_000
    end
  end

  describe "social_clip_list" do
    test "rows carry the render state; status filter; paging envelope", w do
      done = file_clip!(w, 2.0, 14.0)
      _waiting = file_clip!(w, 4.0, 12.0)
      {:ok, _} = Social.render_clip(w.scope, done.id)
      id = done.id
      assert_receive {:social_clip, %Clip{id: ^id, status: "rendered"} = rendered}, 5_000

      assert {:ok, %{clips: clips, total: 2, has_more: false}} =
               call("social_clip_list", %{"profile_id" => w.profile.id}, w.ctx)

      assert length(clips) == 2

      assert {:ok, %{clips: [row], total: 1}} =
               call(
                 "social_clip_list",
                 %{"profile_id" => w.profile.id, "status" => "rendered"},
                 w.ctx
               )

      assert row.id == done.id
      assert row.render_file_id == rendered.render_file_id
      assert {row.width, row.height} == {1080, 1920}
      assert row.duration_s == rendered.duration_s
      assert Map.has_key?(row, :error)
    end

    test "another org's profile is not_found", w do
      assert {:error, %{code: :not_found}} =
               call("social_clip_list", %{"profile_id" => w.other.profile.id}, w.ctx)
    end

    # Clip Studio 1/9: the review state is returned and filterable.
    test "the review_status filter; invalid_review_status for anything else", w do
      [pending, approved, rejected, unrendered] =
        for _ <- 1..4, do: file_clip!(w, 2.0, 14.0)

      review = fn clip, decision ->
        {:ok, clip} = clip |> Clip.review_changeset(decision) |> Repo.update()
        clip
      end

      review.(pending, :reset_pending)
      review.(approved, {:approve, w.approver.id})
      review.(rejected, {:reject, w.approver.id, "payoff is cut off"})

      ids = fn status ->
        assert {:ok, %{clips: clips, total: total}} =
                 call(
                   "social_clip_list",
                   %{"profile_id" => w.profile.id, "review_status" => status},
                   w.ctx
                 )

        assert total == length(clips)
        Enum.map(clips, & &1.id)
      end

      assert ids.("pending") == [pending.id]
      assert ids.("approved") == [approved.id]
      assert ids.("rejected") == [rejected.id]

      assert Enum.sort(ids.(nil)) ==
               Enum.sort([pending.id, approved.id, rejected.id, unrendered.id])

      assert length(ids.("")) == 4

      assert {:ok, %{clips: [row]}} =
               call(
                 "social_clip_list",
                 %{"profile_id" => w.profile.id, "review_status" => "rejected"},
                 w.ctx
               )

      assert row.review_note == "payoff is cut off"
      assert %DateTime{} = row.reviewed_at
      assert row.rev == 1
      assert row.origin == "burrow"
      assert row.look == %{}

      for key <- ~w(title episode_code source_label trim_in_s trim_out_s)a,
          do: assert(Map.has_key?(row, key))

      for bad <- ["done", "APPROVED", "candidate"] do
        assert {:error, %{code: :invalid_review_status}} =
                 call(
                   "social_clip_list",
                   %{"profile_id" => w.profile.id, "review_status" => bad},
                   w.ctx
                 )
      end
    end
  end
end
