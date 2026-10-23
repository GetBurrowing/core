defmodule Platform.Social.AgentDrafts do
  @moduledoc """
  The agent-safe write path into Social (task 01a140a9-4c70, Social 4/7):
  what the `social` MCP tools call. A human approves in Burrow and the
  platform publishes; nothing here approves or publishes.

  ## The ceiling is needs_approval

  An agent may create a post as `draft` or `needs_approval` (the default)
  and nothing else: `approved`, `scheduled`, `published`, `failed` or any
  other value is `{:error, :status_not_allowed}`. Nothing here calls
  `Platform.Social.approve_post/3`. The fields only a human or the publisher
  writes (`approved_by_user_id`, `approved_at`, `external_url`,
  `external_id`, `error`, `rejection_reason`, `rejected_at`) are refused with
  `{:error, :field_not_allowed, fields}`, never dropped silently.

  `update_agent_draft/3` locks the row (`SELECT ... FOR UPDATE`) and re-checks
  its status inside the transaction, so a human approval that lands between
  the read and the write is never overwritten: anything past
  `needs_approval` is `{:error, :post_locked}` with the row untouched. A post
  may go `draft -> needs_approval`, never back.

  ## Scope

  The scope is core's agent home-org shape, `:root` or `{:tenant, org_id}`,
  resolved by the caller from the agent, never from a client `org_id`. Every
  lookup goes through `Platform.Social`'s scoped getters, whose one decision
  is `Platform.Social.visible_orgs/1` (the `RBAC SWAP POINT`). A row outside
  the scope is `{:error, :not_found}`, identical to a missing id.

  Source refs are checked against the PROFILE's org: a `task_id`,
  `meeting_id` or media file id must exist and belong to it, read through
  core's public contexts (`Platform.Tasks`, `Platform.Meetings`,
  `Platform.Files`), never a Repo query on a core table. A `task_id` that
  names a social task (Social 6/7, `Platform.Social.TaskBridge`) must also
  be for the draft's profile, else `{:error, :task_profile_mismatch}`.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Platform.Repo
  alias Platform.Social

  alias Platform.Social.{
    Account,
    Clip,
    ClipLook,
    ClipMedia,
    ClipRender,
    Cover,
    Links,
    OrgFiles,
    Post,
    Profile
  }

  @castable ~w(body media_file_ids link_url scheduled_at status task_id meeting_id
               segment_ids episode_url start_s end_s cover_file_id cover_offset_ms)a
  @forbidden ~w(approved_by_user_id approved_at external_url external_id error
                rejection_reason rejected_at cover_error)
  @agent_statuses ~w(draft needs_approval)
  @default_status "needs_approval"
  @editable_statuses ~w(draft needs_approval)

  @type error ::
          {:error, :not_found | :status_not_allowed | :post_locked | :account_archived}
          | {:error, :no_accounts | :invalid_range | :invalid_source_url}
          | {:error, :invalid_source | :source_not_in_project | :profile_needs_project}
          | {:error, :invalid_crop_x | {:invalid_platforms, [String.t()]}}
          | {:error, :task_profile_mismatch}
          | {:error, :file_not_in_project | :not_a_video | :invalid_title}
          | {:error, :field_not_allowed, [String.t()]}
          | {:error, Ecto.Changeset.t()}

  @doc "Statuses an agent may set."
  @spec agent_statuses() :: [String.t()]
  def agent_statuses, do: @agent_statuses

  @doc "Fields an agent may never send."
  @spec forbidden_fields() :: [String.t()]
  def forbidden_fields, do: @forbidden

  # ── Create ───────────────────────────────────────────────────────────

  @doc """
  One post per `account_ids` entry, all or none, under `profile_id`. Every
  account must belong to the profile and not be archived. With no
  `link_url`, the link is `Links.effective_link/4` (the profile's home_url,
  or the YouTube episode at `start_s`) and it is appended to the body once.
  """
  @spec create_agent_drafts(Social.scope(), term(), map()) :: {:ok, [Post.t()]} | error()
  def create_agent_drafts(scope, profile_id, attrs) do
    attrs = normalize(attrs)

    with :ok <- refuse_forbidden(attrs),
         {:ok, status} <- create_status(attrs),
         {:ok, account_ids} <- account_ids(attrs),
         {:ok, profile} <- fetch_profile(scope, profile_id),
         :ok <- check_task_profile(attrs, profile),
         {:ok, accounts} <- fetch_accounts(scope, profile, account_ids),
         :ok <- require_channels(status, profile, accounts) do
      attrs = Map.put(attrs, "status", status)

      Repo.transaction(fn ->
        Enum.map(accounts, fn account ->
          changeset =
            %Post{account_id: account.id}
            |> agent_changeset(attrs, profile)
            |> put_effective_link(profile)

          case Repo.insert(changeset) do
            {:ok, post} -> post
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
      end)
      |> after_commit()
    end
  end

  # Social 3/7: after commit, every needs_approval post gets its approval
  # card and inbox rows through the one hook in `Platform.Social`.
  # Social 6/7: then the task write-back hears about drafts linked to a
  # task, so a task whose every draft is on a draft_only account (which never
  # publishes) still settles.
  defp after_commit({:ok, posts}) when is_list(posts) do
    posts = Enum.map(posts, &Social.needs_approval_written/1)
    posts |> Enum.filter(& &1.task_id) |> Enum.uniq_by(& &1.task_id) |> Enum.each(&task_hook/1)
    {:ok, posts}
  end

  defp after_commit({:ok, %Post{} = post}) do
    post = Social.needs_approval_written(post)
    if post.task_id, do: task_hook(post)
    {:ok, post}
  end

  defp after_commit(other), do: other

  # Task 01a14ce1 stage 3: each account's card has somewhere to go (an owned
  # account's owner DM, or the profile's channel).
  defp require_channels(status, profile, accounts) do
    Enum.find_value(accounts, :ok, fn account ->
      case Social.require_channel(status, profile, account) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp task_hook(%Post{id: id}), do: Platform.Social.TaskBridge.post_changed(id)

  defp create_status(attrs) do
    case Map.get(attrs, "status", @default_status) do
      status when status in @agent_statuses -> {:ok, status}
      _ -> {:error, :status_not_allowed}
    end
  end

  defp account_ids(%{"account_ids" => ids}) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &is_binary/1), do: {:ok, Enum.uniq(ids)}, else: {:error, :not_found}
  end

  defp account_ids(_), do: {:error, :no_accounts}

  defp fetch_accounts(scope, profile, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Social.get_account(scope, id) do
        %Account{profile_id: profile_id, archived_at: nil} = account
        when profile_id == profile.id ->
          {:cont, {:ok, [account | acc]}}

        %Account{profile_id: profile_id} when profile_id == profile.id ->
          {:halt, {:error, :account_archived}}

        _ ->
          {:halt, {:error, :not_found}}
      end
    end)
    |> case do
      {:ok, accounts} -> {:ok, Enum.reverse(accounts)}
      error -> error
    end
  end

  defp put_effective_link(changeset, %Profile{home_url: home_url}) do
    link =
      Links.effective_link(
        Changeset.get_field(changeset, :link_url),
        home_url,
        Changeset.get_field(changeset, :episode_url),
        Changeset.get_field(changeset, :start_s)
      )

    if link do
      changeset
      |> Changeset.put_change(:link_url, link)
      |> Changeset.put_change(
        :body,
        Links.append_to_body(Changeset.get_field(changeset, :body), link)
      )
    else
      changeset
    end
  end

  # ── Update ───────────────────────────────────────────────────────────

  @doc """
  Updates an agent-editable post (draft or needs_approval). The row is locked
  and its status re-checked in the transaction; past needs_approval it is
  `{:error, :post_locked}`, untouched. A needs_approval post cannot go back
  to draft. Rejection fields are never touched.
  """
  @spec update_agent_draft(Social.scope(), term(), map()) :: {:ok, Post.t()} | error()
  def update_agent_draft(scope, post_id, attrs) do
    attrs = normalize(attrs)

    with :ok <- refuse_forbidden(attrs),
         :ok <- refuse_status_value(attrs),
         {:ok, post} <- fetch_post(scope, post_id) do
      Repo.transaction(fn ->
        locked = Repo.one(from(p in Post, where: p.id == ^post.id, lock: "FOR UPDATE"))

        with %Post{} <- locked || {:error, :not_found},
             :ok <- refuse_locked(locked),
             :ok <- refuse_transition(locked, attrs),
             profile = profile_of(locked),
             :ok <- check_task_profile(attrs, profile),
             changeset = agent_changeset(locked, attrs, profile),
             :ok <-
               Social.require_channel(changeset, profile, Repo.get(Account, locked.account_id)),
             {:ok, updated} <- Repo.update(changeset) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> after_commit()
    end
  end

  defp refuse_status_value(%{"status" => status}) when status not in @agent_statuses,
    do: {:error, :status_not_allowed}

  defp refuse_status_value(_), do: :ok

  defp refuse_locked(%Post{status: status}) when status in @editable_statuses, do: :ok
  defp refuse_locked(%Post{}), do: {:error, :post_locked}

  # needs_approval is a one-way step for an agent: never back to draft.
  defp refuse_transition(%Post{status: "needs_approval"}, %{"status" => "draft"}),
    do: {:error, :status_not_allowed}

  defp refuse_transition(_post, _attrs), do: :ok

  defp profile_of(%Post{account_id: account_id}) do
    account = Repo.get!(Account, account_id)
    Repo.get!(Profile, account.profile_id)
  end

  # ── Clips ────────────────────────────────────────────────────────────

  @doc """
  Proposes a clip candidate under `profile_id`: `start_s >= 0` and
  `end_s > start_s` (both numbers, checked before the DB; member 1's CHECK
  is the backstop), `caption`, `speaker`. The status is always
  `candidate`; the times are also kept as `requested_start_s` /
  `requested_end_s` (the render snaps `start_s`/`end_s` to sentences).

  The footage is EITHER `source_url` (http/https, a YouTube episode) OR
  `source_file_id` + `transcript_file_id` (Social 5/7): a video and its
  VTT/SRT/JSON transcript in core's Files, both in the profile's project
  (`{:error, :source_not_in_project}`; a profile without a project in its
  org is `{:error, :profile_needs_project}`). Both kinds at once, or a file
  source missing its transcript, is `{:error, :invalid_source}`.

  Optional: `crop_x` (0..1, the static crop centre; `{:error,
  :invalid_crop_x}`) and `platforms` (target platforms for the render, each
  one of the profile's accounts' platforms).
  """
  @spec propose_clip(Social.scope(), term(), map()) :: {:ok, Clip.t()} | error()
  def propose_clip(scope, profile_id, attrs) do
    attrs = normalize(attrs)

    with {:ok, kind} <- source_kind(attrs),
         :ok <- if(kind == :url, do: validate_source_url(attrs["source_url"]), else: :ok),
         :ok <- validate_range(attrs["start_s"], attrs["end_s"]),
         :ok <- validate_crop(attrs["crop_x"]),
         {:ok, profile} <- fetch_profile(scope, profile_id),
         {:ok, source} <- check_source(kind, attrs, profile),
         {:ok, platforms} <- validate_platforms(attrs["platforms"], profile) do
      fields =
        attrs
        |> Map.take(~w(start_s end_s caption speaker crop_x))
        |> Map.merge(source)
        |> Map.put("platforms", platforms)

      %Clip{profile_id: profile.id}
      |> Clip.changeset(fields)
      |> Changeset.put_change(:status, "candidate")
      |> Changeset.put_change(:requested_start_s, attrs["start_s"] * 1.0)
      |> Changeset.put_change(:requested_end_s, attrs["end_s"] * 1.0)
      |> Repo.insert()
    end
  end

  @doc """
  Clip Studio 1/9: submits a clip rendered OUTSIDE Burrow (htc-clip-tool)
  for review. `attrs` (string or atom keys): `file_id` (required: a video in
  the profile's project, see `check_clip_file/2`), and optionally `title`
  (non-blank, at most 200, else `{:error, :invalid_title}`), `caption`,
  `speaker`, `episode_code`, `source_label` (default `"external"`),
  `platforms` (each one of the profile's account platforms) and
  `duration_s`/`width`/`height` (used only when the file cannot be probed).
  Any other key, including every review field and `rev`, is ignored.

  In one transaction it inserts the clip with `Clip.submit_changeset/2`
  (external, rendered, review pending, rev 1; look = the profile's effective
  show look; `submitted_by_agent_id` = `agent_id`) and its rev-1
  `Platform.Social.ClipRender` row, then broadcasts the clip.

  Title, caption, speaker and episode code may all be nil: under the clip
  tool's `[privacy] mode = "local"` nothing transcript-derived arrives.
  """
  @spec submit_clip(Social.scope(), term(), map(), Ecto.UUID.t() | nil) ::
          {:ok, Clip.t()} | error()
  def submit_clip(scope, profile_id, attrs, agent_id) do
    attrs = normalize(attrs)

    with {:ok, profile} <- fetch_profile(scope, profile_id),
         {:ok, _project} <- render_project(profile),
         {:ok, file} <- check_clip_file(attrs["file_id"], profile),
         :ok <- validate_title(attrs),
         {:ok, platforms} <- validate_platforms(attrs["platforms"], profile) do
      look = ClipLook.effective(profile.show_look)

      fields =
        attrs
        |> Map.take(~w(title caption speaker episode_code))
        |> Map.merge(clip_file_meta(file, attrs))
        |> Map.merge(%{
          "source_label" => blank_default(attrs["source_label"], "external"),
          "platforms" => platforms,
          "render_file_id" => file.id,
          "look" => look
        })

      Repo.transaction(fn ->
        with {:ok, clip} <-
               %Clip{profile_id: profile.id}
               |> Clip.submit_changeset(fields)
               |> Changeset.put_change(:submitted_by_agent_id, agent_id)
               |> Repo.insert(),
             {:ok, _render} <-
               %ClipRender{}
               |> ClipRender.changeset(%{
                 clip_id: clip.id,
                 rev: 1,
                 file_id: file.id,
                 look: look,
                 submitted_by_agent_id: agent_id
               })
               |> Repo.insert() do
          clip
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, clip} ->
          Social.broadcast_clip(clip)
          {:ok, clip}

        error ->
          error
      end
    end
  end

  defp validate_title(attrs) do
    case Map.fetch(attrs, "title") do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, t} when is_binary(t) -> if valid_title?(t), do: :ok, else: {:error, :invalid_title}
      {:ok, _} -> {:error, :invalid_title}
    end
  end

  defp valid_title?(t), do: String.trim(t) != "" and String.length(t) <= 200

  defp blank_default(v, default) when is_binary(v),
    do: if(String.trim(v) == "", do: default, else: v)

  defp blank_default(_v, default), do: default

  defp source_kind(attrs) do
    file? = present?(attrs["source_file_id"]) or present?(attrs["transcript_file_id"])
    url? = present?(attrs["source_url"])

    cond do
      file? and url? -> {:error, :invalid_source}
      file? -> {:ok, :file}
      true -> {:ok, :url}
    end
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""

  defp check_source(:url, attrs, _profile), do: {:ok, %{"source_url" => attrs["source_url"]}}

  defp check_source(:file, attrs, profile) do
    with true <- present?(attrs["source_file_id"]) and present?(attrs["transcript_file_id"]),
         {:ok, _project} <- render_project(profile),
         :ok <- in_project(attrs["source_file_id"], profile),
         :ok <- in_project(attrs["transcript_file_id"], profile) do
      {:ok,
       %{
         "source_file_id" => attrs["source_file_id"],
         "transcript_file_id" => attrs["transcript_file_id"]
       }}
    else
      false -> {:error, :invalid_source}
      {:error, _} = error -> error
    end
  end

  defp render_project(profile) do
    case Social.render_project(profile) do
      {:ok, project} -> {:ok, project}
      {:error, _} -> {:error, :profile_needs_project}
    end
  end

  # Through core's public Files API; a file in another project (or missing,
  # or soft-deleted) is refused alike.
  defp in_project(id, profile) do
    case project_file(id, profile) do
      {:ok, _file} -> :ok
      :error -> {:error, :source_not_in_project}
    end
  end

  # Clip Studio 1/9: the one rule behind every "is this file the profile's"
  # check. `Platform.Files.get_file/1` hides soft-deleted rows, so a deleted
  # file is missing; a file in another project, or another org's, is
  # refused exactly like a random id.
  defp project_file(id, %Profile{project_id: project_id})
       when is_binary(id) and is_binary(project_id) do
    case Platform.Files.get_file(id) do
      %{project_id: ^project_id, deleted_at: nil} = file -> {:ok, file}
      _ -> :error
    end
  end

  defp project_file(_id, _profile), do: :error

  @doc """
  Clip Studio 1/9: checks that `file_id` names a rendered clip the profile
  may hold: a live file in the profile's project whose content type is
  `video/*`. A missing, deleted, other-project or other-org file is
  `{:error, :file_not_in_project}` alike; any other content type is
  `{:error, :not_a_video}`. Shared by `submit_clip/4` and the clip job
  list's complete (`Platform.Social.ClipJobs`).
  """
  @spec check_clip_file(term(), Profile.t()) ::
          {:ok, Platform.Files.File.t()} | {:error, :file_not_in_project | :not_a_video}
  def check_clip_file(file_id, %Profile{} = profile) do
    case project_file(file_id, profile) do
      {:ok, file} -> if video?(file), do: {:ok, file}, else: {:error, :not_a_video}
      :error -> {:error, :file_not_in_project}
    end
  end

  @doc """
  Clip Studio 1/9: whether `file_id` is a live file in the profile's
  project (any content type). Used for a new clip's episode source and
  transcript (`Platform.Social.ClipJobs`).
  """
  @spec file_in_project?(term(), Profile.t()) :: boolean()
  def file_in_project?(file_id, %Profile{} = profile),
    do: match?({:ok, _}, project_file(file_id, profile))

  @doc """
  Clip Studio 1/9: `platforms` (nil = none) must each be one of the
  profile's live account platforms. `{:ok, unique_list}` or
  `{:error, {:invalid_platforms, bad}}`.
  """
  @spec check_platforms(term(), Profile.t()) ::
          {:ok, [String.t()]} | {:error, {:invalid_platforms, [String.t()]}}
  def check_platforms(platforms, %Profile{} = profile), do: validate_platforms(platforms, profile)

  @doc """
  Clip Studio 1/9: a clip title is optional; given, it is a non-blank
  string of at most 200 characters, else `{:error, :invalid_title}`.
  """
  @spec check_title(map()) :: :ok | {:error, :invalid_title}
  def check_title(attrs), do: attrs |> normalize() |> validate_title()

  defp video?(%{content_type: type}) when is_binary(type), do: String.starts_with?(type, "video/")
  defp video?(_), do: false

  @doc """
  Clip Studio 1/9: the rendered file's measurements. ffprobe on the stored
  file when storage gives a local path; otherwise (or when the probe fails)
  the caller's `duration_s`, `width` and `height`. `byte_size` always comes
  from the file row.
  """
  @spec clip_file_meta(Platform.Files.File.t(), map()) :: map()
  def clip_file_meta(file, attrs) do
    attrs = normalize(attrs)

    base = %{
      "duration_s" => number(attrs["duration_s"]),
      "width" => integer(attrs["width"]),
      "height" => integer(attrs["height"]),
      "byte_size" => file.byte_size
    }

    case probe(file) do
      {:ok, %{duration_s: d, width: w, height: h}} ->
        Map.merge(base, %{"duration_s" => d, "width" => w, "height" => h})

      _ ->
        base
    end
  end

  defp probe(file) do
    with {:ok, path} <- Platform.Files.Extractor.local_path(file),
         true <- File.exists?(path) do
      Platform.Social.Renderer.Ffmpeg.probe(path)
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp number(n) when is_number(n), do: n * 1.0
  defp number(_), do: nil

  defp integer(n) when is_integer(n), do: n
  defp integer(n) when is_float(n), do: round(n)
  defp integer(_), do: nil

  defp validate_crop(nil), do: :ok
  defp validate_crop(x) when is_number(x) and x >= 0 and x <= 1, do: :ok
  defp validate_crop(_), do: {:error, :invalid_crop_x}

  defp validate_platforms(nil, _profile), do: {:ok, []}

  defp validate_platforms(list, profile) when is_list(list) do
    available =
      from(a in Account,
        where: a.profile_id == ^profile.id and is_nil(a.archived_at),
        select: a.platform
      )
      |> Repo.all()

    case Enum.reject(list, &(&1 in available)) do
      [] -> {:ok, Enum.uniq(list)}
      bad -> {:error, {:invalid_platforms, Enum.map(bad, &to_string/1)}}
    end
  end

  defp validate_platforms(other, _profile), do: {:error, {:invalid_platforms, [inspect(other)]}}

  defp validate_source_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, :invalid_source_url}
    end
  end

  defp validate_source_url(_), do: {:error, :invalid_source_url}

  defp validate_range(start_s, end_s)
       when is_number(start_s) and is_number(end_s) and start_s >= 0 and end_s > start_s,
       do: :ok

  defp validate_range(_, _), do: {:error, :invalid_range}

  # ── Shared ───────────────────────────────────────────────────────────

  # Social 6/7: a draft citing a SOCIAL task (one with a
  # `social_task_requests` row) must be for that task's profile. A task_id
  # with no request row keeps the org check in `agent_changeset/3`.
  defp check_task_profile(%{"task_id" => task_id}, %Profile{id: profile_id})
       when is_binary(task_id) do
    case Platform.Social.TaskBridge.request_for_task(task_id) do
      nil -> :ok
      %{profile_id: ^profile_id} -> :ok
      _ -> {:error, :task_profile_mismatch}
    end
  end

  defp check_task_profile(_attrs, _profile), do: :ok

  defp fetch_profile(scope, id) do
    case Social.get_profile(scope, id) do
      %Profile{} = profile -> {:ok, profile}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_post(scope, id) do
    case Social.get_post(scope, id) do
      %Post{} = post -> {:ok, post}
      nil -> {:error, :not_found}
    end
  end

  # String keys throughout (the tools hand over decoded JSON). A nil status
  # means "not given".
  defp normalize(attrs) when is_map(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> then(fn a -> if a["status"] == nil, do: Map.delete(a, "status"), else: a end)
  end

  defp normalize(_), do: %{}

  defp refuse_forbidden(attrs) do
    case Enum.filter(@forbidden, &Map.has_key?(attrs, &1)) do
      [] -> :ok
      fields -> {:error, :field_not_allowed, fields}
    end
  end

  defp agent_changeset(%Post{} = post, attrs, %Profile{org_id: org_id} = profile) do
    post
    |> Changeset.cast(attrs, @castable)
    |> Changeset.validate_required([:status])
    |> Changeset.validate_inclusion(:status, @agent_statuses)
    |> validate_future(:scheduled_at)
    |> validate_ref(:task_id, org_id, &task_org/1)
    |> validate_ref(:meeting_id, org_id, &meeting_org/1)
    |> validate_media(org_id)
    # Social 5/7: a rendered clip's length and size, for MediaRules at publish.
    |> ClipMedia.put_media_meta(profile.id)
    # Task 01a165ec stage 2: the one cover rule, shared with Post.changeset.
    |> Cover.validate(attrs, %{org_id: org_id, profile_id: profile.id})
    |> Changeset.check_constraint(:status, name: :social_posts_status_check)
    |> Changeset.check_constraint(:approved_by_user_id,
      name: :social_posts_approved_needs_approver_check
    )
    |> Changeset.foreign_key_constraint(:account_id)
    |> Changeset.foreign_key_constraint(:task_id)
    |> Changeset.foreign_key_constraint(:meeting_id)
  end

  defp validate_future(changeset, field) do
    case Changeset.get_change(changeset, field) do
      %DateTime{} = at ->
        if DateTime.compare(at, DateTime.utc_now()) == :gt,
          do: changeset,
          else: Changeset.add_error(changeset, field, "must be in the future")

      _ ->
        changeset
    end
  end

  defp validate_ref(changeset, field, org_id, org_of) do
    case Changeset.get_change(changeset, field) do
      nil ->
        changeset

      id ->
        if org_of.(id) == org_id,
          do: changeset,
          else: Changeset.add_error(changeset, field, "must exist in the profile's org")
    end
  end

  defp validate_media(changeset, org_id) do
    ids = Changeset.get_change(changeset, :media_file_ids) || []

    if Enum.all?(ids, &OrgFiles.in_org?(&1, org_id)),
      do: changeset,
      else: Changeset.add_error(changeset, :media_file_ids, "must exist in the profile's org")
  end

  defp task_org(id) do
    case Platform.Tasks.get_task_record(id) do
      %{project_id: project_id} -> project_org(project_id)
      _ -> nil
    end
  end

  defp meeting_org(id) do
    case Platform.Meetings.get_meeting(id) do
      %{project_id: project_id} -> project_org(project_id)
      _ -> nil
    end
  end

  defp project_org(project_id) when is_binary(project_id) do
    case Platform.Tasks.get_project(project_id) do
      %{org_id: org_id} -> org_id
      _ -> nil
    end
  end

  defp project_org(_), do: nil
end
