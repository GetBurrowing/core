defmodule Platform.Social.TaskBridge do
  @moduledoc """
  The meeting/chat to social task bridge (task 01a140a9-831e, Social 6/7).
  A social ask heard in a meeting or chat ("clip the doomsday clock bit",
  "post the episode to LinkedIn") becomes a task in the profile's project,
  assigned to the agent that heard it. That agent drafts the posts with the
  `social` tools, each draft carrying `task_id`. A human approves every post
  in Suite and the platform publishes it; agents cannot approve or publish.

  ## Entry point decision

  The entry point is the agent tool `social_task_request` (in the `social`
  bundle), backed by `request/3`. Core's meeting triage and graduation are
  NOT hooked through a new seam:

    1. a "social" intent kind would mean changing core's LLM classifier
       prompt and its eval corpus, plus `Platform.Meetings.Candidates`, a
       heavily guarded core module;
    2. the calling agent already hears the ask, holds the `social` bundle
       and has an org scope;
    3. every core function needed is already public, so this module makes
       NO core edit (core never names Social:
       `apps/platform/test/platform/extension_boundary_test.exs`).

  Typed Scribe outputs (meeting-agent canvas 01a13700-34ca) did not exist
  when this was built. When they land with a `social` kind, hook that
  output here instead of the tool.

  ## request/3, in order

  Each refusal writes nothing.

    * the input: `ask` non-blank (at most #{2000} characters), `platforms`
      a non-empty list, and `refs` EXACTLY one of `%{meeting_id,
      segment_ids}` (1..50 ids) or `%{episode_url, start_s, end_s}` (http or
      https; `end_s > start_s >= 0`), else `:invalid_refs`;
    * (a) the profile, through the scope (`:not_found` outside it, as for a
      missing id), with a project (`:profile_has_no_project`);
    * (b) each platform has a non-archived account on the profile
      (`:no_account_for_platform`);
    * (c) meeting refs: the meeting is in the profile's project
      (`meeting_readable?/2`, `:meeting_not_found` whatever the reason);
    * (d) `Platform.Social.TaskBridge.SegmentGuard`: no off-topic,
      retracted, vetoed or unclassified segment;
    * (e) the assignee is the requesting agent, which must exist
      (`:no_agent`) and be able to read the project
      (`assignee_can_read?/2`, `:assignee_cannot_read`), so a social task is
      never created only to be refused at dispatch;
    * (f) idempotency: a request with the same `request_key` (profile, refs
      and platforms; not the wording of the ask) returns its task with
      `created: false` and writes nothing;
    * (g) the live pipeline, for meeting refs: a matched candidate still
      `:acting` with no task is `:segment_being_filed` (retry); one closed
      `:done` with a task has its task ADOPTED (social metadata merged,
      planners set only if it has none) instead of a second one created;
    * (h) the task (`kind: "ops"`, `auto_approve_plan: true`, metadata
      `source: "social.request"` plus `social: %{profile_id, platforms,
      refs, request_id}`) and its `social_task_requests` row in ONE
      transaction; all three phase assignees are the agent, and
      `Platform.Tasks.maybe_start_planning_on_create/1` moves it to
      planning. After commit, every OPEN matched candidate is closed
      `:duplicate`, so neither `Candidates.graduate/2` nor Triage files a
      second, generic task for the same words.

  ## Write-back: post_changed/1

  Once EVERY draft linked to a social task is terminal, the task records the
  posts. Classification, per post:

    * `published`: status `published`;
    * `failed`: status `failed` (terminal in Social 2/7: a failed post is
      never retried, so it settles the task, with its error);
    * `rejected`: status `draft` with `rejected_at` set
      (`Platform.Social.Post.rejected?/1`). A redrafted post back in
      `needs_approval` with `rejected_at` still set is NOT terminal;
    * `manual`: the post's account is `draft_only`. Such a post never
      publishes (a human copies it out by hand), so it never blocks
      settlement; the task records it as "draft only, to post by hand";
    * anything else is pending, and one pending post means no write.

  The record (`metadata.social.result`) lists each post sorted by id, with
  `stats` present only when the stored outcome carries engagement stats;
  no vendor returns them today (`Platform.Social.Publisher.status/2` gives
  status, external_url and error), so none is written. Its sha256, minus
  `settled_at`, is kept on the request row: an identical settlement (a
  webhook replay, a concurrent call) writes nothing and leaves the task's
  `updated_at` alone. A later change (a redraft that publishes) changes the
  digest and writes exactly once more.

  The write is ONE `Platform.Tasks.update_task_if_unmodified/4` call (one
  retry on a concurrent edit): metadata merged, never replaced, and one
  managed block between `<!-- social:posts -->` and `<!-- /social:posts -->`
  in the description, replaced in place, so the URLs show on the task page
  and in MCP `task_get` (which does not expose metadata). The task's STATUS
  is never changed: the lifecycle stays with the plan engine and the agent.

  post_changed/1 is called after commit from exactly these sites:
  `Platform.Social.Publishing` (publish, cancel and outcome, through one
  helper), `Platform.Social.Approvals.decide_reject/4`, and
  `Platform.Social.AgentDrafts` (new or edited drafts carrying a task id,
  so an all-draft_only task settles). It never raises.

  Agents rows are read with `Repo.get/2` on `Platform.Agents.Agent`, as
  `Platform.Social.Tools` does: core has no public agent getter.
  """

  import Ecto.Query

  require Logger

  alias Platform.Meetings.Candidates
  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Profile, TaskRequest}
  alias Platform.Social.TaskBridge.SegmentGuard
  alias Platform.Tasks

  @max_ask 2000
  @max_segments 50
  @title_ask 120
  @open_states [:heard, :thinking, :shaping]

  @type agent_ctx :: %{optional(:agent_id) => term(), optional(:space_id) => term()}

  @type refusal ::
          {:error,
           :invalid_refs
           | :invalid_ask
           | :invalid_platforms
           | :not_found
           | :profile_has_no_project
           | :meeting_not_found
           | :segment_being_filed
           | :no_agent
           | :assignee_cannot_read}
          | {:error, :no_account_for_platform, [String.t()]}
          | {:error, SegmentGuard.refusal(), [String.t()]}

  @doc "The longest accepted ask."
  @spec max_ask() :: pos_integer()
  def max_ask, do: @max_ask

  @doc """
  Files (or finds, or adopts) the social task for an ask. `scope` is the
  caller's org scope (`Platform.Social.scope()`, from the agent's home org,
  never a client `org_id`); `agent_ctx` carries `agent_id` and the optional
  `space_id` the ask was heard in; `attrs` carries `profile_id`,
  `platforms`, `ask` and `refs`.

  Returns `{:ok, %{task, request, created, adopted}}` or a refusal.
  """
  @spec request(Social.scope(), agent_ctx(), map()) ::
          {:ok,
           %{
             task: Tasks.Task.t(),
             request: TaskRequest.t(),
             created: boolean(),
             adopted: boolean()
           }}
          | refusal()
  def request(scope, agent_ctx, attrs) do
    attrs = stringify(attrs)
    agent_ctx = stringify(agent_ctx)

    with {:ok, ask} <- validate_ask(attrs["ask"]),
         {:ok, platforms} <- validate_platforms(attrs["platforms"]),
         {:ok, refs} <- canonical_refs(attrs["refs"]),
         {:ok, profile} <- fetch_profile(scope, attrs["profile_id"]),
         {:ok, project} <- profile_project(profile),
         :ok <- check_platforms(scope, profile, platforms),
         {:ok, meeting} <- check_meeting(refs, profile),
         {:ok, matched} <- check_segments(refs, meeting),
         {:ok, agent} <- fetch_agent(agent_ctx["agent_id"]),
         :ok <- check_assignee(agent, project) do
      key = request_key(profile.id, refs, platforms)

      case Repo.get_by(TaskRequest, request_key: key) do
        %TaskRequest{} = existing ->
          {:ok,
           %{
             task: Tasks.get_task_record(existing.task_id),
             request: existing,
             created: false,
             adopted: not is_nil(existing.adopted_candidate_id)
           }}

        nil ->
          filing = %{
            key: key,
            ask: ask,
            platforms: platforms,
            refs: refs,
            profile: profile,
            agent: agent,
            space_id: space_id(agent_ctx["space_id"])
          }

          with {:ok, adopt} <- dedupe(matched) do
            file(filing, adopt, matched)
          end
      end
    end
  end

  # ── Input ────────────────────────────────────────────────────────────

  defp validate_ask(ask) when is_binary(ask) do
    trimmed = String.trim(ask)

    if trimmed != "" and String.length(trimmed) <= @max_ask,
      do: {:ok, trimmed},
      else: {:error, :invalid_ask}
  end

  defp validate_ask(_), do: {:error, :invalid_ask}

  defp validate_platforms(list) when is_list(list) and list != [] do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: {:ok, list |> Enum.uniq() |> Enum.sort()},
      else: {:error, :invalid_platforms}
  end

  defp validate_platforms(_), do: {:error, :invalid_platforms}

  @meeting_keys ~w(meeting_id segment_ids)
  @episode_keys ~w(end_s episode_url start_s)

  @doc """
  The canonical form of `refs`: `%{"meeting_id", "segment_ids"}` (ids
  de-duplicated and sorted) or `%{"episode_url", "start_s", "end_s"}`
  (floats). Anything else is `{:error, :invalid_refs}`.
  """
  @spec canonical_refs(term()) :: {:ok, map()} | {:error, :invalid_refs}
  def canonical_refs(refs) when is_map(refs) do
    refs = refs |> stringify() |> Map.reject(fn {_k, v} -> is_nil(v) end)

    case refs |> Map.keys() |> Enum.sort() do
      @meeting_keys -> meeting_refs(refs)
      @episode_keys -> episode_refs(refs)
      _ -> {:error, :invalid_refs}
    end
  end

  def canonical_refs(_), do: {:error, :invalid_refs}

  defp meeting_refs(%{"meeting_id" => meeting_id, "segment_ids" => ids})
       when is_binary(meeting_id) and is_list(ids) do
    ids = Enum.uniq(ids)

    if String.trim(meeting_id) != "" and ids != [] and length(ids) <= @max_segments and
         Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, %{"meeting_id" => String.downcase(meeting_id), "segment_ids" => Enum.sort(ids)}}
    else
      {:error, :invalid_refs}
    end
  end

  defp meeting_refs(_), do: {:error, :invalid_refs}

  defp episode_refs(%{"episode_url" => url, "start_s" => start_s, "end_s" => end_s})
       when is_binary(url) and is_number(start_s) and is_number(end_s) and start_s >= 0 and
              end_s > start_s do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, %{"episode_url" => url, "start_s" => start_s * 1.0, "end_s" => end_s * 1.0}}

      _ ->
        {:error, :invalid_refs}
    end
  end

  defp episode_refs(_), do: {:error, :invalid_refs}

  @doc """
  The idempotency key: sha256 of the profile id, the canonical refs and the
  sorted platforms. The wording of the ask is deliberately not in it.
  """
  @spec request_key(Ecto.UUID.t(), map(), [String.t()]) :: String.t()
  def request_key(profile_id, refs, platforms) do
    refs_part =
      case refs do
        %{"meeting_id" => m, "segment_ids" => ids} ->
          ["meeting", m | ids]

        %{"episode_url" => url, "start_s" => s, "end_s" => e} ->
          ["episode", url, Float.to_string(s), Float.to_string(e)]
      end

    [profile_id, refs_part, Enum.sort(platforms)]
    |> List.flatten()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # ── (a) profile, (b) platforms ───────────────────────────────────────

  defp fetch_profile(scope, id) do
    case Social.get_profile(scope, id) do
      %Profile{} = profile -> {:ok, profile}
      nil -> {:error, :not_found}
    end
  end

  defp profile_project(%Profile{project_id: nil}), do: {:error, :profile_has_no_project}

  defp profile_project(%Profile{project_id: project_id}) do
    case Tasks.get_project(project_id) do
      %{} = project -> {:ok, project}
      nil -> {:error, :profile_has_no_project}
    end
  end

  defp check_platforms(scope, profile, platforms) do
    live =
      scope
      |> Social.list_accounts(profile_id: profile.id)
      |> Enum.map(& &1.platform)

    case Enum.reject(platforms, &(&1 in Account.platforms() and &1 in live)) do
      [] -> :ok
      missing -> {:error, :no_account_for_platform, missing}
    end
  end

  # ── (c) meeting, (d) segments ────────────────────────────────────────

  defp check_meeting(%{"meeting_id" => meeting_id}, profile) do
    meeting = Platform.Meetings.get_meeting(meeting_id)

    if meeting && meeting_readable?(meeting, profile),
      do: {:ok, meeting},
      else: {:error, :meeting_not_found}
  end

  defp check_meeting(_episode_refs, _profile), do: {:ok, nil}

  @doc """
  RBAC SWAP POINT (meeting read): whether `profile`'s ask may cite
  `meeting`. `Platform.Access` is not on this base, so the rule is
  structural: the meeting is in the profile's project (which is in the
  profile's org). Every other case, a missing meeting included, reads as
  `:meeting_not_found`. With Access, use a scoped Meetings read here.
  """
  @spec meeting_readable?(Platform.Meetings.Meeting.t(), Profile.t()) :: boolean()
  def meeting_readable?(%{project_id: project_id}, %Profile{project_id: project_id})
      when is_binary(project_id),
      do: true

  def meeting_readable?(_meeting, _profile), do: false

  defp check_segments(%{"segment_ids" => ids}, %{id: meeting_id}),
    do: SegmentGuard.check(meeting_id, ids)

  defp check_segments(_episode_refs, nil), do: {:ok, []}

  # ── (e) assignee ─────────────────────────────────────────────────────

  defp fetch_agent(id) do
    case Platform.UUID.valid?(id) && Repo.get(Platform.Agents.Agent, id) do
      %Platform.Agents.Agent{} = agent -> {:ok, agent}
      _ -> {:error, :no_agent}
    end
  end

  defp check_assignee(agent, project) do
    if assignee_can_read?(agent, project), do: :ok, else: {:error, :assignee_cannot_read}
  end

  @doc """
  RBAC SWAP POINT (assignee): whether `agent` may be assigned a task in
  `project`. `Platform.Access` is not on this base, so the rule is core's
  agent home org (`Platform.Experiments.Tools.home_org/1`): `:root`, or
  `{:tenant, org_id}` with the project's org. With Access, this becomes
  `Access.can?(<the agent's owner-capped scope>, "tasks.read", project)`,
  matching the dispatch refusal RBAC member 7 adds to the TaskRouter.
  """
  @spec assignee_can_read?(Platform.Agents.Agent.t(), map()) :: boolean()
  def assignee_can_read?(agent, %{org_id: org_id}) do
    case Platform.Experiments.Tools.home_org(agent) do
      :root -> true
      {:tenant, ^org_id} when is_binary(org_id) -> true
      _ -> false
    end
  end

  # ── (g) the live pipeline ────────────────────────────────────────────

  defp dedupe(matched) do
    cond do
      Enum.any?(matched, &(&1.state == :acting and is_nil(&1.task_id))) ->
        {:error, :segment_being_filed}

      filed = Enum.find(matched, &filed?/1) ->
        case Tasks.get_task_record(filed.task_id) do
          %Tasks.Task{deleted_at: nil} = task -> {:ok, {filed, task}}
          _ -> {:ok, nil}
        end

      true ->
        {:ok, nil}
    end
  end

  defp filed?(c), do: c.state == :closed and c.closed_reason == :done and is_binary(c.task_id)

  # ── (h) filing ───────────────────────────────────────────────────────

  defp file(filing, adopt, matched) do
    request_id = Platform.Types.UUIDv7.generate()

    result =
      Repo.transaction(fn ->
        {task, created?, adopted_candidate_id} =
          case adopt do
            nil -> {create_task(filing, request_id), true, nil}
            {candidate, task} -> {adopt_task(task, filing, request_id), false, candidate.id}
          end

        request =
          %TaskRequest{id: request_id}
          |> TaskRequest.changeset(%{
            profile_id: filing.profile.id,
            task_id: task.id,
            request_key: filing.key,
            platforms: filing.platforms,
            refs: filing.refs,
            ask: filing.ask,
            requested_by_agent_id: filing.agent.id,
            requested_in_space_id: filing.space_id,
            adopted_candidate_id: adopted_candidate_id
          })
          |> Repo.insert()
          |> ok_or_rollback()

        {task, request, created?}
      end)

    case result do
      {:ok, {task, request, created?}} ->
        {:ok, task} = Tasks.maybe_start_planning_on_create(task)
        close_open(matched, task.id)
        {:ok, %{task: task, request: request, created: created?, adopted: not created?}}

      {:error, %Ecto.Changeset{} = changeset} ->
        # A concurrent twin of this request won the unique key: answer with
        # its task, exactly as the idempotency check would have.
        case Repo.get_by(TaskRequest, request_key: filing.key) do
          %TaskRequest{} = existing ->
            {:ok,
             %{
               task: Tasks.get_task_record(existing.task_id),
               request: existing,
               created: false,
               adopted: not is_nil(existing.adopted_candidate_id)
             }}

          nil ->
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_task(filing, request_id) do
    profile = filing.profile

    attrs = %{
      project_id: profile.project_id,
      title: "Social: " <> String.slice(filing.ask, 0, @title_ask),
      description: description(filing, nil),
      kind: "ops",
      auto_approve_plan: true,
      metadata: %{"source" => "social.request", "social" => social_meta(filing, request_id)}
    }

    # RBAC SWAP POINT (task create): pass `access_scope:` here once
    # `Platform.Tasks.create_task/2` honours it on the base (RBAC member 4).
    task = attrs |> Tasks.create_task() |> ok_or_rollback()

    task
    |> Tasks.update_task(%{description: description(filing, task.id)})
    |> ok_or_rollback()
    |> Tasks.set_phase_assignees(phases(filing.agent))
    |> ok_or_rollback()
  end

  defp adopt_task(task, filing, request_id) do
    social = social_meta(filing, request_id)
    task = merge_social(task, social, 1)

    case task.phase_assignees do
      %{"planning" => %{"assignee_id" => id}} when is_binary(id) and id != "" ->
        task

      _ ->
        task |> Tasks.set_phase_assignees(phases(filing.agent)) |> ok_or_rollback()
    end
  end

  # Merges, never replaces: the graduated task's own metadata (its
  # "source" included) survives. One retry on a concurrent write.
  defp merge_social(task, social, retries) do
    metadata = Map.update(task.metadata || %{}, "social", social, &Map.merge(&1, social))

    case Tasks.update_task_if_unmodified(task, %{metadata: metadata}, task.updated_at) do
      {:ok, task} ->
        task

      {:error, {:stale_base, _}} when retries > 0 ->
        merge_social(Tasks.get_task_record(task.id), social, retries - 1)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp social_meta(filing, request_id) do
    %{
      "profile_id" => filing.profile.id,
      "platforms" => filing.platforms,
      "refs" => filing.refs,
      "request_id" => request_id
    }
  end

  defp phases(agent) do
    one = %{"assignee_type" => "agent", "assignee_id" => agent.id}
    %{"planning" => one, "execution" => one, "review" => one}
  end

  @doc false
  def description(filing, task_id) do
    source =
      case filing.refs do
        %{"meeting_id" => m, "segment_ids" => ids} ->
          "Source: meeting #{m}, segments #{Enum.join(ids, ", ")}"

        %{"episode_url" => url, "start_s" => s, "end_s" => e} ->
          "Source: episode #{url} from #{format_s(s)}s to #{format_s(e)}s"
      end

    hint =
      case task_id do
        nil -> "Draft with social_draft_create and this task's id."
        id -> "Draft with social_draft_create task_id=#{id} profile_id=#{filing.profile.id}."
      end

    """
    #{filing.ask}

    #{source}
    Platforms: #{Enum.join(filing.platforms, ", ")}
    Profile: #{filing.profile.name} (#{filing.profile.id})

    #{hint} A human approves each post in Suite and the platform publishes it; agents cannot approve or publish.
    """
  end

  defp format_s(s) when s == trunc(s), do: Integer.to_string(trunc(s))
  defp format_s(s), do: Float.to_string(s)

  # After commit: the live pipeline must not file a second, generic task.
  defp close_open(matched, task_id) do
    for c <- matched, c.state in @open_states, is_nil(c.closed_reason) do
      case Candidates.close(c, {:duplicate, "filed as social task #{task_id}"}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Social] could not close candidate #{c.id} as duplicate of #{task_id}: #{inspect(reason)}"
          )
      end
    end

    :ok
  end

  # ── Write-back ───────────────────────────────────────────────────────

  @open_marker "<!-- social:posts -->"
  @close_marker "<!-- /social:posts -->"

  @doc """
  Settles the social task of `post_id` once all its drafts are terminal
  (see the moduledoc). Returns `:noop` (no task, no request row, or an
  identical settlement already written), `:not_settled` (a draft is still
  pending), `:settled` (written), or `:ok` after an error, which is logged:
  this runs after the post's own write committed and never raises.
  """
  @spec post_changed(term()) :: :noop | :not_settled | :settled | :ok
  def post_changed(post_id) do
    with %Social.Post{task_id: task_id} when is_binary(task_id) <- get_post(post_id),
         %TaskRequest{} = request <- request_for_task(task_id) do
      settle(request)
    else
      _ -> :noop
    end
  rescue
    error ->
      Logger.error("[Social] task write-back for post #{inspect(post_id)}: #{inspect(error)}")
      :ok
  catch
    kind, reason ->
      Logger.error(
        "[Social] task write-back for post #{inspect(post_id)}: #{inspect({kind, reason})}"
      )

      :ok
  end

  defp get_post(id) do
    if Platform.UUID.valid?(id), do: Repo.get(Social.Post, id)
  end

  defp settle(%TaskRequest{id: id}) do
    {:ok, result} =
      Repo.transaction(fn ->
        # Serialises concurrent settlements of one task.
        request = Repo.one(from(r in TaskRequest, where: r.id == ^id, lock: "FOR UPDATE"))
        profile = Repo.get!(Profile, request.profile_id)
        posts = Social.list_posts(profile.org_id, task_id: request.task_id)
        accounts = posts |> Enum.map(& &1.account_id) |> accounts_by_id(profile.org_id)
        entries = Enum.map(posts, &entry(&1, Map.fetch!(accounts, &1.account_id)))

        cond do
          entries == [] or Enum.any?(entries, &(&1["outcome"] == "pending")) ->
            :not_settled

          digest(entries) == request.settled_digest ->
            :noop

          true ->
            write(request, entries)
        end
      end)

    result
  end

  defp accounts_by_id(ids, org_id) do
    ids
    |> Enum.uniq()
    |> Map.new(fn id -> {id, Social.get_account(org_id, id)} end)
  end

  @doc false
  # One post's line in the record.
  def entry(%Social.Post{} = post, %Account{} = account) do
    %{
      "post_id" => post.id,
      "account_id" => account.id,
      "platform" => account.platform,
      "handle" => account.handle,
      "outcome" => outcome(post, account),
      "external_url" => post.external_url,
      "error" => post.error,
      "rejection_reason" => post.rejection_reason
    }
  end

  defp outcome(%Social.Post{status: "published"}, _account), do: "published"
  defp outcome(%Social.Post{status: "failed"}, _account), do: "failed"

  defp outcome(%Social.Post{} = post, account) do
    cond do
      Social.Post.rejected?(post) -> "rejected"
      account.approval_mode == "draft_only" -> "manual"
      true -> "pending"
    end
  end

  # No vendor returns engagement stats today, so entries carry no "stats" key.
  # When one does, store them with the post's outcome and add the key in
  # entry/2 (the moduledoc's settled-record shape).

  @doc false
  def digest(entries) do
    entries
    |> Enum.sort_by(& &1["post_id"])
    |> Enum.map(fn entry -> entry |> Enum.sort() |> Enum.map(&Tuple.to_list/1) end)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp write(request, entries) do
    entries = Enum.sort_by(entries, & &1["post_id"])
    digest = digest(entries)

    record = %{
      "settled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "posts" => entries
    }

    case write_task(Tasks.get_task_record(request.task_id), record, entries, 1) do
      {:ok, _task} ->
        request |> TaskRequest.settled_changeset(digest) |> Repo.update!()
        :settled

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # RBAC SWAP POINT (write-back): `Platform.Access` is not on this base. Once
  # it is AND `update_task_if_unmodified/4` honours `access_scope:`, pass
  # `access_scope: Platform.Access.Scope.system()`: the writer is the
  # platform acting on a webhook or a human decision, not the agent.
  defp write_task(nil, _record, _entries, _retries), do: {:error, :task_not_found}

  defp write_task(task, record, entries, retries) do
    metadata = task.metadata || %{}
    social = Map.put(metadata["social"] || %{}, "result", record)

    attrs = %{
      metadata: Map.put(metadata, "social", social),
      description: put_block(task.description, block(entries))
    }

    case Tasks.update_task_if_unmodified(task, attrs, task.updated_at) do
      {:error, {:stale_base, _}} when retries > 0 ->
        write_task(Tasks.get_task_record(task.id), record, entries, retries - 1)

      other ->
        other
    end
  end

  @doc false
  def block(entries) do
    lines =
      Enum.map(entries, fn e ->
        who = String.upcase(e["platform"] || "") <> handle(e["handle"])

        what =
          case e["outcome"] do
            "published" -> e["external_url"] || "published (no URL returned)"
            "failed" -> "failed: #{e["error"]}"
            "rejected" -> "rejected: #{e["rejection_reason"]}"
            "manual" -> "draft only, to post by hand"
            # Never written (a pending post means no settlement); total so
            # the settle gate above is the only thing that stops a write.
            _ -> "awaiting a human"
          end

        "- #{who}: #{what}"
      end)

    Enum.join([@open_marker | lines] ++ [@close_marker], "\n")
  end

  defp handle(nil), do: ""
  defp handle(""), do: ""
  defp handle(h), do: " @" <> String.trim_leading(h, "@")

  @doc """
  `description` with the ONE managed posts block set to `block`: an
  existing block is replaced in place (any further copies dropped); with
  none, stray markers left by a human edit are removed and the block is
  appended. Never two blocks.
  """
  @spec put_block(String.t() | nil, String.t()) :: String.t()
  def put_block(description, block) do
    description = description || ""
    re = ~r/<!-- social:posts -->.*?<!-- \/social:posts -->/s

    case Regex.run(re, description, return: :index) do
      [{start, len}] ->
        prefix = binary_part(description, 0, start)
        suffix = binary_part(description, start + len, byte_size(description) - start - len)
        strip_markers(prefix) <> block <> strip_markers(Regex.replace(re, suffix, ""))

      nil ->
        case String.trim_trailing(strip_markers(description)) do
          "" -> block <> "\n"
          text -> text <> "\n\n" <> block <> "\n"
        end
    end
  end

  defp strip_markers(text),
    do: text |> String.replace(@open_marker, "") |> String.replace(@close_marker, "")

  # ── Shared ───────────────────────────────────────────────────────────

  defp ok_or_rollback({:ok, value}), do: value
  defp ok_or_rollback({:error, reason}), do: Repo.rollback(reason)
  defp ok_or_rollback({:error, reason, _details}), do: Repo.rollback(reason)

  defp space_id(id) do
    if Platform.UUID.valid?(id) and Platform.Chat.get_space(id), do: id, else: nil
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  @doc """
  The request row for `task_id`, or nil (used by the draft link check and
  the write-back).
  """
  @spec request_for_task(term()) :: TaskRequest.t() | nil
  def request_for_task(task_id) do
    if Platform.UUID.valid?(task_id),
      do: Repo.one(from(r in TaskRequest, where: r.task_id == ^task_id))
  end
end
