defmodule Platform.Federation.ToolArguments do
  @moduledoc """
  Argument policy for the federated tool surface: which declared-required
  parameters a caller must actually supply, and which declarations the
  runtime has never enforced.

  `dispatch/3` is the entry point both federation transports call. It runs
  `validate/2` and, only if that passes, hands the call to
  `ToolSurface.execute/3`. A single composition point is the whole design:
  a third transport cannot get the ordering wrong, and the two existing ones
  cannot answer the same malformed call differently.

  Authorization is deliberately NOT folded in here. `ToolAuthorization.authorize/2`
  runs first at both call sites and its refusal frames are load-bearing —
  `RuntimeChannel.deny_tool_call/3` documents the exact shape openclaw's
  client unwraps. Two policies, two modules, one fixed order at each door.

  ## Why the boundary lives here and not inside `ToolSurface`

  Same rationale as the sibling `Platform.Federation.ToolAuthorization`, and
  deliberately the same shape so the two policies cannot answer differently.
  `Platform.Federation.ToolSurface` is a catalogue-plus-executor: its
  `execute/3` is ~100 pattern-matched clauses and its `tool_definitions/0` is
  a pure list transform. Fronting `execute/3` in-module would mean renaming
  every clause to `do_execute/3` — a mechanical thousand-line diff to a file
  under constant contention. Argument policy is cross-transport policy, and
  `ToolAuthorization` already establishes that cross-transport policy lives
  in a sibling module so the streamable-HTTP endpoint and the WebSocket
  runtime channel cannot drift apart. This module composes the pure
  catalogue the same way.

  ## Scope: presence, never type and never emptiness

  The requirement modelled here is that the caller *named* the argument.
  Type validation and emptiness validation are a far larger breaking
  surface — several handlers accept an explicitly empty value as meaningful
  (`plan_create` with `stages: []` creates a stage-less plan; `principal_search`
  with a one-character query deliberately answers `{:ok, %{results: []}}`) —
  and are out of scope. `ToolSurface.require_string/3` and `require_integer/3`
  remain the per-handler mechanism for type coercion.

  So `validate/2` accepts `stages: []`, `limit: 0` and `evidence: %{}`. The
  one concession is that a blank or whitespace-only *string* counts as absent:
  `%{"plan_id" => "   "}` names nothing a handler can use, and treating it as
  present would hand the same `nil`-shaped failure back to the caller under a
  different disguise.

  ## Why the refusal code is per-parameter

  `code: :"missing_\#{param}"`, not a generic `:missing_required_argument`.
  `task_design_decline` and `plan_architecture_verdict` each document a CLOSED
  code taxonomy in their `limitations` prose and instruct remote runtimes to
  branch on it — `missing_task_id`, `missing_reason`, `missing_summary`. A
  generic code would put a value on the wire that is absent from every
  declared set, which is the same signal-does-not-reach-its-reader defect this
  module exists to remove. Per-parameter codes mean the generic gate emits
  exactly the codes those tools already document, from one producer instead of
  two.

  The message deliberately carries no backticks (`"stage_start: stage_id is
  required"`, not `` "`stage_id` is required" ``), matching the phrasing
  already asserted by tests that pin real handler behaviour. `recoverable` is
  always `true`: an agent that misspelled an argument can retry, and telling
  it otherwise — as `space_list_agents` did — is advice to give up on a typo.

  ## Declarations vs. behaviour

  A `required: true` entry in `tool_definitions/0` is documentation. Nothing
  in the runtime reads it: there is no generic validator, so a missing
  argument reaches the handler as `nil` and fails — or does not fail — however
  that particular handler happens to be written.

  Where a declaration and the handler disagree, **the behaviour is what
  callers rely on**, and the fix is to correct the declaration, not the
  handler. Promoting a de-facto-optional parameter to a hard error is a
  breaking change dressed as a bug fix, and there are live runtimes.

  Two correction mechanisms, applied by the survey backing this module:

    * **Aliases.** The handler accepts a second key for the same value
      (`Map.get(args, "task_id") || Map.get(args, "id")`). The declaration
      grows an `aliases:` list and any alias satisfies the requirement.
      `aliases:` is inert for the advertised MCP schema — `MCPController`'s
      `property_schema/1` reads only `:type`, `:description` and `:schema` —
      so this changes no client's view of the tool.

    * **`@behaviour_exempt`.** The handler resolves the value from somewhere
      other than `args` (the call context), or documents a default for the
      key being absent. The gate must never enforce these.

  ## What the survey found

  126 `required: true` declarations across the 90 tools (127 when the survey
  was taken; stage 5 demoted `stage_list`'s `plan_id` — see "Conditional
  requirements leave this module" below). Nine are aspirational:

    * Five carry an undeclared alias — four `id`-for-`<x>_id` fallbacks plus
      `canvas.create`'s `initial_state`-for-`document`.
    * Three resolve `space_id` from the call context when the argument is
      absent, so a context-bound runtime legitimately omits it.
    * One (`task_create`'s `title`) has an in-source comment declaring the
      absent-key default to be preserved *for wire compatibility*.

  The remaining 117 are classified honest, meaning no handler resolves the
  value from anywhere but `args` under its declared or aliased key. What they
  do when it is missing is not uniform, and that non-uniformity is the
  ticket's actual complaint — a caller cannot tell a malformed call from a
  broken server:

    * `space_list_agents` reaches `where([p], p.space_id == ^nil)` and raises
      `ArgumentError` — a 500 naming nothing. (`stage_list` failed this way
      too, and was the ticket's headline example, until stage 5.)
    * `validation_evaluate` raises `Ecto.NoResultsError` from inside a
      `Repo.transaction` — different exception, different layer, same 500.
    * `canvas_get` does not raise at all: it answers `"Canvas not found: "`
      with `recoverable: false`, telling the caller a canvas they never named
      does not exist, and not to retry.
    * `task_complete` is the only handler that pattern-matches its required
      key in the clause head (`%{"task_id" => task_id}`), so a call without it
      matches no clause and falls through to the catch-all: it reports
      `"Unknown tool: task_complete"`, `recoverable: false`. The caller is
      told a tool that exists does not.

  Four of the 118 deserve their own note, because they neither raise nor
  misreport — they apply a default when the key is absent:
  `plan_create`'s `stages` and `review_request_create`'s `items` default to
  `[]`, and `space_search_messages`' and `principal_search`'s `query` default
  to `""` (`principal_search` then answers `{:ok, %{results: []}}` for a
  search it never ran). They are classified honest rather than exempt as a
  deliberate ruling: the default is the absence of a check rather than a
  documented capability, and no caller benefits from an unnamed search
  reporting no matches. Enforcing them is a real behaviour change and is
  recorded here so a later stage ships it knowingly rather than by accident.
  `task_create`'s `title` is the one default that IS exempt, because its
  in-source comment declares the absent-key defaults preserved for wire
  compatibility — an explicit promise the other four do not make.

  The classification is re-derived from source by
  `test/platform/federation/tool_arguments_test.exs`, which fails when a
  `required: true` declaration is added without classification and when an
  alias fallback appears in a handler without a matching declaration.

  ## One mechanism, not two

  Task 019fa609 stage 4 deleted the twenty-seven hand-written presence checks
  `ToolSurface` used to carry (fifteen tools: `react`, `space_list_agents`,
  `space_leave`, `org_list_descendants`, `meeting_create`, `task_ack`,
  `intent_ack`, four `stack_*` tools, `plan_create`, `report_blocker`,
  `prompt_template_update`). They disagreed with each other on wording, on
  whether a `code` was emitted at all, and on `recoverable` — `space_list_agents`
  told an agent that misspelled `space_id` not to retry. `validate/2` is now the
  single producer, so every missing-argument refusal on the surface carries the
  same shape and a `missing_<param>` code.

  Three kinds of check deliberately survived in the handlers, because the gate
  does not and should not model them:

    * **Conditional requirements.** `skill.get`'s "exactly one of `slug` or
      `id`", and since stage 5 `stage_list`'s "exactly one of `plan_id` or
      `task_id`" — both parameters are `required: false`, so there is nothing
      for a per-parameter gate to enforce.
    * **Value and range checks.** `validation_evaluate`'s
      `status in ~w(passed failed)`; `alarm_silence`'s `until_seconds` range and
      `reason` length; `intent_ack`'s status set.
    * **Present-but-unusable.** `task_design_decline`'s <8-character reason and
      `plan_architecture_verdict`'s malformed-finding checks. Note the seam:
      because a blank string counts as absent here, the gate answers the
      whitespace-only input first and the handler's richer prose is unreachable
      for it. The `code` is identical either way, so a client branching on the
      taxonomy sees no difference; a human reading the message does.

  One documented casualty, recorded rather than papered over:
  `ToolSurface.validate_subagent_id/1` is KEPT even though `subagent_id` is
  declared required on both `task_ack` and `intent_ack`, because it also
  enforces a whitespace rule and a 128-byte cap, and because for `intent_ack` a
  rejected id has a side effect the gate does not reproduce
  (`IntentQueue.record_rejected_ack/2`, which is what splits a later timeout
  into `:no_ack_spawn_failed` rather than `:timed_out`). Through `dispatch/3`
  an absent or blank `subagent_id` is now refused before that evidence is
  recorded — see `tool_surface_intent_ack_test.exs` for the test that pins both
  halves of that seam.

  ## Conditional requirements leave this module

  Task 019fa609 stage 5 gave `stage_list` a second entry point — `plan_id` OR
  `task_id`, resolving to the task's current plan — and that took it out of
  scope here entirely. A per-parameter gate cannot express "exactly one of
  these two": declaring either one `required: true` would refuse the other's
  callers, and declaring neither leaves nothing to enforce. Both are now
  `required: false` and the handler refuses on its own, `skill.get`-style,
  with its own closed code set (`missing_plan_reference`,
  `plan_task_mismatch`, `no_current_plan`) documented in the tool's
  `limitations` and compared against observed behaviour by a test.

  Worth stating plainly, because it reads as a contradiction: the tool that
  motivated the ticket is not covered by the mechanism the ticket asked for.
  That is not a gap. Widening the gate to model conditional rules would make
  `required: true` mean something different per tool, which is precisely the
  "documentation the runtime does not read" failure this module exists to
  end. A rule the gate cannot state honestly belongs in the handler that can.

  ## Undeclared keys: opt-in strictness (task 01a0acc3)

  Presence is one half of argument policy; the other half is a key the tool
  never declared. Before task 01a0acc3 nothing on the surface looked: a
  `task_list` call carrying `assignee_id` reached a handler that reads only
  `project_id`, `epic_id` and `status` as filters, and answered with the
  UNFILTERED list. The caller could not tell "my filter matched everything"
  from "my filter was thrown away", and read the first page as its board.

  **Scope: `task_list` and nothing else.** `strict_tools/0` is the complete
  list of tools whose undeclared keys are refused, and today it holds exactly
  `"task_list"`. Every other tool keeps ignoring extra keys, as it always has.
  A global flip is unsafe: live runtimes send undeclared keys to other tools
  and nobody has surveyed which, so refusing them surface-wide would break
  callers that work today — the same "breaking change dressed as a bug fix"
  the presence gate declined to make.

  **To opt a tool in**, add its name to `@strict_tools`. Its declared keys are
  its `parameters` plus every `aliases:` entry, read from
  `ToolSurface.tool_definitions/0` — so there is no second list to keep in
  sync. Before adding one, check what its live callers actually send.

  **Why `space_id` is always tolerated.** Both transports read `space_id` out
  of the tool ARGS to build the call context (`MCPController.build_context/2`,
  `RuntimeChannel.execute_tool_call/4`), and the legacy openclaw plugin tells
  agents to pass it to `suite_task_list` and forwards params verbatim. It is a
  transport key that happens to travel in `args`, not a tool parameter, so a
  strict tool must still accept it. `@transport_reserved` lists such keys;
  each entry needs a transport that reads it.

  The unknown-key check runs BEFORE the required check, so a misspelled
  required key is reported as the misspelling rather than as a missing key.
  The refusal carries `code: :unknown_parameter`, `recoverable: true`, and
  `unknown_parameters` — the sorted list of offending keys.
  """

  alias Platform.Federation.ToolSurface

  @typedoc "A declared-required parameter and the other keys that satisfy it."
  @type required_param :: %{key: String.t(), aliases: [String.t()]}

  # ── Aspirational declarations the gate must not enforce ────────────────
  #
  # `{tool_name, parameter, reason}`. Every entry is a case where the handler
  # completes correctly with the argument absent, so requiring it would break
  # callers that work today. Entries are NOT a to-do list — each is a
  # deliberate ruling that the declaration overstates the requirement.
  #
  # Aliased parameters are deliberately absent from this list: an alias is
  # still a requirement, just one that a second key can satisfy.
  @behaviour_exempt [
    {"attachment.upload_inline", "space_id",
     "Platform.Chat.Attachments.ToolHandlers.require_space_id/2 falls back to context[:space_id]; a space-bound runtime legitimately omits the argument."},
    {"attachment.upload_start", "space_id",
     "Platform.Chat.Attachments.ToolHandlers.require_space_id/2 falls back to context[:space_id]; a space-bound runtime legitimately omits the argument."},
    {"canvas.create", "space_id",
     "Platform.Chat.Canvas.ToolHandlers.create/2 falls back to context[:space_id]; a space-bound runtime legitimately omits the argument."},
    {"task_create", "title",
     "ToolSurface's task_create clause applies Map.put_new(\"title\", \"Untitled Task\") under an in-source comment declaring the absent-key defaults preserved for wire compatibility."}
  ]

  # ── Tools whose undeclared keys are refused (OPT-IN) ───────────────────
  #
  # An opt-in list, not a default. A global flip is unsafe: live runtimes send
  # undeclared keys to other tools and nobody has surveyed which, so refusing
  # them everywhere would break callers that work today. Add a tool here only
  # after checking what its callers send. Task 01a0acc3.
  @strict_tools ["task_list"]

  # ── Keys a strict tool must still tolerate ─────────────────────────────
  #
  # Transport keys that travel in `args` without being tool parameters. Each
  # entry needs a reader outside the tool:
  #
  #   * `space_id` — `MCPController.build_context/2` and
  #     `RuntimeChannel.execute_tool_call/4` both read `args["space_id"]` to
  #     build the call context, and the legacy openclaw plugin
  #     (startup-suite-channel src/message-bridge.ts) tells agents to pass it
  #     to suite_task_list, forwarding params verbatim (src/channel.ts).
  @transport_reserved ["space_id"]

  # ── Honest declarations whose handler still defaults on absence ────────
  #
  # `{tool_name, parameter, current_behaviour}`. These are NOT exemptions —
  # the gate is expected to enforce them — but each one changes an outcome
  # that exists today, so enforcing is a deliberate act rather than a
  # no-op. Recorded so a later stage ships the change knowingly, and so a
  # reviewer can weigh each one individually.
  @default_on_absence [
    {"plan_create", "stages", "Map.get(args, \"stages\", []) — creates a stage-less plan."},
    {"review_request_create", "items",
     "Map.get(args, \"items\", []) — files a review request with nothing to review."},
    {"space_search_messages", "query",
     "Map.get(args, \"query\", \"\") — searches the space for the empty string."},
    {"principal_search", "query",
     "Map.get(args, \"query\", \"\") — answers {:ok, %{results: []}} for a search never run."}
  ]

  @doc """
  Run the argument gate, then execute. **The** entry point to the federated
  tool surface: `ToolSurface.execute/3` is `@doc false` and must not be called
  directly.

  That is not a style preference. Since task 019fa609 stage 4 the handlers no
  longer carry their own presence checks — `validate/2` is the only producer of
  a missing-argument refusal — so a caller that skips this function reaches
  handlers that raise on a `nil` argument (`space_list_agents` on `space_id`,
  `intent_ack` on `intent_id`) instead of refusing it. Both federation
  transports call `dispatch/3`; a third must too.

  Authorization is NOT performed here — `ToolAuthorization.authorize/2` runs
  first at each transport and stays there, because its refusal frames differ
  per transport in ways that are load-bearing.
  """
  @spec dispatch(String.t(), map(), map()) :: {:ok, term()} | {:error, term()}
  def dispatch(tool_name, args, context) when is_binary(tool_name) and is_map(args) do
    with :ok <- validate(tool_name, args) do
      ToolSurface.execute(tool_name, args, context)
    end
  end

  @doc """
  Is every declared-required parameter of `tool_name` named in `args`?

  Presence only: a parameter is satisfied by its declared key or by any of its
  declared aliases, carrying any non-nil value that is not a blank string. No
  type check, no emptiness check — see the moduledoc for why widening this
  would be a much larger breaking change.

  Exempt parameters (`behaviour_exempt/0`) are skipped: the handler completes
  without them, so enforcing would break callers that work today.

  Returns `:ok`, or `{:error, envelope}` naming the FIRST missing parameter in
  declaration order. One parameter per refusal rather than a list, because the
  refusal has to fit the `%{error:, code:, recoverable:, suggestion:}` shape
  both transports already carry, and a single `code` cannot name two.

  A tool with no required parameters passes, and so does an unknown tool —
  deciding that a name does not exist is `ToolAuthorization`'s job, and it has
  already run by the time this is called.

  For a tool in `strict_tools/0` (today only `task_list`), an undeclared key
  is refused first with `code: :unknown_parameter`, naming every such key.
  `transport_reserved/0` keys are tolerated. Every other tool is not checked.
  """
  @spec validate(String.t(), map()) :: :ok | {:error, map()}
  def validate(tool_name, args) when is_binary(tool_name) and is_map(args) do
    with :ok <- validate_known_keys(tool_name, args) do
      validate_required(tool_name, args)
    end
  end

  # Only tools in `@strict_tools` are checked; every other tool returns `:ok`
  # here, so `validate/2` answers for them exactly as it did before.
  defp validate_known_keys(tool_name, args) when tool_name in @strict_tools do
    case unknown_keys(tool_name, args) do
      [] -> :ok
      unknown -> {:error, unknown_refusal(tool_name, unknown)}
    end
  end

  defp validate_known_keys(_tool_name, _args), do: :ok

  defp unknown_keys(tool_name, args) do
    allowed = declared_keys(tool_name) ++ @transport_reserved

    args
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in allowed))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unknown_refusal(tool_name, unknown) do
    declared = tool_name |> declared_keys() |> Enum.sort() |> Enum.join(", ")

    %{
      error: "#{tool_name}: unknown parameter(s) #{Enum.join(unknown, ", ")}",
      code: :unknown_parameter,
      recoverable: true,
      unknown_parameters: unknown,
      suggestion:
        "Declared parameters for #{tool_name}: #{declared}. " <>
          "Call tools/list for the full inputSchema."
    }
  end

  defp validate_required(tool_name, args) do
    tool_name
    |> required_params()
    |> Enum.reject(&exempt?(tool_name, &1.key))
    |> Enum.find(&missing?(&1, args))
    |> case do
      nil -> :ok
      param -> {:error, refusal(tool_name, param)}
    end
  end

  defp missing?(%{key: key, aliases: aliases}, args) do
    not Enum.any?([key | aliases], fn k -> named?(Map.get(args, k)) end)
  end

  # Blank strings are absent; every other non-nil term is present. `false`,
  # `0`, `[]` and `%{}` are all values a caller deliberately chose.
  defp named?(nil), do: false
  defp named?(value) when is_binary(value), do: String.trim(value) != ""
  defp named?(_value), do: true

  defp refusal(tool_name, %{key: key, aliases: aliases}) do
    %{
      error: "#{tool_name}: #{key} is required",
      code: :"missing_#{key}",
      recoverable: true,
      suggestion: suggestion(tool_name, key, aliases)
    }
  end

  defp suggestion(tool_name, key, []) do
    "Pass `#{key}` in the arguments for `#{tool_name}`. Call tools/list for the full inputSchema."
  end

  defp suggestion(tool_name, key, aliases) do
    accepted = Enum.map_join(aliases, " or ", &"`#{&1}`")

    "Pass `#{key}` in the arguments for `#{tool_name}` (#{accepted} is also accepted). " <>
      "Call tools/list for the full inputSchema."
  end

  @doc """
  The `{tool, parameter, reason}` triples the gate must not enforce.

  See the moduledoc for why each is aspirational rather than honest.
  """
  @spec behaviour_exempt() :: [{String.t(), String.t(), String.t()}]
  def behaviour_exempt, do: @behaviour_exempt

  @doc """
  Honest declarations whose handler nonetheless defaults when the key is
  absent, with the behaviour enforcement would replace.

  Not exemptions — advisory. Enforcing these is correct and also a visible
  behaviour change.
  """
  @spec default_on_absence() :: [{String.t(), String.t(), String.t()}]
  def default_on_absence, do: @default_on_absence

  @doc """
  The tools whose undeclared keys `validate/2` refuses with
  `code: :unknown_parameter`. Opt-in: every tool not listed here ignores
  extra keys. See the moduledoc section on undeclared keys.
  """
  @spec strict_tools() :: [String.t()]
  def strict_tools, do: @strict_tools

  @doc "Keys every strict tool tolerates because a transport reads them from `args`."
  @spec transport_reserved() :: [String.t()]
  def transport_reserved, do: @transport_reserved

  @doc """
  Every key `tool_name` declares: its `parameters` plus every declared
  `aliases:` entry, as strings. `[]` for an unknown tool.
  """
  @spec declared_keys(String.t()) :: [String.t()]
  def declared_keys(tool_name) when is_binary(tool_name) do
    case find_tool(tool_name) do
      nil ->
        []

      tool ->
        tool
        |> Map.get(:parameters, %{})
        |> Enum.flat_map(fn {key, spec} ->
          aliases = if is_map(spec), do: Map.get(spec, :aliases, []), else: []
          [to_string(key) | Enum.map(aliases, &to_string/1)]
        end)
        |> Enum.uniq()
    end
  end

  @doc "Is `parameter` on `tool` a declaration the runtime has never enforced?"
  @spec exempt?(String.t(), String.t()) :: boolean()
  def exempt?(tool, parameter) when is_binary(tool) and is_binary(parameter) do
    Enum.any?(@behaviour_exempt, fn {t, p, _reason} -> t == tool and p == parameter end)
  end

  @doc """
  Every `required: true` parameter declared for `tool_name`, with the alias
  keys that also satisfy it.

  Pure: reads `ToolSurface.tool_definitions/0` and nothing else — no Repo, no
  principal. Exempt parameters are still returned; filtering them is the
  gate's job, so a caller can see the full declared surface.

  Returns `[]` for an unknown tool name, and for a tool that declares no
  required parameters. Those two cases are deliberately indistinguishable
  here — refusing an unknown tool is `ToolAuthorization`'s decision, not this
  module's.
  """
  @spec required_params(String.t()) :: [required_param()]
  def required_params(tool_name) when is_binary(tool_name) do
    case find_tool(tool_name) do
      nil -> []
      tool -> declared_required(tool)
    end
  end

  defp find_tool(tool_name),
    do: Enum.find(ToolSurface.tool_definitions(), &(&1.name == tool_name))

  @doc """
  `{tool_name, required_param}` for every declared-required parameter in the
  whole surface. The survey's machine-readable form.
  """
  @spec all_required_params() :: [{String.t(), required_param()}]
  def all_required_params do
    for tool <- ToolSurface.tool_definitions(),
        param <- declared_required(tool),
        do: {tool.name, param}
  end

  defp declared_required(tool) do
    tool
    |> Map.get(:parameters, %{})
    |> Enum.filter(fn {_key, spec} -> is_map(spec) and Map.get(spec, :required) == true end)
    |> Enum.map(fn {key, spec} ->
      %{key: to_string(key), aliases: Enum.map(Map.get(spec, :aliases, []), &to_string/1)}
    end)
    |> Enum.sort_by(& &1.key)
  end
end
