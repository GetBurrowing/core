defmodule Platform.Social.ClipHeadlineQualificationTest do
  use Platform.DataCase, async: false
  import Platform.SocialFixtures
  alias Platform.Repo
  alias Platform.Social.{ClipJobs, ClipRender}

  test "queued defaults, edit, regeneration and appearance preserve immutable source and wording receipt" do
    w = render_world!()

    {:ok, _} =
      ClipJobs.save_show_default(w.org_id, w.profile.id, w.approver.id, %{
        "title" => %{"template" => "chrome-hook", "secs" => 2.0}
      })

    {:ok, %{clip: clip, job: initial}} =
      ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
        source_url: "https://example.com/original.mp4",
        in_s: 1500.0,
        out_s: 1504.0
      })

    assert initial.payload["headline_template"]["template"] == "chrome-hook"

    assert initial.payload["headline_template"]["timing"] == %{
             "entrance_s" => 0.2,
             "hold_s" => 1.55,
             "exit_s" => 0.25,
             "total_s" => 2.0
           }

    assert initial.payload["headline_template"]["assets"]["font_sha256"] ==
             "a4ba3a92350ebb031da0cb47630ac49eb265082ca1bc0450442f4a83ab947cab"

    {:ok, _} =
      ClipJobs.save_show_default(w.org_id, w.profile.id, w.approver.id, %{
        "title" => %{"template" => "arcade-punch", "secs" => 4.0}
      })

    old_payload = initial.payload
    base = complete!(w, initial, "initial")
    assert base.look["title"]["template"] == "chrome-hook"
    assert base.source["source_url"] == "https://example.com/original.mp4"
    before = Repo.get!(ClipRender, base.id)

    {:ok, edit} =
      ClipJobs.enqueue_fix(w.org_id, clip.id, w.approver.id, %{
        "base_render_id" => base.id,
        "operation" => "edit_headline",
        "headline" => "Google"
      })

    assert edit.payload["headline"]["requested_headline"] == "Google"
    assert edit.payload["candidate_id"] == "original-candidate"
    assert edit.payload["headline_template"]["template"] == "chrome-hook"
    edited = complete!(w, edit, "edited")

    {:ok, regenerate} =
      ClipJobs.enqueue_fix(w.org_id, clip.id, w.approver.id, %{
        "base_render_id" => edited.id,
        "operation" => "regenerate_headline"
      })

    assert regenerate.payload["fix"]["operation"] == "regenerate_headline"
    assert regenerate.payload["candidate_id"] == "original-candidate"
    assert regenerate.payload["headline_template"]["template"] == "chrome-hook"
    regenerated = complete!(w, regenerate, "regenerated")

    {:ok, appearance} =
      ClipJobs.enqueue_appearance(w.org_id, clip.id, w.approver.id, %{
        base_render_id: regenerated.id,
        look: %{"title" => %{"template" => "neon-broadcast"}}
      })

    assert appearance.payload["headline_template"]["template"] == "neon-broadcast"
    assert appearance.payload["headline_base"] == regenerated.provenance["headline"]["content"]
    assert appearance.payload["candidate_id"] == "original-candidate"
    assert Repo.get!(ClipRender, base.id) == before
    assert Repo.reload!(initial).payload == old_payload
  end

  defp complete!(w, job, name) do
    file = stored_file!(w.project, "#{name} render #{unique()}", name <> ".mp4", "video/mp4")
    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.agent.id)
    content = String.duplicate("a", 64)

    receipt =
      job.payload["headline_template"]
      |> Map.delete("emphasis_text")
      |> Map.merge(%{
        "content" => %{"artifact" => "sha256:" <> content, "sha256" => content},
        "output_sha256" => file.content_hash
      })

    {:ok, %{clip: clip}} =
      ClipJobs.complete(w.scope, job.id, w.agent.id, %{
        file_id: file.id,
        candidate_id: "original-candidate",
        headline_applied: true,
        headline_render: receipt
      })

    Repo.get_by!(ClipRender, clip_id: clip.id, rev: clip.rev)
  end
end
