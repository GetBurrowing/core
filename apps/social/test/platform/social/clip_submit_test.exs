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
    [version] = renders(clip.id)
    assert version.headline == "Who makes Total War?"
    assert version.caption == nil
    assert version.duration_s == 31.5
    assert version.byte_size == w.rendered.byte_size
    assert version.actual_start_s == nil
    assert version.requested_start_s == nil
    assert version.snapshot_status == "recorded"
    assert version.provenance == %{"kind" => "external_submit"}

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

  describe "a repeat of one profile + exact file is idempotent" do
    defp clips_for(profile_id),
      do: Repo.all(from(c in Clip, where: c.profile_id == ^profile_id, order_by: c.id))

    defp render_total(profile_id) do
      Repo.aggregate(
        from(r in ClipRender,
          join: c in Clip,
          on: c.id == r.clip_id,
          where: c.profile_id == ^profile_id
        ),
        :count
      )
    end

    test "a repeat returns the existing clip: one clip, one render", w do
      assert {:ok, %{clip: first}} = submit(w, %{"file_id" => w.rendered.id, "title" => "One"})
      assert {:ok, %{clip: again}} = submit(w, %{"file_id" => w.rendered.id, "title" => "One"})

      assert again.id == first.id
      assert [_one] = clips_for(w.profile.id)
      assert render_total(w.profile.id) == 1
    end

    test "a repeat with another title or caption changes nothing", w do
      assert {:ok, %{clip: first}} =
               submit(w, %{"file_id" => w.rendered.id, "title" => "One", "caption" => "c1"})

      before = Repo.get!(Clip, first.id)

      assert {:ok, %{clip: again}} =
               submit(w, %{"file_id" => w.rendered.id, "title" => "Two", "caption" => "c2"})

      assert again.id == first.id
      assert again.title == "One" and again.caption == "c1"
      assert Repo.get!(Clip, first.id) == before
      assert render_total(w.profile.id) == 1
    end

    test "review state is kept: a rejected clip stays rejected and is not revived", w do
      assert {:ok, %{clip: first}} = submit(w, %{"file_id" => w.rendered.id})

      Repo.update_all(from(c in Clip, where: c.id == ^first.id),
        set: [
          review_status: "rejected",
          review_note: "no",
          reviewed_by_user_id: w.approver.id,
          reviewed_at: DateTime.utc_now()
        ]
      )

      assert {:ok, %{clip: again}} = submit(w, %{"file_id" => w.rendered.id, "title" => "New"})
      assert again.id == first.id
      assert again.review_status == "rejected"
      assert again.review_note == "no"
      assert again.title == nil
      assert [_one] = clips_for(w.profile.id)
    end

    test "a removed clip is not live: a repeat makes a new clip and leaves the removed one", w do
      assert {:ok, %{clip: first}} = submit(w, %{"file_id" => w.rendered.id})
      removed_at = DateTime.utc_now()
      Repo.update_all(from(c in Clip, where: c.id == ^first.id), set: [removed_at: removed_at])

      assert {:ok, %{clip: second}} = submit(w, %{"file_id" => w.rendered.id})
      assert second.id != first.id
      assert %Clip{removed_at: %DateTime{}} = Repo.get!(Clip, first.id)
      assert %Clip{removed_at: nil, review_status: "pending"} = Repo.get!(Clip, second.id)

      # and now the new one is the live clip a further repeat returns
      assert {:ok, %{clip: third}} = submit(w, %{"file_id" => w.rendered.id})
      assert third.id == second.id
      assert length(clips_for(w.profile.id)) == 2
    end

    test "a repeat submit of a rejected clip leaves the stored row untouched", w do
      assert {:ok, %{clip: first}} = submit(w, %{"file_id" => w.rendered.id})

      old = DateTime.add(DateTime.utc_now(), -3600, :second)

      Repo.update_all(from(c in Clip, where: c.id == ^first.id),
        set: [
          review_status: "rejected",
          review_note: "no",
          reviewed_by_user_id: w.approver.id,
          reviewed_at: old,
          updated_at: old
        ]
      )

      before = Repo.get!(Clip, first.id)
      assert before.review_status == "rejected"

      assert {:ok, %{clip: again}} = submit(w, %{"file_id" => w.rendered.id, "title" => "New"})
      assert again.id == first.id

      after_repeat = Repo.get!(Clip, first.id)
      assert after_repeat.review_status == "rejected"
      assert after_repeat.review_note == "no"
      assert after_repeat.reviewed_by_user_id == w.approver.id
      assert after_repeat.reviewed_at == before.reviewed_at
      assert after_repeat.updated_at == before.updated_at
      assert after_repeat == before
    end

    test "a first import broadcasts the clip; a repeat broadcasts nothing", w do
      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, Platform.Social.clips_topic(w.profile.id))

      assert {:ok, %{clip: first}} = submit(w, %{"file_id" => w.rendered.id})
      first_id = first.id
      # control: the same subscription does see a created clip, so the refute can fail
      assert_receive {:social_clip, %Clip{id: ^first_id}}

      assert {:ok, %{clip: again}} = submit(w, %{"file_id" => w.rendered.id})
      assert again.id == first_id
      refute_receive {:social_clip, _}, 200
    end

    test "a repeat returns the oldest live clip when more than one exists", w do
      now = DateTime.utc_now()
      oldest_at = DateTime.add(now, -7200, :second)
      newest_at = DateTime.add(now, -60, :second)

      insert_live = fn at ->
        Repo.insert!(%Clip{
          profile_id: w.profile.id,
          render_file_id: w.rendered.id,
          status: "rendered",
          origin: "external",
          review_status: "pending",
          inserted_at: at,
          updated_at: at
        })
      end

      # the newest goes in first, so neither insert order nor id order picks the oldest
      newest = insert_live.(newest_at)
      oldest = insert_live.(oldest_at)
      assert DateTime.compare(oldest.inserted_at, newest.inserted_at) == :lt

      assert {:ok, %{clip: again}} = submit(w, %{"file_id" => w.rendered.id})
      assert again.id == oldest.id
      assert again.id != newest.id
      assert length(clips_for(w.profile.id)) == 2
    end

    test "a different file or a different profile gets its own clip", w do
      other_file = stored_file!(w.project, "second clip #{unique()}", "c2.mp4", "video/mp4")

      {:ok, sibling} =
        Platform.Social.create_profile(w.org_id, %{
          name: "Sibling #{unique()}",
          project_id: w.project.id
        })

      assert {:ok, %{clip: a}} = submit(w, %{"file_id" => w.rendered.id})
      assert {:ok, %{clip: b}} = submit(w, %{"file_id" => other_file.id})

      assert {:ok, %{clip: c}} =
               call(
                 "social_clip_submit",
                 %{"profile_id" => sibling.id, "file_id" => w.rendered.id},
                 w.ctx
               )

      assert length(Enum.uniq([a.id, b.id, c.id])) == 3
      assert length(clips_for(w.profile.id)) == 2
      assert length(clips_for(sibling.id)) == 1
    end

    test "a repeat is still refused for an unauthorized caller, and leaks nothing", w do
      assert {:ok, %{clip: _}} = submit(w, %{"file_id" => w.rendered.id})

      outsider =
        call(
          "social_clip_submit",
          %{"profile_id" => w.profile.id, "file_id" => w.rendered.id},
          %{agent_id: w.other.agent.id}
        )

      random =
        call(
          "social_clip_submit",
          %{"profile_id" => Ecto.UUID.generate(), "file_id" => w.rendered.id},
          %{agent_id: w.other.agent.id}
        )

      assert {:error, %{code: :not_found}} = outsider
      assert outsider == random
      assert [_one] = clips_for(w.profile.id)
    end

    test "a repeat is still refused when the file is no longer a live video in the project", w do
      assert {:ok, %{clip: first}} = submit(w, %{"file_id" => w.rendered.id})

      # not a video any more
      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^w.rendered.id),
        set: [content_type: "text/plain"]
      )

      assert {:error, %{code: :not_a_video}} = submit(w, %{"file_id" => w.rendered.id})

      # deleted
      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^w.rendered.id),
        set: [content_type: "video/mp4", deleted_at: DateTime.utc_now()]
      )

      assert {:error, %{code: :file_not_in_project}} = submit(w, %{"file_id" => w.rendered.id})
      assert [%Clip{id: id}] = clips_for(w.profile.id)
      assert id == first.id
    end

    test "a repeat is still refused for a profile without a project, and for bad title or platforms",
         w do
      assert {:ok, %{clip: _}} = submit(w, %{"file_id" => w.rendered.id})

      assert {:error, %{code: :invalid_title}} =
               submit(w, %{"file_id" => w.rendered.id, "title" => String.duplicate("t", 201)})

      assert {:error, %{code: :invalid_argument}} =
               submit(w, %{"file_id" => w.rendered.id, "platforms" => ["instagram"]})

      Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id), set: [project_id: nil])

      assert {:error, %{code: :profile_needs_project}} =
               submit(w, %{"file_id" => w.rendered.id})

      assert [_one] = clips_for(w.profile.id)
    end
  end
end
