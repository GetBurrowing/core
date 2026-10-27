defmodule Platform.Social.ClipFixesTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Repo
  alias Platform.Social.{Clip, ClipJobs, ClipRender, ClipVersions}

  setup do
    w = render_world!()
    file = stored_file!(w.project, "render #{unique()}", "v1.mp4", "video/mp4")

    {:ok, %{job: job}} =
      ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
        source_url: "https://example.com/episode.mp4",
        in_s: 10.0,
        out_s: 30.0
      })

    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)

    {:ok, %{clip: clip}} =
      ClipJobs.complete(w.scope, job.id, w.agent.id, %{
        file_id: file.id,
        actual_in_s: 10.2,
        actual_out_s: 29.8,
        title: "Original",
        candidate_id: "candidate-1"
      })

    {:ok, [base]} = ClipVersions.recent(w.scope, w.profile.id, clip.id)
    Map.merge(w, %{clip: clip, base: base, render_file: file})
  end

  defp fix(w, attrs),
    do:
      ClipJobs.enqueue_fix(
        w.org_id,
        w.clip.id,
        w.approver.id,
        Map.put(attrs, :base_render_id, w.base.id)
      )

  test "nudge uses immutable actual bounds; success appends n+1 and retains prior file", w do
    assert {:ok, job} = fix(w, %{operation: "nudge", edge: "start", delta_s: 1})
    assert job.payload["in_s"] == 11.2
    assert job.payload["out_s"] == 29.8
    assert job.payload["expected_rev"] == 2
    assert job.payload["candidate_id"] == "candidate-1"
    assert Repo.get!(Clip, w.clip.id).render_file_id == w.render_file.id
    assert {:error, :job_in_flight} = fix(w, %{operation: "alternate_cut"})
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
    next_file = stored_file!(w.project, "new render #{unique()}", "v2.mp4", "video/mp4")

    assert {:ok, %{clip: clip}} =
             ClipJobs.complete(w.scope, job.id, w.agent.id, %{
               file_id: next_file.id,
               actual_in_s: 11.3,
               actual_out_s: 29.8
             })

    assert clip.rev == 2
    assert clip.review_status == "pending"
    assert Repo.get!(ClipRender, w.base.id).file_id == w.render_file.id
    assert {:error, :stale_version} = fix(w, %{operation: "alternate_cut"})
    {:ok, [latest, _]} = ClipVersions.recent(w.scope, w.profile.id, clip.id)
    assert latest.requested_start_s == 11.2
    assert latest.actual_start_s == 11.3
    assert latest.headline == "Original"
  end

  test "four edge/direction nudges are exact one second operations", w do
    for {edge, delta, a, b} <- [
          {"start", -1, 9.2, 29.8},
          {"start", 1, 11.2, 29.8},
          {"end", -1, 10.2, 28.8},
          {"end", 1, 10.2, 30.8}
        ] do
      assert {:ok, job} = fix(w, %{operation: "nudge", edge: edge, delta_s: delta})
      assert job.payload["in_s"] == a
      assert job.payload["out_s"] == b
      {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
      assert {:ok, _} = ClipJobs.fail(w.scope, job.id, w.agent.id, "fixture failure")
      assert Repo.get!(Clip, w.clip.id).render_file_id == w.render_file.id
    end
  end

  test "caption corrections identify an exact position and carry only user input", w do
    assert {:ok, job} =
             fix(w, %{
               operation: "caption_word",
               position: 3,
               original: "there",
               replacement: "their"
             })

    assert job.payload["fix"]["caption_fixes"] == %{
             "position" => 3,
             "original" => "there",
             "replacement" => "their"
           }

    refute Map.has_key?(job.payload, "transcript")
  end

  test "headline and alternate remain rerender intents tied to same clip", w do
    for operation <- ["regenerate_headline", "alternate_cut"] do
      assert {:ok, job} = fix(w, %{operation: operation})
      assert job.kind == "rerender"
      assert job.clip_id == w.clip.id
      assert job.payload["base_render_id"] == w.base.id
      {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
      {:ok, _} = ClipJobs.fail(w.scope, job.id, w.agent.id, "not rendered")
    end
  end

  test "invalid and unauthorized asks do not enqueue", w do
    for attrs <- [
          %{operation: "unknown"},
          %{operation: "nudge", edge: "start", delta_s: 2},
          %{operation: "caption_word", original: "x", replacement: "y"},
          %{operation: "caption_word", position: 0, original: "x", replacement: "two words"}
        ] do
      assert {:error, _} = fix(w, attrs)
    end

    assert {:error, :not_found} =
             ClipJobs.enqueue_fix(w.org_id, w.clip.id, w.approver.id, %{
               base_render_id: Ecto.UUID.generate(),
               operation: "alternate_cut"
             })

    assert {:error, :not_a_human} =
             ClipJobs.enqueue_fix(w.org_id, w.clip.id, w.agent.id, %{
               base_render_id: w.base.id,
               operation: "alternate_cut"
             })

    assert Repo.aggregate(Platform.Social.ClipJob, :count, :id) == 1
  end

  test "a render arriving while a fix runs makes completion stale without promotion", w do
    {:ok, job} = fix(w, %{operation: "nudge", edge: "end", delta_s: 1})
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
    file = stored_file!(w.project, "concurrent #{unique()}", "concurrent.mp4", "video/mp4")

    {:ok, promoted} =
      Repo.transaction(fn ->
        ClipVersions.append!(w.clip.id, file, %{}, %{
          completion_key: "concurrent",
          headline: "Concurrent"
        })
      end)

    assert {:error, :stale_version} =
             ClipJobs.complete(w.scope, job.id, w.agent.id, %{file_id: w.render_file.id})

    assert Repo.get!(Clip, w.clip.id).render_file_id == file.id
    assert Repo.get!(Clip, w.clip.id).rev == promoted.rev
    assert {:ok, versions} = ClipVersions.recent(w.scope, w.profile.id, w.clip.id)
    assert length(versions) == 2
  end

  test "nudge rejects negative source start and crossing end", w do
    base = %{w.base | actual_start_s: 0.0, actual_end_s: 0.5}

    assert {:error, :invalid_range} =
             Platform.Social.ClipFixes.validate(
               base,
               %{"operation" => "nudge", "edge" => "start", "delta_s" => -1}
             )

    assert {:error, :invalid_range} =
             Platform.Social.ClipFixes.validate(
               base,
               %{"operation" => "nudge", "edge" => "start", "delta_s" => 1}
             )
  end
end
