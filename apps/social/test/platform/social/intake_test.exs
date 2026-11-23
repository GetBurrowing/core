defmodule Platform.Social.IntakeTest do
  @moduledoc """
  Social Studio slice C: `Intake.import_manifest/4`
  turns an externally rendered clip manifest into Studio clip records.

  Importing a manifest creates clips with
  `flow: "studio"`, `origin: "external"`, `review_status: "pending"`, rev 1,
  one render row each, the manifest's approval status stored only as a claim;
  re-importing the same manifest creates nothing new; a profile with Studio off
  refuses with `:studio_disabled`; no guest tables or columns exist.

  Replay (design owner addition): an equivalent replay returns the existing
  clip unchanged (`:exists`); a reused ref with a different file or payload is
  `:external_ref_conflict`; a reviewed clip is never overwritten.

  Mutation checks to run (each should fail the named tests):
    * delete the `studio_enabled` check: "a profile with Studio off refuses";
    * delete the approver check: "a non-approver is refused";
    * set `review_status` from the claim: "the manifest's approval claim is stored, never applied";
    * delete the `pg_advisory_xact_lock` line: "an import waits while another
      connection holds the ref lock".

  Async false: the Fake publisher's call log and the unboxed race tests are global.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Social
  alias Platform.Social.{Clip, ClipPublish, ClipRender, Intake, Profile, Studio}
  alias Platform.Tasks.Project
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    %{w: studio_world!()}
  end

  # One manifest entry backed by a real stored video file in the world's project.
  defp entry(w, ref, attrs \\ %{}) do
    file = stored_file!(w.project, "clip bytes #{unique()}", "#{unique()}.mp4", "video/mp4")

    Map.merge(
      %{
        "external_ref" => ref,
        "file_id" => file.id,
        "title" => "Title #{ref}",
        "caption" => "Caption #{ref}",
        "speaker" => "Host",
        "episode_code" => "EP04",
        "platforms" => ["tiktok"],
        "duration_s" => 31.5,
        "width" => 1080,
        "height" => 1920,
        "approval_claim" => %{"status" => "proposed", "approved" => false}
      },
      attrs
    )
  end

  defp manifest(entries), do: %{"clips" => entries}

  defp import!(w, entries),
    do: Intake.import_manifest(w.scope, w.profile.id, manifest(entries), w.approver.id)

  defp clips(w),
    do: Repo.all(from(c in Clip, where: c.profile_id == ^w.profile.id, order_by: c.inserted_at))

  defp renders(clip_id), do: Repo.all(from(r in ClipRender, where: r.clip_id == ^clip_id))
  defp statuses({:ok, %{clips: results}}), do: Enum.map(results, & &1.status)

  describe "a manifest becomes Studio clip records" do
    test "creates one studio clip and one render per entry", %{w: w} do
      entries = [entry(w, "ep4/aaa"), entry(w, "ep4/bbb"), entry(w, "ep4/ccc")]

      assert {:ok, %{clips: results}} = import!(w, entries)
      assert Enum.map(results, & &1.external_ref) == ["ep4/aaa", "ep4/bbb", "ep4/ccc"]
      assert Enum.all?(results, &(&1.status == :created))

      stored = clips(w)
      assert length(stored) == 3

      for clip <- stored do
        assert clip.flow == "studio"
        assert clip.origin == "external"
        assert clip.review_status == "pending"
        assert clip.status == "rendered"
        assert clip.rev == 1
        assert clip.reviewed_by_user_id == nil
        assert [render] = renders(clip.id)
        assert render.rev == 1
        assert render.file_id == clip.render_file_id
      end

      first = Enum.find(stored, &(&1.external_ref == "ep4/aaa"))
      assert first.title == "Title ep4/aaa"
      assert first.episode_code == "EP04"
      assert first.platforms == ["tiktok"]
      assert first.duration_s == 31.5
    end

    test "the manifest's approval claim is stored, never applied", %{w: w} do
      claim = %{"status" => "approved", "approved" => true, "approved_by" => "someone"}
      assert {:ok, _} = import!(w, [entry(w, "ep4/claimed", %{"approval_claim" => claim})])

      [clip] = clips(w)
      assert clip.review_status == "pending"
      assert clip.reviewed_at == nil
      assert clip.reviewed_by_user_id == nil
      assert clip.import_claim["approval_claim"] == claim
    end

    test "a studio clip never reaches the legacy publish selectors or legacy approval", %{w: w} do
      assert {:ok, _} = import!(w, [entry(w, "ep4/studio")])
      [clip] = clips(w)

      assert {:error, :studio_clip} =
               Social.draft_clip(
                 w.org_id,
                 clip.id,
                 w.approver.id,
                 %{"render_id" => render_id!(clip), "account_ids" => [w.tiktok.id]},
                 now: DateTime.utc_now()
               )

      assert ClipPublish.due(DateTime.add(DateTime.utc_now(), 86_400, :second)) == []
      assert Repo.aggregate(from(p in Social.Post, where: p.clip_id == ^clip.id), :count) == 0
      assert Enum.reject(Fake.calls(), &match?({:verify_webhook, _, _}, &1)) == []
    end

    test "no guest column or table exists" do
      cols =
        Repo.query!(
          "SELECT table_name, column_name FROM information_schema.columns " <>
            "WHERE table_name LIKE 'social_%' AND (column_name ILIKE '%guest%' OR table_name ILIKE '%guest%')"
        )

      assert cols.rows == []
    end
  end

  describe "per-clip results" do
    test "a file outside the project fails that clip and the rest import", %{w: w} do
      other_project = project!(w.other_org_id)
      foreign = stored_file!(other_project, "x", "x.mp4", "video/mp4")

      result =
        import!(w, [
          entry(w, "ep4/good-1"),
          entry(w, "ep4/bad", %{"file_id" => foreign.id}),
          entry(w, "ep4/good-2")
        ])

      assert statuses(result) == [:created, {:error, :file_not_in_project}, :created]
      assert Enum.map(clips(w), & &1.external_ref) |> Enum.sort() == ["ep4/good-1", "ep4/good-2"]
    end

    test "a non-video file is refused for that clip", %{w: w} do
      text = stored_file!(w.project, "words", "notes.txt", "text/plain")

      assert statuses(import!(w, [entry(w, "ep4/text", %{"file_id" => text.id})])) == [
               {:error, :not_a_video}
             ]

      assert clips(w) == []
    end

    test "a missing or blank external_ref fails that clip only", %{w: w} do
      result =
        import!(w, [
          entry(w, "ep4/ok"),
          Map.delete(entry(w, "x"), "external_ref"),
          entry(w, "   ")
        ])

      assert statuses(result) == [
               :created,
               {:error, :invalid_external_ref},
               {:error, :invalid_external_ref}
             ]
    end

    test "a clip with no title imports with a nil title (a local-mode export carries none)", %{
      w: w
    } do
      no_key = entry(w, "ep4/no-title-key") |> Map.delete("title")
      nil_title = entry(w, "ep4/nil-title", %{"title" => nil})

      assert statuses(import!(w, [no_key, nil_title])) == [:created, :created]
      assert clips(w) |> Enum.map(& &1.title) == [nil, nil]
    end

    test "a title the clip cannot hold rolls that clip back: no clip and no orphan render", %{
      w: w
    } do
      before_renders = Repo.aggregate(ClipRender, :count)
      result = import!(w, [entry(w, "ep4/long", %{"title" => String.duplicate("t", 201)})])

      assert statuses(result) == [{:error, :invalid_title}]
      assert clips(w) == []
      assert Repo.aggregate(ClipRender, :count) == before_renders
    end

    test "platforms the profile does not have are refused for that clip", %{w: w} do
      result = import!(w, [entry(w, "ep4/pf", %{"platforms" => ["myspace"]})])
      assert statuses(result) == [{:error, {:invalid_platforms, ["myspace"]}}]
    end

    test "a ref repeated inside one manifest refuses the whole manifest", %{w: w} do
      assert {:error, :duplicate_external_ref} =
               import!(w, [entry(w, "ep4/dup"), entry(w, "ep4/dup")])

      assert clips(w) == []
    end

    test "a manifest that is not a list of clips is invalid", %{w: w} do
      for bad <- [%{}, %{"clips" => []}, %{"clips" => "nope"}, %{"clips" => [1]}, "nope", nil] do
        assert {:error, :invalid_manifest} =
                 Intake.import_manifest(w.scope, w.profile.id, bad, w.approver.id)
      end

      assert clips(w) == []
    end
  end

  describe "replay" do
    test "re-importing the same manifest creates nothing new", %{w: w} do
      entries = [entry(w, "ep4/one"), entry(w, "ep4/two")]
      assert {:ok, %{clips: first}} = import!(w, entries)
      before = clips(w)

      assert {:ok, %{clips: second}} = import!(w, entries)
      assert Enum.map(second, & &1.status) == [:exists, :exists]
      assert Enum.map(second, & &1.clip_id) == Enum.map(first, & &1.clip_id)
      assert clips(w) == before
      assert Enum.map(before, &length(renders(&1.id))) == [1, 1]
    end

    test "a reused ref with a different file is a conflict and changes nothing", %{w: w} do
      e = entry(w, "ep4/same")
      assert {:ok, _} = import!(w, [e])
      before = clips(w)

      other = stored_file!(w.project, "other bytes #{unique()}", "other.mp4", "video/mp4")

      assert statuses(import!(w, [%{e | "file_id" => other.id}])) == [
               {:error, :external_ref_conflict}
             ]

      assert clips(w) == before
    end

    test "omitted platforms and an empty list are the same entry (both import as none)", %{w: w} do
      e = entry(w, "ep4/platforms") |> Map.delete("platforms")
      assert {:ok, %{clips: [%{status: :created, clip_id: id}]}} = import!(w, [e])

      assert {:ok, %{clips: [%{status: :exists, clip_id: ^id}]}} =
               import!(w, [Map.put(e, "platforms", [])])

      assert {:ok, %{clips: [%{status: :exists, clip_id: ^id}]}} =
               import!(w, [Map.put(e, "platforms", nil)])

      assert statuses(import!(w, [Map.put(e, "platforms", ["tiktok"])])) ==
               [{:error, :external_ref_conflict}]
    end

    test "a reused ref with a different title or claim is a conflict", %{w: w} do
      e = entry(w, "ep4/same")
      assert {:ok, _} = import!(w, [e])

      assert statuses(import!(w, [%{e | "title" => "Changed"}])) == [
               {:error, :external_ref_conflict}
             ]

      assert statuses(
               import!(w, [
                 %{e | "approval_claim" => %{"status" => "approved", "approved" => true}}
               ])
             ) ==
               [{:error, :external_ref_conflict}]
    end

    test "a reviewed clip is never overwritten, by an equivalent or a conflicting replay", %{w: w} do
      e = entry(w, "ep4/reviewed")
      assert {:ok, _} = import!(w, [e])
      [clip] = clips(w)

      reviewed =
        clip |> Clip.review_changeset({:approve, w.approver.id}) |> Repo.update!()

      assert statuses(import!(w, [e])) == [:exists]

      assert statuses(import!(w, [%{e | "title" => "Changed"}])) == [
               {:error, :external_ref_conflict}
             ]

      assert Repo.get!(Clip, clip.id) == reviewed
      assert Repo.get!(Clip, clip.id).review_status == "approved"
      assert length(renders(clip.id)) == 1
    end

    test "an entry that states the file's hash and size imports when they still match", %{w: w} do
      file = stored_file!(w.project, "media bytes #{unique()}", "m.mp4", "video/mp4")

      e =
        entry(w, "ep4/media", %{
          "file_id" => file.id,
          "sha256" => file.content_hash,
          "size_bytes" => file.byte_size
        })

      assert statuses(import!(w, [e])) == [:created]
      assert statuses(import!(w, [e])) == [:exists]
    end

    test "an entry whose stated hash or size no longer matches the file is :file_changed", %{w: w} do
      file = stored_file!(w.project, "media bytes #{unique()}", "m.mp4", "video/mp4")

      wrong_hash =
        entry(w, "ep4/wrong-hash", %{
          "file_id" => file.id,
          "sha256" => String.duplicate("0", 64),
          "size_bytes" => file.byte_size
        })

      wrong_size =
        entry(w, "ep4/wrong-size", %{
          "file_id" => file.id,
          "sha256" => file.content_hash,
          "size_bytes" => file.byte_size + 1
        })

      assert statuses(import!(w, [wrong_hash, wrong_size])) == [
               {:error, :file_changed},
               {:error, :file_changed}
             ]

      assert clips(w) == []
    end

    test "a replay that states the hash is checked against the file as it is now", %{w: w} do
      file = stored_file!(w.project, "replay media #{unique()}", "m.mp4", "video/mp4")

      e =
        entry(w, "ep4/replay-media", %{
          "file_id" => file.id,
          "sha256" => file.content_hash,
          "size_bytes" => file.byte_size
        })

      assert statuses(import!(w, [e])) == [:created]
      [before] = clips(w)

      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
        set: [content_hash: String.duplicate("a", 64)]
      )

      assert statuses(import!(w, [e])) == [{:error, :file_changed}]
      assert clips(w) == [before]
      assert length(renders(before.id)) == 1

      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
        set: [content_hash: file.content_hash, deleted_at: DateTime.utc_now()]
      )

      assert statuses(import!(w, [e])) == [{:error, :file_not_in_project}]
      assert clips(w) == [before]
    end

    test "a replay with no stated hash is :exists whatever happened to the file", %{w: w} do
      file = stored_file!(w.project, "plain replay #{unique()}", "m.mp4", "video/mp4")
      e = entry(w, "ep4/plain", %{"file_id" => file.id})
      assert statuses(import!(w, [e])) == [:created]

      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
        set: [content_hash: String.duplicate("b", 64)]
      )

      assert statuses(import!(w, [e])) == [:exists]
    end

    test "a files.read deny on the project refuses the import while social.use still holds", %{
      w: w
    } do
      e = entry(w, "ep4/no-read")

      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, w.approver.id},
          permission: "files.read",
          resource: {:project, w.profile.project_id}
        })

      assert :ok = Studio.authorize_studio_actor(w.profile, w.approver.id)

      assert {:error, :no_file_access} =
               Intake.import_manifest(w.scope, w.profile.id, manifest([e]), w.approver.id)

      assert clips(w) == []
    end

    test "a hash without a size, or a size without a hash, is refused", %{w: w} do
      file = stored_file!(w.project, "media bytes #{unique()}", "m.mp4", "video/mp4")

      only_hash =
        entry(w, "ep4/only-hash", %{"file_id" => file.id, "sha256" => file.content_hash})

      only_size =
        entry(w, "ep4/only-size", %{"file_id" => file.id, "size_bytes" => file.byte_size})

      assert statuses(import!(w, [only_hash, only_size])) == [
               {:error, :invalid_media_claim},
               {:error, :invalid_media_claim}
             ]

      assert clips(w) == []
    end

    test "the same ref in another profile is a separate clip", %{w: w} do
      {:ok, second} =
        Social.create_profile(w.org_id, %{
          name: "Second #{unique()}",
          project_id: w.project.id,
          approver_user_ids: [w.approver.id],
          space_id: w.profile.space_id
        })

      {:ok, _} = Studio.set_enabled(w.org_id, second.id, w.approver.id, true)
      {:ok, _} = Social.create_account(w.org_id, second, %{platform: "tiktok", handle: "@two"})

      assert {:ok, _} = import!(w, [entry(w, "ep4/shared-ref")])

      assert {:ok, %{clips: [%{status: :created}]}} =
               Intake.import_manifest(
                 w.scope,
                 second.id,
                 manifest([entry(w, "ep4/shared-ref")]),
                 w.approver.id
               )
    end
  end

  describe "who and when" do
    test "a profile with Studio off refuses with :studio_disabled and writes nothing", %{w: w} do
      {:ok, off} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      e = entry(w, "ep4/off")

      assert {:error, :studio_disabled} =
               Intake.import_manifest(w.scope, off.id, manifest([e]), w.approver.id)

      assert clips(w) == []
    end

    test "a non-approver is refused and writes nothing", %{w: w} do
      member = member!(user!(), w.org_id)

      assert {:error, reason} =
               Intake.import_manifest(
                 w.scope,
                 w.profile.id,
                 manifest([entry(w, "ep4/x")]),
                 member.id
               )

      assert reason in [:not_an_approver, :approver_no_access]
      assert clips(w) == []
    end

    test "an agent id is refused: intake is human only", %{w: w} do
      assert {:error, :not_a_human} =
               Intake.import_manifest(
                 w.scope,
                 w.profile.id,
                 manifest([entry(w, "ep4/x")]),
                 w.agent.id
               )

      assert clips(w) == []
    end

    test "another org's scope reads :not_found and learns nothing about existing refs", %{w: w} do
      e = entry(w, "ep4/private")
      assert {:ok, _} = import!(w, [e])

      assert {:error, :not_found} =
               Intake.import_manifest(
                 {:tenant, w.other_org_id},
                 w.profile.id,
                 manifest([e]),
                 w.outsider.id
               )
    end

    test "Studio off is checked before the caller, as in the check order", %{w: w} do
      {:ok, off} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      member = member!(user!(), w.org_id)

      assert {:error, :studio_disabled} =
               Intake.import_manifest(w.scope, off.id, manifest([entry(w, "ep4/x")]), member.id)
    end
  end

  describe "the project and social.use steps (slice A's Studio.authorize_studio_actor/2)" do
    defp set_project!(w, project_id) do
      Repo.update_all(from(p in Profile, where: p.id == ^w.profile.id),
        set: [project_id: project_id]
      )

      :ok
    end

    test "a valid control: a deny on ANOTHER project does not refuse", %{w: w} do
      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, w.approver.id},
          permission: "social.use",
          resource: {:project, project!(w.org_id).id}
        })

      assert statuses(import!(w, [entry(w, "ep4/control")])) == [:created]
    end

    test "a profile with no project is refused :studio_needs_project", %{w: w} do
      e = entry(w, "ep4/x")
      :ok = set_project!(w, nil)

      assert {:error, :studio_needs_project} =
               Intake.import_manifest(w.scope, w.profile.id, manifest([e]), w.approver.id)

      assert clips(w) == []
    end

    test "another org's project is refused :studio_needs_project", %{w: w} do
      e = entry(w, "ep4/x")
      :ok = set_project!(w, project!(w.other_org_id).id)

      assert {:error, :studio_needs_project} =
               Intake.import_manifest(w.scope, w.profile.id, manifest([e]), w.approver.id)

      assert clips(w) == []
    end

    test "an archived project is refused :studio_needs_project", %{w: w} do
      e = entry(w, "ep4/x")

      Repo.update_all(from(p in Project, where: p.id == ^w.project.id),
        set: [archived_at: DateTime.utc_now()]
      )

      assert {:error, :studio_needs_project} =
               Intake.import_manifest(w.scope, w.profile.id, manifest([e]), w.approver.id)

      assert clips(w) == []
    end

    test "a project scheduled for deletion is refused :studio_needs_project", %{w: w} do
      e = entry(w, "ep4/x")

      Repo.update_all(from(p in Project, where: p.id == ^w.project.id),
        set: [deletion_scheduled_at: DateTime.utc_now()]
      )

      assert {:error, :studio_needs_project} =
               Intake.import_manifest(w.scope, w.profile.id, manifest([e]), w.approver.id)

      assert clips(w) == []
    end

    test "a project-level deny of social.use refuses while the module stays visible", %{w: w} do
      e = entry(w, "ep4/x")

      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, w.approver.id},
          permission: "social.use",
          resource: {:project, w.profile.project_id}
        })

      assert Platform.Access.module_access?(
               Platform.Access.Scope.for_user(w.approver),
               :social,
               "social.use"
             )

      assert :ok = Social.approver_check(w.org_id, w.profile, w.approver.id)

      assert {:error, :no_social_access} =
               Intake.import_manifest(w.scope, w.profile.id, manifest([e]), w.approver.id)

      assert clips(w) == []
    end

    test "a non-approver is refused with the approver vocabulary before the project is looked at",
         %{w: w} do
      member = member!(user!(), w.org_id)
      e = entry(w, "ep4/x")
      :ok = set_project!(w, nil)

      assert {:error, reason} =
               Intake.import_manifest(w.scope, w.profile.id, manifest([e]), member.id)

      assert reason in [:not_an_approver, :approver_no_access]
    end

    test "a replay of an existing ref is refused too when the project is no longer valid", %{w: w} do
      e = entry(w, "ep4/replay")
      assert {:ok, _} = import!(w, [e])
      before = clips(w)

      Repo.update_all(from(p in Project, where: p.id == ^w.project.id),
        set: [archived_at: DateTime.utc_now()]
      )

      assert {:error, :studio_needs_project} =
               Intake.import_manifest(w.scope, w.profile.id, manifest([e]), w.approver.id)

      assert clips(w) == before
    end

    test "deleting the profile is refused while it holds an imported clip", %{w: w} do
      assert {:ok, _} = import!(w, [entry(w, "ep4/kept")])
      [clip] = clips(w)

      assert {:error, :has_studio_clips} = Social.delete_profile(w.org_id, w.profile)
      assert Repo.get(Clip, clip.id)
      assert length(renders(clip.id)) == 1
    end
  end

  # Inside the SQL sandbox every process shares one connection and one
  # transaction, so a lock can never block anybody and a race test would pass
  # without the lock (see group_conversation_dedupe_test.exs). These tests run
  # outside it, commit their fixtures and delete them in on_exit.
  describe "concurrent replay" do
    setup do
      # The same shape as clip_closing_video_test.exs `committed_world!/0`: users made by the
      # world are found by diffing the table, and rows are deleted in dependency order
      # (profile, project, space, agent, users, orgs). Every step is attempted even if one
      # raises, and the first error is re-raised at the end, so a failing step cannot leave
      # committed rows that fail unrelated tests later in the run.
      w =
        unboxed(fn ->
          before = Repo.all(from(u in Platform.Accounts.User, select: u.id))
          w = studio_world!()
          created = Repo.all(from(u in Platform.Accounts.User, select: u.id)) -- before
          Map.put(w, :created_users, created)
        end)

      on_exit(fn ->
        steps = [
          fn ->
            Repo.delete_all(from(p in Platform.Social.Profile, where: p.id == ^w.profile.id))
          end,
          fn ->
            Repo.delete_all(from(p in Platform.Tasks.Project, where: p.id == ^w.project.id))
          end,
          fn ->
            Repo.delete_all(from(s in Platform.Chat.Space, where: s.id == ^w.profile.space_id))
          end,
          fn -> Repo.delete_all(from(a in Platform.Agents.Agent, where: a.id == ^w.agent.id)) end,
          fn ->
            Repo.delete_all(from(u in Platform.Accounts.User, where: u.id in ^w.created_users))
          end,
          fn ->
            Repo.delete_all(
              from(o in Platform.Tenancy.Org, where: o.id in ^[w.org_id, w.other_org_id])
            )
          end
        ]

        unboxed(fn ->
          errors =
            for step <- steps, reduce: [] do
              acc ->
                try do
                  step.()
                  acc
                rescue
                  e -> [e | acc]
                end
            end

          if errors != [], do: raise(List.last(errors))
        end)
      end)

      %{w: w}
    end

    defp unboxed(fun),
      do: Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end) |> Task.await(30_000)

    defp unboxed_task(fun), do: Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
    defp lock_key(w, ref), do: "social:clip_import:#{w.profile.id}:#{ref}"

    defp clip_file!(w),
      do: unboxed(fn -> stored_file!(w.project, "bytes #{unique()}", "c.mp4", "video/mp4") end)

    defp entry_for(ref, file) do
      %{"external_ref" => ref, "file_id" => file.id, "title" => "T", "platforms" => ["tiktok"]}
    end

    test "an import waits while another connection holds the ref lock", %{w: w} do
      parent = self()
      ref = "ep4/locked"
      file = clip_file!(w)

      holder =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
              lock_key(w, ref)
            ])

            send(parent, :locked)

            receive do
              :release -> :ok
            after
              10_000 -> :timeout
            end
          end)
        end)

      assert_receive :locked, 5_000

      importer =
        unboxed_task(fn ->
          Intake.import_manifest(
            w.scope,
            w.profile.id,
            manifest([entry_for(ref, file)]),
            w.approver.id
          )
        end)

      assert Task.yield(importer, 300) == nil, "import returned while the ref lock was held"

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 5_000)
      assert {:ok, %{clips: [%{status: :created}]}} = Task.await(importer, 5_000)
    end

    test "two identical concurrent imports create one clip: one :created, one :exists", %{w: w} do
      file = clip_file!(w)
      e = entry_for("ep4/race", file)

      tasks =
        for _ <- 1..2 do
          unboxed_task(fn ->
            Intake.import_manifest(w.scope, w.profile.id, manifest([e]), w.approver.id)
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 15_000))
      assert Enum.sort(Enum.map(results, &statuses/1)) == [[:created], [:exists]]

      unboxed(fn ->
        assert [clip] = Repo.all(from(c in Clip, where: c.profile_id == ^w.profile.id))
        assert length(renders(clip.id)) == 1
      end)
    end

    test "two conflicting concurrent imports of one ref: one wins, the other conflicts", %{w: w} do
      file_a = clip_file!(w)
      file_b = clip_file!(w)

      tasks =
        for file <- [file_a, file_b] do
          unboxed_task(fn ->
            Intake.import_manifest(
              w.scope,
              w.profile.id,
              manifest([entry_for("ep4/race-conflict", file)]),
              w.approver.id
            )
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 15_000))

      assert Enum.sort_by(Enum.map(results, &statuses/1), &inspect/1) ==
               [[:created], [{:error, :external_ref_conflict}]]

      unboxed(fn ->
        assert [_one] = Repo.all(from(c in Clip, where: c.profile_id == ^w.profile.id))
      end)
    end
  end
end
