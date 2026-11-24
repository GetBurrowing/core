defmodule Platform.Social.ClipReviewFeed do
  @moduledoc """
  The read model behind the Clips tab's Review bay (Clip Studio 3/9, task
  01a16662-8c00), plus the one write the bay's details rail makes.

  Owned by this task: it reads through `Platform.Social`'s org-scoped
  getters and never edits `social.ex`, `clip.ex` or `clip_jobs.ex`.

    * `review_queue/2`: the profile's clips waiting for a human, i.e.
      `review_status` "pending" WITH a rendered file, oldest first.
    * `rendering/2`: the profile's open clip jobs (`new_clip`/`rerender`,
      queued, claimed or running), oldest first.
    * `pending_count/2`: the length of `review_queue/2`, counted in SQL.
    * `fetch_clip/3`: one clip, refused identically (`{:error, :not_found}`)
      for another org, another profile of the same org, and an id that
      does not exist, so a URL param can never tell them apart.
    * `byline/2`: who submitted the clip, an agent name resolved only when
      the agent's home org admits the clip's org.
    * `save_details/5`: title, caption and platforms on a PENDING clip, by
      an approver (`Platform.Social.approver_check/3` first). It never
      writes a review field.

  Every function takes the viewer's `org_id`; a profile outside it reads
  as empty (lists, count 0) or `{:error, :not_found}` (single rows).
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Clip, ClipJob, Profile}

  @open_statuses ~w(queued claimed running)
  @open_kinds ~w(new_clip rerender)
  @detail_keys ~w(title caption platforms)

  @doc "Pending, rendered clips of the profile, `inserted_at` then `id` ascending."
  @spec review_queue(Ecto.UUID.t(), term()) :: [Clip.t()]
  def review_queue(org_id, profile_id) do
    case Social.get_profile(org_id, profile_id) do
      %Profile{} = profile -> profile |> queue_query() |> Repo.all()
      nil -> []
    end
  end

  @doc "How many clips `review_queue/2` would return."
  @spec pending_count(Ecto.UUID.t(), term()) :: non_neg_integer()
  def pending_count(org_id, profile_id) do
    case Social.get_profile(org_id, profile_id) do
      %Profile{} = profile ->
        profile |> queue_query() |> exclude(:order_by) |> Repo.aggregate(:count)

      nil ->
        0
    end
  end

  defp queue_query(%Profile{id: profile_id}) do
    from(c in Clip,
      where:
        c.profile_id == ^profile_id and c.flow == "legacy" and is_nil(c.removed_at) and
          c.review_status == "pending" and not is_nil(c.render_file_id),
      order_by: [asc: c.inserted_at, asc: c.id]
    )
  end

  @doc """
  The profile's open render jobs, oldest first, each as
  `%{id, kind, status, title, episode_code, progress, eta_s, clip_id}`.
  `title` is the job's clip title, else the payload's, else nil.
  """
  @spec rendering(Ecto.UUID.t(), term()) :: [map()]
  def rendering(org_id, profile_id) do
    case Social.get_profile(org_id, profile_id) do
      %Profile{id: id} ->
        from(j in ClipJob,
          left_join: c in Clip,
          on: c.id == j.clip_id,
          where: j.profile_id == ^id and j.status in @open_statuses and j.kind in @open_kinds,
          where: is_nil(c.id) or c.flow == "legacy",
          order_by: [asc: j.inserted_at, asc: j.id],
          select: {j, c}
        )
        |> Repo.all()
        |> Enum.map(&render_row/1)

      nil ->
        []
    end
  end

  @headline_errors ~w(HEADLINE_CLI_UNSUPPORTED HEADLINE_REQUEST_UNSUPPORTED HEADLINE_VOICE_MISSING
    HEADLINE_BASE_MISSING HEADLINE_BASE_STALE HEADLINE_SPAN_INVALID HEADLINE_SPAN_STALE
    HEADLINE_CANDIDATE_MISSING HEADLINE_EMPTY HEADLINE_UNBACKED HEADLINE_OUTPUT_UNSUPPORTED
    HEADLINE_OVERLAY_DISABLED HEADLINE_RENDER_APPROVAL_REQUIRED HEADLINE_REVIEW_NOT_APPLIED
    HEADLINE_APPLIED_MISMATCH HEADLINE_PRIVACY_EXPORT_REFUSED HEADLINE_PREPARE_FAILED
    HEADLINE_RENDER_MISSING)

  @doc "Recent automatic episode outcomes, including failures before any candidate exists."
  def episode_jobs(org_id, profile_id) do
    case Social.get_profile(org_id, profile_id) do
      %Profile{id: id} ->
        parents =
          Repo.all(
            from(j in ClipJob,
              where: j.profile_id == ^id and j.kind == "episode",
              order_by: [desc: j.inserted_at, desc: j.id],
              limit: 20
            )
          )

        ids = Enum.flat_map(parents, &(&1.payload["child_job_ids"] || []))
        children = Repo.all(from(j in ClipJob, where: j.profile_id == ^id and j.id in ^ids))
        by_id = Map.new(children, &{&1.id, &1})

        Enum.map(parents, fn job ->
          child_rows =
            (job.payload["child_job_ids"] || [])
            |> Enum.flat_map(fn id -> if by_id[id], do: [episode_row(by_id[id])], else: [] end)

          job |> episode_row() |> Map.put(:children, child_rows)
        end)

      nil ->
        []
    end
  end

  defp episode_row(job) do
    %{
      id: job.id,
      status: job.status,
      uploaded_at: Calendar.strftime(job.inserted_at, "%b %d, %H:%M UTC"),
      progress: job.progress,
      step: episode_step(job),
      code: episode_error(job.error)
    }
  end

  # Never render runner error prose, source filenames, URLs or generated private
  # headlines. Only persisted protocol outcomes and this closed code set cross UI.
  defp episode_error(error) when is_binary(error) do
    code = error |> String.split(":", parts: 2) |> hd()

    if code in @headline_errors or
         code in ~w(RUNNER_UNAVAILABLE RUNNER_TIMEOUT EPISODE_INCOMPLETE),
       do: code,
       else: "RENDER_FAILED"
  end

  defp episode_error(_), do: "RENDER_FAILED"

  defp episode_step(%{status: "queued"}), do: "Waiting for runner"
  defp episode_step(%{status: "claimed"}), do: "Runner connected"
  defp episode_step(%{status: "failed"}), do: "Failed"

  defp episode_step(%{status: "done", kind: "episode", result: %{"outcome" => "no_picks"}}),
    do: "No picks found"

  defp episode_step(%{status: "done", kind: "episode"}), do: "Clips ready for review"
  defp episode_step(%{status: "done"}), do: "Ready for review"
  defp episode_step(%{kind: "episode", payload: %{"pick_plan" => _}}), do: "Rendering picks"
  defp episode_step(%{kind: "episode"}), do: "Processing episode"
  defp episode_step(_), do: "Generating headline and rendering"

  @doc "Latest headline attempt, scoped to this profile; errors expose stable codes only."
  def headline_attempt(org_id, profile_id, clip_id) do
    with {:ok, _} <- fetch_clip(org_id, profile_id, clip_id) do
      from(j in ClipJob,
        where: j.profile_id == ^profile_id and j.clip_id == ^clip_id,
        order_by: [desc: j.inserted_at, desc: j.id]
      )
      |> Repo.all()
      |> Enum.find(fn j ->
        j.payload["headline"] != nil or
          get_in(j.payload, ["fix", "operation"]) == "regenerate_headline"
      end)
      |> case do
        nil -> nil
        job -> %{id: job.id, status: job.status, code: headline_error(job.error)}
      end
    else
      _ -> nil
    end
  end

  defp headline_error(error) when is_binary(error) do
    code = error |> String.split(":", parts: 2) |> hd()
    if code in @headline_errors, do: code, else: "RENDER_FAILED"
  end

  defp headline_error(_), do: "RENDER_FAILED"

  defp render_row({%ClipJob{} = job, clip}) do
    payload = job.payload || %{}

    %{
      id: job.id,
      kind: job.kind,
      status: job.status,
      clip_id: job.clip_id,
      title: present(clip && clip.title) || present(payload["title"]),
      episode_code: present(clip && clip.episode_code) || present(payload["episode_code"]),
      progress: job.progress,
      eta_s: job.eta_s
    }
  end

  @doc """
  The clip, if it is in `org_id` AND on `profile_id`. Anything else
  (another org, another profile, a random or malformed id) is the same
  `{:error, :not_found}`.
  """
  @spec fetch_clip(Ecto.UUID.t(), term(), term()) :: {:ok, Clip.t()} | {:error, :not_found}
  def fetch_clip(org_id, profile_id, clip_id) do
    case Social.get_clip(org_id, clip_id) do
      %Clip{profile_id: ^profile_id} = clip when not is_nil(profile_id) -> {:ok, clip}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  `%{source_label, agent_name}` for the bay's subhead. The agent's name is
  shown only when its home org is root or the clip's org (`org_id`);
  otherwise, or with no submitting agent, `agent_name` is nil.
  """
  @spec byline(Ecto.UUID.t(), Clip.t()) :: %{
          source_label: String.t() | nil,
          agent_name: String.t() | nil
        }
  def byline(org_id, %Clip{} = clip) do
    %{source_label: clip.source_label, agent_name: agent_name(org_id, clip.submitted_by_agent_id)}
  end

  defp agent_name(_org_id, nil), do: nil

  defp agent_name(org_id, agent_id) do
    with %Platform.Agents.Agent{} = agent <- Repo.get(Platform.Agents.Agent, agent_id),
         true <- agent_in_org?(agent, org_id) do
      agent.name
    else
      _ -> nil
    end
  end

  defp agent_in_org?(agent, org_id) do
    case Platform.Experiments.Tools.home_org(agent) do
      :root -> true
      {:tenant, ^org_id} -> true
      _ -> false
    end
  end

  @doc """
  Saves the details rail's `title`, `caption` and `platforms` on a pending
  clip. Only those three keys of `attrs` are read; a `review_status` (or
  anything else) in `attrs` is ignored.

  Order: the clip is fetched through `fetch_clip/3`; the profile is re-read
  org-scoped and `Platform.Social.approver_check/3` runs before anything
  else is looked at; the clip must still be pending (`{:error, :not_pending}`);
  `platforms` must be among the platforms of the profile's non-archived
  accounts (`{:error, {:invalid_platforms, bad}}`). A refusal writes nothing.
  On success the clip is broadcast with `Platform.Social.broadcast_clip/1`.
  """
  @spec save_details(Ecto.UUID.t(), term(), term(), term(), map()) ::
          {:ok, Clip.t()} | {:error, term()}
  def save_details(org_id, profile_id, clip_id, user_id, attrs) when is_map(attrs) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.take(@detail_keys)

    with %Profile{} = profile <- Social.get_profile(org_id, profile_id) || {:error, :not_found},
         :ok <- Social.approver_check(org_id, profile, user_id),
         {:ok, clip} <- fetch_clip(org_id, profile.id, clip_id),
         :ok <- pending(clip),
         {:ok, text} <- text_changes(attrs),
         {:ok, platforms} <- platforms(org_id, profile, attrs) do
      changes = if platforms, do: Map.put(text, :platforms, platforms), else: text

      clip
      |> Changeset.change(changes)
      |> validate_details()
      |> Repo.update()
      |> case do
        {:ok, clip} ->
          Social.broadcast_clip(clip)
          {:ok, clip}

        error ->
          error
      end
    end
  end

  def save_details(_org_id, _profile_id, _clip_id, _user_id, _attrs), do: {:error, :invalid}

  @doc """
  The details rail's title/caption rules as a changeset on `clip`: only the
  `"title"` and `"caption"` keys of `attrs` are read; an omitted key is left
  alone. A title is trimmed, may not be blank or null and has at most 200
  characters; a caption is kept as given, null clears it, at most 2200. A
  non-string value is `{:error, {:invalid, field}}` before any changeset.
  Writes nothing. `Platform.Social.AgentDrafts.update_clip_copy/4` applies
  it; `save_details/5` is unchanged and reaches the same rules through the
  shared private helpers (`text_changes/1`, `validate_details/1`).
  """
  @spec copy_changeset(Clip.t(), map()) ::
          {:ok, Changeset.t()} | {:error, {:invalid, :title | :caption}}
  def copy_changeset(%Clip{} = clip, attrs) when is_map(attrs) do
    with {:ok, text} <- attrs |> Map.take(~w(title caption)) |> text_changes() do
      {:ok, clip |> Changeset.change(text) |> validate_details()}
    end
  end

  @doc """
  The clip's copy revision: an opaque token that names its current title and
  caption and nothing else. Whoever reads a clip to edit or to decide on it
  sends it back (`social_clip_update_copy`'s `expected_copy_rev`, Create
  drafts' `"copy_rev"`) and the write refuses when the copy has since changed.

  It is derived from the two columns, not from `updated_at` or `rev`: every
  writer of those columns moves it, including one that bypasses timestamps,
  and a write that touches neither (platforms, review, look) leaves it alone,
  so it never refuses for an unrelated change. `nil` and `""` are different
  copies, and so is a word moved from the title to the caption. Equal copy,
  equal token: restoring the old words restores the old token, which is
  correct because the reader's view is then true again.

  It is a fingerprint of the copy VALUE, not a monotonic edit revision. Change
  the copy away and back (A, then B, then A) and the token is the same as at
  the start, so a reader who saw A cannot tell from the token that the copy
  was ever B. It guards against acting on a copy that is different now, not
  against an edit that happened in between and was undone.
  """
  @spec copy_rev(Clip.t()) :: String.t()
  def copy_rev(%Clip{title: title, caption: caption}) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({:clip_copy, 1, title, caption}))

    "c1-" <> Base.url_encode64(binary_part(digest, 0, 12), padding: false)
  end

  defp pending(%Clip{review_status: "pending"}), do: :ok
  defp pending(%Clip{}), do: {:error, :not_pending}

  defp platforms(_org_id, _profile, attrs) when not is_map_key(attrs, "platforms"),
    do: {:ok, nil}

  defp platforms(org_id, profile, %{"platforms" => list}) when is_list(list) do
    available = org_id |> Social.list_accounts(profile_id: profile.id) |> Enum.map(& &1.platform)

    case Enum.reject(list, &(is_binary(&1) and &1 in available)) do
      [] -> {:ok, Enum.uniq(list)}
      bad -> {:error, {:invalid_platforms, Enum.map(bad, &to_string/1)}}
    end
  end

  defp platforms(_org_id, _profile, %{"platforms" => other}),
    do: {:error, {:invalid_platforms, [inspect(other)]}}

  # Title is trimmed and may not be blank; caption is kept as typed (nil
  # clears it). A non-string value for either is refused before any write.
  defp text_changes(attrs) do
    Enum.reduce_while(
      [title: "title", caption: "caption"],
      {:ok, %{}},
      &text_change(attrs, &1, &2)
    )
  end

  defp text_change(attrs, {field, key}, {:ok, acc}) do
    case Map.fetch(attrs, key) do
      :error -> {:cont, {:ok, acc}}
      {:ok, v} when is_binary(v) -> {:cont, {:ok, Map.put(acc, field, text(field, v))}}
      {:ok, nil} when field == :caption -> {:cont, {:ok, Map.put(acc, :caption, nil)}}
      {:ok, _} -> {:halt, {:error, {:invalid, field}}}
    end
  end

  defp text(:title, v), do: String.trim(v)
  defp text(:caption, v), do: v

  defp validate_details(changeset) do
    changeset
    |> blank_title()
    |> Changeset.validate_length(:title, max: 200)
    |> Changeset.validate_length(:caption, max: 2200)
  end

  defp blank_title(changeset) do
    case Changeset.fetch_change(changeset, :title) do
      {:ok, title} when title in [nil, ""] ->
        Changeset.add_error(changeset, :title, "can't be blank")

      _ ->
        changeset
    end
  end

  defp present(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp present(_), do: nil
end
