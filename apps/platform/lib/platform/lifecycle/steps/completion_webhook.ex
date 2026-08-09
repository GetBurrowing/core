defmodule Platform.Lifecycle.Steps.CompletionWebhook do
  @moduledoc """
  NOTIFY: POST a completion payload when a task reaches `done`
  (ADR-0046, task 019fe1b7 stage 4).

  Fire-and-report. It is **never a gate**: it cannot hold a transition and
  cannot send a task back, and that is enforced in two independent places
  rather than trusted to the declaration site — see "A notify cannot gate".

  ## The edge set is `->done` ONLY, and that is a decision, not an inheritance

  Stage 3's effect hangs on `EdgeInventory.terminal_edges/0`, which is every
  inbound edge to `done` **or `cancelled`**. This notify deliberately hangs on
  the narrower `EdgeInventory.completion_edges/0` — the inbound edges to
  `done` alone.

  Sharing stage 3's helper would have been one character cheaper and wrong.
  The two hooks answer different questions. Worktree cleanup asks *"is anyone
  coming back to this directory?"*, and for a cancelled task the answer is no,
  so the effect belongs there. This webhook makes an **outbound claim to a
  third party** that a task completed. A cancelled task did not complete;
  telling a consumer it did is a false statement, and one that no consumer can
  correct from the payload because `status` would read `"cancelled"` on an
  event whose whole name says otherwise. If cancellation notification is
  wanted it is a different event with a different payload, declared on the
  `->cancelled` edges explicitly — not acquired by accident from a shared
  terminal-edge helper.

  Within `->done` the set is still DERIVED, never transcribed, and that
  matters for the same reason it did in stage 3: ADR-0041 stack members reach
  `done` from `in_review` or `in_progress` and **never pass through
  `deploying`**. A webhook hung on `deploying->done` alone would fire for solo
  tasks, look correct in every test written about it, and silently never fire
  for a stack member.

  ## A notify cannot gate — REJECTED AT CONFIG LOAD (option chosen)

  The stage offered two options: reject the gate-shaped declaration at config
  load, or accept it and make it have no blocking effect. **Rejection at
  config load is what ships.**

  Why that one: "accepted but ignored" is the silence this whole ADR is
  written against. A pipeline author who writes `await: true` on a notify has
  a belief about their pipeline; an implementation that quietly ignores the
  flag leaves the belief intact and unfalsifiable, and it is indistinguishable
  from a `can_divert` that stopped working. A load-time rejection with its own
  message is a bug report. It also mirrors the rule already next to it —
  `backlog.created` prohibits gates the same way, with the same structured
  error shape.

  The rule keys off the REGISTRY entry (`StepRegistry.notify_step?/2`), not
  off the step's name or its position, so it applies to any future notify and
  cannot be defeated by reordering.

  The shipped declaration in `Platform.Lifecycle.Edges.default_steps/1` is
  `await: false, can_divert: false`, which is the same rule satisfied rather
  than exempted.

  ## `:sync`, and the honest limit on "cannot stall the transition"

  This step settles inside `start/2`, which means it runs INLINE on the
  transition path — `await: false` buys nothing here, because the executor
  only awaits things that returned `{:running, ref}`. `:sync` is chosen
  anyway: a detached POST would leave the run row at `started` forever, and
  the stage requires a `failed` row for a webhook that a consumer rejected.

  What bounds the inline call is `Platform.Lifecycle.step_timeout_ms/0`,
  taken from the executor's context — member 3's per-step budget, NOT a second
  timeout knob invented here. It is applied as both a connect and a receive
  timeout, and Req's retry is disabled so the wall clock is one timeout and
  not three.

  Stated plainly because it is a real limit and not a solved problem: that
  budget defaults to thirty minutes, which bounds the transition path in the
  formal sense and not in any useful one. Closing it properly needs either a
  notify-specific budget (a second knob, which this stack forbids) or a
  durable outbox the POST is drained from (a migration nobody has written).
  Under test the executor's injected budget is small, so the tests bound
  themselves.

  ## The URL is configuration and appears nowhere in this repository

  This repository is public. The endpoint is supplied per project in the
  pipeline declaration's `"url"` key, validated against
  `StepRegistry.webhook_host_allowed?/1` (empty by default — fail-closed) at
  config load. There is no default URL, no fallback host, and no literal
  hostname in `lib/`. A declaration with no `"url"` posts NOTHING and reports
  `{:completed, %{posted: false, reason: :not_configured}}` — which is the
  shipped default's state, and is `completed` rather than `not_applicable`
  for the same reason stage 3 gave: `not_applicable` belongs to a traversed
  edge with an EMPTY pipeline, and this pipeline is not empty.

  ## The payload carries four keys and no runtime identity

  `task_id`, `project_id`, `status`, `edge`. The terminating edge is included
  so a consumer can tell a stack member's `in_review->done` from a solo task's
  `deploying->done`. Agent runtime ids, session ids, worktree paths and host
  references are deliberately absent — they are exactly the fields that make a
  payload unshippable from a public codebase, and a consumer that needs them
  should be reading an API, not a webhook.
  """

  @behaviour Platform.Lifecycle.Step

  alias Platform.Lifecycle

  @impl Platform.Lifecycle.Step
  def kind, do: :sync

  @doc """
  Arity-1 entry point for the registry's `{mod, fun, 1}` MFA shape.

  Same shim the other built-in steps carry. The executor prefers `start/2`
  when the module exports it, but a test asserts every allowlist entry
  resolves to a real arity-1 function.
  """
  @spec start(map()) :: Platform.Lifecycle.Step.start_result()
  def start(context) when is_map(context), do: start(%{}, context)

  @impl Platform.Lifecycle.Step
  def start(step_config, %{task: task, edge: edge} = context) when is_map(step_config) do
    case Map.get(step_config, "url") do
      url when is_binary(url) and url != "" ->
        post(url, payload(task, edge), timeout_ms(context))

      _no_url ->
        {:completed, %{posted: false, reason: :not_configured}}
    end
  end

  @doc """
  The completion payload, as posted.

  Exposed so a test can pin the EXACT key set against the shipped builder
  rather than against a copy of it written in the test.
  """
  @spec payload(struct(), binary()) :: map()
  def payload(task, edge) when is_binary(edge) do
    %{
      "task_id" => task.id,
      "project_id" => task.project_id,
      "status" => task.status,
      "edge" => edge
    }
  end

  # The executor puts its own effective per-step budget in the context. Falling
  # back to `Lifecycle.step_timeout_ms/0` covers a direct caller; neither branch
  # introduces a knob of its own.
  defp timeout_ms(context) do
    case Map.get(context, :step_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _absent -> Lifecycle.step_timeout_ms()
    end
  end

  defp post(url, payload, timeout) do
    # `retry: false` on purpose: Req retries transport errors and 5xx by
    # default, which would multiply the one budget above by the retry count
    # and turn a bounded inline call into an unbounded one.
    req_client()
    |> Req.post(
      url: url,
      json: payload,
      retry: false,
      receive_timeout: timeout,
      connect_options: [timeout: timeout]
    )
    |> case do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:completed, %{posted: true, status: status}}

      {:ok, %Req.Response{status: status}} ->
        {:failed, {:webhook_rejected, status}}

      {:error, reason} ->
        {:failed, {:webhook_transport_error, reason}}
    end
  rescue
    error -> {:failed, {:webhook_error, error}}
  end

  # Injectable client read from app env, mirroring
  # `Platform.ExternalAgents.req_client/0` and
  # `Platform.Memory.Providers.StartupSuite.req_client/0`. Tests stub with
  # `Req.Test`; nothing here hardcodes a client, so the step is testable
  # without a network.
  defp req_client do
    Application.get_env(:platform, :completion_webhook_req_client, Req.new())
  end
end
