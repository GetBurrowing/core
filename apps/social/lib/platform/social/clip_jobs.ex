defmodule Platform.Social.ClipJobs do
  @moduledoc """
  Clip Studio's job list (task 01a16661-e234, Clip Studio 1/9): the context
  behind `Platform.Social.ClipJob`. It lives in its own file so
  `Platform.Social` (`social.ex`) stays untouched; it calls Social's public
  functions only.

  ## Human side

  `enqueue_new_clip/4`, `enqueue_rerender/4` and `save_show_default/4` are
  for Burrow's LiveViews, never agent tools. Each takes the profile's org
  and a USER id that must pass `Platform.Social.approver_check/3` (an agent
  id is `{:error, :not_a_human}`), and looks the profile or clip up through
  the org scope (another org's is `{:error, :not_found}`, like a missing id).

  A `new_clip` job's clip is created `candidate` and stays so until the
  runner completes: never `rendering`, because `Platform.Social.RenderQueue`
  re-enqueues every `rendering` clip into Burrow's own ffmpeg renderer at
  boot. A re-render's requested look and trim live in the job payload only;
  the clip row keeps describing its rendered rev until complete.

  ## Agent side

  `list_jobs/3`, `claim/3`, `progress/5`, `complete/4` and `fail/5` take the
  agent's home-org scope; every job lookup joins `social_profiles.org_id`
  against `Platform.Social.visible_orgs/1`, so another org's job is
  `{:error, :not_found}`, identical to a missing one. `claim/3` is ONE
  conditional update (`WHERE status = 'queued'`): exactly one claimer wins,
  the rest get `{:error, :already_claimed}`. Progress, complete and fail are
  for the claimer only (`{:error, :not_claimer}`) and an open job only
  (`{:error, :job_closed}`).

  `complete/4` takes only the `social_clip_submit` arguments (`file_id`,
  `title`, `caption`, `speaker`, `episode_code`, `platforms`, `duration_s`,
  `width`, `height`, `source_label`); the file is checked as
  `Platform.Social.AgentDrafts.check_clip_file/2` checks it. A completed
  clip goes back to review as pending through
  `Platform.Social.Clip.review_changeset/2`; no agent ever writes a review
  field. A re-render bumps `rev`, keeps the clip id and adds a
  `Platform.Social.ClipRender` row; earlier render rows are never touched.

  ## Privacy

  Under the clip tool's `[privacy] mode = "local"` the runner sends no
  title, caption, speaker or episode code; every payload and result field
  tolerates nil.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social

  alias Platform.Social.{
    AgentDrafts,
    Clip,
    ClipJob,
    ClipLook,
    ClipVersions,
    Profile,
    ClipClosingVideo
  }

  @base_profile "how-to-computer"
  @result_keys ~w(file_id title caption speaker episode_code platforms duration_s width height
                  source_label actual_in_s actual_out_s caption_fixes candidate_id alternate_id headline_applied)
  @meta_keys ~w(title caption speaker episode_code)

  @type error :: {:error, atom() | tuple() | Ecto.Changeset.t()}

  @doc "The keys `complete/4` takes from a result; everything else is dropped."
  @spec result_keys() :: [String.t()]
  def result_keys, do: @result_keys

  @doc "The clip-tool user profile a profile's looks live in: `burrow-<full profile id>`."
  @spec clip_user_profile(Profile.t() | Ecto.UUID.t()) :: String.t()
  def clip_user_profile(%Profile{id: id}), do: clip_user_profile(id)
  def clip_user_profile(id) when is_binary(id), do: "burrow-" <> id

  @doc """
  Internal discovery path: queues a source episode without a human identity or
  clip/trim. Both ids are re-read under a transaction; source eligibility is
  checked against the persisted pipeline and tenant project. Never exposed as
  a tool or used to bypass the manual enqueue approver checks.
  """
  def enqueue_episode(pipeline_id, source_file_id) do
    Repo.transaction(fn ->
      pipeline = Repo.get(Platform.Social.EpisodePipeline, pipeline_id)
      profile = pipeline && ClipClosingVideo.lock_profile(pipeline.profile_id)

      source = Platform.Social.ClipClosingVideo.lock_file(source_file_id)

      project = profile && Repo.get(Platform.Tasks.Project, profile.project_id)

      unless pipeline && profile && source && project && project.org_id == profile.org_id &&
               is_nil(project.archived_at) &&
               Platform.Social.EpisodeDiscovery.eligible?(source, profile, pipeline) do
        Repo.rollback(:ineligible_episode)
      end

      payload = %{
        "kind" => "episode",
        "source_file_id" => source.id,
        "episode" => %{"source_file_id" => source.id},
        "profile_id" => profile.id,
        "project_id" => profile.project_id,
        "pipeline_id" => pipeline.id,
        "pipeline_version" => pipeline.version,
        "clip_user_profile" => clip_user_profile(profile),
        "look" => ClipLook.effective(profile.show_look),
        "closing_video" => ok_or_rollback(ClipClosingVideo.snapshot(profile))
      }

      %ClipJob{}
      |> ClipJob.enqueue_changeset(%{
        profile_id: profile.id,
        kind: "episode",
        source_file_id: source.id,
        episode_pipeline_id: pipeline.id,
        payload: payload
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:profile_id, :source_file_id, :episode_pipeline_id]
      )
      |> case do
        {:ok, _} ->
          Repo.get_by!(ClipJob,
            profile_id: profile.id,
            source_file_id: source.id,
            episode_pipeline_id: pipeline.id
          )

        {:error, error} ->
          Repo.rollback(error)
      end
    end)
    |> notify_job()
  end

  # ── Human side ───────────────────────────────────────────────────────

  @doc "Queues a typed text fix against the current immutable render, without changing playback."
  def enqueue_fix(org_id, clip_id, user_id, attrs) do
    attrs = normalize(attrs)

    with %Clip{} = found <- Social.get_clip(org_id, clip_id) || {:error, :not_found},
         {:ok, _profile} <- human_profile(org_id, found.profile_id, user_id) do
      Repo.transaction(fn ->
        clip =
          Repo.one(
            from(c in Clip, where: c.id == ^found.id and is_nil(c.removed_at), lock: "FOR UPDATE")
          )

        if is_nil(clip), do: Repo.rollback(:not_found)
        profile = ok_or_rollback(human_profile(org_id, clip.profile_id, user_id))

        base =
          ok_or_rollback(ClipVersions.get(org_id, profile.id, clip.id, attrs["base_render_id"]))

        if base.rev != clip.rev, do: Repo.rollback(:stale_version)

        unless is_binary(base.file_id) && Platform.Files.get_file(base.file_id),
          do: Repo.rollback(:version_unplayable)

        fix = ok_or_rollback(Platform.Social.ClipFixes.validate(base, attrs))
        look = ClipLook.effective(base.look)

        payload =
          payload(
            "rerender",
            profile,
            clip,
            look,
            fix["in_s"],
            fix["out_s"],
            nil,
            ClipVersions.next_rev(clip)
          )
          |> Map.merge(%{
            "base_render_id" => base.id,
            "candidate_id" => base.candidate_id,
            "alternate_id" => base.alternate_id,
            "title" => base.headline,
            "caption" => base.caption,
            "episode" => base.source || %{},
            "fix" => fix,
            "caption_fixes" => caption_fix_history(base.caption_fixes, fix["caption_fixes"])
          })
          |> maybe_headline(fix)
          |> Map.merge(%{
            "source_id" => base.source["source_file_id"] || clip.id
          })

        insert_job!(profile, clip, "rerender", payload, user_id)
      end)
    end
  end

  @doc "Queues an appearance change against an exact immutable current render."
  def enqueue_appearance(org_id, clip_id, user_id, attrs) do
    enqueue_appearance_request(org_id, clip_id, user_id, attrs, false)
  end

  defp enqueue_appearance_request(org_id, clip_id, user_id, attrs, closing_only) do
    attrs = normalize(attrs)

    with %Clip{} = found <- Social.get_clip(org_id, clip_id) || {:error, :not_found} do
      Repo.transaction(fn ->
        clip =
          Repo.one(
            from(c in Clip, where: c.id == ^found.id and is_nil(c.removed_at), lock: "FOR UPDATE")
          )

        if is_nil(clip), do: Repo.rollback(:not_found)
        profile = ok_or_rollback(human_profile(org_id, clip.profile_id, user_id))

        base =
          ok_or_rollback(ClipVersions.get(org_id, profile.id, clip.id, attrs["base_render_id"]))

        if base.rev != clip.rev, do: Repo.rollback(:stale_version)

        # human_profile/3 holds the same profile lock as default writes. Check
        # here, not just in the form visibility, against that current choice.
        if closing_only and
             ClipClosingVideo.same_ending?(base.closing_video, profile.closing_video),
           do: Repo.rollback(:closing_video_unchanged)

        if closing_only and
             (clip.review_status == "approved" or
                Repo.exists?(
                  from(p in Platform.Social.Post,
                    where:
                      p.clip_render_id == ^base.id and
                        p.status in ["approved", "scheduled", "published"]
                  )
                )),
           do: Repo.rollback(:version_approved)

        if closing_only and
             Repo.exists?(
               from(j in ClipJob,
                 where: j.clip_id == ^clip.id and j.status in ["queued", "claimed", "running"]
               )
             ),
           do: Repo.rollback(:job_in_flight)

        unless is_binary(base.file_id) && Platform.Files.get_file(base.file_id),
          do: Repo.rollback(:version_unplayable)

        requested =
          ok_or_rollback(validate_look(if(closing_only, do: %{}, else: attrs["look"] || %{})))

        look = ClipLook.effective(ClipLook.merge(base.look, requested))
        ok_or_rollback(validate_look(look))
        source = base.source || %{}
        in_s = base.actual_start_s || base.trim_in_s || base.requested_start_s
        out_s = base.actual_end_s || base.trim_out_s || base.requested_end_s

        payload =
          payload("rerender", profile, clip, look, in_s, out_s, nil, ClipVersions.next_rev(clip))
          |> Map.merge(%{
            "appearance" => true,
            "base_render_id" => base.id,
            "candidate_id" => base.candidate_id,
            "alternate_id" => base.alternate_id,
            "title" => base.headline,
            "caption" => base.caption,
            "caption_fixes" => base.caption_fixes,
            "episode" => source
          })
          # Always send an explicit style, even when it equals the show default:
          # the CLI's saved process-time style otherwise takes precedence.
          |> put_in(["clip_overrides", "mapped", "captions.style"], ClipLook.caption_style(look))

        insert_job!(profile, clip, "rerender", payload, user_id)
      end)
      |> notify_job()
    end
  end

  @doc "Apply today's closing default to the exact current unapproved version via the existing rerender path."
  def enqueue_closing_video(org_id, clip_id, user_id, attrs) do
    enqueue_appearance_request(org_id, clip_id, user_id, attrs, true)
  end

  defp maybe_headline(payload, %{"headline" => headline}),
    do: payload |> Map.put("headline", headline) |> Map.delete("fix")

  defp maybe_headline(payload, _fix), do: payload

  defp caption_fix_history(previous, nil), do: previous

  defp caption_fix_history(previous, correction) do
    edits =
      case previous do
        %{"edits" => edits} when is_list(edits) -> edits
        previous when is_map(previous) -> [previous]
        _ -> []
      end

    %{"edits" => edits ++ [correction]}
  end

  @doc """
  Queues a new clip from an episode: `attrs` has `source_url` OR
  `source_file_id` (+ optional `transcript_file_id`, both in the profile's
  project), `in_s` and `out_s` (source seconds, `0 <= in_s < out_s`) and
  an optional `title`. In one transaction: the clip (origin burrow, status
  candidate, rev 1, the profile's effective show look, trim = in/out) and
  its queued `new_clip` job.

  Returns `{:ok, %{clip: clip, job: job}}`.
  """
  @spec enqueue_new_clip(Ecto.UUID.t(), term(), term(), map()) ::
          {:ok, %{clip: Clip.t(), job: ClipJob.t()}} | error()
  def enqueue_new_clip(org_id, profile_id, user_id, attrs) do
    attrs = normalize(attrs)

    with {:ok, profile} <- human_profile(org_id, profile_id, user_id),
         {:ok, _source} <- episode_source(attrs, profile),
         :ok <- check_range(attrs["in_s"], attrs["out_s"]),
         :ok <- AgentDrafts.check_title(Map.take(attrs, ["title"])) do
      in_s = attrs["in_s"] * 1.0
      out_s = attrs["out_s"] * 1.0

      Repo.transaction(fn ->
        profile = ok_or_rollback(human_profile(org_id, profile.id, user_id))
        source = ok_or_rollback(episode_source(attrs, profile))
        look = ClipLook.effective(profile.show_look)

        clip =
          %Clip{profile_id: profile.id}
          |> Clip.changeset(Map.merge(source, %{"title" => attrs["title"]}))
          |> Changeset.put_change(:status, "candidate")
          |> Changeset.put_change(:rev, 1)
          |> Changeset.put_change(:look, look)
          |> Changeset.put_change(:trim_in_s, in_s)
          |> Changeset.put_change(:trim_out_s, out_s)
          |> Changeset.put_change(:requested_start_s, in_s)
          |> Changeset.put_change(:requested_end_s, out_s)
          |> insert_or_rollback()

        payload = payload("new_clip", profile, clip, look, in_s, out_s, nil, 1)
        job = insert_job!(profile, clip, "new_clip", payload, user_id)
        %{clip: clip, job: job}
      end)
      |> broadcast_clip()
    end
  end

  @doc """
  Queues a re-render of `clip_id` with `%{look, trim_in_s, trim_out_s}`
  (each optional; the look may be partial and is merged over the clip's
  current look, then validated with `ClipLook.validate/1`). The request
  goes in the job payload only. An open job on the clip is
  `{:error, :job_in_flight}`; a bad look is `{:error, {:invalid_look, messages}}`;
  a bad trim is `{:error, :invalid_range}`.

  Returns `{:ok, job}`.
  """
  @spec enqueue_rerender(Ecto.UUID.t(), term(), term(), map()) :: {:ok, ClipJob.t()} | error()
  def enqueue_rerender(org_id, clip_id, user_id, attrs) do
    attrs = normalize(attrs)

    with %Clip{} = found <- Social.get_clip(org_id, clip_id) || {:error, :not_found} do
      Repo.transaction(fn ->
        clip =
          Repo.one(
            from(c in Clip, where: c.id == ^found.id and is_nil(c.removed_at), lock: "FOR UPDATE")
          )

        if is_nil(clip), do: Repo.rollback(:not_found)
        base = current_base!(org_id, clip, attrs["base_render_id"])

        with {:ok, profile} <- human_profile(org_id, clip.profile_id, user_id),
             {:ok, requested} <- validate_look(attrs["look"] || %{}),
             look = ClipLook.effective(ClipLook.merge(clip.look, requested)),
             {:ok, look} <- validate_look(look),
             in_s =
               number_or(
                 attrs["trim_in_s"],
                 (base && base.actual_start_s) || clip.trim_in_s || clip.requested_start_s
               ),
             out_s =
               number_or(
                 attrs["trim_out_s"],
                 (base && base.actual_end_s) || clip.trim_out_s || clip.requested_end_s
               ),
             :ok <- check_optional_range(in_s, out_s) do
          note = if clip.review_status == "rejected", do: clip.review_note

          payload =
            payload(
              "rerender",
              profile,
              clip,
              look,
              in_s,
              out_s,
              note,
              ClipVersions.next_rev(clip)
            )
            |> pin_base(base)

          %ClipJob{}
          |> ClipJob.enqueue_changeset(%{
            profile_id: profile.id,
            clip_id: clip.id,
            kind: "rerender",
            payload: payload,
            requested_by_user_id: user_id
          })
          |> Repo.insert()
          |> case do
            {:ok, job} -> job
            {:error, changeset} -> Repo.rollback(in_flight_or(changeset))
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  defp current_base!(scope, clip, requested_id) do
    base =
      if requested_id do
        ok_or_rollback(ClipVersions.get(scope, clip.profile_id, clip.id, requested_id))
      else
        Repo.one(
          from(r in Platform.Social.ClipRender,
            where: r.clip_id == ^clip.id and r.rev == ^clip.rev and is_nil(r.removed_at)
          )
        )
      end

    if base && base.rev != clip.rev, do: Repo.rollback(:stale_version)
    base
  end

  defp pin_base(payload, nil), do: payload

  defp pin_base(payload, base) do
    Map.merge(payload, %{
      "base_render_id" => base.id,
      "candidate_id" => base.candidate_id,
      "alternate_id" => base.alternate_id,
      "caption_fixes" => base.caption_fixes,
      "episode" => base.source || payload["episode"]
    })
  end

  @doc """
  Writes `look` (validated, possibly partial) to the profile's `show_look`
  and queues a `save_default` job (no clip), in one transaction. Clips
  enqueued afterwards copy it.

  Returns `{:ok, %{profile: profile, job: job}}`.
  """
  @spec save_show_default(Ecto.UUID.t(), term(), term(), map()) ::
          {:ok, %{profile: Profile.t(), job: ClipJob.t()}} | error()
  def save_show_default(org_id, profile_id, user_id, look) do
    with {:ok, profile} <- human_profile(org_id, profile_id, user_id),
         {:ok, look} <- validate_look(look || %{}) do
      Repo.transaction(fn ->
        profile =
          profile
          |> Changeset.change(show_look: look)
          |> insert_or_rollback(:update)

        full = ClipLook.effective(look)
        caption_renderer = ok_or_rollback(Platform.Social.ClipCaptionRenderer.qualify(full))
        ok_or_rollback(Platform.Social.ClipMusic.payload(profile, full))
        delta = ClipLook.delta(full, ClipLook.default())

        payload =
          profile
          |> base_payload("save_default", nil, full, nil, nil, nil, nil)
          |> Map.merge(%{
            "look_delta" => delta,
            "clip_overrides" => ClipLook.to_clip_overrides(delta),
            "caption_renderer" => caption_renderer
          })

        job = insert_job!(profile, nil, "save_default", payload, user_id)
        %{profile: profile, job: job}
      end)
    end
  end

  defp human_profile(org_id, profile_id, user_id) do
    with %Profile{} = profile <- Social.get_profile(org_id, profile_id) || {:error, :not_found},
         :ok <- Social.approver_check(profile.org_id, profile, user_id) do
      profile =
        if Repo.in_transaction?(), do: ClipClosingVideo.lock_profile(profile.id), else: profile

      with true <- not is_nil(profile) and profile.org_id == org_id,
           :ok <- Social.approver_check(profile.org_id, profile, user_id),
           {:ok, project} <- Social.render_project(profile),
           true <- is_nil(project.archived_at) do
        {:ok, profile}
      else
        _ -> {:error, :not_found}
      end
    end
  end

  defp episode_source(attrs, profile) do
    url = present(attrs["source_url"])
    file = present(attrs["source_file_id"])
    transcript = present(attrs["transcript_file_id"])

    cond do
      url && (file || transcript) ->
        {:error, :invalid_source}

      url ->
        if http_url?(url), do: {:ok, %{"source_url" => url}}, else: {:error, :invalid_source_url}

      file ->
        if Enum.all?(
             Enum.reject([file, transcript], &is_nil/1),
             &AgentDrafts.file_in_project?(&1, profile)
           ),
           do: {:ok, %{"source_file_id" => file, "transcript_file_id" => transcript}},
           else: {:error, :source_not_in_project}

      true ->
        {:error, :invalid_source}
    end
  end

  defp http_url?(url) do
    match?(
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "",
      URI.parse(url)
    )
  end

  defp check_range(in_s, out_s)
       when is_number(in_s) and is_number(out_s) and in_s >= 0 and out_s > in_s,
       do: :ok

  defp check_range(_, _), do: {:error, :invalid_range}

  defp check_optional_range(nil, nil), do: :ok
  defp check_optional_range(in_s, nil) when is_number(in_s) and in_s >= 0, do: :ok
  defp check_optional_range(in_s, out_s), do: check_range(in_s, out_s)

  defp validate_look(look) do
    case ClipLook.validate(look) do
      {:ok, look} -> {:ok, look}
      {:error, messages} -> {:error, {:invalid_look, messages}}
    end
  end

  defp number_or(n, _default) when is_number(n), do: n * 1.0
  defp number_or(_n, default), do: default

  defp in_flight_or(%Changeset{errors: errors} = changeset) do
    if Enum.any?(errors, fn {_k, {_m, opts}} ->
         opts[:constraint_name] == "social_clip_jobs_one_open_per_clip"
       end),
       do: :job_in_flight,
       else: changeset
  end

  defp insert_job!(profile, clip, kind, payload, user_id) do
    %ClipJob{}
    |> ClipJob.enqueue_changeset(%{
      profile_id: profile.id,
      clip_id: clip && clip.id,
      kind: kind,
      payload: payload,
      requested_by_user_id: user_id
    })
    |> Repo.insert()
    |> case do
      {:ok, job} -> job
      {:error, changeset} -> Repo.rollback(in_flight_or(changeset))
    end
  end

  # ── Payload ──────────────────────────────────────────────────────────

  defp payload(
         kind,
         profile,
         clip,
         look,
         in_s,
         out_s,
         review_note,
         expected_rev,
         closing \\ :current
       ) do
    profile = ClipClosingVideo.lock_profile(profile.id)
    caption_renderer = ok_or_rollback(Platform.Social.ClipCaptionRenderer.qualify(look))

    closing =
      if closing == :current,
        do: ok_or_rollback(ClipClosingVideo.snapshot(profile)),
        else: closing

    delta = ClipLook.delta(look, ClipLook.effective(profile.show_look))
    music = ok_or_rollback(Platform.Social.ClipMusic.payload(profile, look))

    profile
    |> base_payload(kind, clip, look, in_s, out_s, review_note, expected_rev)
    |> Map.merge(%{
      "look_delta" => delta,
      "clip_overrides" => ClipLook.to_clip_overrides(delta),
      "music" => music,
      "closing_video" => closing,
      "caption_renderer" => caption_renderer
    })
  end

  defp base_payload(profile, kind, clip, look, in_s, out_s, review_note, expected_rev) do
    %{
      "kind" => kind,
      "clip_id" => clip && clip.id,
      "profile_id" => profile.id,
      "profile_name" => profile.name,
      "clip_user_profile" => clip_user_profile(profile),
      "base_profile" => @base_profile,
      "title" => clip && clip.title,
      "episode" => %{
        "source_url" => clip && clip.source_url,
        "source_file_id" => clip && clip.source_file_id,
        "transcript_file_id" => clip && clip.transcript_file_id
      },
      "in_s" => in_s,
      "out_s" => out_s,
      "look" => look,
      "review_note" => review_note,
      "expected_rev" => expected_rev
    }
  end

  # ── Agent side ───────────────────────────────────────────────────────

  @doc """
  The jobs on a profile in the agent's scope, oldest first. `filters`:
  `status`, `kind` (nil = any). Another org's profile is `{:error, :not_found}`.
  """
  @spec list_jobs(Social.scope(), term(), keyword() | map()) :: {:ok, [ClipJob.t()]} | error()
  def list_jobs(scope, profile_id, filters \\ []) do
    filters = Map.new(filters, fn {k, v} -> {to_string(k), v} end)

    case Social.get_profile(scope, profile_id) do
      %Profile{} = profile ->
        jobs =
          scope
          |> scoped_jobs()
          |> where([j], j.profile_id == ^profile.id)
          |> filter(:status, present(filters["status"]))
          |> filter(:kind, present(filters["kind"]))
          |> order_by([j], asc: j.inserted_at, asc: j.id)
          |> Repo.all()

        {:ok, jobs}

      nil ->
        {:error, :not_found}
    end
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, field, value), do: where(query, [j], field(j, ^field) == ^value)

  @doc """
  Claims a queued job for `agent_id`: one conditional update. `{:ok, job}`
  for the one claimer that wins; `{:error, :already_claimed}` for every
  other (and for a job that is no longer queued).
  """
  @spec claim(Social.scope(), term(), Ecto.UUID.t()) :: {:ok, ClipJob.t()} | error()
  def claim(scope, job_id, agent_id) do
    with {:ok, job} <- fetch_job(scope, job_id) do
      now = DateTime.utc_now()

      from(j in ClipJob, where: j.id == ^job.id and j.status == "queued", select: j)
      |> Repo.update_all(
        set: [status: "claimed", claimed_by_agent_id: agent_id, claimed_at: now, updated_at: now]
      )
      |> case do
        {1, [job]} -> notify_job({:ok, job})
        {0, _} -> {:error, :already_claimed}
      end
    end
  end

  @doc """
  The claimer reports `progress` (0..1) and an optional `eta_s` (>= 0); the
  job becomes `running`. `{:error, :invalid_progress}` for anything else.
  """
  @spec progress(Social.scope(), term(), Ecto.UUID.t(), term(), term()) ::
          {:ok, ClipJob.t()} | error()
  def progress(scope, job_id, agent_id, progress, eta_s \\ nil) do
    with :ok <- check_progress(progress, eta_s) do
      locked(scope, job_id, agent_id, fn job, _profile ->
        job
        |> ClipJob.progress_changeset(%{progress: progress * 1.0, eta_s: eta_s && round(eta_s)})
        |> insert_or_rollback(:update)
      end)
    end
  end

  defp check_progress(p, eta)
       when is_number(p) and p >= 0 and p <= 1 and (is_nil(eta) or (is_number(eta) and eta >= 0)),
       do: :ok

  defp check_progress(_, _), do: {:error, :invalid_progress}

  @doc """
  Short-lived download for the claimer of an open job. The default episode
  source and optional selected music asset are taken from durable job identity, never caller attrs.
  Re-check readiness/provenance and project ownership before minting a Files
  signed URL; do not persist or log the returned bearer URL.
  """
  @spec source_download(Social.scope(), term(), Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | error()
  def source_download(scope, job_id, agent_id, asset \\ "episode") do
    locked(scope, job_id, agent_id, fn job, profile ->
      # Same profile -> file lock order as settings/enqueue: the pinned download
      # cannot mint a URL while tenant identity or file metadata is changing.
      profile =
        if asset == "closing_video", do: ClipClosingVideo.lock_profile(profile.id), else: profile

      source =
        case asset do
          "episode" ->
            checked_episode_source!(job, profile)

          "music" ->
            music = job.payload["music"] || %{}
            unless music["enabled"] == true, do: Repo.rollback(:music_unavailable)
            ok_or_rollback(Platform.Social.ClipMusic.resolve(profile, music["file_id"]))

          "closing_video" ->
            ok_or_rollback(
              ClipClosingVideo.resolve_snapshot(profile, job.payload["closing_video"])
            )

          _ ->
            Repo.rollback(:invalid_asset)
        end

      expires_at = DateTime.add(DateTime.utc_now(), 900, :second)
      url = ok_or_rollback(Platform.Files.SignedUrl.url(source, expires_at: expires_at))

      %{
        file_id: source.id,
        project_id: profile.project_id,
        url: url,
        expires_at: expires_at,
        content_type: source.content_type,
        byte_size: source.byte_size,
        content_hash: source.content_hash,
        max_bytes: if(asset == "closing_video", do: ClipClosingVideo.max_bytes(), else: nil)
      }
    end)
  end

  defp checked_episode_source!(job, profile) do
    source = job.source_file_id && Platform.Files.get_file(job.source_file_id)

    pipeline =
      job.episode_pipeline_id &&
        Repo.get(Platform.Social.EpisodePipeline, job.episode_pipeline_id)

    project = profile.project_id && Repo.get(Platform.Tasks.Project, profile.project_id)

    unless job.kind == "episode" && source && pipeline && project &&
             project.org_id == profile.org_id && is_nil(project.archived_at) &&
             Platform.Social.EpisodeDiscovery.eligible?(source, profile, pipeline) do
      Repo.rollback(:source_unavailable)
    end

    source
  end

  @doc "Persist a content-free pick plan under the episode lock; replays return the same child ids."
  def plan_episode(scope, job_id, agent_id, picks) do
    locked(scope, job_id, agent_id, fn job, profile ->
      unless job.kind == "episode", do: Repo.rollback(:not_an_episode)
      checked_episode_source!(job, profile)
      unless is_list(picks) and length(picks) <= 100, do: Repo.rollback(:invalid_picks)

      picks =
        Enum.map(picks, fn raw ->
          pick = normalize(raw)

          unless is_binary(pick["candidate_id"]) and byte_size(pick["candidate_id"]) in 1..200 and
                   check_range(pick["in_s"], pick["out_s"]) == :ok,
                 do: Repo.rollback(:invalid_picks)

          Map.take(pick, ~w(candidate_id in_s out_s))
        end)

      unless length(Enum.uniq_by(picks, & &1["candidate_id"])) == length(picks),
        do: Repo.rollback(:invalid_picks)

      case job.payload["pick_plan"] do
        nil ->
          children =
            Enum.map(picks, fn pick ->
              source = %{"source_file_id" => job.source_file_id}

              clip =
                %Clip{profile_id: profile.id}
                |> Clip.changeset(source)
                |> Changeset.put_change(:status, "candidate")
                |> Changeset.put_change(:rev, 1)
                |> Changeset.put_change(:look, ClipLook.effective(profile.show_look))
                |> Changeset.put_change(:requested_start_s, pick["in_s"] * 1.0)
                |> Changeset.put_change(:requested_end_s, pick["out_s"] * 1.0)
                |> insert_or_rollback()

              pay =
                payload(
                  "new_clip",
                  profile,
                  clip,
                  clip.look,
                  pick["in_s"] * 1.0,
                  pick["out_s"] * 1.0,
                  nil,
                  1,
                  job.payload["closing_video"]
                )
                |> Map.merge(%{
                  "episode_job_id" => job.id,
                  "candidate_id" => pick["candidate_id"],
                  "source_id" => job.source_file_id,
                  "headline" => %{"consumer" => "episode"}
                })

              insert_job!(profile, clip, "new_clip", pay, nil)
            end)

          job
          |> Changeset.change(status: "running", progress: 0.4)
          |> Changeset.change(
            payload:
              Map.merge(job.payload, %{
                "pick_plan" => picks,
                "child_job_ids" => Enum.map(children, & &1.id)
              })
          )
          |> insert_or_rollback(:update)

          children

        ^picks ->
          episode_children(job)

        _ ->
          Repo.rollback(:pick_plan_changed)
      end
    end)
  end

  defp episode_children(job) do
    ids = job.payload["child_job_ids"] || []
    rows = Repo.all(from(j in ClipJob, where: j.id in ^ids)) |> Map.new(&{&1.id, &1})
    Enum.map(ids, &Map.fetch!(rows, &1))
  end

  @doc """
  The claimer completes the job with `result` (only `result_keys/0` are
  read). For `new_clip` and `rerender` the file must be a video in the
  profile's project; the clip (locked FOR UPDATE) becomes rendered with that
  file, the payload's look and trim, and review pending, and gains a
  `ClipRender` row (`rerender` bumps `rev`). `save_default` writes no clip.
  The job becomes done with progress 1.0.

  Returns `{:ok, %{job: job, clip: clip | nil}}`.
  """
  @spec complete(Social.scope(), term(), Ecto.UUID.t(), map()) ::
          {:ok, %{job: ClipJob.t(), clip: Clip.t() | nil}} | error()
  def complete(scope, job_id, agent_id, result) do
    result = normalize(result)
    override? = Map.has_key?(result, "closing_video")
    result = Map.take(result, @result_keys)

    locked(scope, job_id, agent_id, fn job, profile ->
      if override?, do: Repo.rollback(:closing_video_override)
      clip = complete_clip(job, profile, agent_id, result)

      result =
        if job.kind == "episode" do
          count = length(job.payload["child_job_ids"] || [])
          %{"pick_count" => count, "outcome" => if(count == 0, do: "no_picks", else: "rendered")}
        else
          result
        end

      job =
        job
        |> ClipJob.finish_changeset(:done, result)
        |> insert_or_rollback(:update)

      %{job: job, clip: clip}
    end)
    |> case do
      {:ok, %{clip: %Clip{} = clip}} = ok ->
        Social.broadcast_clip(clip)
        ok

      other ->
        other
    end
  end

  defp complete_clip(%ClipJob{kind: "episode"} = job, _profile, _agent_id, _result) do
    unless is_list(job.payload["pick_plan"]), do: Repo.rollback(:episode_not_planned)

    unless Enum.all?(episode_children(job), &(&1.status == "done")),
      do: Repo.rollback(:episode_incomplete)

    nil
  end

  defp complete_clip(%ClipJob{kind: "save_default"}, _profile, _agent_id, _result), do: nil

  defp complete_clip(%ClipJob{kind: kind} = job, profile, agent_id, result)
       when kind in ["new_clip", "rerender"] do
    if job.payload["episode_job_id"] && result["headline_applied"] != true,
      do: Repo.rollback(:headline_not_applied)

    file = ok_or_rollback(AgentDrafts.check_clip_file(result["file_id"], profile))
    ok_or_rollback(AgentDrafts.check_title(Map.take(result, ["title"])))
    platforms = ok_or_rollback(check_platforms(result, profile))

    clip =
      from(c in Clip, where: c.id == ^job.clip_id and is_nil(c.removed_at), lock: "FOR UPDATE")
      |> Repo.one()
      |> case do
        nil -> Repo.rollback(:not_found)
        clip -> clip
      end

    payload = job.payload || %{}

    if payload["base_render_id"] && payload["expected_rev"] != ClipVersions.next_rev(clip),
      do: Repo.rollback(:stale_version)

    look = payload["look"] || clip.look
    # When a closing contract is enabled, only measured TOTAL output facts are
    # accepted. Runner-reported content duration must never substitute for them.
    closing_enabled = get_in(payload, ["closing_video", "enabled"]) == true
    meta = AgentDrafts.clip_file_meta(file, if(closing_enabled, do: %{}, else: result))

    if closing_enabled and
         not (is_number(meta["duration_s"]) and meta["duration_s"] > 0 and
                is_integer(meta["width"]) and meta["width"] > 0 and is_integer(meta["height"]) and
                meta["height"] > 0),
       do: Repo.rollback(:output_measurements_unavailable)

    render_attrs =
      Map.merge(meta, %{
        "status" => "rendered",
        "render_file_id" => file.id,
        "rendered_at" => DateTime.utc_now(),
        "error" => nil
      })

    render_attrs =
      if platforms, do: Map.put(render_attrs, "platforms", platforms), else: render_attrs

    effective_result =
      if payload["fix"] || payload["headline"] || payload["appearance"],
        do:
          Map.merge(
            Map.take(payload, ~w(title caption)),
            Map.reject(result, fn {_k, v} -> is_nil(v) end)
          ),
        else: result

    # Only user-authored input may cross the local headline privacy boundary.
    effective_result =
      case payload["headline"] do
        %{"consumer" => "edit", "requested_headline" => text} ->
          Map.put(effective_result, "title", text)

        _ ->
          effective_result
      end

    changes =
      effective_result
      |> Map.take(@meta_keys)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.merge(%{
        look: look,
        trim_in_s: payload["in_s"],
        trim_out_s: payload["out_s"],
        source_label: present(result["source_label"]) || clip.source_label || "htc-clip-tool"
      })
      |> then(fn c ->
        if kind == "new_clip", do: Map.put(c, :submitted_by_agent_id, agent_id), else: c
      end)

    attrs =
      render_attrs
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.merge(changes)

    ClipVersions.append!(clip.id, file, attrs, %{
      requested_start_s: payload["in_s"],
      requested_end_s: payload["out_s"],
      actual_start_s: result["actual_in_s"],
      actual_end_s: result["actual_out_s"],
      headline: effective_result["title"],
      caption: effective_result["caption"],
      caption_fixes: result["caption_fixes"] || payload["caption_fixes"],
      candidate_id: result["candidate_id"] || payload["candidate_id"],
      alternate_id: result["alternate_id"] || payload["alternate_id"],
      submitted_by_agent_id: agent_id,
      source: payload["episode"],
      closing_video: payload["closing_video"],
      provenance: %{"kind" => "clip_job", "job_id" => job.id, "job_kind" => kind},
      completion_key: "clip_job:" <> job.id
    })
  end

  defp check_platforms(%{"platforms" => nil}, _profile), do: {:ok, nil}

  defp check_platforms(%{"platforms" => list}, profile),
    do: AgentDrafts.check_platforms(list, profile)

  defp check_platforms(_result, _profile), do: {:ok, nil}

  @doc """
  The claimer fails the job: status failed, `error` (at most 2000
  characters, prefixed with the clip tool's error `code` when given). A
  `new_clip` job's clip stays candidate with no file.
  """
  @spec fail(Social.scope(), term(), Ecto.UUID.t(), term(), term()) ::
          {:ok, ClipJob.t()} | error()
  def fail(scope, job_id, agent_id, error, code \\ nil) do
    with {:ok, message} <- fail_message(error, code) do
      locked(scope, job_id, agent_id, fn job, _profile ->
        job
        |> ClipJob.finish_changeset(:failed, message)
        |> insert_or_rollback(:update)
      end)
      |> case do
        {:ok, job} = result ->
          Platform.Social.EpisodePipeline.child_failed(job)
          result

        other ->
          other
      end
    end
  end

  defp fail_message(error, code) when is_binary(error) do
    case {String.trim(error), present(code)} do
      {"", _} -> {:error, :invalid_error}
      {msg, nil} -> {:ok, String.slice(msg, 0, 2000)}
      {msg, code} -> {:ok, String.slice("#{code}: #{msg}", 0, 2000)}
    end
  end

  defp fail_message(_error, _code), do: {:error, :invalid_error}

  # ── Shared ───────────────────────────────────────────────────────────

  # Every job lookup: the job's profile must be in a visible org.
  defp scoped_jobs(scope) do
    case Social.visible_orgs(scope) do
      :all ->
        from(j in ClipJob)

      [] ->
        where(ClipJob, false)

      org_ids ->
        from(j in ClipJob,
          join: p in Profile,
          on: p.id == j.profile_id,
          where: p.org_id in ^org_ids
        )
    end
  end

  defp fetch_job(scope, job_id) do
    with {:ok, id} <- Ecto.UUID.cast(job_id || ""),
         %ClipJob{} = job <- scope |> scoped_jobs() |> where([j], j.id == ^id) |> Repo.one() do
      {:ok, job}
    else
      _ -> {:error, :not_found}
    end
  end

  # Runs `fun.(job, profile)` in a transaction with the job locked FOR
  # UPDATE, for the claimer of an open (claimed or running) job only.
  defp locked(scope, job_id, agent_id, fun) do
    with {:ok, %ClipJob{id: id}} <- fetch_job(scope, job_id) do
      Repo.transaction(fn ->
        job = Repo.one!(from(j in ClipJob, where: j.id == ^id, lock: "FOR UPDATE"))

        cond do
          is_nil(agent_id) or job.claimed_by_agent_id != agent_id -> Repo.rollback(:not_claimer)
          job.status not in ["claimed", "running"] -> Repo.rollback(:job_closed)
          true -> fun.(job, Repo.get!(Profile, job.profile_id))
        end
      end)
      |> case do
        {:ok, _} = result ->
          broadcast_job(Repo.get!(ClipJob, id))
          result

        other ->
          other
      end
    end
  end

  @doc false
  def broadcast_job(%ClipJob{} = job) do
    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      Social.clips_topic(job.profile_id),
      {:social_clip_job, %{id: job.id, profile_id: job.profile_id}}
    )

    :ok
  end

  defp notify_job({:ok, %ClipJob{} = job} = result) do
    broadcast_job(job)
    result
  end

  defp notify_job(result), do: result

  defp insert_or_rollback(changeset, action \\ :insert) do
    case apply(Repo, action, [changeset]) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp ok_or_rollback(:ok), do: :ok
  defp ok_or_rollback({:ok, value}), do: value
  defp ok_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp broadcast_clip({:ok, %{clip: clip}} = ok) do
    Social.broadcast_clip(clip)
    ok
  end

  defp broadcast_clip(other), do: other

  defp present(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp present(_), do: nil

  defp normalize(attrs) when is_map(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  defp normalize(_), do: %{}
end
