defmodule Platform.Chat.Canvas.ToolAccess do
  @moduledoc """
  The authorization seam between the canvas MCP tools and
  `Platform.Chat.CanvasAccess` (task 019fb01b, stage 1).

  Every canvas-id-keyed read and write on the agent tool surface asks its
  question here, in one shape, so the surface cannot grow a second answer.
  Handlers keep their argument parsing and their payload building; they do not
  keep their own authorization.

  ## Not `Platform.Federation.ToolAuthorization`

  Different question, deliberately different name. That module decides which
  tool NAMES a runtime may call at all, out of its capability bundle, and takes
  a `%Platform.Agents.AgentRuntime{}`. This one decides whether a caller may
  touch one particular canvas ROW, and takes a canvas id. A tool call passes
  through both: the bundle check first, at the transport, then this one inside
  the handler. Named `ToolAccess` rather than `ToolAuth` so that a reader
  grepping for one does not land in the other.

  ## Why a module and not a function on `CanvasAccess`

  `CanvasAccess` is transport-neutral: the LiveView, `Tasks.CanvasAttachments`
  and the MCP surface all call it. Two things here are transport artifacts —
  the federation context map, and the `%{error:, recoverable:, suggestion:}`
  envelope the model parses — and putting either in the policy core is how the
  policy core stops being reusable.

  Not a private helper inside `ToolHandlers` either: `VersionHandlers` would
  then have to call a sibling handler for its authorization. The dependency
  direction is `ToolAccess -> CanvasAccess -> Chat`, so nothing here points at
  `Platform.Federation.ToolSurface` and the circular-dependency constraint
  recorded in `VersionHandlers` still holds.

  ## Reads use the reader's grants and the writer's deletion rule

  `CanvasAccess.fetch_for_viewer/3` deliberately RETURNS a soft-deleted canvas
  to a grant-holder, so the standalone page can render "this was removed"
  instead of lying to someone who has it bookmarked. Over MCP that behaviour is
  wrong twice: it would newly serve deleted documents to agents, and it would
  spin up a `Canvas.Server` for a canvas nobody should be reading. Every
  pre-existing MCP read went through `Chat.get_canvas/2`, which filters
  `deleted_at`.

  So `fetch_for_read/2` takes the reader's grant set (`:member`,
  `:task_reader`, `:org_reader`, `:system`) and the writer's deletion rule
  (deleted collapses to not-found). Neither door on its own has that
  combination, which is why this is a fold and not a delegation.

  ## `:not_found` and `:forbidden` stay distinct

  Collapsing read denials into not-found would relocate the existence oracle
  rather than remove it: `canvas.patch` and `canvas.restore` keep the two
  answers apart, so a caller can probe the write door and read the difference.
  The distinction is also load-bearing for a model caller — not-found means the
  attachment it was handed is stale, forbidden means ask for roster.

  ## Denial payloads carry the caller's `canvas_id` and nothing else

  No title, no `space_id`, no org, no space kind. A denial must not let the
  caller tell a channel canvas from a DM canvas from an execution-space canvas.
  The SUCCESS payload of `canvas.describe` does return `space_id`; that is a
  read the caller was authorized for, and the denial must not inherit it.

  ## Every forbidden read is emitted, not only returned

  `fetch_for_read/2` emits `[:platform, :chat, :canvas_read_denied]` on the
  forbidden branch, registered in `Platform.Audit.TelemetryHandler`'s explicit
  allowlist so it lands in `audit_events` (task 019fb01b, stage 5). Without that
  registration `:telemetry.execute/3` is a silent no-op — no error, no log —
  which is the trap `Platform.Chat.CanvasAccess`'s moduledoc already names for
  the sibling `[:platform, :chat, :canvas_read]` event.

  The row records the caller (`actor_type` is `"agent"`, `"user"` for the
  user-shaped context `actor/1` accepts, or `"anonymous"` for a runtime with no
  linked agent), the canvas id, and `runtime_id` when the context carries one.

  This is the detection control for the existence oracle stage 3 chose to keep.
  Holding `:not_found` and `:forbidden` apart lets a caller with the `canvas`
  bundle ask "does this id exist" one id at a time; the defence offered was that
  UUIDv7 ids are expensive to guess, which is an argument about how hard the
  sweep is and not an argument that anyone would see it. Now they can: a
  forbidden answer is the sweep's HIT, and `runtime_id` in the metadata is what
  makes a run of them attributable to one caller rather than a scatter of
  unrelated mistakes.

  Three things deliberately do NOT emit, so the signal stays worth reading:

    * `:not_found`. A stale task attachment produces one on a completely honest
      call — `@not_found_suggestion` below tells callers to expect it — and a
      probe sweep produces mostly these. Emitting them would bury the hits.
    * `fetch_for_write/3` denials. A refused write is a different signal class,
      and the write itself is what downstream audit records.
    * Denials decided in `CanvasAccess` for the LiveView. This module is the MCP
      transport adapter, so `surface: "mcp_tool"` in the metadata states the
      coverage boundary rather than implying the event covers every door.
  """

  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasAccess

  @type context :: map()
  @type payload :: %{
          required(:error) => String.t(),
          required(:recoverable) => boolean(),
          required(:canvas_id) => term(),
          required(:suggestion) => String.t()
        }

  @default_write_denial "Access denied: writing a canvas requires participation in the canvas's space. " <>
                          "Being able to read a canvas (via a task it is attached to, or via your org) " <>
                          "does not confer write access."

  @default_write_suggestion "Ask a human to add you to the space that owns this canvas."

  @read_denial "Access denied: you do not have read access to this canvas. " <>
                 "Reading a canvas requires participation in the space that owns it."

  @read_suggestion "Ask a human to add you to the space that owns this canvas, " <>
                     "or ask for the canvas to be shared with you."

  @not_found_suggestion "Check the canvas id. If it came from a task attachment, the attachment " <>
                          "may be stale — use canvas_list to see what the space actually has."

  @doc """
  Normalize a federation tool context into a `t:Platform.Chat.CanvasAccess.actor/0`.

  The context is built in exactly two places —
  `PlatformWeb.MCPController.build_context/2` and
  `PlatformWeb.RuntimeChannel.execute_tool_call/4` — and both produce
  `%{space_id, agent_id, agent_participant_id, runtime_id}`. So in production
  this yields `{:agent, id}` or `nil`.

  The `:user_id` arm is kept because the handler surface accepts a user-driven
  context (`VersionHandlers.restore/2` is exercised with one) even though no
  builder emits one today. Contexts are platform-constructed, never
  caller-supplied, so the arm is not a forgeable escalation.

  A nil `agent_id` yields NO principal. `agent_id` is a nullable `:binary_id`
  on `Platform.Agents.AgentRuntime`, so an authenticated runtime with no linked
  agent is reachable, and it must deny rather than fall through. There is
  deliberately no clause that promotes an unidentified caller to `:system`, and
  none that promotes `runtime.owner_user_id` into `{:user, id}` — that would
  hand a remote process its human owner's org-wide reach.
  """
  @spec actor(context()) :: {:agent, binary()} | {:user, binary()} | nil
  def actor(context) when is_map(context) do
    cond do
      is_binary(Map.get(context, :agent_id)) -> {:agent, Map.get(context, :agent_id)}
      is_binary(Map.get(context, :user_id)) -> {:user, Map.get(context, :user_id)}
      true -> nil
    end
  end

  def actor(_context), do: nil

  @doc """
  Resolve a canvas the caller intends to READ, or return an MCP error payload.

  Returns `{:ok, canvas}` when any read grant applies and the canvas is live;
  `{:error, payload}` otherwise. The grant level is deliberately not returned:
  no caller needs it, and echoing it back would tell a caller which door it
  came through.

  Audit is left at its default (`true`). The remount de-duplication that
  `fetch_for_viewer/3`'s `:audit` option exists for is a LiveView concern; a
  tool call is a discrete read and should mint a row.

  `opts` is passed to `CanvasAccess.fetch_for_viewer/3`. Its `:access_scope`
  (task 01a1386d-e528 stage 5, the calling runtime's
  `Platform.Access.Scope.for_runtime/1`) makes a canvas a `canvas.read` deny
  covers answer with the SAME not-found payload as a canvas id that does not
  exist. No `:access_scope`, or no grant naming `canvas.read`, and the answer
  is unchanged.
  """
  @spec fetch_for_read(term(), context(), keyword()) :: {:ok, Canvas.t()} | {:error, payload()}
  def fetch_for_read(canvas_id, context, opts \\ []) do
    case CanvasAccess.fetch_for_viewer(canvas_id, actor(context), opts) do
      {:ok, %Canvas{deleted_at: nil} = canvas, _level} ->
        {:ok, canvas}

      # Grant held, canvas deleted. `fetch_for_viewer/3` has already emitted its
      # read audit event by this point, which is the honest record: an
      # authorized principal did ask for this canvas. What it does not get is
      # the document.
      {:ok, %Canvas{}, _level} ->
        {:error, not_found_payload(canvas_id)}

      {:error, :not_found} ->
        {:error, not_found_payload(canvas_id)}

      {:error, :forbidden} ->
        emit_read_denied(canvas_id, context)
        {:error, forbidden_payload(canvas_id, @read_denial, @read_suggestion)}
    end
  end

  @doc """
  Resolve a canvas the caller intends to WRITE, or return an MCP error payload.

  Returns `{:ok, canvas}` when the caller holds `:member` or is `:system`.
  Read levels (`:task_reader`, `:org_reader`) are rejected: that asymmetry is
  `CanvasAccess.fetch_for_writer/2`'s whole point, and this function must not
  soften it.

  ## Options

    * `:denial` — the forbidden sentence. The two write tools differ only here
      (`canvas.patch` explains that read does not confer write; `canvas.restore`
      explains that it overwrites the whole document), so the sentence is the
      caller's and the resolution is shared.
    * `:suggestion` — the recovery hint. Defaults to asking a human for roster.

  Neither option reaches the not-found answer. A missing canvas is not a
  permission verdict, and reporting a permission sentence for one would tell
  the caller the canvas exists.
  """
  @spec fetch_for_write(term(), context(), keyword()) :: {:ok, Canvas.t()} | {:error, payload()}
  def fetch_for_write(canvas_id, context, opts \\ []) do
    case CanvasAccess.fetch_for_writer(canvas_id, actor(context)) do
      {:ok, canvas} ->
        {:ok, canvas}

      {:error, :not_found} ->
        {:error, not_found_payload(canvas_id)}

      {:error, :forbidden} ->
        {:error,
         forbidden_payload(
           canvas_id,
           Keyword.get(opts, :denial, @default_write_denial),
           Keyword.get(opts, :suggestion, @default_write_suggestion)
         )}
    end
  end

  # ── Denial telemetry ──────────────────────────────────────────────────────

  # Registered in `Platform.Audit.TelemetryHandler`'s `@events`. Emitted
  # synchronously, matching every other `[:platform, :chat, _]` event, so a test
  # can assert the audit row immediately after the call returns.
  @denied_event [:platform, :chat, :canvas_read_denied]

  # `canvas_id` is a binary on this branch by construction:
  # `CanvasAccess.fetch_for_viewer/3` answers `:not_found` for any non-binary
  # argument, so a value that could not be cast to the `resource_id` string
  # column never reaches here. `inspect/1` covers the branch anyway rather than
  # writing nil: a denial row that names no canvas is the same information loss
  # a failed cast would cause, reached by a different route.
  #
  # `context` is NOT assumed to be a map. `actor/1` above accepts any term
  # because callers pass `nil` and `:system`, and a detection control that turns
  # a clean denial into a `BadMapError` would be a worse outage than the one it
  # was added to catch.
  defp emit_read_denied(canvas_id, context) do
    {actor_type, actor_id} = denial_actor(actor(context))

    :telemetry.execute(
      @denied_event,
      %{system_time: System.system_time()},
      %{
        actor_id: actor_id,
        actor_type: actor_type,
        resource_type: "canvas",
        resource_id: if(is_binary(canvas_id), do: canvas_id, else: inspect(canvas_id)),
        action: "read_denied",
        # The transport, not the policy. `CanvasAccess` decides denials for the
        # LiveView too and those do not come through here; naming the surface
        # keeps a reader of the audit stream from reading absence as safety.
        surface: "mcp_tool"
      }
      # What turns a scatter of denials into an attributable sweep. The agent id
      # alone is not enough: it is nil for exactly the caller shape most worth
      # tracking, an authenticated runtime with no linked agent.
      #
      # Merged only when present, never as an explicit nil. `TelemetryHandler`'s
      # `ensure_json_safe/1` stringifies atoms, and `nil` is an atom, so a
      # nil-valued key persists as the STRING "nil" — an operator filtering on
      # `metadata->>'runtime_id' IS NULL` would get zero rows and no hint why.
      |> put_if_binary(:runtime_id, runtime_id(context))
    )

    :ok
  end

  defp runtime_id(context) when is_map(context), do: Map.get(context, :runtime_id)
  defp runtime_id(_context), do: nil

  defp put_if_binary(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp put_if_binary(map, _key, _value), do: map

  # "anonymous" is `Platform.Audit.Event`'s existing value for an
  # unauthenticated request, which is what a runtime with a nil `agent_id` is.
  # Not "system": that is the platform acting on its own behalf, and filing an
  # unidentified remote caller under it would hide the most interesting row in
  # this stream behind the most common one.
  defp denial_actor({:agent, id}), do: {"agent", id}
  defp denial_actor({:user, id}), do: {"user", id}
  defp denial_actor(nil), do: {"anonymous", nil}

  # ── Payloads ──────────────────────────────────────────────────────────────

  # `canvas_id` is echoed exactly as the caller sent it, including a malformed
  # value: it is the caller's own input, and echoing it is what lets a model
  # correlate the denial with the call it made. Nothing else about the canvas
  # appears in either payload — see the moduledoc.
  defp not_found_payload(canvas_id) do
    %{
      error: "canvas #{inspect_id(canvas_id)} not found",
      recoverable: false,
      canvas_id: canvas_id,
      suggestion: @not_found_suggestion
    }
  end

  defp forbidden_payload(canvas_id, denial, suggestion) do
    %{
      error: denial,
      recoverable: false,
      canvas_id: canvas_id,
      suggestion: suggestion
    }
  end

  defp inspect_id(canvas_id) when is_binary(canvas_id), do: canvas_id
  defp inspect_id(canvas_id), do: inspect(canvas_id)
end
