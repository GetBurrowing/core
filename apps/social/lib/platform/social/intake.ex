defmodule Platform.Social.Intake do
  @moduledoc """
  Social Studio slice C: turns a manifest of
  externally rendered clips into Studio clip records.

  The manifest is data a person hands over; nothing in it is a decision.
  Intake never ingests bytes: each entry names a `file_id` that is already a
  live video in the profile's project (`AgentDrafts.check_clip_file/2`), and
  an entry whose file is not there fails alone while the others import.

      %{"clips" => [
        %{"external_ref" => "ep4/d7952b11ee",   # required, stable per clip, at most 200 chars
          "file_id" => "…",                      # required, a video in the profile's project
          "title" => …, "caption" => …, "speaker" => …, "episode_code" => …,
          "platforms" => ["tiktok"], "duration_s" => 31.5, "width" => 1080, "height" => 1920,
          "approval_claim" => %{…}}              # stored as a claim, never applied
      ]}

  ## What an imported clip is

  Written in one transaction per clip, with its first render row: `flow`
  `studio`, `origin` `external`, `review_status` `pending`, rev 1,
  `reviewed_by_user_id` nil. The manifest's approval status lives only in
  `import_claim["approval_claim"]`. Nothing here approves, schedules, posts or
  contacts anyone, and no guest data is read or stored.

  ## Order of checks

  Once, before any clip: scoped load of the profile (another org reads `:not_found`,
  before any ref is looked up, so a replay cannot expose another profile's clips),
  `studio_enabled`, the caller (a live human passing `Social.approver_check/3`; an
  agent is `:not_a_human`), then `Studio.authorize_studio_actor/2` (the profile's live
  same-org project, the module lock, and `social.use` on that project), then the manifest.

  Then, for each clip, in its own transaction: the profile row is locked `FOR SHARE`
  (`Social.lock_profile/3`, the same lock `Studio.create_post/4` takes, so
  `Social.delete_profile/2` waits for an import and an import waits for it), and the
  decisions are made again on the row read under that lock, in the same order:
  `studio_enabled`, `Social.approver_check/3`, `Studio.authorize_studio_actor/2`. A
  preflight check does not stand in for them: an approver removed or archived while the
  import waited for the row is refused here, before any ref is looked up, so neither a
  create nor a replay (which would return an existing clip id) happens. A profile deleted
  meanwhile reads `:not_found` for that clip. Only then the per-ref lock below.
  Lock order: profile row first, then the ref.

  `platforms` is checked once, against the profile's live accounts, and is not authoritative:
  a clip stores platform names only (no account id), so no account row is locked here, and
  nothing sends from a clip. Slice B re-checks the account itself, under the full lock, when a
  render is accepted into a post.

  ## Replay

  `external_ref` is unique per profile. A transaction-scoped advisory lock on
  `(profile, ref)` serialises two imports of one ref (an aborted transaction
  from a unique violation is never relied on); the unique index is the backstop.

    * same ref, same payload: `:exists`, the clip untouched (even if it has been
      reviewed since);
    * same ref, different file or payload: `{:error, :external_ref_conflict}`, nothing
      written. A reviewed clip is never overwritten.

  "Same payload" is a SHA-256 digest of the imported fields, kept in
  `import_claim["payload_sha256"]`.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, ClipLook, ClipVersions, Profile, Studio}

  @max_clips 100
  @max_ref 200
  @payload_keys ~w(file_id title caption speaker episode_code platforms duration_s width height
                   approval_claim)

  @type entry_result :: %{
          external_ref: String.t() | nil,
          status: :created | :exists | {:error, term()},
          clip_id: Ecto.UUID.t() | nil
        }

  @doc """
  Imports `manifest` into `profile_id` as `user_id`. Returns
  `{:ok, %{clips: [entry_result]}}` in manifest order, or a refusal of the whole
  call: `:not_found`, `:studio_disabled`, a `Social.approver_refusal()`,
  `:studio_needs_project`, `:no_social_access`, `:invalid_manifest`, or
  `:duplicate_external_ref` (nothing is written in any of these). A clip whose profile
  changed or was deleted between those checks and its own transaction reports the same
  refusal for that clip alone.
  """
  @spec import_manifest(Social.scope(), term(), term(), term()) ::
          {:ok, %{clips: [entry_result()]}} | {:error, term()}
  def import_manifest(scope, profile_id, manifest, user_id) do
    with %Profile{} = profile <- Social.get_profile(scope, profile_id) || {:error, :not_found},
         :ok <- require_enabled(profile),
         :ok <- Social.approver_check(profile.org_id, profile, user_id),
         :ok <- Studio.authorize_studio_actor(profile, user_id),
         {:ok, entries} <- parse(manifest),
         :ok <- distinct_refs(entries) do
      {:ok, %{clips: Enum.map(entries, &import_entry(profile, user_id, &1))}}
    end
  end

  # ── The manifest ─────────────────────────────────────────────────────

  defp parse(manifest) when is_map(manifest) do
    case Map.get(stringify(manifest), "clips") do
      list when is_list(list) and list != [] and length(list) <= @max_clips ->
        if Enum.all?(list, &is_map/1),
          do: {:ok, Enum.map(list, &stringify/1)},
          else: {:error, :invalid_manifest}

      _ ->
        {:error, :invalid_manifest}
    end
  end

  defp parse(_), do: {:error, :invalid_manifest}

  defp distinct_refs(entries) do
    refs = for e <- entries, {:ok, ref} <- [ref(e)], do: ref
    if length(refs) == length(Enum.uniq(refs)), do: :ok, else: {:error, :duplicate_external_ref}
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp ref(%{"external_ref" => ref}) when is_binary(ref) do
    ref = String.trim(ref)

    if ref != "" and String.length(ref) <= @max_ref,
      do: {:ok, ref},
      else: {:error, :invalid_external_ref}
  end

  defp ref(_), do: {:error, :invalid_external_ref}

  # ── One clip ─────────────────────────────────────────────────────────

  defp import_entry(profile, user_id, entry) do
    case ref(entry) do
      {:ok, ref} ->
        profile |> import_clip(user_id, ref, entry) |> result(ref)

      {:error, reason} ->
        %{external_ref: nil, status: {:error, reason}, clip_id: nil}
    end
  end

  defp result({:ok, status, %Clip{id: id}}, ref),
    do: %{external_ref: ref, status: status, clip_id: id}

  defp result({:error, reason}, ref),
    do: %{external_ref: ref, status: {:error, reason}, clip_id: nil}

  defp import_clip(profile, user_id, ref, entry) do
    payload = payload(entry)
    digest = digest(payload)

    Repo.transaction(fn ->
      # Profile row first (shared with Studio post creation; excludes a deletion), then the
      # decisions again on the row as it is now, then the narrower per-ref lock.
      locked =
        Social.lock_profile(profile.org_id, profile.id, :share) || Repo.rollback(:not_found)

      with :ok <- require_enabled(locked),
           :ok <- Social.approver_check(locked.org_id, locked, user_id),
           :ok <- Studio.authorize_studio_actor(locked, user_id) do
        lock!(locked, ref)

        case existing(locked, ref) do
          %Clip{} = clip -> replay(clip, digest)
          nil -> create(locked, ref, entry, payload, digest)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {status, clip}} -> {:ok, status, clip}
      {:error, %Changeset{}} -> {:error, :invalid_clip}
      {:error, reason} -> {:error, reason}
    end
  end

  # Same payload: the existing clip, untouched. Anything else is a conflict.
  defp replay(clip, digest) do
    if get_in(clip.import_claim || %{}, ["payload_sha256"]) == digest,
      do: {:exists, clip},
      else: Repo.rollback(:external_ref_conflict)
  end

  defp create(profile, ref, entry, payload, digest) do
    with {:ok, file} <- AgentDrafts.check_clip_file(entry["file_id"], profile),
         :ok <- AgentDrafts.check_title(entry),
         {:ok, platforms} <- AgentDrafts.check_platforms(entry["platforms"], profile) do
      fields =
        entry
        |> Map.take(~w(title caption speaker episode_code))
        |> Map.merge(AgentDrafts.clip_file_meta(file, entry))
        |> Map.merge(%{
          "source_label" => "external",
          "platforms" => platforms,
          "render_file_id" => file.id,
          "look" => ClipLook.effective(profile.show_look)
        })

      claim = %{"approval_claim" => payload["approval_claim"], "payload_sha256" => digest}

      clip =
        %Clip{profile_id: profile.id, flow: "studio", external_ref: ref, import_claim: claim}
        |> Clip.submit_changeset(fields)
        |> Changeset.unique_constraint(:external_ref,
          name: :social_clips_profile_external_ref_index
        )
        |> Repo.insert()
        |> case do
          {:ok, clip} -> clip
          {:error, changeset} -> Repo.rollback(rollback_reason(changeset))
        end

      ClipVersions.append!(clip.id, file, %{}, %{
        headline: clip.title,
        caption: clip.caption,
        source: %{"origin" => "external", "source_label" => clip.source_label},
        provenance: %{"kind" => "studio_intake"},
        completion_key: "studio_intake:" <> clip.id
      })

      {:created, Repo.get!(Clip, clip.id)}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp rollback_reason(%Changeset{errors: errors} = changeset) do
    if Keyword.has_key?(errors, :external_ref), do: :external_ref_conflict, else: changeset
  end

  defp existing(%Profile{id: profile_id}, ref) do
    Repo.one(from(c in Clip, where: c.profile_id == ^profile_id and c.external_ref == ^ref))
  end

  # Serialises two imports of one ref until the first commits, so the second reads
  # the first's row instead of tripping the unique index inside an open transaction.
  defp lock!(%Profile{id: profile_id}, ref) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "social:clip_import:#{profile_id}:#{ref}"
    ])
  end

  # The fields an entry is judged equivalent on. Platforms are a set, and omitted, nil
  # and an empty list are the same entry (all import as no platforms); the claim is
  # compared as given, since a changed claim is a changed manifest.
  defp payload(entry) do
    entry
    |> Map.take(@payload_keys)
    |> Map.update("platforms", [], fn
      nil -> []
      list when is_list(list) -> list |> Enum.uniq() |> Enum.sort()
      other -> other
    end)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp digest(payload) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(payload, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp require_enabled(%Profile{} = profile),
    do: if(Studio.enabled?(profile), do: :ok, else: {:error, :studio_disabled})
end
