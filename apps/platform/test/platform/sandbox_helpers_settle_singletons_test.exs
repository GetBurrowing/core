# Pins `Platform.SandboxHelpers.settle_singletons/1` — the teardown barrier
# that keeps a singleton's cast-driven Repo work inside the sandbox owner's
# lifetime (task 01a0d4d6 stage 1).
#
# The measured leak it closes: `RuntimeChannel.join/3` casts
# `DeadLetterReplay.schedule/1`, the drain runs INLINE in `handle_cast` with
# `spacing_ms/0` sleeps between deliveries, and nothing waited for it — so the
# owner exited while the drain was still in `DeadLetters.pending_for_runtime/1`
# (7/6/7 "still using a connection from owner" events per full run, seeds
# 77/7700/70007, all with Client `Platform.Federation.DeadLetterReplay`).
#
# What is asserted is an OBSERVABLE CONSEQUENCE of the wait, not the call: two
# replayable rows are queued, the drain is CAST (the production path, default
# spacing), and the barrier is called straight after. Both rows must already be
# `replayed` when it returns. Drop `DeadLetterReplay` from the settle list and
# the barrier returns within milliseconds, while the second delivery is still
# behind its 250ms gap — the second row is `pending`, and this goes red.
#
# `async: false` for the reason in `dead_letter_replay_test.exs`'s header: the
# drain runs in a shared singleton that can only use this test's connection via
# shared sandbox mode.
defmodule Platform.SandboxHelpersSettleSingletonsTest do
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.AgentResponder
  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetterReplay
  alias Platform.Federation.RuntimePresence
  alias Platform.SandboxHelpers
  alias Platform.Tasks

  setup do
    runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), runtime_pres)
    :ok
  end

  describe "settle_singletons/1" do
    test "returns only after an in-flight DeadLetterReplay cast drain has finished" do
      ctx = offline_runtime("settle")
      subject = fresh_subject("Settle")

      rows =
        for position <- 1..2 do
          {:ok, stage} =
            Tasks.create_stage(%{
              plan_id: subject.plan.id,
              position: position,
              name: "Stage #{position}",
              status: "passed"
            })

          dead_letter_via_responder(ctx, stage_metadata(%{subject | stage: stage}))
        end

      # PRE-state: both queued. Without this the assertion below could pass on
      # rows that were never pending.
      assert Enum.map(rows, &reload(&1).disposition) == ["pending", "pending"]

      RuntimePresence.track(ctx.runtime.runtime_id)

      # The production path: a cast, default spacing. Nothing but the barrier
      # below waits for it.
      :ok = DeadLetterReplay.schedule(ctx.runtime.runtime_id)

      assert :ok = SandboxHelpers.settle_singletons()

      dispositions = Enum.map(rows, &reload(&1).disposition)

      assert dispositions == ["replayed", "replayed"],
             """
             settle_singletons/1 returned while DeadLetterReplay's cast drain was
             still in flight. Dispositions: #{inspect(dispositions)}

             A `pending` row here means the barrier did not wait on
             DeadLetterReplay's mailbox — it is missing from
             `Platform.SandboxHelpers.settle_targets/0`, or its `:__drain__`
             clause is gone. That is the teardown order under which the sandbox
             owner exits mid-`pending_for_runtime/1`.
             """
    end

    test "DeadLetterReplay's deadline covers one full drain, derived from its accessors" do
      full_drain_ms = DeadLetterReplay.max_per_reconnect() * DeadLetterReplay.spacing_ms()

      assert {DeadLetterReplay, timeout} =
               List.keyfind(SandboxHelpers.settle_targets(), DeadLetterReplay, 0)

      assert timeout > full_drain_ms
    end

    test "a singleton that does not settle in time is WARNED about by name, not swallowed" do
      # A private stand-in, not a real singleton: AttentionRouter is gated off
      # in test (`:start_attention_router`), and suspending DeadLetterReplay
      # would cost its full-drain deadline.
      name = :"settle_singletons_probe_#{System.unique_integer([:positive])}"
      # `Elixir.Agent`: `Agent` is aliased to `Platform.Agents.Agent` here.
      {:ok, pid} = Elixir.Agent.start(fn -> :ok end, name: name)

      # Suspended, it cannot answer `:__drain__`, so the call must hit its
      # deadline. Killed (never resumed) in `after`: resumed, it would crash on
      # the queued unknown call instead of exiting quietly.
      :ok = :sys.suspend(pid)

      log =
        try do
          capture_log(fn -> assert :ok = SandboxHelpers.settle_singletons([{name, 50}]) end)
        after
          Process.exit(pid, :kill)
        end

      assert log =~ "#{inspect(name)} did not settle within 50ms"
    end
  end

  # ── Fixtures (from dead_letter_replay_test.exs) ─────────────────────

  defp offline_runtime(prefix) do
    suffix = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "settle-#{prefix}-#{suffix}@example.com",
        name: "Settle Owner #{suffix}",
        oidc_sub: "oidc-settle-#{prefix}-#{suffix}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-settle-#{prefix}-#{suffix}",
        display_name: "settle-runtime-#{suffix}"
      })

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "settle-#{prefix}-#{suffix}",
        name: "Settle Agent #{suffix}",
        status: "active",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert!()

    refute RuntimePresence.online?(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    %{runtime: runtime, agent: agent, owner: owner}
  end

  defp fresh_subject(name) do
    suffix = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "#{name} Project #{suffix}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "#{name} Task #{suffix}"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "passed"})

    %{project: project, task: task, plan: plan, stage: stage}
  end

  defp dead_letter_via_responder(%{runtime: runtime, agent: agent}, metadata) do
    signal = %{
      reason: :system_event,
      metadata:
        Map.merge(
          %{
            feature: "architecture",
            agent_id: agent.id,
            agent_slug: agent.slug,
            responsibility_key: "architecture.audit_diff",
            trigger_kind: :event_topic
          },
          metadata
        )
    }

    assert {:error, :runtime_offline} = AgentResponder.respond(signal)

    Repo.one!(
      from(d in DeadLetter,
        where: d.runtime_id == ^runtime.runtime_id,
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: 1
      )
    )
  end

  defp stage_metadata(%{task: task, plan: plan, stage: stage}) do
    %{task_id: task.id, plan_id: plan.id, stage_id: stage.id}
  end

  defp reload(%DeadLetter{id: id}), do: Repo.get!(DeadLetter, id)
end
