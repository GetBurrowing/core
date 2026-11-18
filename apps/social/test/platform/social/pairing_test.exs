defmodule Platform.Social.PairingTest do
  @moduledoc """
  Social Studio slice C, pairing delta: matches the entries of a clip-tool export to the
  videos already uploaded to the profile's project, by SHA-256 and byte size, and turns
  confirmed choices into an intake manifest.

  Rules under test (calcifer's brief):
    * a single exact match is proposed; several matches need a choice; none reads
      "no matching uploaded file";
    * a file is never matched by name;
    * only live, finalized video files of THIS profile's project are candidates (another
      project's file with the same bytes is invisible);
    * the chosen file is re-verified when the manifest is built, and again at import
      (`Intake` checks the expected hash and size against the file as it is then);
    * a local-mode export has no title and still imports.

  Mutation checks to run: match on the filename instead of the hash; drop the
  project filter; skip the size comparison; skip the re-verification of a choice.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.SocialFixtures
  import Platform.SocialStudioFixtures

  alias Platform.Social.{Clip, Intake, Pairing, Studio}

  setup do
    %{w: studio_world!()}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # One export entry as `clip project export-intake` writes it, for `bytes`.
  # `local?` leaves out the title and speakers, as a local-mode project does.
  defp export_entry(ref, bytes, opts \\ []) do
    base = %{
      "external_ref" => ref,
      "files" => %{"captioned" => "01_#{ref |> String.replace("/", "-")}.mp4"},
      "size_bytes" => byte_size(bytes),
      "sha256" => sha(bytes),
      "duration_s" => 31.5,
      "approval_claim" => %{
        "status" => "cut",
        "approved" => false,
        "approval_recorded" => false,
        "approver_recorded" => false,
        "reapproval_pending" => false
      }
    }

    if Keyword.get(opts, :local?, false),
      do: base,
      else: Map.merge(base, %{"title" => "Title #{ref}", "speakers" => ["Host", "Guest"]})
  end

  defp export(entries),
    do: %{"version" => 1, "project" => "ep4", "clips" => entries, "skipped" => []}

  defp upload!(w, bytes, name \\ "clip.mp4"),
    do: stored_file!(w.project, bytes, name, "video/mp4")

  defp propose(w, entries),
    do: Pairing.propose(w.scope, w.profile.id, export(entries), w.approver.id)

  defp match_of({:ok, %{entries: entries}}, ref),
    do: Enum.find(entries, &(&1.external_ref == ref)).match

  defp clips(w), do: Repo.all(from(c in Clip, where: c.profile_id == ^w.profile.id))

  describe "proposing matches" do
    test "one exact match is proposed, with the file's id, name and size", %{w: w} do
      bytes = "exactly these bytes #{unique()}"
      file = upload!(w, bytes, "my-upload.mp4")

      assert {:one, found} = match_of(propose(w, [export_entry("ep4/a", bytes)]), "ep4/a")
      assert found.id == file.id
      assert found.name == file.name
      assert found.byte_size == byte_size(bytes)
      assert found.content_hash == sha(bytes)
    end

    test "no uploaded file with those bytes reads :none", %{w: w} do
      upload!(w, "something else #{unique()}")
      assert :none = match_of(propose(w, [export_entry("ep4/a", "never uploaded")]), "ep4/a")
    end

    test "a file is never matched by name: the same name with other bytes is no match", %{w: w} do
      upload!(w, "other bytes #{unique()}", "01_ep4-a.mp4")
      assert :none = match_of(propose(w, [export_entry("ep4/a", "the real bytes")]), "ep4/a")
    end

    test "a hash match with a different size is no match (changed media)", %{w: w} do
      bytes = "sized bytes #{unique()}"
      upload!(w, bytes)
      entry = export_entry("ep4/a", bytes) |> Map.put("size_bytes", byte_size(bytes) + 1)
      assert :none = match_of(propose(w, [entry]), "ep4/a")
    end

    test "the same bytes in another project are invisible", %{w: w} do
      bytes = "foreign bytes #{unique()}"
      stored_file!(project!(w.org_id), bytes, "clip.mp4", "video/mp4")
      stored_file!(project!(w.other_org_id), bytes, "clip.mp4", "video/mp4")
      assert :none = match_of(propose(w, [export_entry("ep4/a", bytes)]), "ep4/a")
    end

    test "a deleted file is not a candidate", %{w: w} do
      bytes = "deleted bytes #{unique()}"
      file = upload!(w, bytes)

      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      assert :none = match_of(propose(w, [export_entry("ep4/a", bytes)]), "ep4/a")
    end

    test "a file whose upload was never finalized is not a candidate, though hash and size match",
         %{
           w: w
         } do
      bytes = "unfinished upload #{unique()}"
      file = upload!(w, bytes)

      # A started-and-never-completed upload: the row has the hash and size, but nothing is stored
      # under it (`Files.finalized_upload?/1` is false without a storage key). An ordinary
      # reservation has no hash and is excluded by the hash predicate anyway; this row is not.
      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
        set: [storage_key: ""]
      )

      refute Platform.Files.finalized_upload?(Repo.get!(Platform.Files.File, file.id))
      assert :none = match_of(propose(w, [export_entry("ep4/a", bytes)]), "ep4/a")
    end

    test "a plain unfinished reservation (no hash yet) is not a candidate", %{w: w} do
      bytes = "reservation #{unique()}"
      file = upload!(w, bytes)

      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
        set: [content_hash: nil, ingest_status: "pending"]
      )

      assert :none = match_of(propose(w, [export_entry("ep4/a", bytes)]), "ep4/a")
    end

    test "a file that is not a video is not a candidate", %{w: w} do
      bytes = "text bytes #{unique()}"
      stored_file!(w.project, bytes, "notes.txt", "text/plain")
      assert :none = match_of(propose(w, [export_entry("ep4/a", bytes)]), "ep4/a")
    end

    # DEFENSIVE, not a state normal uploads can reach: the unique (content_hash, project_id)
    # index forbids two rows with the same bytes in one project. The index is dropped inside
    # this test's sandbox transaction (the DDL rolls back) only to exercise the code path, so
    # that a future change to the index cannot silently make `:many` wrong.
    test "defensive: two files with the same bytes (index dropped) need a choice", %{w: w} do
      bytes = "twin bytes #{unique()}"
      first = upload!(w, bytes, "a.mp4")

      # The unique (content_hash, project_id) index normally makes this impossible; drop it for
      # this test only (the sandbox transaction rolls the DDL back) to prove the code path.
      Repo.query!("DROP INDEX IF EXISTS platform_files_content_hash_project_id_index")

      {:ok, second} =
        Platform.Files.create_file(%{
          project_id: w.project.id,
          name: "b.mp4",
          original_filename: "b.mp4",
          content_type: "video/mp4",
          byte_size: byte_size(bytes),
          storage_key: "files/#{w.project.id}/#{unique()}/b.mp4",
          content_hash: sha(bytes)
        })

      assert {:many, files} = match_of(propose(w, [export_entry("ep4/a", bytes)]), "ep4/a")
      assert Enum.sort(Enum.map(files, & &1.id)) == Enum.sort([first.id, second.id])
    end

    test "two entries with identical bytes are flagged as sharing one file", %{w: w} do
      bytes = "shared bytes #{unique()}"
      file = upload!(w, bytes)

      {:ok, %{entries: [a, b]}} =
        propose(w, [export_entry("ep4/a", bytes), export_entry("ep4/b", bytes)])

      assert {:one, %{id: id}} = a.match
      assert id == file.id
      assert a.shared_with == ["ep4/b"]
      assert b.shared_with == ["ep4/a"]
    end

    test "an entry with no usable hash or size is invalid and matches nothing", %{w: w} do
      bytes = "valid #{unique()}"
      upload!(w, bytes)

      entries = [
        export_entry("ep4/no-hash", bytes) |> Map.delete("sha256"),
        export_entry("ep4/short-hash", bytes) |> Map.put("sha256", "abc"),
        export_entry("ep4/bad-size", bytes) |> Map.put("size_bytes", "12"),
        Map.delete(export_entry("x", bytes), "external_ref")
      ]

      {:ok, %{entries: result}} = propose(w, entries)

      assert Enum.map(result, & &1.match) ==
               [
                 {:invalid, :bad_hash},
                 {:invalid, :bad_hash},
                 {:invalid, :bad_size},
                 {:invalid, :bad_ref}
               ]
    end

    test "an upper-case hash still matches (the exporter writes lower case; do not depend on it)",
         %{
           w: w
         } do
      bytes = "case bytes #{unique()}"
      upload!(w, bytes)
      entry = export_entry("ep4/a", bytes) |> Map.update!("sha256", &String.upcase/1)
      assert {:one, _} = match_of(propose(w, [entry]), "ep4/a")
    end

    test "an export that is not a list of clips is refused", %{w: w} do
      for bad <- [%{}, %{"clips" => []}, %{"clips" => "x"}, "x", nil] do
        assert {:error, :invalid_export} =
                 Pairing.propose(w.scope, w.profile.id, bad, w.approver.id)
      end
    end
  end

  describe "who may ask" do
    test "Studio off, a non-approver, another org and a bad project are refused with intake's reasons",
         %{w: w} do
      e = export_entry("ep4/a", "x")
      member = member!(user!(), w.org_id)

      assert {:error, reason} = Pairing.propose(w.scope, w.profile.id, export([e]), member.id)
      assert reason in [:not_an_approver, :approver_no_access]

      assert {:error, :not_found} =
               Pairing.propose(
                 {:tenant, w.other_org_id},
                 w.profile.id,
                 export([e]),
                 w.outsider.id
               )

      Repo.update_all(from(p in Platform.Social.Profile, where: p.id == ^w.profile.id),
        set: [project_id: nil]
      )

      assert {:error, :studio_needs_project} =
               Pairing.propose(w.scope, w.profile.id, export([e]), w.approver.id)

      {:ok, off} = Studio.set_enabled(w.org_id, w.profile.id, w.approver.id, false)
      assert off.studio_enabled == false

      assert {:error, :studio_disabled} =
               Pairing.propose(w.scope, w.profile.id, export([e]), w.approver.id)
    end
  end

  describe "refs in the export" do
    test "an entry with no usable ref is reported as invalid by position, never dropped", %{w: w} do
      bytes = "ref test #{unique()}"
      file = upload!(w, bytes)
      good = export_entry("ep4/good", bytes)
      missing = Map.delete(export_entry("x", bytes), "external_ref")
      blank = Map.put(export_entry("x", bytes), "external_ref", "   ")

      assert {:ok, %{manifest: %{"clips" => [%{"external_ref" => "ep4/good"}]}} = result} =
               Pairing.build_manifest(
                 w.scope,
                 w.profile.id,
                 export([good, missing, blank]),
                 %{"ep4/good" => file.id},
                 w.approver.id
               )

      assert result.invalid == [{1, :bad_ref}, {2, :bad_ref}]
      assert result.unresolved == [] and result.rejected == []
    end

    test "a ref repeated in the export, whitespace variants included, refuses the whole call", %{
      w: w
    } do
      bytes = "dup test #{unique()}"
      file = upload!(w, bytes)
      entries = [export_entry("ep4/a", bytes), export_entry(" ep4/a ", bytes)]

      assert {:error, :duplicate_external_ref} = propose(w, entries)

      assert {:error, :duplicate_external_ref} =
               Pairing.build_manifest(
                 w.scope,
                 w.profile.id,
                 export(entries),
                 %{"ep4/a" => file.id},
                 w.approver.id
               )
    end
  end

  describe "file read permission" do
    defp deny_files_read!(w) do
      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, w.approver.id},
          permission: "files.read",
          resource: {:project, w.profile.project_id}
        })
    end

    test "a files.read deny on the project refuses propose and build while social.use still holds",
         %{w: w} do
      bytes = "no file access #{unique()}"
      file = upload!(w, bytes)
      e = export_entry("ep4/a", bytes)
      deny_files_read!(w)

      # social.use is still allowed on the project: this is the files.read deny alone
      assert :ok = Studio.authorize_studio_actor(w.profile, w.approver.id)

      assert {:error, :no_file_access} = propose(w, [e])

      assert {:error, :no_file_access} =
               Pairing.build_manifest(
                 w.scope,
                 w.profile.id,
                 export([e]),
                 %{"ep4/a" => file.id},
                 w.approver.id
               )
    end

    test "a deny on ANOTHER project does not refuse", %{w: w} do
      bytes = "other deny #{unique()}"
      upload!(w, bytes)

      {:ok, _} =
        Platform.Access.Grants.deny(%{
          principal: {:user, w.approver.id},
          permission: "files.read",
          resource: {:project, project!(w.org_id).id}
        })

      assert {:one, _} = match_of(propose(w, [export_entry("ep4/a", bytes)]), "ep4/a")
    end
  end

  describe "turning choices into an intake manifest" do
    test "a chosen file becomes an intake entry with the expected hash and size", %{w: w} do
      bytes = "build bytes #{unique()}"
      file = upload!(w, bytes)
      e = export_entry("ep4/a", bytes)

      assert {:ok, %{manifest: %{"clips" => [clip]}, unresolved: [], rejected: []}} =
               Pairing.build_manifest(
                 w.scope,
                 w.profile.id,
                 export([e]),
                 %{"ep4/a" => file.id},
                 w.approver.id
               )

      assert clip["external_ref"] == "ep4/a"
      assert clip["file_id"] == file.id
      assert clip["sha256"] == sha(bytes)
      assert clip["size_bytes"] == byte_size(bytes)
      assert clip["title"] == "Title ep4/a"
      assert clip["speaker"] == "Host, Guest"
      assert clip["duration_s"] == 31.5
      assert clip["approval_claim"]["approved"] == false
      refute Map.has_key?(clip, "files")
    end

    test "an entry with no choice is unresolved, not guessed", %{w: w} do
      bytes = "unchosen #{unique()}"
      upload!(w, bytes)

      assert {:ok, %{manifest: %{"clips" => []}, unresolved: ["ep4/a"], rejected: []}} =
               Pairing.build_manifest(
                 w.scope,
                 w.profile.id,
                 export([export_entry("ep4/a", bytes)]),
                 %{},
                 w.approver.id
               )
    end

    test "a choice that is not a current candidate is rejected for that entry alone", %{w: w} do
      good_bytes = "good #{unique()}"
      good = upload!(w, good_bytes)
      other = upload!(w, "unrelated #{unique()}")

      entries = [export_entry("ep4/good", good_bytes), export_entry("ep4/bad", "bad bytes")]
      choices = %{"ep4/good" => good.id, "ep4/bad" => other.id}

      assert {:ok,
              %{manifest: %{"clips" => [%{"external_ref" => "ep4/good"}]}, rejected: rejected}} =
               Pairing.build_manifest(
                 w.scope,
                 w.profile.id,
                 export(entries),
                 choices,
                 w.approver.id
               )

      assert rejected == [{"ep4/bad", :not_a_candidate}]
    end

    test "a file changed after it was proposed is rejected when the manifest is built", %{w: w} do
      bytes = "changing #{unique()}"
      file = upload!(w, bytes)
      e = export_entry("ep4/a", bytes)
      assert {:one, %{id: id}} = match_of(propose(w, [e]), "ep4/a")

      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
        set: [content_hash: sha("replaced")]
      )

      assert {:ok, %{manifest: %{"clips" => []}, rejected: [{"ep4/a", :not_a_candidate}]}} =
               Pairing.build_manifest(
                 w.scope,
                 w.profile.id,
                 export([e]),
                 %{"ep4/a" => id},
                 w.approver.id
               )
    end

    test "a file that stopped being a finalized upload after proposing is rejected when building",
         %{
           w: w
         } do
      bytes = "became unfinished #{unique()}"
      file = upload!(w, bytes)
      e = export_entry("ep4/a", bytes)
      assert {:one, %{id: id}} = match_of(propose(w, [e]), "ep4/a")

      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
        set: [storage_key: ""]
      )

      assert {:ok, %{manifest: %{"clips" => []}, rejected: [{"ep4/a", :not_a_candidate}]}} =
               Pairing.build_manifest(
                 w.scope,
                 w.profile.id,
                 export([e]),
                 %{"ep4/a" => id},
                 w.approver.id
               )
    end

    test "a foreign project's file cannot be chosen", %{w: w} do
      bytes = "foreign choice #{unique()}"
      foreign = stored_file!(project!(w.org_id), bytes, "clip.mp4", "video/mp4")

      assert {:ok, %{rejected: [{"ep4/a", :not_a_candidate}]}} =
               Pairing.build_manifest(
                 w.scope,
                 w.profile.id,
                 export([export_entry("ep4/a", bytes)]),
                 %{"ep4/a" => foreign.id},
                 w.approver.id
               )
    end

    test "a choice naming an entry that is not in the export is rejected", %{w: w} do
      file = upload!(w, "orphan #{unique()}")

      assert {:ok, %{rejected: [{"ep4/missing", :unknown_ref}]}} =
               Pairing.build_manifest(
                 w.scope,
                 w.profile.id,
                 export([export_entry("ep4/a", "x")]),
                 %{"ep4/missing" => file.id},
                 w.approver.id
               )
    end
  end

  describe "a real export (fixtures/clip_export_local_mode, see PROVENANCE.md)" do
    @fixture Path.expand("../../fixtures/clip_export_local_mode", __DIR__)

    defp real_export, do: @fixture |> Path.join("export.json") |> File.read!() |> Jason.decode!()
    defp real_video(name), do: @fixture |> Path.join("videos/#{name}") |> File.read!()

    test "the actual exporter output pairs with its videos, imports, and replays", %{w: w} do
      export = real_export()
      one = upload!(w, real_video("01_Synthetic-clip-one.mp4"))
      two = upload!(w, real_video("02_Synthetic-clip-two.mp4"))

      assert {:ok, %{entries: [first, second]}} =
               Pairing.propose(w.scope, w.profile.id, export, w.approver.id)

      assert first.external_ref == "synthetic-ep/0000000001"
      assert {:one, %{id: id_one}} = first.match
      assert {:one, %{id: id_two}} = second.match
      assert {id_one, id_two} == {one.id, two.id}
      assert first.shared_with == [] and second.shared_with == []

      choices = %{first.external_ref => id_one, second.external_ref => id_two}

      assert {:ok, %{manifest: manifest, unresolved: [], rejected: []}} =
               Pairing.build_manifest(w.scope, w.profile.id, export, choices, w.approver.id)

      assert {:ok, %{clips: [%{status: :created}, %{status: :created}]}} =
               Intake.import_manifest(w.scope, w.profile.id, manifest, w.approver.id)

      by_ref = Map.new(clips(w), &{&1.external_ref, &1})
      one_clip = by_ref["synthetic-ep/0000000001"]
      two_clip = by_ref["synthetic-ep/0000000002"]

      # local mode: no title, and every clip lands pending whatever the claim says
      assert one_clip.title == nil and two_clip.title == nil
      assert one_clip.flow == "studio" and two_clip.flow == "studio"
      assert one_clip.review_status == "pending" and two_clip.review_status == "pending"
      assert one_clip.duration_s == 30.5 and two_clip.duration_s == 35.25

      # the approved clip's claim is stored as a claim, with no approver named
      assert two_clip.import_claim["approval_claim"]["approved"] == true
      assert two_clip.import_claim["approval_claim"]["approver_recorded"] == false
      assert one_clip.import_claim["approval_claim"]["approved"] == false

      # the clip with no rendered file never appears
      refute Map.has_key?(by_ref, "synthetic-ep/0000000003")

      assert {:ok, %{clips: [%{status: :exists}, %{status: :exists}]}} =
               Intake.import_manifest(w.scope, w.profile.id, manifest, w.approver.id)
    end

    test "with no upload, every real entry reads :none", %{w: w} do
      assert {:ok, %{entries: entries}} =
               Pairing.propose(w.scope, w.profile.id, real_export(), w.approver.id)

      assert Enum.map(entries, & &1.match) == [:none, :none]
    end

    test "the fixture's hashes and sizes are those of its videos", _ctx do
      for entry <- real_export()["clips"] do
        name = entry["files"]["captioned"]
        bytes = real_video(name)
        assert entry["sha256"] == sha(bytes)
        assert entry["size_bytes"] == byte_size(bytes)
      end
    end
  end

  describe "exporter, pairing and intake together" do
    test "a local-mode export (no title) pairs and imports, and a replay returns :exists", %{w: w} do
      bytes_a = "episode clip a #{unique()}"
      bytes_b = "episode clip b #{unique()}"
      a = upload!(w, bytes_a)
      b = upload!(w, bytes_b)

      export =
        export([
          export_entry("ep4/a", bytes_a, local?: true),
          export_entry("ep4/b", bytes_b, local?: true)
        ])

      assert {:ok, %{entries: [%{match: {:one, fa}}, %{match: {:one, fb}}]}} =
               Pairing.propose(w.scope, w.profile.id, export, w.approver.id)

      assert {fa.id, fb.id} == {a.id, b.id}

      choices = %{"ep4/a" => fa.id, "ep4/b" => fb.id}

      assert {:ok, %{manifest: manifest}} =
               Pairing.build_manifest(w.scope, w.profile.id, export, choices, w.approver.id)

      assert {:ok, %{clips: [%{status: :created}, %{status: :created}]}} =
               Intake.import_manifest(w.scope, w.profile.id, manifest, w.approver.id)

      assert Enum.map(clips(w), & &1.title) == [nil, nil]
      assert Enum.all?(clips(w), &(&1.flow == "studio" and &1.review_status == "pending"))

      assert {:ok, %{clips: [%{status: :exists}, %{status: :exists}]}} =
               Intake.import_manifest(w.scope, w.profile.id, manifest, w.approver.id)
    end

    test "media changed between pairing and import is refused at import, nothing is written", %{
      w: w
    } do
      bytes = "will change #{unique()}"
      file = upload!(w, bytes)
      e = export_entry("ep4/a", bytes)

      {:ok, %{manifest: manifest}} =
        Pairing.build_manifest(
          w.scope,
          w.profile.id,
          export([e]),
          %{"ep4/a" => file.id},
          w.approver.id
        )

      Repo.update_all(from(f in Platform.Files.File, where: f.id == ^file.id),
        set: [content_hash: sha("swapped"), byte_size: 3]
      )

      assert {:ok, %{clips: [%{status: {:error, :file_changed}, clip_id: nil}]}} =
               Intake.import_manifest(w.scope, w.profile.id, manifest, w.approver.id)

      assert clips(w) == []
    end

    test "a matching pairing does not make a replay with another file acceptable", %{w: w} do
      bytes = "replay #{unique()}"
      file = upload!(w, bytes)
      e = export_entry("ep4/a", bytes)

      {:ok, %{manifest: manifest}} =
        Pairing.build_manifest(
          w.scope,
          w.profile.id,
          export([e]),
          %{"ep4/a" => file.id},
          w.approver.id
        )

      assert {:ok, %{clips: [%{status: :created}]}} =
               Intake.import_manifest(w.scope, w.profile.id, manifest, w.approver.id)

      other = upload!(w, "other file #{unique()}")
      [entry] = manifest["clips"]
      moved = %{"clips" => [Map.put(entry, "file_id", other.id)]}

      assert {:ok, %{clips: [%{status: {:error, reason}}]}} =
               Intake.import_manifest(w.scope, w.profile.id, moved, w.approver.id)

      assert reason == :external_ref_conflict
      assert length(clips(w)) == 1
    end
  end
end
