defmodule Platform.Responsibilities.NativeDispatchEnvelopeTest do
  @moduledoc """
  The `system_event` envelope AS IT LEAVES THE SERVER — pinned at the last
  boundary `core` can observe, the `PlatformWeb.Endpoint.broadcast/3` on
  `runtime:<runtime_id>`.

  ## The contract being pinned

  The native (chatless) responsibility fire broadcasts a BARE envelope:

      %{signal: %{...}}

  and nothing else. No `message`, no `history`, no `context` — those keys
  belong to the chat-triggered path (`dispatch_to_external/2`), and the two
  shapes are deliberately not unified. Within the signal:

    * the human-readable body is at `signal.prompt`, and ONLY there;
    * the correlation ids (`task_id`, `plan_id`, `stage_id`, `project_id`)
      appear BOTH at the signal root — so a federated runtime can read them
      without digging — AND in `signal.metadata`, where the Router put them,
      so no existing consumer is broken. The lift is additive;
    * `space_id` is deliberately absent at both levels;
    * a key with no value is omitted entirely rather than sent as nil, which
      is what keeps "absent" a meaningful assertion here.

  A `message` key mirroring `signal.prompt` was considered during this task
  and deliberately not shipped — see `build_system_event_payload/1` in
  `agent_responder.ex`. Its absence is asserted below for the body-bearing
  case as well as the empty one, because the general contract is "one body,
  one key" rather than "no body, no key".

  ## HONESTY LIMIT — read this before trusting the file

  **This test could not have failed for the bug that actually happened, and
  no test in this repo could have.**

  `Responsibilities.Router.build_native_signal/4` was correct throughout the
  entire defect: it put `prompt`, `plan_id` and `task_id` into `metadata` the
  whole time. The defect was on the CLIENT side of the websocket — the
  inbound handlers read the chat path's `message.content` against a payload
  that carried real data under keys they did not read. A server-side
  assertion of what the server builds proves nothing about a consumer
  reading the wrong key, and this file must not be cited as if it did. The
  fix landed in the clients, under tasks `019fa56b` and `019fa618-ca92`.

  What this file CAN do, and is for:

    * pin the payload SHAPE, so a future server-side change that drops
      `signal.prompt`, stops lifting the correlation ids, or re-widens the
      envelope is caught here rather than six days later in a transcript
      audit; and
    * give the client repos a captured, real envelope to write their own
      inbound-handler fixture tests against. The cross-repo half of the
      regression lives there, not here.

  ## Why the whole path, and not `build_native_signal/4` in isolation

  Every value asserted below travels four modules before it is measured:
  `Router.fire_trigger/2` → `Providers.Architecture.build_prompt/1` →
  `AgentResponder.respond/1` → the PubSub broadcast. A unit test on the
  Router would assert a map the Router had just built — the tautology this
  stage exists to avoid. So the responsibility row comes from
  `ArchitectureReviewPlan.register/0`, the prompt is rendered by the real
  provider over a real seeded plan, and the assertion is on the
  `%Phoenix.Socket.Broadcast{}` a subscribed runtime actually receives.

  `{:ok, :dispatched}` from `fire_trigger/2` is deliberately NOT the
  evidence — it means the hand-off was accepted, and it is `:ok` on a path
  that broadcasts an empty envelope. The received broadcast is the evidence.

  ## Fixture non-degeneracy

  Prior stages of this task were repeatedly bitten by fixtures that made a
  mutation invisible, so, explicitly:

    * `task_id`, `plan_id`, `stage_id` and `project_id` are four DISTINCT
      generated ids. A mutation that swaps two of them in the lift, or that
      lifts one key under another's name, changes an assertion.
    * `signal.prompt` is pinned to a measured, data-derived block
      (`@plan_summary_shape` rendered over the seeded ids) rather than to a
      `byte_size(...) > n` property. A property assertion is satisfied by
      any long string, including a wrong one.
    * every absence assertion about the envelope sits next to a positive
      assertion on the SAME received payload — `signal.prompt` pinned to
      seeded content, the ids pinned to seeded ids — so no refute can be
      passing because the body arrived hollow.
    * every `refute Map.has_key?/2` is preceded, in the same test, by
      positive assertions on other keys of the same map, so it cannot pass
      because the broadcast never arrived.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.ArchitectureReviewPlan
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Tasks

  # Measured off a probe run, not restated from the handler source. These are
  # the first and last sentences of `ArchitectureReviewPlan.build_prompt/1`'s
  # SYSTEM slot, which `Router.classify_prompt_outcome/1` joins to the user slot
  # with exactly one blank line. Pinning both ends of the system half plus the
  # start of the user half is what makes the join itself observable: collapse
  # the "\n\n" separator, or drop the system turn from
  # `prompt_map_to_messages/2`, and one of the three goes red.
  @system_half_opens "You are the Architect on the Suite plan-review path (ADR-0044, gated by ADR-0046)."
  @system_half_closes "a number is not a reference the human reviewer can follow."
  @user_half_opens "You are the Architect. A plan has been submitted and **it is held at\n" <>
                     "`pending_review` until you answer.**"

  setup do
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)

    # `maybe_dispatch/1` spawns an unlinked Task in :async mode, which would
    # both race `assert_receive` and land outside the ownership sandbox.
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    # RuntimePresence is a process-global Agent; the presence lookup at
    # `broadcast_system_event/3` reads through it, and without this allowance
    # the online? check runs unowned and the fire dead-letters instead of
    # broadcasting.
    presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), presence)

    on_exit(fn ->
      if previous_mode do
        Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
      else
        Application.delete_env(:platform, :chat_agent_dispatch_mode)
      end
    end)

    :ok
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  # `kind: "native"` + `runtime_type: "external"` is the federated shape:
  # `Router.dispatch_assignee/4` sends it down `dispatch_native/6` (an
  # `Agent.kind` of "external" would take the HTTP path instead), and
  # `AgentResponder.dispatch_system_event/2`'s first clause matches on
  # `runtime_type: "external"` with a binary `runtime_id`. Both halves are
  # required; getting either wrong silently routes to a path that broadcasts
  # nothing, which is why the topic subscription is set up here too.
  defp federated_assignee(responsibility_key) do
    owner =
      Repo.insert!(%User{
        email: "nde-#{uniq()}@example.com",
        name: "Envelope Owner",
        oidc_sub: "oidc-nde-#{uniq()}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-nde-#{uniq()}",
        display_name: "envelope-runtime"
      })

    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "nde-agent-#{uniq()}",
        name: "Envelope Assignee",
        status: "active",
        kind: "native",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert!()

    {:ok, _} = Roles.set_override(responsibility_key, agent.id)

    topic = "runtime:#{runtime.runtime_id}"
    :ok = PlatformWeb.Endpoint.subscribe(topic)

    %{agent: agent, runtime: runtime, topic: topic}
  end

  # The row comes from the handler's own `register/0`. A hand-written map
  # would keep passing against a spec nobody dispatches.
  defp review_plan_row do
    [spec] = ArchitectureReviewPlan.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    row
  end

  defp seed_plan do
    {:ok, project} = Tasks.create_project(%{name: "Envelope Project #{uniq()}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "NDE_TASK_TITLE",
        description: "NDE_TASK_INTENT",
        status: "planning"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "NDE_STAGE_NAME",
        description: "NDE_STAGE_DESCRIPTION"
      })

    %{project: project, task: task, plan: plan, stage: stage}
  end

  # The exact block `architecture.review_plan.v1` renders from the gathered
  # `:plan_payload` slot, measured from a probe run. It is the strongest pin
  # available on `signal.prompt` that is not a restatement of the test's own
  # variables: every id in it took the four-module trip, and all four are
  # distinct, so an id printed under the wrong label fails here.
  defp plan_summary_block(%{project: project, task: task, plan: plan, stage: stage}) do
    """
    ## Plan summary (task under review)

    Task: #{task.title} (task_id: #{task.id})
    Task status: planning
    Task intent:
      #{task.description}

    plan_id: #{plan.id}
    Plan version: 1 (status: draft)
    Project: #{project.id}

    Stages (1):
      - stage 1 — #{stage.name} [pending]: #{stage.description}
        stage_id: #{stage.id}
        gates: (none — this stage is unprotected)
    """
    |> String.trim_trailing()
  end

  defp await_envelope(topic) do
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "attention",
                     payload: payload
                   },
                   2000

    payload
  end

  # ── the fired envelope ─────────────────────────────────────────────────────

  describe "architecture.review_plan fired at a federated runtime" do
    setup do
      row = review_plan_row()
      seeded = seed_plan()
      runtime = federated_assignee(row.key)

      Map.merge(seeded, Map.put(runtime, :row, row))
    end

    test "the broadcast envelope carries the rendered prompt at signal.prompt and nowhere else",
         ctx do
      # The four ids are distinct by construction — see the moduledoc's
      # fixture-degeneracy note. They are passed as the trigger meta the
      # plan-submit hook publishes.
      assert {:ok, :dispatched} =
               Router.fire_trigger(ctx.row, %{
                 kind: :event_topic,
                 plan_id: ctx.plan.id,
                 task_id: ctx.task.id,
                 stage_id: ctx.stage.id,
                 project_id: ctx.project.id
               })

      payload = await_envelope(ctx.topic)
      signal = payload.signal
      prompt = signal.prompt

      # ── the body, pinned to measured content ─────────────────────────────
      #
      # THIS is the assertion the stage brief calls the control: a binary of
      # real, seeded, four-module-travelled content. Had the server ever been
      # the culprit, this is the line that would have gone red.
      assert is_binary(prompt)
      assert prompt =~ plan_summary_block(ctx)

      # The join `classify_prompt_outcome/1` performs, both ends of it. Two
      # halves, one blank line, system first.
      assert [system_half, user_half] = String.split(prompt, "\n\n", parts: 2)
      assert String.starts_with?(system_half, @system_half_opens)
      assert String.ends_with?(system_half, @system_half_closes)
      assert String.starts_with?(user_half, @user_half_opens)

      # Not the legacy template-render fallback, which emits the bare slug
      # string as the entire user turn and no system turn at all.
      refute prompt =~ ArchitectureReviewPlan.template_slug()

      # ── the envelope is BARE, body-bearing case included ─────────────────
      #
      # `signal.prompt` above is the ONE body key on this path, and it is
      # asserted non-empty and content-pinned four lines up — so this refute
      # cannot be passing because the dispatch never fired or arrived hollow.
      #
      # The absence of `message` is the GENERAL contract here, not a
      # no-prompt special case: a mirrored `message.content` was considered
      # and rejected (see `agent_responder.ex`,
      # `build_system_event_payload/1`), because two keys carrying one body
      # is what let the two envelope shapes diverge. This is the assertion
      # that goes red if someone re-adds the shim.
      refute Map.has_key?(payload, :message)
      assert Map.keys(payload) == [:signal]

      # ── correlation ids at the TOP level (stage 4's lift) ────────────────
      assert signal.task_id == ctx.task.id
      assert signal.plan_id == ctx.plan.id
      assert signal.stage_id == ctx.stage.id
      assert signal.project_id == ctx.project.id

      # ...and still in metadata, where the Router put them. Lifting is
      # additive; a consumer reading `signal.metadata.task_id` keeps working.
      assert signal.metadata.task_id == ctx.task.id
      assert signal.metadata.plan_id == ctx.plan.id
      assert signal.metadata.stage_id == ctx.stage.id
      assert signal.metadata.project_id == ctx.project.id
      assert signal.metadata.prompt == prompt

      # ── the status, on the case that HAS a body ──────────────────────────
      #
      # `prompt_status` is present even when it is `:rendered`, so a client
      # can read its ABSENCE as "this server predates the field" rather than
      # having to infer the status from whether `prompt` showed up.
      assert signal.prompt_status == :rendered
      assert signal.metadata.prompt_status == :rendered

      # And the reason key is absent here. A status field that is always
      # populated is not evidence that any branch ran; this refute is what
      # makes the `:no_work` / `:render_gap` reasons below mean something,
      # and it sits beside a `prompt` pinned to seeded content above.
      refute Map.has_key?(signal, :prompt_absence_reason)
      refute Map.has_key?(signal.metadata, :prompt_absence_reason)

      # ── routing identity ─────────────────────────────────────────────────
      assert signal.reason == :system_event
      assert signal.responsibility_key == "architecture.review_plan"
      assert signal.feature == "architecture"
      assert signal.trigger_kind == :event_topic
      assert signal.agent_id == ctx.agent.id
      assert signal.agent_slug == ctx.agent.slug
    end

    # WHAT THE WHOLE-PATH DRIVE SHOWS THAT A UNIT TEST CANNOT.
    #
    # Stage 4 pinned `space_id`'s absence by handing `AgentResponder.respond/1`
    # a metadata map that already contained one, and refuting the lift took
    # it. Driven from `fire_trigger/2` the absence turns out to be
    # OVERDETERMINED, and neither cause is the lift whitelist:
    #
    #   1. `Router.put_trigger_scalars/2`'s whitelist is
    #      `[:task_id, :plan_id, :stage_id, :project_id]`, so a trigger's
    #      `space_id` never enters `metadata` on this path at all; and
    #   2. `Router.build_native_signal/4` DOES put it on the signal ROOT
    #      (`router.ex:1432`), and `AgentResponder.build_system_event_signal/2`
    #      then rebuilds the signal from `context[:metadata]` alone — so the
    #      root `space_id` the Router set is DISCARDED before the broadcast.
    #
    # Recorded because it is load-bearing in the opposite direction to how it
    # reads: the space a responsibility fire came from is not recoverable by a
    # runtime today, at either level, and three separate places would have to
    # change to make it so. `claude-code-suite-channel`'s `src/attention.ts`
    # pins where a pending permission prompt gets answered from the top-level
    # `signal.space_id` ONLY, so that is the guard being preserved.
    test "the trigger's space_id survives to neither the signal root nor its metadata",
         ctx do
      space_id = Ecto.UUID.generate()

      assert {:ok, :dispatched} =
               Router.fire_trigger(ctx.row, %{
                 kind: :event_topic,
                 plan_id: ctx.plan.id,
                 task_id: ctx.task.id,
                 space_id: space_id
               })

      payload = await_envelope(ctx.topic)
      signal = payload.signal

      # Positive control for the refutes: a populated envelope really did
      # arrive from THIS fire, carrying the ids the whitelist does admit and
      # a body at the contract key.
      assert signal.task_id == ctx.task.id
      assert signal.plan_id == ctx.plan.id
      assert signal.metadata.task_id == ctx.task.id
      assert String.starts_with?(signal.prompt, @system_half_opens)

      # Bare envelope again, on a second body-bearing fire.
      refute Map.has_key?(payload, :message)

      refute Map.has_key?(signal, :space_id)
      refute Map.has_key?(signal.metadata, :space_id)
    end
  end

  # ── the no-prompt envelope ─────────────────────────────────────────────────

  describe "a fire whose feature has no registered provider" do
    setup do
      key = "ndenoprovider.fire#{uniq()}"

      {:ok, row} =
        Responsibilities.create_responsibility(%{
          key: key,
          feature: "ndenoprovider",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 4 * * *"},
          scope: "global",
          cost_profile: "low_freq_capable"
        })

      seeded = seed_plan()
      runtime = federated_assignee(key)

      Map.merge(seeded, Map.put(runtime, :row, row))
    end

    test "omits the prompt key entirely rather than sending an empty body, and still lifts the ids",
         ctx do
      # `Providers.feature_provider("ndenoprovider")` returns `:error`, so
      # `build_prompt_via_provider/2` falls to `:legacy`, which
      # `classify_prompt_outcome/1` names `{:absent, :legacy}` and
      # `build_native_signal/4` renders as an omitted key. This is the real
      # production shape for a feature with no `build_prompt/1`, driven end to
      # end rather than simulated by handing the responder a nil prompt.
      assert {:ok, :dispatched} =
               Router.fire_trigger(ctx.row, %{
                 kind: :cron,
                 task_id: ctx.task.id,
                 plan_id: ctx.plan.id,
                 stage_id: nil
               })

      payload = await_envelope(ctx.topic)
      signal = payload.signal

      # POSITIVE CONTROL, first and deliberately verbose. `refute
      # Map.has_key?/2` passes on a map that never arrived and on one that
      # arrived empty; these assertions establish that a real, populated
      # envelope is in hand before anything is refuted about it.
      assert signal.reason == :system_event
      assert signal.responsibility_key == ctx.row.key
      assert signal.feature == "ndenoprovider"
      assert signal.trigger_kind == :cron
      assert signal.agent_id == ctx.agent.id
      assert signal.agent_slug == ctx.agent.slug

      # The lift is independent of whether a prompt rendered — a client still
      # needs to know which task woke it even when the body is empty.
      assert signal.task_id == ctx.task.id
      assert signal.plan_id == ctx.plan.id
      assert signal.metadata.task_id == ctx.task.id
      assert signal.metadata.plan_id == ctx.plan.id

      # No prompt rendered, so no body key at all. An empty `signal.prompt`
      # would read to a client as "the server had something to say and it was
      # nothing"; an absent key lets a client's own
      # `System dispatch: <reason>` placeholder do its job.
      refute Map.has_key?(signal, :prompt)

      # ...but the SILENCE IS NOW NAMED (stage 3). The key stays absent; what
      # changed is that the envelope says why, so a runtime can tell this
      # apart from a provider that deliberately declined.
      assert signal.prompt_status == :render_gap
      assert signal.prompt_absence_reason == "provider_has_no_build_prompt"
      assert signal.metadata.prompt_status == :render_gap
      assert signal.metadata.prompt_absence_reason == "provider_has_no_build_prompt"

      # Same bare envelope as the body-bearing case — the shape does not vary
      # with whether a prompt rendered, only `signal.prompt` does.
      assert Map.keys(payload) == [:signal]
      refute Map.has_key?(payload, :message)
      refute Map.has_key?(payload, :history)
      refute Map.has_key?(payload, :context)

      # A nil scalar produces NO key rather than a nil one, at both layers —
      # `Router.put_trigger_scalars/2`'s is_binary guard and
      # `AgentResponder.maybe_put/3`. That is what keeps "absent" meaningful
      # for the two ids asserted present above.
      refute Map.has_key?(signal, :stage_id)
      refute Map.has_key?(signal.metadata, :stage_id)
    end
  end

  # ── deliberate silence vs. a broken render ─────────────────────────────────
  #
  # THE QUESTION THIS SECTION ANSWERS ON THE WIRE, and the reason the whole
  # task exists.
  #
  # An empty prompt is SOMETIMES LEGITIMATE.
  # `Handlers.MeetingActionItems.build_prompt/1` returns
  # `{:error, :no_transcript_text}` on purpose over a blank transcript — a
  # model round-trip over no content is spend with no possible output — and
  # `gather_transcript(nil)` yields `formatted_text: ""`, so a fire whose
  # `transcript_id` does not resolve lands there too. That is the
  # discriminating datapoint in the original report: the `meetings.action_items`
  # fire that rendered had transcript text and the later one had none.
  # Content-dependent, not intermittent, not a regression.
  #
  # A wiring gap and a render gap are NOT legitimate. Before this stage all
  # three left the server as the same envelope.
  describe "prompt_status tells deliberate silence apart from a render gap" do
    setup do
      # (a) THE LEGITIMATE NO-WORK FIRE — the real registered row, the real
      # handler, the real refusal. A throwaway provider returning
      # `{:error, :no_transcript_text}` would prove the mapping table and
      # nothing about whether any shipping key can reach it.
      [action_items_attrs] = MeetingActionItems.register()
      {:ok, no_work_row} = Responsibilities.upsert_by_key(action_items_attrs)
      no_work = Map.put(federated_assignee(no_work_row.key), :row, no_work_row)

      # (b) THE RENDER GAP — a feature with no registered provider at all,
      # which is the production shape of `tasks.*` before stage 2 and of any
      # key whose provider ships no `build_prompt/1`.
      gap_key = "ndenoprovider.gap#{uniq()}"

      {:ok, gap_row} =
        Responsibilities.create_responsibility(%{
          key: gap_key,
          feature: "ndenoprovider",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 5 * * *"},
          scope: "global",
          cost_profile: "low_freq_capable"
        })

      gap = Map.put(federated_assignee(gap_key), :row, gap_row)

      %{no_work: no_work, gap: gap}
    end

    # THE ASSERTION THE WHOLE TASK EXISTS FOR. Two REAL envelopes, captured
    # from two real fires, held side by side.
    #
    # WHAT FAILURE LOOKS LIKE: if a future edit maps both causes onto one
    # atom — the exact defect being removed — the inequality goes red and
    # prints the shared value. A pair of independent equality assertions
    # would BOTH stay green if the mapping table were deleted and replaced
    # with a constant, as long as the constant were the right one for each;
    # only the inequality refuses a collapse directly. Both shapes are here
    # because the inequality alone is satisfied by any two distinct wrong
    # values.
    test "a blank transcript is :no_work, an absent builder is :render_gap, and they differ",
         ctx do
      assert {:ok, :dispatched} =
               Router.fire_trigger(ctx.no_work.row, %{
                 kind: :event_topic,
                 payload: %{transcript_id: nil}
               })

      no_work = await_envelope(ctx.no_work.topic).signal

      assert {:ok, :dispatched} =
               Router.fire_trigger(ctx.gap.row, %{kind: :cron, fired_at: DateTime.utc_now()})

      gap = await_envelope(ctx.gap.topic).signal

      # POSITIVE CONTROL FIRST, on BOTH envelopes and before any refutation.
      # `refute Map.has_key?/2` passes on an envelope that never arrived, so
      # without this a broken fixture reads as a pass.
      assert no_work.reason == :system_event
      assert no_work.responsibility_key == "meetings.action_items"
      assert no_work.feature == "meetings"
      assert no_work.trigger_kind == :event_topic
      assert no_work.agent_id == ctx.no_work.agent.id

      assert gap.reason == :system_event
      assert gap.responsibility_key == ctx.gap.row.key
      assert gap.feature == "ndenoprovider"
      assert gap.trigger_kind == :cron
      assert gap.agent_id == ctx.gap.agent.id

      # THE DISTINGUISHABILITY ASSERTION.
      assert no_work.prompt_status != gap.prompt_status,
             "two causes that need different fixes collapsed onto the shared status " <>
               inspect(no_work.prompt_status) <>
               " — that is the defect this task exists to remove"

      assert no_work.prompt_status == :no_work
      assert gap.prompt_status == :render_gap

      # The reason names the cause, not merely the fact.
      assert no_work.prompt_absence_reason == "no_transcript_text"
      assert gap.prompt_absence_reason == "provider_has_no_build_prompt"

      # NEITHER SHIPS A BODY. The status is an ADDITION; re-adding an empty
      # `prompt` would break this for the right reason.
      refute Map.has_key?(no_work, :prompt)
      refute Map.has_key?(gap, :prompt)

      # `metadata` is passed whole by `AgentResponder.build_system_event_signal/2`,
      # so the metadata copy comes free — asserted rather than assumed, since
      # a consumer reading `signal.metadata.prompt_status` is as likely as one
      # reading the root.
      assert no_work.metadata.prompt_status == :no_work
      assert gap.metadata.prompt_absence_reason == "provider_has_no_build_prompt"
    end

    # TWO DIFFERENT GAPS, ONE STATUS, DIFFERENT REASONS. `:render_gap` is a
    # verdict a client branches on; `prompt_absence_reason` is what tells a
    # human which row to go seed. Pinning the slug-carrying shape is what
    # stops the reason from quietly becoming a constant per status.
    test "a default_prompt_template with no row is a render gap that names the slug", ctx do
      slug = "nde.nonexistent_#{uniq()}.v1"
      refute PromptTemplates.get_template_by_slug(slug)

      key = "ndenoprovider.missingtmpl#{uniq()}"

      {:ok, row} =
        Responsibilities.create_responsibility(%{
          key: key,
          feature: "ndenoprovider",
          trigger_kind: "cron",
          trigger_config: %{"expression" => "0 6 * * *"},
          scope: "global",
          cost_profile: "low_freq_capable",
          default_prompt_template: slug
        })

      %{topic: topic, agent: agent} = federated_assignee(key)

      assert {:ok, :dispatched} =
               Router.fire_trigger(row, %{kind: :cron, fired_at: DateTime.utc_now()})

      signal = await_envelope(topic).signal

      assert signal.responsibility_key == key
      assert signal.agent_id == agent.id
      assert signal.prompt_status == :render_gap
      assert signal.prompt_absence_reason == "template_missing:#{slug}"
      refute Map.has_key?(signal, :prompt)

      # Same status as the no-builder gap in the test above — deliberately,
      # a client's branch is on the status — but NOT the same reason, which
      # is the half a human acts on.
      refute signal.prompt_absence_reason == "provider_has_no_build_prompt"

      # ...and still distinct from the legitimate case, driven here rather
      # than restated so the comparison is between two received envelopes.
      assert {:ok, :dispatched} =
               Router.fire_trigger(ctx.no_work.row, %{
                 kind: :event_topic,
                 payload: %{transcript_id: nil}
               })

      no_work = await_envelope(ctx.no_work.topic).signal
      assert no_work.prompt_status != signal.prompt_status
    end

    # THE OBSERVABILITY HALF. `dispatch_external/5` aborts on a refusal and
    # emits `failed` telemetry; `dispatch_native/6` proceeds silently, which
    # is why three keys could ship empty for weeks without a counter moving.
    # Native's dispatch DECISION is deliberately unchanged — the agent still
    # wakes — but the gap is now countable rather than only greppable.
    #
    # Attached and asserted directly rather than read off a globally-attached
    # handler: `TelemetryHandlerTest`'s `on_exit` detaches
    # `Platform.Audit.TelemetryHandler` globally, and a test that depended on
    # it would silently stop observing anything.
    test "a gap emits prompt_absent telemetry and a rendered dispatch does not", ctx do
      test_pid = self()
      handler_id = "nde-prompt-absent-#{uniq()}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:platform, :responsibilities, :prompt_absent],
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:prompt_absent, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # THE RENDERED FIRE FIRST, so the refute below has a positive control:
      # a real dispatch that really happened and really carried a body.
      review_row = review_plan_row()
      seeded = seed_plan()
      %{topic: review_topic} = federated_assignee(review_row.key)

      assert {:ok, :dispatched} =
               Router.fire_trigger(review_row, %{
                 kind: :event_topic,
                 plan_id: seeded.plan.id,
                 task_id: seeded.task.id
               })

      rendered = await_envelope(review_topic).signal
      assert rendered.prompt_status == :rendered
      assert is_binary(rendered.prompt)

      refute_receive {:prompt_absent, _measurements, _metadata}, 200

      # ...and now the gap.
      assert {:ok, :dispatched} =
               Router.fire_trigger(ctx.gap.row, %{kind: :cron, fired_at: DateTime.utc_now()})

      _ = await_envelope(ctx.gap.topic)

      assert_receive {:prompt_absent, measurements, metadata}, 1000

      assert metadata.key == ctx.gap.row.key
      assert metadata.feature == "ndenoprovider"
      assert metadata.prompt_status == :render_gap
      assert metadata.reason == "provider_has_no_build_prompt"
      assert metadata.dispatch == :native
      assert is_integer(measurements.system_time)
    end
  end

  # WHICH REFUSALS COUNT AS LEGITIMATE — pinned, because the list is the one
  # place a real gap could be mislabelled as deliberate silence.
  #
  # The whitelist's asymmetry is the point: a new refusal wrongly reported as
  # a gap is noise someone fixes in one line, while a new gap wrongly
  # reported as `:no_work` is silence, which is the defect. `:no_build_prompt`
  # is the trap — it arrives shaped like a refusal but means "this key does
  # not own its prompt", which is a wiring gap.
  describe "the no-work refusal whitelist" do
    test "names only reasons a provider chose, and never :no_build_prompt" do
      assert Router.no_work_refusals() == [:no_transcript_text]
      refute :no_build_prompt in Router.no_work_refusals()
    end
  end
end
