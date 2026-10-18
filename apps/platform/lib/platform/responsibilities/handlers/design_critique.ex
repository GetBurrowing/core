defmodule Platform.Responsibilities.Handlers.DesignCritique do
  @moduledoc """
  `design.critique` responsibility provider (task `019fe844` stage 1).

  Critiques an existing canvas. Shipped as a registration-only stub in
  task 019f2455; this revision fills in the real context and prompt so a
  fire reaches the model with a canvas actually attached to it.

  ## Spec

    * `key` — `"design.critique"`
    * `feature` — `"design"`
    * `trigger_kind` — `chat_pattern`, `(?i)@designer\\s+(critique|review)\\b`
      with an optional trailing canvas id / canvas URL capture
    * `scope` — `per_space`
    * `context_provided` — `["canvas_snapshot", "grounding_notes"]`
    * `default_prompt_template` — `"design.critique.v1"`
    * `cost_profile` — `low_freq_capable`

  ## The trigger names the role, and no agent handle is kept as an alias

  The rule this module now encodes: the chat trigger addresses the
  DESIGNER ROLE, and no agent handle — `@vega`, `@saru`, or any future
  holder's — is kept as an alias. The history of why is below, and it is
  the reasoning that generalises.

  No dispatch template, doc, seed or runbook ever instructed anyone to
  type `@vega`. The handle existed only in this module's stub trigger —
  the bug being fixed — so keeping it as an alias would preserve a name
  whose sole source is the defect. Dropped outright.

  The generalisation, which is what the trigger now encodes: a handle names
  a PERSON, a token names the JOB — and the job is what the trigger means.
  So the trigger addresses `@designer`, and no agent handle appears in it at
  all; `@saru` was only ever correct by luck, one reassignment from being the
  same stale name as `@vega`.

  ## An unresolvable canvas is a REFUSAL, never an empty dispatch

  `gather_context/2` resolves the target canvas in three steps:

    1. an explicit `ctx[:canvas_id]`,
    2. a canvas id captured by the chat trigger regex (the human pasted
       an id or a canvas URL after the verb),
    3. the most recently updated canvas in `ctx[:space_id]`.

  If none of the three resolves it returns `{:error, :no_canvas_resolved}`
  and the Router's `refuse_dispatch/5` arm logs, emits
  `:context_gather_refused` telemetry and bills no model call. Critique
  with no artefact under critique is not a degraded answer, it is a
  fabricated one.

  `grounding_notes` is the asymmetric slot and NEVER refuses — the same
  asymmetry `Handlers.ArchitectureReviewPlan` documents between
  `:plan_payload` and `:sibling_tasks`. A requester who pasted a canvas
  and typed nothing else has asked a complete question.

  ## Why this handler owns `build_prompt/1`

  Without the callback the Router falls to the legacy DB-template path
  and renders `design.critique.v1`, whose seeded body also says "You are
  Vega" — and prod template rows are hand-edited live via the
  `prompt_template_update` MCP tool, so no PR can guarantee the DB body.
  Owning `build_prompt/1` makes the Router take its `{:messages, _}`
  branch and skips `abort_prompt_absent/4` entirely. Same shape as
  `Handlers.DesignTaskDirection` and `Handlers.ArchitectureReviewPlan`.

  ## `dispatch_space_id` comes from the TRIGGER space here, and from the
  ## resolved task in `Handlers.DesignTaskDirection` — deliberately

  The two handlers in this feature resolve the same field from opposite
  sources. That is a settled decision, not drift, and it is recorded in
  both moduledocs so the next reader does not "fix" one of them.

  `DesignTaskDirection` refuses to read `trigger_meta[:space_id]` because
  it fires on `task:planning_started` — an event nobody addressed to
  anybody. The space id in that payload is incidental, and honouring it
  would auto-invite the Designer into whatever channel happened to be in
  scope.

  `design.critique` only ever fires because someone ADDRESSED THE DESIGNER
  ROLE: a human typing `@designer critique …` in a channel, or an agent
  passing an explicit `:space_id` to `Platform.Design.Critique.request/1`.
  The space is not incidental — it is the second half of "critique this,
  here", which is why the responsibility is `per_space` in the first
  place. Inviting an assignee into a space you explicitly summoned it
  into is consent, not leakage.

  The shared rule, which neither handler breaks: never invite from a space
  id nobody named. They disagree only about which spaces count as named,
  because their triggers differ.

  ## The chat_pattern path is HUMAN-ONLY, by design

  `Router.maybe_fire_chat_patterns/3` skips any message whose
  `author_participant_type == "agent"`, so an agent cannot invoke this
  responsibility by typing the handle. That guard is a feedback-loop
  defence and must NOT be weakened; the programmatic entry point is a
  separate seam.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.MarkdownExporter
  alias Platform.Design.Critique
  alias Platform.Design.Critique.Verdict
  alias Platform.Responsibilities.Responsibility
  alias Platform.Responsibilities.RoleTrigger
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @key "design.critique"
  @feature "design"

  # ONE source for the role key: the trigger regex and the metadata map both
  # read it, so the token a human types and the role we dispatch to cannot
  # drift apart.
  @role "designer"

  @template_slug "design.critique.v1"

  # A canvas of screenshots and long-form markdown is unbounded; the
  # concierge applies its own token ceiling and would silently drop the
  # tail. Truncate here so the drop is DISCLOSED in the prompt.
  @snapshot_budget 8_000

  # Task descriptions are grounding, not the subject — a paragraph is
  # plenty and a full spec would drown the canvas itself.
  @task_description_budget 500

  @uuid_regex ~r/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "chat_pattern",
        trigger_config: %{
          # Trailing group captures an optional canvas id, with or
          # without a URL prefix ("@designer critique <id>" and
          # "@designer critique /chat/canvas/<id>" both land). It is
          # passed as `:trailing` so it stays the LAST group —
          # `strip_canvas_id/1` scans positional captures.
          "regex" =>
            RoleTrigger.chat_regex(@role, "(critique|review)",
              trailing:
                "(?:\\s+\\S*?" <>
                  "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-" <>
                  "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}))?"
            )
        },
        scope: "per_space",
        context_provided: ["canvas_snapshot", "grounding_notes"],
        output_contract: %{
          "issues" => "list[map]"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.design",
          "role" => @role
        }
      }
    ]
  end

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def gather_context(_responsibility, ctx) when is_map(ctx), do: do_gather(ctx)
  def gather_context(_responsibility, _ctx), do: {:error, :no_canvas_resolved}

  defp do_gather(ctx) do
    case resolve_canvas(ctx) do
      %Canvas{} = canvas ->
        {:ok,
         ctx
         |> base_context(canvas)
         |> put_dispatch_space(ctx, canvas)}

      nil ->
        Logger.info(
          "[design.critique] no canvas resolved from trigger payload " <>
            "(keys=#{inspect(Map.keys(ctx))}) — refusing dispatch"
        )

        {:error, :no_canvas_resolved}
    end
  end

  defp base_context(ctx, canvas) do
    %{
      canvas_snapshot: render_snapshot(canvas),
      grounding_notes: grounding_notes(ctx),
      canvas_id: canvas.id
    }
  end

  # `:dispatch_space_id` is not a prompt slot — see
  # `Platform.Responsibilities.Provider`. It is the provider opting its
  # assignee into the space so a native recipient is not told to write
  # into a space it does not participate in. Trigger space first (this
  # responsibility is `per_space` and the request is answered where it
  # was asked), the resolved canvas's own space as the fallback. Omitted
  # entirely when neither resolves, which keeps the funnel's clean
  # `:no_space_named` skip.
  defp put_dispatch_space(context, ctx, %Canvas{space_id: canvas_space}) do
    case fetch(ctx, :space_id) || canvas_space do
      id when is_binary(id) and id != "" -> Map.put(context, :dispatch_space_id, id)
      _ -> context
    end
  end

  @impl true
  @doc """
  Build the (system + user) messages the Router hands to the dispatcher.

  The system slot names SARU and restates the JSON output contract; the
  user slot carries the canvas snapshot and whatever grounding was
  supplied. Never returns `{:error, _}` — `gather_context/2` already
  refused every state in which there is nothing to critique, and the
  Router reads any error other than `:no_build_prompt` as a dropped
  dispatch.
  """
  @spec build_prompt(map()) :: {:ok, %{system: String.t(), user: String.t()}}
  def build_prompt(context) when is_map(context) do
    system =
      "You are Saru, the Designer on Burrow. You are critiquing ONE design canvas. " <>
        "Report only what you can see in the snapshot you were given — never invent a " <>
        "screen, a component or a colour that is not in it. Respond with a single JSON " <>
        ~s(object of the shape {"issues": [{"severity", "location", "issue", ) <>
        ~s("suggestion"}]}. `severity` is one of "blocker", "major" or "minor"; ) <>
        "`location` names the node, section or region of the canvas the issue is in; " <>
        "`suggestion` is a concrete change, not a principle. An empty `issues` list is a " <>
        "valid answer when the canvas is sound — padding it with taste notes is worse " <>
        "than returning nothing."

    user = """
    ## Canvas under critique

    #{Map.get(context, :canvas_snapshot) || "(no canvas snapshot available)"}

    ## Grounding

    #{grounding_block(Map.get(context, :grounding_notes))}
    """

    {:ok, %{system: system, user: String.trim_trailing(user)}}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(%Responsibility{} = _responsibility, output, trigger_meta)
      when is_map(trigger_meta) do
    # LANDING seam only. The dispatch itself is the Router's
    # (`dispatch_assignee/4` → `safe_dispatch/4`); by the time this runs
    # the model has already answered.
    #
    # This is the ASYNC arm — a human typed `@designer critique` in a channel
    # — and it shares ONE landing function with the synchronous
    # `Platform.Design.Critique.request/1`, so the two paths cannot
    # deliver differently. There is no return value to hand anyone here,
    # which is exactly why the synchronous path exists.
    parsed = Verdict.parse(output)

    Logger.info(
      "[design.critique] received critique output " <>
        "(issues=#{length(parsed.issues)}, unparseable=#{parsed.unparseable?}, " <>
        "space_id=#{inspect(fetch(trigger_meta, :space_id))})"
    )

    _ =
      Critique.land_verdict(parsed, %{
        task_id: fetch(trigger_meta, :task_id),
        review_request_id: fetch(trigger_meta, :review_request_id),
        space_id: fetch(trigger_meta, :space_id)
      })

    :ok
  end

  def handle_output(_responsibility, _output, _trigger_meta), do: :ok

  # ── Canvas resolution ─────────────────────────────────────────────────────

  defp resolve_canvas(ctx) do
    canvas_from_id(fetch(ctx, :canvas_id)) ||
      canvas_from_match(fetch(ctx, :match)) ||
      latest_canvas_in_space(fetch(ctx, :space_id))
  end

  defp canvas_from_id(id) when is_binary(id) and id != "" do
    Chat.get_canvas(id)
  rescue
    error ->
      Logger.warning(
        "[design.critique] canvas #{inspect(id)} unreadable (#{inspect(error.__struct__)})"
      )

      nil
  end

  defp canvas_from_id(_id), do: nil

  # `Router.fire_matching_chat_patterns/2` puts `Regex.run/2`'s POSITIONAL
  # capture list in `:match`, so the canvas id's index moves the moment
  # anyone edits the regex. Scan for the first capture that looks like a
  # UUID instead of indexing into the list.
  defp canvas_from_match(captures) when is_list(captures) do
    captures
    |> Enum.filter(&is_binary/1)
    |> Enum.find_value(fn capture ->
      case Regex.run(@uuid_regex, capture) do
        [uuid] -> canvas_from_id(uuid)
        _ -> nil
      end
    end)
  end

  defp canvas_from_match(_captures), do: nil

  defp latest_canvas_in_space(space_id) when is_binary(space_id) and space_id != "" do
    space_id
    |> Chat.list_canvases()
    |> Enum.max_by(& &1.updated_at, DateTime, fn -> nil end)
  rescue
    error ->
      Logger.warning(
        "[design.critique] canvases for space #{inspect(space_id)} unreadable " <>
          "(#{inspect(error.__struct__)})"
      )

      nil
  end

  defp latest_canvas_in_space(_space_id), do: nil

  # ── Snapshot ──────────────────────────────────────────────────────────────

  defp render_snapshot(%Canvas{} = canvas) do
    body =
      case MarkdownExporter.export_markdown(canvas) do
        {:ok, markdown} -> truncate(markdown)
        {:error, reason} -> "(canvas body unrenderable — #{inspect(reason)})"
      end

    """
    Canvas: #{canvas.title || "(untitled)"} (canvas_id: #{canvas.id})

    #{body}
    """
    |> String.trim_trailing()
  end

  defp truncate(markdown) when is_binary(markdown) do
    if String.length(markdown) > @snapshot_budget do
      dropped = String.length(markdown) - @snapshot_budget

      String.slice(markdown, 0, @snapshot_budget) <> "\n...[truncated #{dropped} chars]"
    else
      markdown
    end
  end

  # ── Grounding ─────────────────────────────────────────────────────────────

  defp grounding_notes(ctx) do
    [note_line(fetch(ctx, :note)), task_line(fetch(ctx, :task_id))]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp note_line(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> "Requester note: " <> trimmed
    end
  end

  defp note_line(_note), do: nil

  defp task_line(task_id) when is_binary(task_id) and task_id != "" do
    case safe_task(task_id) do
      %TaskSchema{} = task ->
        "Task: #{task.title || "(untitled)"} (task_id: #{task.id})\n" <>
          truncate_description(task.description)

      _ ->
        nil
    end
  end

  defp task_line(_task_id), do: nil

  defp truncate_description(description) when is_binary(description) do
    if String.length(description) > @task_description_budget do
      String.slice(description, 0, @task_description_budget) <> "…"
    else
      description
    end
  end

  defp truncate_description(_description), do: "(no task description recorded)"

  defp safe_task(id) do
    Tasks.get_task_record(id)
  rescue
    error ->
      Logger.warning(
        "[design.critique] task #{inspect(id)} unreadable (#{inspect(error.__struct__)}); " <>
          "gathering without it"
      )

      nil
  end

  defp grounding_block(notes) when is_binary(notes) do
    case String.trim(notes) do
      "" -> "(no grounding supplied — critique the canvas on its own terms)"
      trimmed -> trimmed
    end
  end

  defp grounding_block(_notes),
    do: "(no grounding supplied — critique the canvas on its own terms)"

  # ── Shared helpers ────────────────────────────────────────────────────────

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp fetch(_map, _key), do: nil
end
