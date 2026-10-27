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
  alias Platform.Social.{AgentDrafts, Clip, ClipJob, ClipLook, ClipVersions, Profile}

  @base_profile "how-to-computer"
  @result_keys ~w(file_id title caption speaker episode_code platforms duration_s width height
                  source_label actual_in_s actual_out_s caption_fixes candidate_id alternate_id)
  @meta_keys ~w(title caption speaker episode_code)

  @type error :: {:error, atom() | tuple() | Ecto.Changeset.t()}

  @doc "The keys `complete/4` takes from a result; everything else is dropped."
  @spec result_keys() :: [String.t()]
  def result_keys, do: @result_keys

  @doc "The clip-tool user profile a profile's looks live in: `burrow-<full profile id>`."
  @spec clip_user_profile(Profile.t() | Ecto.UUID.t()) :: String.t()
  def clip_user_profile(%Profile{id: id}), do: clip_user_profile(id)
  def clip_user_profile(id) when is_binary(id), do: "burrow-" <> id

  # ── Human side ───────────────────────────────────────────────────────

  @doc "Queues a typed text fix against the current immutable render, without changing playback."
  def enqueue_fix(org_id, clip_id, user_id, attrs) do
    attrs = normalize(attrs)

    with %Clip{} = found <- Social.get_clip(org_id, clip_id) || {:error, :not_found},
         {:ok, profile} <- human_profile(org_id, found.profile_id, user_id) do
      Repo.transaction(fn ->
        clip = Repo.one!(from(c in Clip, where: c.id == ^found.id, lock: "FOR UPDATE"))

        base =
          ok_or_rollback(ClipVersions.get(org_id, profile.id, clip.id, attrs["base_render_id"]))

        if base.rev != clip.rev, do: Repo.rollback(:stale_version)

        unless is_binary(base.file_id) && Platform.Files.get_file(base.file_id),
          do: Repo.rollback(:version_unplayable)

        fix = ok_or_rollback(Platform.Social.ClipFixes.validate(base, attrs))
        look = ClipLook.effective(base.look)

        payload =
          payload("rerender", profile, clip, look, fix["in_s"], fix["out_s"], nil, clip.rev + 1)
          |> Map.merge(%{
            "base_render_id" => base.id,
            "candidate_id" => base.candidate_id,
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
         {:ok, source} <- episode_source(attrs, profile),
         :ok <- check_range(attrs["in_s"], attrs["out_s"]),
         :ok <- AgentDrafts.check_title(Map.take(attrs, ["title"])) do
      in_s = attrs["in_s"] * 1.0
      out_s = attrs["out_s"] * 1.0
      look = ClipLook.effective(profile.show_look)

      Repo.transaction(fn ->
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

    with %Clip{} = clip <- Social.get_clip(org_id, clip_id) || {:error, :not_found},
         {:ok, profile} <- human_profile(org_id, clip.profile_id, user_id),
         {:ok, requested} <- validate_look(attrs["look"] || %{}),
         look = ClipLook.effective(ClipLook.merge(clip.look, requested)),
         {:ok, look} <- validate_look(look),
         in_s = number_or(attrs["trim_in_s"], clip.trim_in_s || clip.requested_start_s),
         out_s = number_or(attrs["trim_out_s"], clip.trim_out_s || clip.requested_end_s),
         :ok <- check_optional_range(in_s, out_s) do
      note = if clip.review_status == "rejected", do: clip.review_note
      payload = payload("rerender", profile, clip, look, in_s, out_s, note, clip.rev + 1)

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
        {:ok, job} -> {:ok, job}
        {:error, changeset} -> {:error, in_flight_or(changeset)}
      end
    end
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
        delta = ClipLook.delta(full, ClipLook.default())

        payload =
          profile
          |> base_payload("save_default", nil, full, nil, nil, nil, nil)
          |> Map.merge(%{
            "look_delta" => delta,
            "clip_overrides" => ClipLook.to_clip_overrides(delta)
          })

        job = insert_job!(profile, nil, "save_default", payload, user_id)
        %{profile: profile, job: job}
      end)
    end
  end

  defp human_profile(org_id, profile_id, user_id) do
    with %Profile{} = profile <- Social.get_profile(org_id, profile_id) || {:error, :not_found},
         :ok <- Social.approver_check(profile.org_id, profile, user_id) do
      {:ok, profile}
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

  defp payload(kind, profile, clip, look, in_s, out_s, review_note, expected_rev) do
    delta = ClipLook.delta(look, ClipLook.effective(profile.show_look))

    profile
    |> base_payload(kind, clip, look, in_s, out_s, review_note, expected_rev)
    |> Map.merge(%{"look_delta" => delta, "clip_overrides" => ClipLook.to_clip_overrides(delta)})
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
        {1, [job]} -> {:ok, job}
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
    result = result |> normalize() |> Map.take(@result_keys)

    locked(scope, job_id, agent_id, fn job, profile ->
      clip = complete_clip(job, profile, agent_id, result)

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

  defp complete_clip(%ClipJob{kind: "save_default"}, _profile, _agent_id, _result), do: nil

  defp complete_clip(%ClipJob{kind: kind} = job, profile, agent_id, result)
       when kind in ["new_clip", "rerender"] do
    file = ok_or_rollback(AgentDrafts.check_clip_file(result["file_id"], profile))
    ok_or_rollback(AgentDrafts.check_title(Map.take(result, ["title"])))
    platforms = ok_or_rollback(check_platforms(result, profile))

    clip =
      from(c in Clip, where: c.id == ^job.clip_id, lock: "FOR UPDATE")
      |> Repo.one()
      |> case do
        nil -> Repo.rollback(:not_found)
        clip -> clip
      end

    payload = job.payload || %{}

    if payload["base_render_id"] && payload["expected_rev"] != clip.rev + 1,
      do: Repo.rollback(:stale_version)

    look = payload["look"] || clip.look
    meta = AgentDrafts.clip_file_meta(file, result)

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
      if payload["fix"] || payload["headline"],
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
    end
  end

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
