defmodule Platform.Responsibilities.Handlers.DesignTaskDirection do
  @moduledoc """
  `design.task_direction` responsibility provider (ADR-0046 stack member 7,
  task `019f9b29-5ecd` stage 3).

  Fires BEFORE planning on a task the UI-surface heuristic
  (`Platform.Design.UiSurface.ui_task?/1`, stage 1) flagged, and produces
  **direction** — what the surface is, a palette, type roles, layout intent,
  and a self-critique — delivered as a canvas attached to the task. Stage 4
  fires it and listens for that attachment; stage 6 retargets the planner
  prompt at it.

  ## Scope discipline is the load-bearing property

  This handler must be **incapable of doing the architect's job**. The
  architecture side of ADR-0046 already owns plan review
  (`architecture.review_plan`), and a design step that drifts into module
  boundaries and data flow is the architect built a second time, badly and
  at the wrong point in the lifecycle.

  The defence is `@scope_fence`, carried in the SYSTEM slot of
  `build_prompt/1` and stated as a **prohibition**, not a preference. The
  guard that keeps it honest is in
  `test/platform/responsibilities/handlers/design_task_direction_test.exs`:
  the rendered USER prompt may contain none of an architectural vocabulary
  probe set, and the paired positive control renders
  `ArchitectureReviewPlan.build_prompt/1` over an equivalent context and
  requires that the SAME probe set fires there. Without that control the
  absence assertion would pass against an empty string.

  Note the asymmetry, because it is not an oversight: the absence assertions
  run against the USER slot only. The SYSTEM slot names the prohibited
  domains verbatim — a prohibition that cannot say what it prohibits is not a
  prohibition — so asserting their absence there would be asserting the fence
  is missing.

  ## Why a new key rather than reusing `design.spec_writer`

  Rejected, for two independent reasons:

    * Its trigger is `chat_pattern` `(?i)@designer\\s+spec\\b` at `per_space`
      scope. Repurposing the row either breaks the live chat invocation or
      leaves two triggers on one row.
    * Its `context_provided` is `["canvas_snapshot", "grounding_notes"]` —
      "extract components from an EXISTING canvas", the opposite direction of
      travel from "produce direction from a task description".

  `architecture.review_plan` got a dedicated key for the architecture half of
  ADR-0046; design gets the symmetric treatment.

  ## Spec

    * `key` — `"design.task_direction"`
    * `feature` — `"design"`
    * `trigger_kind` — `event_topic` with `topic: "task:planning_started"`
    * `scope` — `per_project`
    * `context_provided` — `["task_payload", "brand_context", "attached_canvases"]`
    * `default_prompt_template` — `"design.task_direction.v1"`
    * `cost_profile` — `low_freq_capable`

  The `responsibilities` row itself lands at boot —
  `Platform.Responsibilities.Registry` upserts every `BuiltIns` provider — so
  adding this module to `BuiltIns.providers/0` is sufficient for the row.
  Migration `20260726051346_seed_design_task_direction.exs` exists for the
  two things boot does NOT cover on an already-migrated database: the
  `designer` ROLE BUNDLE row and the PROMPT TEMPLATE row.

  ## `gather_context/2` degrades, it never refuses

  All three slots collapse to a `%{missing?: true}` map rather than raising
  or returning `{:error, _}`. This is deliberately the OPPOSITE of
  `architecture.review_plan`'s `:plan_payload`, which refuses an unresolvable
  plan — and the difference is what each step is for. "Review this plan"
  without a plan is a broken trigger. "Give direction for this surface" with
  a thin task is the ordinary early-lifecycle state this step exists to serve;
  a designer handed a title and no description still has something to say.
  The cost of degrading is bounded because `handle_output/3` cannot deliver
  anywhere without a resolvable task and execution space, so a dispatch over
  an empty context produces nothing rather than something wrong.

  The three slot names are declared but have no
  `Platform.Responsibilities.ContextProviders` clause — they are materialised
  here. That is recorded in `@unresolved_slots` in
  `test/platform/responsibilities/architecture_context_bridge_test.exs`,
  which fails if a slot is declared with neither a resolver nor a stated
  reason.

  ## Why `design.critique` reads `dispatch_space_id` the OPPOSITE way

  `dispatch_space_id/1` below derives the invite space from the resolved
  task and pointedly refuses `trigger_meta[:space_id]`.
  `Handlers.DesignCritique` does take the trigger space. The divergence is
  a decision (task `019fe844` stage 2), recorded in both moduledocs so
  neither reads as a bug in the other.

  The difference is the trigger. This step fires on
  `task:planning_started`, which nobody addressed to anybody — the space
  in its payload is incidental and honouring it would invite the Designer
  into whatever channel happened to be in scope. `design.critique` fires
  only when someone addressed the Designer role: a human typing
  `@designer critique …`, or a
  caller passing an explicit `:space_id` to
  `Platform.Design.Critique.request/1`. There the space is half the
  request, not an accident of routing.

  The shared rule both obey: never invite from a space id nobody named.

  ## `handle_output/3` is the external-agent path only

  The Router calls it for `kind: "external"`. Native/federated agents go
  through `dispatch_native/4` and never reach it — they act on the prompt,
  and the prompt's delivery instruction tells them to create a canvas and
  attach it with `task_attach_canvas`. Both paths therefore converge on the
  same completion signal: a canvas attached to the task.

  Every failure arm logs and returns `:ok`. The order of the `with` chain is
  load-bearing: everything that can fail is resolved BEFORE the canvas is
  created, so a failure leaves zero canvases rather than an orphan canvas
  attached to nothing.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Chat
  alias Platform.Design.Brand
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tasks.Task, as: TaskSchema

  @key "design.task_direction"
  @feature "design"
  @template_slug "design.task_direction.v1"

  @attachment_note "design direction (ADR-0046 pre-plan)"
  @canvas_title "Design direction"

  # The whole defence against building the architect twice. Stated as a
  # prohibition rather than a preference, and asserted in
  # `design_task_direction_test.exs`.
  @scope_fence "Your remit is the visual surface only — layout, palette, type, " <>
                 "component choice, brand adherence. Do NOT comment on module boundaries, " <>
                 "data model, data flow, schema design, or code structure; that is the " <>
                 "Architect's remit and a separate step in this same lifecycle. If " <>
                 "everything you have to say is architectural, say nothing."

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc """
  The scope fence carried in the system slot of `build_prompt/1`.

  Exposed so the guard test asserts against the shipped constant rather than
  a restated copy that would keep passing after the real one drifted.
  """
  @spec scope_fence() :: String.t()
  def scope_fence, do: @scope_fence

  @doc "Note written on the canvas attachment `handle_output/3` creates."
  @spec attachment_note() :: String.t()
  def attachment_note, do: @attachment_note

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        # Fired directly by the pre-plan hook (stage 4) via
        # `Responsibilities.fire/2` rather than through a Phoenix.PubSub
        # subscription — the `topic` slot is documentation for operators
        # inspecting the row, same convention as
        # `architecture.review_plan`'s `plan:submitted`.
        trigger_config: %{"topic" => "task:planning_started"},
        scope: "per_project",
        context_provided: ["task_payload", "brand_context", "attached_canvases"],
        output_contract: %{
          "direction" => "string"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.design",
          "status" => "active",
          "role" => "designer",
          "adr" => "0046"
        }
      }
    ]
  end

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def gather_context(_responsibility, ctx) when is_map(ctx), do: {:ok, do_gather(ctx)}
  def gather_context(_responsibility, _ctx), do: {:ok, do_gather(%{})}

  @doc """
  Arity-1 gather, for tests and for callers that already hold the trigger
  payload.

  Always returns a map — this handler has no refusal. See the moduledoc for
  why that differs from `architecture.review_plan`.
  """
  @spec gather_context(map()) :: map()
  def gather_context(ctx) when is_map(ctx), do: do_gather(ctx)
  def gather_context(_ctx), do: do_gather(%{})

  @doc """
  Render the design-direction instruction by piping the gathered context
  through the `design.task_direction.v1` prompt template.

  Falls back to `PromptTemplates.default_content_for_slug/1` when the DB row
  is missing (early boot, un-migrated test DB) so a missing seed never
  strands the caller with an empty prompt.
  """
  @spec render_instruction(map()) :: String.t()
  def render_instruction(context) when is_map(context) do
    assigns = context_to_assigns(context)

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, rendered} when is_binary(rendered) and rendered != "" ->
        rendered

      _ ->
        fallback =
          case PromptTemplates.default_content_for_slug(@template_slug) do
            nil -> ""
            body -> body
          end

        interpolate_fallback(fallback, assigns)
    end
  end

  @impl true
  @doc """
  Build the (system + user) messages the Router hands to the dispatcher.

  The system slot carries `@scope_fence`; the user slot is the rendered
  instruction. Never returns `{:error, _}` — there is no context state that
  makes direction unaskable, and the Router treats any error other than
  `:no_build_prompt` as a refusal that drops the dispatch entirely.
  """
  @spec build_prompt(map()) :: {:ok, %{system: String.t(), user: String.t()}}
  def build_prompt(context) when is_map(context) do
    system =
      "You are the Designer on the Burrow pre-plan design path (ADR-0046). " <>
        @scope_fence <>
        " Your direction is advisory: it does not block development and is expected to " <>
        "be iterated."

    {:ok, %{system: system, user: render_instruction(context)}}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(%Responsibility{} = _responsibility, output, trigger_meta)
      when is_map(trigger_meta) do
    with {:ok, task_id} <- resolve_task_id(trigger_meta),
         {:ok, direction} <- resolve_direction(output),
         {:ok, attributed_to} <- resolve_attribution(trigger_meta),
         {:ok, space} <- resolve_space(task_id),
         {:ok, participant} <- resolve_participant(space),
         {:ok, canvas} <- create_direction_canvas(space, participant, direction),
         {:ok, _attachment} <- attach(task_id, canvas.id, attributed_to) do
      Logger.info(
        "[design.task_direction] attached direction canvas #{canvas.id} to task #{task_id}"
      )

      :ok
    else
      {:skip, reason} ->
        Logger.info("[design.task_direction] nothing delivered — #{reason}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "[design.task_direction] delivery failed reason=#{inspect(reason)} — " <>
            "direction not attached"
        )

        :ok
    end
  end

  # ── Context gathering ─────────────────────────────────────────────────────

  defp do_gather(ctx) do
    task = fetch_task(ctx)

    %{
      task_payload: task_payload(task),
      brand_context: brand_context(task),
      attached_canvases: attached_canvases(task),
      # NOT a prompt slot. This is the provider OPTING IN to the dispatch
      # invite: `Router.put_dispatch_space/2` lifts it to the native signal's
      # `metadata.space_id`, which `Platform.Chat.AgentResponder.dispatch_space_id/1`
      # passes to `Platform.Chat.DispatchMembership.ensure_writable/3` as the
      # only input it has. A provider that names none keeps the
      # `:no_space_named` skip. See `Platform.Responsibilities.Provider`.
      #
      # WHY THIS RESPONSIBILITY OPTS IN. The pre-plan designer is fired
      # against one specific task and has no database-expressible binding to
      # it: she is not `tasks.assignee_id`, she is not in `phase_assignees`,
      # and `responsibilities` is a registry rather than a dispatch log, so
      # there is no per-fire row either. Her binding exists only inside the
      # prompt text she was handed, and `Platform.Tasks.TaskAccess` is built
      # from assignee + phase_assignees + space participation, so without the
      # participant row this mints it DENIES the flagship consumer of
      # `task_attach_canvas`. The step fires once, holds 30 minutes and never
      # redelivers (ADR-0046), so that denial is unrecoverable within it.
      dispatch_space_id: dispatch_space_id(task)
    }
  end

  # Resolved through `ExecutionSpace.find_by_task_id/1` — the SAME resolver
  # `TaskAccess.space_member?/2` reads the grant back through, and the same one
  # `resolve_space/1` delivers into on the external path. A second resolution
  # path is how a row gets written into a space the gate does not look in.
  #
  # Derived from the RESOLVED task rather than from `trigger_meta.space_id`.
  # `Router.put_dispatch_space/2` deliberately refuses to sniff trigger meta,
  # and the reason applies here too: the chat_pattern producer puts an
  # arbitrary human channel in that key, and honouring it would auto-invite a
  # responsibility holder into whatever channel a regex matched.
  #
  # Rescued for the same reason `PreplanStep.execution_space_id/1` is: every
  # slot in `do_gather/1` degrades rather than raising, and a nil here is a
  # clean `:no_space_named` skip with the dispatch still going out.
  defp dispatch_space_id(%TaskSchema{id: task_id}) when is_binary(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      %{id: id} when is_binary(id) -> id
      _other -> nil
    end
  rescue
    error ->
      Logger.warning(
        "[design.task_direction] execution space for task #{task_id} unresolvable " <>
          "(#{inspect(error.__struct__)}); dispatching without an invite"
      )

      nil
  end

  defp dispatch_space_id(_task), do: nil

  defp fetch_task(ctx) do
    case extract_task_id(ctx) do
      id when is_binary(id) and id != "" -> safe_get_task(id)
      _ -> nil
    end
  end

  defp safe_get_task(id) do
    Tasks.get_task_record(id)
  rescue
    error ->
      Logger.warning(
        "[design.task_direction] task #{inspect(id)} unreadable " <>
          "(#{inspect(error.__struct__)}); gathering without it"
      )

      nil
  end

  defp task_payload(%TaskSchema{} = task) do
    %{
      missing?: false,
      task_id: task.id,
      title: task.title,
      description: task.description,
      project_id: task.project_id
    }
  end

  defp task_payload(_task),
    do: %{missing?: true, note: "no task resolved from the trigger payload"}

  # `Brand.resolve/1` is contractually incapable of raising — see
  # `Platform.Design.Brand`'s moduledoc. The rescue is here because THIS
  # function's contract is "never raises" and that must hold even if the
  # brand contract later loosens; it is defence in depth, not a live arm.
  defp brand_context(%TaskSchema{} = task) do
    Brand.resolve(task)
  rescue
    error ->
      Logger.warning(
        "[design.task_direction] brand resolution raised #{inspect(error.__struct__)}; " <>
          "falling back to advisory enforcement"
      )

      %{missing?: true, enforcement: :advisory, note: "brand resolution unavailable"}
  end

  defp brand_context(_task) do
    %{
      missing?: true,
      enforcement: :advisory,
      note: "no task resolved, so no project to resolve brand against"
    }
  end

  defp attached_canvases(%TaskSchema{} = task) do
    entries = CanvasAttachments.list_task_canvases(task.id)

    canvases =
      entries
      |> Enum.map(fn entry ->
        %{
          canvas_id: entry.attachment.canvas_id,
          title: entry.canvas && entry.canvas.title,
          note: entry.attachment.note,
          live?: not is_nil(entry.canvas)
        }
      end)

    %{missing?: false, total: length(canvases), canvases: canvases}
  rescue
    error ->
      Logger.warning(
        "[design.task_direction] attachment list unreadable " <>
          "(#{inspect(error.__struct__)}); rendering an empty block"
      )

      %{missing?: true, note: "attachment list unreadable"}
  end

  defp attached_canvases(_task),
    do: %{missing?: true, note: "no task resolved, so no attachments to list"}

  # ── Prompt assembly ───────────────────────────────────────────────────────

  defp context_to_assigns(context) do
    %{
      task_summary: format_task_summary(Map.get(context, :task_payload)),
      brand_context: format_brand_context(Map.get(context, :brand_context)),
      attached_canvases: format_attached_canvases(Map.get(context, :attached_canvases))
    }
  end

  defp format_task_summary(%{missing?: false} = payload) do
    """
    Task: #{payload.title || "(untitled)"} (task_id: #{payload.task_id})
    Project: #{payload.project_id || "(none)"}

    What the task asks for:
    #{indent(payload.description)}
    """
    |> String.trim_trailing()
  end

  defp format_task_summary(%{} = payload) do
    "(no task resolved — #{Map.get(payload, :note, "unknown")}. Ask for the task " <>
      "before giving direction; do not invent a surface.)"
  end

  defp format_task_summary(_payload), do: "(no task resolved)"

  # A missing brand must arrive as an INSTRUCTION, not as silence — the same
  # reasoning as the architect's unavailable ADR index. Handed a blank block a
  # model reads "this product has no identity" and invents one confidently.
  defp format_brand_context(%{guidance: guidance} = brand) when is_binary(guidance) do
    "Enforcement: #{Map.get(brand, :enforcement, :advisory)}\n\n" <> guidance
  end

  defp format_brand_context(%{} = brand) do
    "Enforcement: #{Map.get(brand, :enforcement, :advisory)}\n\n" <>
      "(no brand context resolved — #{Map.get(brand, :note, "unknown")}. Treat the " <>
      "palette and type roles below as PROVISIONAL and say so; do not present " <>
      "invented values as the product's identity.)"
  end

  defp format_brand_context(_brand), do: "(no brand context resolved)"

  defp format_attached_canvases(%{missing?: false, canvases: []}),
    do: "(none — nothing has been attached to this task yet)"

  defp format_attached_canvases(%{missing?: false, canvases: canvases})
       when is_list(canvases) do
    header =
      "#{length(canvases)} canvas(es) already attached. Do NOT re-issue direction that " <>
        "one of these already carries — extend or revise it instead."

    Enum.join([header | Enum.map(canvases, &format_canvas_line/1)], "\n")
  end

  defp format_attached_canvases(%{} = payload),
    do: "(attached canvases unavailable — #{Map.get(payload, :note, "unknown")})"

  defp format_attached_canvases(_payload), do: "(attached canvases unavailable)"

  defp format_canvas_line(canvas) do
    suffix = if canvas.live?, do: "", else: " [canvas deleted — stale attachment]"

    "- #{canvas.title || "(untitled)"} (canvas_id: #{canvas.canvas_id}" <>
      note_fragment(canvas.note) <> ")" <> suffix
  end

  defp note_fragment(note) when is_binary(note) and note != "", do: ", note: #{note}"
  defp note_fragment(_note), do: ""

  defp indent(nil), do: "  (no description recorded)"
  defp indent(""), do: "  (no description recorded)"

  defp indent(text) when is_binary(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))
  end

  defp indent(_text), do: "  (no description recorded)"

  # Same mustache substitution `PromptTemplates` applies, for the fallback
  # body. Mirrors `ArchitectureReviewPlan.interpolate_fallback/2`.
  defp interpolate_fallback("", _assigns), do: ""

  defp interpolate_fallback(content, assigns) when is_binary(content) do
    Regex.replace(~r/\{\{(\w+)\}\}/, content, fn _match, key ->
      value =
        try do
          atom_key = String.to_existing_atom(key)
          Map.get(assigns, atom_key) || Map.get(assigns, key) || ""
        rescue
          ArgumentError -> Map.get(assigns, key) || ""
        end

      to_string(value)
    end)
  end

  # ── Output delivery ───────────────────────────────────────────────────────

  defp resolve_task_id(trigger_meta) do
    case extract_task_id(trigger_meta) do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        {:skip,
         "no task_id in trigger_meta (keys=#{inspect(Map.keys(trigger_meta))}), " <>
           "so there is nothing to attach direction to"}
    end
  end

  defp resolve_direction(output) do
    case extract_direction(output) do
      md when is_binary(md) ->
        case String.trim(md) do
          "" -> {:skip, "the model returned an empty direction"}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:skip, "unrecognised output payload — expected a \"direction\" string"}
    end
  end

  # Attribution is resolved BEFORE the canvas is created on purpose: the
  # attachment row REQUIRES `attached_by_id`, so an unresolvable agent would
  # otherwise leave a canvas in the space attached to nothing.
  defp resolve_attribution(trigger_meta) do
    case extract_agent_id(trigger_meta) || role_agent_id() do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        {:skip,
         "no agent to attribute the attachment to (none on the trigger payload and no " <>
           "agent holds the design.task_direction responsibility)"}
    end
  end

  defp role_agent_id do
    case Roles.assignee_for(@key) do
      %{id: id} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve_space(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      %{id: _id} = space -> {:ok, space}
      _ -> {:skip, "no execution space for task #{task_id}"}
    end
  end

  defp resolve_participant(space) do
    case ExecutionSpace.ensure_system_participant(space.id) do
      {:ok, participant} -> {:ok, participant}
      {:error, reason} -> {:error, {:no_participant, reason}}
    end
  end

  defp create_direction_canvas(space, participant, direction) do
    attrs = %{
      space_id: space.id,
      created_by: participant.id,
      title: @canvas_title,
      document: direction_document(direction),
      metadata: %{
        "source" => "design.task_direction",
        "adr" => "0046"
      }
    }

    case Chat.create_canvas(attrs) do
      {:ok, canvas} -> {:ok, canvas}
      {:error, reason} -> {:error, {:canvas_create_failed, reason}}
    end
  end

  defp direction_document(direction) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{
            "id" => "direction",
            "type" => "markdown",
            "props" => %{"content" => direction}
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  # `:system`, not `{:agent, agent_id}` — attribution is not authorization, and
  # here the two genuinely differ.
  #
  # This handler creates the canvas itself, in the task's execution space, via
  # `ExecutionSpace.ensure_system_participant/1`. The agent it is ATTRIBUTED to
  # is resolved separately from the trigger payload or the
  # `design.task_direction` role holder, and that agent is frequently NOT a
  # participant of that execution space. Authorizing as the attributed agent
  # would therefore deny — and ADR-0046's pre-plan design step fires once with
  # no redelivery, so it would not fail loudly, it would silently never deliver.
  #
  # The platform is the actor here; it created the canvas one call ago.
  defp attach(task_id, canvas_id, agent_id) do
    case CanvasAttachments.attach_canvas(:system, task_id, canvas_id,
           note: @attachment_note,
           attached_by: %{kind: "agent", id: agent_id}
         ) do
      {:ok, attachment} -> {:ok, attachment}
      {:error, reason} -> {:error, {:attach_failed, reason}}
    end
  end

  # ── Extraction ────────────────────────────────────────────────────────────

  defp extract_task_id(meta) when is_map(meta) do
    Map.get(meta, :task_id) || Map.get(meta, "task_id") ||
      case Map.get(meta, :task) || Map.get(meta, "task") do
        %TaskSchema{id: id} -> id
        %{id: id} when is_binary(id) -> id
        _ -> nil
      end
  end

  defp extract_task_id(_meta), do: nil

  defp extract_agent_id(meta) when is_map(meta) do
    Map.get(meta, :agent_id) || Map.get(meta, "agent_id") ||
      case Map.get(meta, :agent) || Map.get(meta, "agent") do
        %{id: id} when is_binary(id) -> id
        _ -> nil
      end
  end

  defp extract_agent_id(_meta), do: nil

  defp extract_direction(%{"direction" => md}) when is_binary(md), do: md
  defp extract_direction(%{direction: md}) when is_binary(md), do: md
  defp extract_direction(md) when is_binary(md), do: md
  defp extract_direction(_output), do: nil
end
