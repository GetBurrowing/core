defmodule Platform.Social.Tools do
  @moduledoc """
  Behaviour of the `social` bundle's tools (task 01a140a9-4c70, Social 4/7);
  definitions in `Platform.Social.ToolDefinitions`. Core dispatches here
  through the extension fallback in `ToolSurface.execute/3`, which puts the
  calling agent's home org in the context (`:agent_home_org`).

  ## Scope comes from the agent

  A call with no agent (no `agent_id` that loads an `agents` row) is refused
  with `no_agent`; it never falls through to `:root`. The scope is the
  context's `:agent_home_org` (core's rule), and every decision on it is
  `Platform.Social.visible_orgs/1`, the `RBAC SWAP POINT`. A client `org_id`
  only narrows `social_profile_list`, and only within that scope.

  ## No publish, no approve

  Writes go through `Platform.Social.AgentDrafts`, whose ceiling is
  `needs_approval`. `social_task_request` (Social 6/7) files a task through
  `Platform.Social.TaskBridge`, assigned to the calling agent; the agent
  and space come from the context, never from arguments. Refusals are Play-style envelopes
  `%{error, code, recoverable, suggestion}`; each status or lock refusal
  repeats that a human approves and the platform publishes.
  """

  alias Platform.Federation.ResultBound
  alias Platform.Social
  alias Platform.Social.{Account, AgentDrafts, Clip, Post, Profile, TaskBridge, ToolDefinitions}

  @human ToolDefinitions.human_approves()

  @spec execute(String.t(), map(), map()) :: {:ok, map()} | {:error, map()}
  def execute(tool, args, context) do
    args = if is_map(args), do: args, else: %{}
    context = if is_map(context), do: context, else: %{}

    cond do
      tool == "social_task_request" ->
        with {:ok, scope} <- scope(context), do: task_request(args, scope, context)

      tool in ToolDefinitions.names() ->
        with {:ok, scope} <- scope(context), do: run(tool, args, scope)

      true ->
        {:error, unknown_tool(tool)}
    end
  end

  # ── Social 6/7: social_task_request ──────────────────────────────────

  @ref_keys ~w(meeting_id segment_ids episode_url start_s end_s)

  # The agent comes from the context and a client org_id is ignored (the
  # scope is the agent's home org). Core's context takes `space_id` from the
  # call's arguments (`Platform.Federation.ToolCall.build_context/2`), so it
  # is recorded only when the calling agent is a participant of that space.
  defp task_request(args, scope, context) do
    agent = agent(context)
    agent_ctx = %{agent_id: agent.id, space_id: heard_in(context, agent)}

    attrs = %{
      "profile_id" => args["profile_id"],
      "platforms" => args["platforms"],
      "ask" => args["ask"],
      "refs" => Map.take(args, @ref_keys)
    }

    case TaskBridge.request(scope, agent_ctx, attrs) do
      {:ok, %{task: task, created: created}} ->
        {:ok,
         %{
           task_id: task.id,
           created: created,
           status: task.status,
           profile_id: attrs["profile_id"],
           platforms: task.metadata["social"]["platforms"],
           hint:
             "Draft the posts with social_draft_create task_id=#{task.id} profile_id=#{attrs["profile_id"]}. " <>
               @human
         }}

      error ->
        {:error, task_error(error)}
    end
  end

  defp heard_in(%{agent_participant_id: id, space_id: space_id}, _agent)
       when is_binary(id) and is_binary(space_id),
       do: space_id

  defp heard_in(%{space_id: space_id}, agent) when is_binary(space_id) do
    if Platform.UUID.valid?(space_id) and Platform.Chat.get_agent_participant(space_id, agent.id),
      do: space_id
  end

  defp heard_in(_context, _agent), do: nil

  defp task_error({:error, :invalid_refs}) do
    err(
      :invalid_refs,
      "invalid refs: cite EITHER meeting_id with 1 to 50 segment_ids OR episode_url (http/https) with 0 <= start_s < end_s",
      true,
      "Pass exactly one kind of source."
    )
  end

  defp task_error({:error, :invalid_ask}) do
    err(
      :invalid_argument,
      "ask must be non-blank and at most #{TaskBridge.max_ask()} characters",
      true,
      "Pass the human's request in their words."
    )
  end

  defp task_error({:error, :invalid_platforms}) do
    err(
      :invalid_argument,
      "platforms must be a non-empty list of platform names",
      true,
      "Call social_profile_get for the profile's account platforms."
    )
  end

  defp task_error({:error, :not_found}), do: not_found("profile")

  defp task_error({:error, :profile_has_no_project}) do
    err(
      :profile_has_no_project,
      "the profile has no project, so there is nowhere to file the task",
      false,
      "Ask a human to set the profile's project."
    )
  end

  defp task_error({:error, :no_account_for_platform, platforms}) do
    err(
      :no_account_for_platform,
      "no live account on the profile for: #{Enum.join(platforms, ", ")}",
      true,
      "Call social_profile_get for the profile's account platforms."
    )
  end

  defp task_error({:error, :meeting_not_found}) do
    err(
      :meeting_not_found,
      "meeting not found in the profile's project",
      false,
      "Cite a meeting in the profile's project, or the episode by URL and time."
    )
  end

  defp task_error({:error, :segment_unclassified, ids}) do
    err(
      :segment_unclassified,
      "not classified yet: #{Enum.join(ids, ", ")}",
      true,
      "Retry shortly, or cite the episode by URL and time."
    )
  end

  defp task_error({:error, :segment_off_topic, ids}) do
    err(
      :segment_off_topic,
      "these segments were classed off-topic, so no social task is filed: #{Enum.join(ids, ", ")}",
      false,
      "Drop them; a social ask needs an on-topic segment."
    )
  end

  defp task_error({:error, :segment_retracted, ids}) do
    err(
      :segment_retracted,
      "these segments were retracted or stopped by a human, so no social task is filed: #{Enum.join(ids, ", ")}",
      false,
      "Do not file it; the human took the ask back."
    )
  end

  defp task_error({:error, :segment_being_filed}) do
    err(
      :segment_being_filed,
      "the meeting pipeline is filing a task for these segments right now",
      true,
      "Retry shortly: the filed task will be adopted."
    )
  end

  defp task_error({:error, :assignee_cannot_read}) do
    err(
      :assignee_cannot_read,
      "you cannot read the profile's project, so the task cannot be assigned to you",
      false,
      "Ask a human to file it, or to give your agent access to the project."
    )
  end

  defp task_error({:error, :no_agent}), do: no_agent()
  defp task_error(other), do: error_envelope(other)

  defp no_agent do
    err(
      :no_agent,
      "no agent: social tools act only for an agent",
      false,
      "Call through an agent runtime's MCP token or channel."
    )
  end

  # ── Scope ────────────────────────────────────────────────────────────

  defp scope(context) do
    case agent(context) do
      nil ->
        {:error, no_agent()}

      agent ->
        {:ok, home_org(context, agent)}
    end
  end

  defp agent(%{agent: %Platform.Agents.Agent{} = agent}), do: agent

  defp agent(%{agent_id: id}) when is_binary(id) do
    if Platform.UUID.valid?(id), do: Platform.Repo.get(Platform.Agents.Agent, id)
  end

  defp agent(_), do: nil

  # Core's seam always sets this from the agent; the fallback (core's public
  # twin of the same rule) covers a direct call.
  defp home_org(%{agent_home_org: :root}, _agent), do: :root
  defp home_org(%{agent_home_org: {:tenant, id} = home}, _agent) when is_binary(id), do: home
  defp home_org(_context, agent), do: Platform.Experiments.Tools.home_org(agent)

  # ── Tools ────────────────────────────────────────────────────────────

  defp run("social_profile_list", args, scope) do
    org_id =
      case blank_to_nil(args["org_id"]) && Ecto.UUID.cast(args["org_id"]) do
        {:ok, id} -> id
        _ -> blank_to_nil(args["org_id"])
      end

    if org_id && not Social.org_visible?(scope, org_id) do
      {:error,
       err(
         :unauthorized,
         "unauthorized: not a member of org #{org_id}",
         false,
         "Drop org_id, or pass your own org. Your org comes from your agent."
       )}
    else
      profiles =
        scope
        |> Social.list_profiles()
        |> Enum.filter(&(org_id == nil or &1.org_id == org_id))
        |> Enum.map(&profile_json(&1, scope, false))

      {:ok, ResultBound.whole(:profiles, profiles)}
    end
  end

  defp run("social_profile_get", args, scope) do
    case Social.get_profile(scope, args["profile_id"]) do
      %Profile{} = profile -> {:ok, profile_json(profile, scope, true)}
      nil -> {:error, not_found("profile")}
    end
  end

  defp run("social_draft_create", args, scope) do
    attrs = Map.drop(args, ["profile_id", "org_id"])

    case AgentDrafts.create_agent_drafts(scope, args["profile_id"], attrs) do
      {:ok, posts} -> {:ok, %{posts: Enum.map(posts, &post_json/1), count: length(posts)}}
      error -> {:error, error_envelope(error)}
    end
  end

  defp run("social_draft_update", args, scope) do
    attrs = Map.drop(args, ["post_id", "org_id"])

    case AgentDrafts.update_agent_draft(scope, args["post_id"], attrs) do
      {:ok, post} -> {:ok, %{post: post_json(post)}}
      error -> {:error, error_envelope(error)}
    end
  end

  defp run("social_post_list", args, scope) do
    case Social.get_profile(scope, args["profile_id"]) do
      %Profile{} = profile ->
        {limit, offset} = ResultBound.page(args)

        filters = [
          profile_id: profile.id,
          status: blank_to_nil(args["status"]),
          refused: args["refused"] == true
        ]

        posts = Social.list_posts(scope, filters)
        page = posts |> Enum.drop(offset) |> Enum.take(limit) |> Enum.map(&post_json/1)

        {:ok,
         ResultBound.paged(:posts, page, length(posts), offset, %{limit: limit, offset: offset})}

      nil ->
        {:error, not_found("profile")}
    end
  end

  defp run("social_clip_propose", args, scope) do
    attrs =
      Map.take(
        args,
        ~w(source_url source_file_id transcript_file_id start_s end_s caption speaker crop_x platforms)
      )

    case AgentDrafts.propose_clip(scope, args["profile_id"], attrs) do
      {:ok, clip} -> {:ok, %{clip: clip_json(clip)}}
      error -> {:error, error_envelope(error)}
    end
  end

  # Social 5/7. Enqueues and returns: the render runs in Social's queue,
  # never in this tool-call process.
  defp run("social_clip_render", args, scope) do
    opts = %{"platforms" => args["platforms"], "force" => args["force"] == true}

    case Social.render_clip(scope, args["clip_id"], opts) do
      {:ok, clip} -> {:ok, %{clip: clip_json(clip)}}
      error -> {:error, error_envelope(error)}
    end
  end

  defp run("social_clip_list", args, scope) do
    case Social.get_profile(scope, args["profile_id"]) do
      %Profile{} = profile ->
        {limit, offset} = ResultBound.page(args)

        clips =
          Social.list_clips(scope, profile_id: profile.id, status: blank_to_nil(args["status"]))

        page = clips |> Enum.drop(offset) |> Enum.take(limit) |> Enum.map(&clip_json/1)

        {:ok,
         ResultBound.paged(:clips, page, length(clips), offset, %{limit: limit, offset: offset})}

      nil ->
        {:error, not_found("profile")}
    end
  end

  # ── Envelopes ────────────────────────────────────────────────────────

  defp error_envelope({:error, :already_rendering}) do
    err(
      :already_rendering,
      "already rendering: this clip is in the render queue",
      true,
      "Poll social_clip_list until its status is rendered or failed."
    )
  end

  defp error_envelope({:error, :already_rendered}) do
    err(
      :already_rendered,
      "already rendered: pass force true to render it again",
      true,
      "Use its render_file_id, or call again with force true."
    )
  end

  defp error_envelope({:error, :profile_needs_project}) do
    err(
      :profile_needs_project,
      Social.profile_needs_project(),
      false,
      "Ask a human to set the profile's project (one in the profile's org)."
    )
  end

  defp error_envelope({:error, :invalid_source}) do
    err(
      :invalid_source,
      "give EITHER source_url OR source_file_id with transcript_file_id",
      true,
      "Pass one source kind; a file source needs both file ids."
    )
  end

  defp error_envelope({:error, :source_not_in_project}) do
    err(
      :source_not_in_project,
      "the source video and transcript must be files in the profile's project",
      true,
      "Upload them to the profile's project in Burrow Files and pass those ids."
    )
  end

  defp error_envelope({:error, :invalid_crop_x}) do
    err(:invalid_argument, "crop_x must be a number from 0 to 1", true, "Omit it for the centre.")
  end

  defp error_envelope({:error, {:invalid_platforms, bad}}) do
    err(
      :invalid_argument,
      "platforms must be among the profile's accounts; not available: #{Enum.join(bad, ", ")}",
      true,
      "Call social_profile_get for the profile's account platforms."
    )
  end

  defp error_envelope({:error, :status_not_allowed}) do
    err(
      :status_not_allowed,
      "status not allowed: an agent may set only draft or needs_approval. " <> @human,
      true,
      "Omit status (it defaults to needs_approval) or pass draft."
    )
  end

  defp error_envelope({:error, :field_not_allowed, fields}) do
    err(
      :field_not_allowed,
      "field not allowed: #{Enum.join(fields, ", ")}. Approval, publishing and rejection fields are written by Burrow, never by an agent. " <>
        @human,
      true,
      "Drop #{Enum.join(fields, ", ")} and retry."
    )
  end

  defp error_envelope({:error, :post_locked}) do
    err(
      :post_locked,
      "post locked: it is past needs_approval and can no longer be edited by an agent. " <>
        @human,
      false,
      "Draft a new post with social_draft_create if a change is needed."
    )
  end

  defp error_envelope({:error, :not_found}), do: not_found("profile, account, post or clip")

  defp error_envelope({:error, :task_profile_mismatch}) do
    err(
      :task_profile_mismatch,
      "that task is a social task for another profile; nothing was written",
      false,
      "Draft for the task's own profile (task_get shows it), or drop task_id."
    )
  end

  defp error_envelope({:error, :invalid_range}) do
    err(
      :invalid_range,
      "invalid range: start_s and end_s must be numbers with 0 <= start_s < end_s",
      true,
      "Pass start_s and end_s in seconds, end after start."
    )
  end

  defp error_envelope({:error, :invalid_source_url}) do
    err(
      :invalid_argument,
      "source_url must be an http or https URL",
      true,
      "Pass the episode's full URL."
    )
  end

  defp error_envelope({:error, :no_accounts}) do
    err(
      :invalid_argument,
      "account_ids must name at least one of the profile's accounts",
      true,
      "Call social_profile_get for the profile's account ids."
    )
  end

  defp error_envelope({:error, :account_archived}) do
    err(
      :account_archived,
      "an account is archived and takes no new posts; nothing was created",
      true,
      "Drop the archived account from account_ids."
    )
  end

  defp error_envelope({:error, :profile_has_no_channel}) do
    err(
      :profile_has_no_channel,
      "the profile has no channel for approval cards, so a post cannot wait for approval; nothing was written",
      true,
      "Save it as status draft, or ask a human to set the profile's channel."
    )
  end

  defp error_envelope({:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    :invalid_argument
    |> err(
      "invalid: " <> Enum.map_join(errors, "; ", fn {k, v} -> "#{k} #{Enum.join(v, ", ")}" end),
      true,
      "Fix the named fields and retry."
    )
    |> Map.put(:errors, errors)
  end

  defp error_envelope(other),
    do: err(:failed, "social tool failed: #{inspect(other)}", false, "Report this.")

  defp not_found(what),
    do: err(:not_found, "#{what} not found", false, "Check the id with social_profile_list.")

  defp unknown_tool(tool) do
    err(
      :unknown_tool,
      "Unknown tool: #{tool}. There is no publish or approve tool: a human approves in Burrow and the platform publishes.",
      false,
      "The social tools are #{Enum.join(ToolDefinitions.names(), ", ")}."
    )
  end

  defp err(code, error, recoverable, suggestion),
    do: %{error: error, code: code, recoverable: recoverable, suggestion: suggestion}

  # ── JSON ─────────────────────────────────────────────────────────────

  defp profile_json(%Profile{} = p, scope, full?) do
    accounts =
      scope
      |> Social.list_accounts(profile_id: p.id)
      |> Enum.map(&account_json/1)

    base = %{
      id: p.id,
      org_id: p.org_id,
      name: p.name,
      home_url: p.home_url,
      default_hashtags: p.default_hashtags,
      accounts: accounts
    }

    if full?, do: Map.put(base, :voice_notes, p.voice_notes), else: base
  end

  # Never secret_slug, provider refs or anything credential-shaped.
  defp account_json(%Account{} = a),
    do: %{
      id: a.id,
      platform: a.platform,
      handle: a.handle,
      approval_mode: a.approval_mode,
      status: a.status
    }

  defp post_json(%Post{} = p) do
    Map.take(p, [
      :id,
      :account_id,
      :status,
      :body,
      :link_url,
      :media_file_ids,
      :scheduled_at,
      :error,
      :rejection_reason,
      :rejected_at,
      :refused_reason,
      :refused_at,
      :retry_after,
      :approved_at,
      :task_id,
      :meeting_id,
      :segment_ids,
      :episode_url,
      :start_s,
      :end_s,
      :inserted_at,
      :updated_at
    ])
  end

  defp clip_json(%Clip{} = c),
    do:
      Map.take(c, [
        :id,
        :profile_id,
        :status,
        :error,
        :source_url,
        :source_file_id,
        :transcript_file_id,
        :requested_start_s,
        :requested_end_s,
        :start_s,
        :end_s,
        :caption,
        :speaker,
        :crop_x,
        :platforms,
        :render_file_id,
        :duration_s,
        :width,
        :height,
        :byte_size,
        :attempts,
        :rendered_at
      ])

  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank_to_nil(_), do: nil
end
