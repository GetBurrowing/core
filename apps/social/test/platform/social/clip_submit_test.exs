defmodule Platform.Social.ClipSubmitTest do
  @moduledoc """
  Clip Studio 1/9 (task 01a16661-e234) stage 2: `social_clip_submit` lands a
  clip rendered outside Burrow as review pending, external, rev 1, with one
  rev-1 render row and the profile's effective show look. The file must be a
  live video in the profile's project; every other file is refused alike.
  No review field and no agent id is ever taken from arguments.

  Through `ToolArguments.dispatch/3` (the door both transports use) unless
  a test names `AgentDrafts` directly.
  """
  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.SocialFixtures

  alias Platform.Federation.ToolArguments
  alias Platform.Repo
  alias Platform.Social.{AgentDrafts, Clip, ClipLook, ClipRender, Profile}

  setup do
    world = render_world!()
    other = render_world!()

    {:ok, profile} =
      world.profile
      |> Ecto.Changeset.change(show_look: %{"cap" => %{"size" => 7.0}, "music" => false})
      |> Repo.update()

    rendered =
      stored_file!(world.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    %{world | profile: profile}
    |> Map.merge(%{other: other, rendered: rendered, ctx: %{agent_id: world.agent.id}})
  end

  defp call(tool, args, ctx), do: ToolArguments.dispatch(tool, args, ctx)

  defp submit(w, args) do
    call("social_clip_submit", Map.merge(%{"profile_id" => w.profile.id}, args), w.ctx)
  end

  defp renders(clip_id) do
    Repo.all(from(r in ClipRender, where: r.clip_id == ^clip_id, order_by: r.rev))
  end

  test "a submit lands pending, external, rev 1, render_file_id = file_id", w do
    assert {:ok, %{clip: json}} =
             submit(w, %{
               "file_id" => w.rendered.id,
               "title" => "Who makes Total War?",
               "episode_code" => "S2E14",
               "source_label" => "htc-clip-tool",
               "platforms" => ["tiktok"],
               "duration_s" => 31.5,
               "width" => 1080,
               "height" => 1920
             })

    clip = Repo.get!(Clip, json.id)
    look = ClipLook.effective(w.profile.show_look)

    assert %Clip{
             origin: "external",
             status: "rendered",
             review_status: "pending",
             rev: 1,
             title: "Who makes Total War?",
             episode_code: "S2E14",
             source_label: "htc-clip-tool",
             platforms: ["tiktok"],
             source_url: nil,
             source_file_id: nil
           } = clip

    assert clip.render_file_id == w.rendered.id
    assert clip.submitted_by_agent_id == w.agent.id
    assert clip.look == look
    assert look["cap"]["size"] == 7.0 and look["music"] == false
    assert {clip.duration_s, clip.width, clip.height} == {31.5, 1080, 1920}
    assert clip.byte_size == w.rendered.byte_size

    assert [%ClipRender{rev: 1, file_id: file_id, look: ^look, submitted_by_agent_id: by}] =
             renders(clip.id)

    assert file_id == w.rendered.id
    assert by == w.agent.id

    assert json.review_status == "pending"
    assert json.origin == "external"
    assert json.rev == 1
  end

  test "source_label defaults to external" do
    w = render_world!()
    file = stored_file!(w.project, "rendered #{unique()}", "c.mp4", "video/mp4")

    assert {:ok, %{clip: %{source_label: "external"}}} =
             call(
               "social_clip_submit",
               %{"profile_id" => w.profile.id, "file_id" => file.id},
               %{agent_id: w.agent.id}
             )
  end

  describe "the file must be a live video in the profile's project" do
    test "another org's file is refused", w do
      random = submit(w, %{"file_id" => Ecto.UUID.generate()})
      assert {:error, %{code: :file_not_in_project} = expected} = random
      assert submit(w, %{"file_id" => w.other.video.id}) == {:error, expected}
      assert Repo.aggregate(Clip, :count) == 0
    end

    test "another project's file is refused", w do
      elsewhere = file!(w.org_id)
      assert elsewhere.project_id != w.profile.project_id

      assert {:error, %{code: :file_not_in_project}} =
               submit(w, %{"file_id" => elsewhere.id})

      assert submit(w, %{"file_id" => elsewhere.id}) ==
               submit(w, %{"file_id" => Ecto.UUID.generate()})
    end

    test "a deleted file is refused like a missing one", w do
      {:ok, _} = Platform.Files.delete_file(%{id: w.agent.id, type: "system"}, w.rendered)

      assert {:error, %{code: :file_not_in_project}} =
               submit(w, %{"file_id" => w.rendered.id})
    end

    test "a non-video is refused", w do
      assert w.transcript.content_type == "text/vtt"
      assert w.transcript.project_id == w.profile.project_id

      assert {:error, %{code: :not_a_video}} = submit(w, %{"file_id" => w.transcript.id})
      assert Repo.aggregate(Clip, :count) == 0
    end
  end

  test "another org's profile_id is not_found, the same as a random UUID", w do
    args = %{"file_id" => w.rendered.id}

    theirs =
      call("social_clip_submit", Map.put(args, "profile_id", w.other.profile.id), w.ctx)

    random = call("social_clip_submit", Map.put(args, "profile_id", Ecto.UUID.generate()), w.ctx)

    assert {:error, %{code: :not_found}} = theirs
    assert theirs == random
  end

  test "review args in submit and propose are not written", w do
    review = %{
      "review_status" => "approved",
      "review_note" => "ok",
      "reviewed_by_user_id" => w.approver.id,
      "reviewed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "rev" => 9,
      "origin" => "burrow"
    }

    assert {:ok, %{clip: %{id: submitted_id}}} =
             submit(w, Map.merge(review, %{"file_id" => w.rendered.id}))

    assert {:ok, %{clip: %{id: proposed_id}}} =
             call(
               "social_clip_propose",
               Map.merge(review, %{
                 "profile_id" => w.profile.id,
                 "source_url" => "https://www.youtube.com/watch?v=abc",
                 "start_s" => 1.0,
                 "end_s" => 9.0
               }),
               w.ctx
             )

    assert %Clip{
             review_status: "pending",
             review_note: nil,
             reviewed_by_user_id: nil,
             reviewed_at: nil,
             rev: 1,
             origin: "external"
           } = Repo.get!(Clip, submitted_id)

    assert %Clip{
             review_status: nil,
             review_note: nil,
             reviewed_by_user_id: nil,
             reviewed_at: nil,
             rev: 1,
             origin: "burrow"
           } = Repo.get!(Clip, proposed_id)

    # the context path ignores them too
    {:ok, clip} =
      AgentDrafts.submit_clip(
        {:tenant, w.org_id},
        w.profile.id,
        Map.merge(review, %{"file_id" => w.rendered.id}),
        w.agent.id
      )

    assert %Clip{review_status: "pending", rev: 1, reviewed_by_user_id: nil} = clip
  end

  test "a submit with title nil and caption nil succeeds and clip_json returns nil", w do
    assert {:ok, %{clip: json}} =
             submit(w, %{
               "file_id" => w.rendered.id,
               "title" => nil,
               "caption" => nil,
               "speaker" => nil,
               "episode_code" => nil
             })

    for key <- [:title, :caption, :speaker, :episode_code] do
      assert Map.fetch!(json, key) == nil
    end

    assert {:ok, %{clips: [listed]}} =
             call("social_clip_list", %{"profile_id" => w.profile.id}, w.ctx)

    assert listed.title == nil and listed.caption == nil
    assert listed.review_status == "pending"
  end

  test "a blank or over-long title is invalid_title", w do
    for title <- ["", "   ", String.duplicate("t", 201), 42] do
      assert {:error, %{code: :invalid_title}} =
               submit(w, %{"file_id" => w.rendered.id, "title" => title})
    end

    assert {:ok, _} =
             submit(w, %{"file_id" => w.rendered.id, "title" => String.duplicate("t", 200)})
  end

  test "platforms must be the profile's", w do
    assert {:error, %{code: :invalid_argument}} =
             submit(w, %{"file_id" => w.rendered.id, "platforms" => ["instagram"]})
  end

  test "submitted_by is the calling agent even when args name another", w do
    impostor = pinned_agent!(w.org_id)

    assert {:ok, %{clip: %{id: id}}} =
             submit(w, %{
               "file_id" => w.rendered.id,
               "agent_id" => impostor.id,
               "submitted_by_agent_id" => impostor.id
             })

    assert Repo.get!(Clip, id).submitted_by_agent_id == w.agent.id
    assert [%ClipRender{submitted_by_agent_id: by}] = renders(id)
    assert by == w.agent.id
  end

  test "a profile with no project is profile_needs_project", w do
    {:ok, bare} =
      Platform.Social.create_profile(w.org_id, %{name: "Bare #{unique()}", project_id: nil})

    assert %Profile{project_id: nil} = bare

    assert {:error, %{code: :profile_needs_project}} =
             call(
               "social_clip_submit",
               %{"profile_id" => bare.id, "file_id" => w.rendered.id},
               w.ctx
             )
  end
end
