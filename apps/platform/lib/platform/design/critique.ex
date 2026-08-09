defmodule Platform.Design.Critique do
  @moduledoc """
  Synchronous, agent-callable entry point for `design.critique`
  (task `019fe844` stage 2).

  ## Why a second entry point exists at all

  `design.critique` is a `chat_pattern` responsibility, and
  `Platform.Responsibilities.Router.maybe_fire_chat_patterns/3` drops any
  message whose `author_participant_type == "agent"`. That guard is a
  feedback-loop defence — without it an agent's own reply can re-fire the
  responsibility that produced it — and it is CORRECT. But every consumer
  of this responsibility is an agent reviewer following the reviewer
  dispatch template, so the chat path is unreachable from the only caller
  that exists. Renaming the handle (stage 1) moved that defect rather than
  fixing it.

  The answer is not to weaken the guard. It is this: a plain function the
  reviewer calls, which returns the verdict to the caller and lands it on
  the artefacts a human actually reads.

  ## The synchronous return IS the primary landing

  A critique posted into a channel and nowhere else is indistinguishable
  from no critique — nobody re-reads the channel. So `request/1` returns
  the parsed verdict to its caller, and `land_verdict/2` additionally
  attaches it to the pending review request (the surface the human
  dispositions) and logs it to the execution space (audit trail). The two
  landings are independent and best-effort: neither can take the other
  down, and neither can take the return value down. Same posture
  `Handlers.ArchitectureReviewPlan` takes between its gate settlement and
  its annotation post.

  ## Where the chat landing goes, and why it is never nowhere

  `land_verdict/2` resolves ONE space from either `:space_id` (what the
  chat trigger meta supplies, and the only key it supplies) or `:task_id`
  (what the tool path supplies), preferring `:space_id` when both are
  present because that is the channel the human is actually reading.

  An execution space gets `post_log/2` — the audit-trail posture, log-only
  because nobody is sitting in an execution space waiting to be answered.
  An ORDINARY channel gets a visible `post_engagement/3` message instead.
  A log-only message reads as chrome, and somebody typed `@saru critique`
  in that channel and is waiting on a reply; answering them invisibly is
  the same failure as not answering. The one outcome ruled out is the
  silent no-op that shipped before: an earlier cut consumed only
  `:task_id`, so every human-typed critique — which carries no task_id at
  all — was dropped without a trace while the tool path stayed green. The
  unit suite could not see it because every test exercised the tool path.
  The space-only shape is now pinned by its own detectors.

  ## Errors reach the CALLER, never a log line

  `:responsibility_unfilled`, `:no_canvas_resolved` and friends are
  returned, not swallowed. A reviewer that cannot obtain a design review
  needs to know that, so it can say so in its own review request — which
  is exactly the escape hatch the dispatch template describes. A logged
  refusal reads as silence to the caller, and silence is what produced the
  false "design review NOT obtained" record this task exists to fix.

  ## `dispatch_space_id`: this key honours the trigger space, and
  `design.task_direction` does not — deliberately

  The two handlers in this feature resolve the same field from opposite
  sources, and the divergence is a decision rather than drift.
  `Handlers.DesignTaskDirection` refuses to read `trigger_meta[:space_id]`
  because it fires on `task:planning_started`, an event nobody addressed
  to anybody: the space id in its trigger payload is incidental, and
  honouring it would auto-invite the Designer into whatever channel
  happened to be in scope. `design.critique` fires only when someone
  ADDRESSED SARU BY NAME — a human typing `@saru critique …` in a channel,
  or an agent passing an explicit `:space_id` to `request/1`. The space is
  not incidental there; it is the second half of the request, and the
  responsibility is `per_space` precisely because "critique this, here" is
  the whole ask. Inviting an assignee into a space you explicitly summoned
  it into is consent, not leakage.

  The rule the two share, and the one that actually matters: never invite
  from a space id that nobody named. They disagree about which spaces
  count as named because their triggers differ, not because one of them is
  wrong. See the mirrored paragraph in `DesignTaskDirection`.
  """

  require Logger

  alias Platform.Chat
  alias Platform.Design.Critique.Verdict
  alias Platform.ExternalAgents.Dispatcher, as: ExternalDispatcher
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.DesignCritique
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Tasks.ReviewRequests

  @key "design.critique"
  @review_item_label "Design review (Saru)"

  @doc """
  Obtain a design critique of one canvas, synchronously.

  Recognised keys: `:canvas_id`, `:note`, `:task_id`, `:review_request_id`,
  `:space_id`, `:requested_by`.

  Returns `{:ok, %{issues: [...], raw: binary(), unparseable?: boolean(),
  review_item_id: binary() | nil}}` or `{:error, term()}`.
  """
  @spec request(map()) :: {:ok, map()} | {:error, term()}
  def request(args) when is_map(args) do
    with {:ok, responsibility} <- load_responsibility(),
         {:ok, agent} <- resolve_external_assignee(),
         {:ok, context} <- DesignCritique.gather_context(responsibility, args),
         {:ok, prompt} <- DesignCritique.build_prompt(context),
         {:ok, output} <- dispatch(responsibility, agent, context, prompt) do
      parsed = Verdict.parse(output)

      {:ok, Map.put(parsed, :review_item_id, land_verdict(parsed, args))}
    end
  end

  def request(_args), do: {:error, :invalid_arguments}

  @doc """
  Deliver a parsed critique to the two places a human might read it.

  Both landings are best-effort and INDEPENDENT — a missing review
  request must not stop the execution-space log, and an unresolvable
  execution space must not stop the review item. Returns the id of the
  review item created, or `nil` when none was.

  Shared by the synchronous path above and the handler's asynchronous
  `handle_output/3`, so the two can never drift into delivering
  differently.
  """
  @spec land_verdict(map(), map()) :: binary() | nil
  def land_verdict(parsed, opts) when is_map(parsed) and is_map(opts) do
    rendered = Verdict.render(parsed)

    item_id = land_on_review_request(rendered, fetch(opts, :review_request_id))
    _ = land_in_space(rendered, fetch(opts, :space_id), fetch(opts, :task_id))

    item_id
  end

  def land_verdict(_parsed, _opts), do: nil

  # ── Resolution ────────────────────────────────────────────────────────────

  defp load_responsibility do
    case Responsibilities.get_by_key(@key) do
      %Responsibility{} = row -> {:ok, row}
      _ -> {:error, :responsibility_not_registered}
    end
  end

  # Override-aware (`responsibility_overrides` first, then the role
  # bundle), so a Control Center override reaches this path exactly as it
  # reaches the Router's.
  defp resolve_external_assignee do
    case Roles.assignee_for(@key) do
      nil ->
        {:error, :responsibility_unfilled}

      %{kind: "external"} = agent ->
        {:ok, agent}

      %{kind: kind} ->
        # Not a silent no-op. The native path is the Router's
        # fire-and-forget signal business; this function promised its
        # caller a verdict and a native assignee cannot supply one
        # synchronously.
        {:error, {:assignee_not_external, kind}}
    end
  end

  # Mirrors `Router.safe_dispatch/4`: a transport blow-up is an error
  # value to the requesting agent, not an exit that takes its whole tool
  # call down.
  defp dispatch(responsibility, agent, context, %{system: system, user: user}) do
    messages = [
      %{role: "system", content: system},
      %{role: "user", content: user}
    ]

    ExternalDispatcher.dispatch(responsibility, agent, context, messages: messages)
  rescue
    error -> {:error, {:dispatch_raised, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:dispatch_exited, reason}}
  end

  # ── Landings ──────────────────────────────────────────────────────────────

  defp land_on_review_request(rendered, request_id)
       when is_binary(request_id) and request_id != "" do
    case ReviewRequests.add_item(request_id, %{
           label: @review_item_label,
           content: rendered
         }) do
      {:ok, item} ->
        item.id

      {:error, reason} ->
        Logger.info(
          "[design.critique] could not attach critique to review request " <>
            "#{request_id} (#{inspect(reason)}) — verdict still returned to caller"
        )

        nil
    end
  rescue
    error ->
      Logger.warning(
        "[design.critique] review-request landing raised " <>
          "(#{inspect(error.__struct__)}); verdict still returned to caller"
      )

      nil
  end

  defp land_on_review_request(_rendered, _request_id), do: nil

  # `:space_id` is what the CHAT path supplies, and it is the only key it
  # supplies — see the moduledoc. `:task_id` is what the tool path
  # supplies. Resolve either into one space and post there; a caller that
  # names both gets the space it named, because the human who typed the
  # handle is reading THAT channel.
  defp land_in_space(rendered, space_id, task_id) do
    case resolve_space(space_id, task_id) do
      %{id: id, kind: "execution"} ->
        ExecutionSpace.post_log(id, rendered)
        :ok

      %{id: id} ->
        # An ordinary channel: log-only messages read as chrome there, and
        # the person who asked has to be able to READ the answer.
        ExecutionSpace.post_engagement(id, rendered,
          metadata: %{"source" => "design.critique", "kind" => "critique"}
        )

        :ok

      nil ->
        Logger.info(
          "[design.critique] no space resolved (space_id=#{inspect(space_id)}, " <>
            "task_id=#{inspect(task_id)}) — skipping the chat landing"
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("[design.critique] chat landing raised (#{inspect(error.__struct__)})")

      :ok
  end

  defp resolve_space(space_id, task_id) do
    space_by_id(space_id) || space_by_task(task_id)
  end

  defp space_by_id(space_id) when is_binary(space_id) and space_id != "",
    do: Chat.get_space(space_id)

  defp space_by_id(_space_id), do: nil

  defp space_by_task(task_id) when is_binary(task_id) and task_id != "",
    do: ExecutionSpace.find_by_task_id(task_id)

  defp space_by_task(_task_id), do: nil

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(_map, _key), do: nil
end
