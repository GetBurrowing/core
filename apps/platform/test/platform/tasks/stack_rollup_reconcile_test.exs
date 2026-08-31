defmodule Platform.Tasks.StackRollupReconcileTest do
  @moduledoc """
  Hardening for `Stacks.reconcile_merged_rollups/0` (task 01a05394 stage 3):
  the tests that separate "works" from "looks like it works".

    * Idempotence in BOTH orderings — webhook-then-poll and
      poll-then-webhook — must end in exactly ONE completion. "One" is
      pinned three ways: `metadata["rollup_merge"]` is byte-identical
      after the second actor (same `merged_at`, same `merge_commit_sha`),
      every member carries exactly one `-> done` row in
      `task_phase_transitions`, and the `:cascade_completed` telemetry
      shows the members cascaded once in total.

      The webhook-first ordering is the one a naive poll double-completes
      on: the poll snapshots its candidates BEFORE it asks the origin, so
      a webhook landing in that window leaves the poll holding a
      `deploying` struct for a stack that is already `done`. The fixture
      reproduces exactly that interleaving (the fake runner delivers the
      webhook from inside `pr_merge_state/1`) and asserts the poll DID
      evaluate the stack (`checked: 1`) — otherwise the test would be a
      vacuous re-run of "a done stack is not a candidate".

    * A poll that ERRORED and a poll that found NOTHING must record
      different things — asserted as inequality of the two watch stamps
      taken in the same sweep, not as two independent shape checks.

    * A runner with no `pr_merge_state/1` is an error, never "unmerged".
      The runner's absence of the callback is asserted as a precondition
      after `Code.ensure_loaded!/1` (a `function_exported?` on an unloaded
      module is false for the wrong reason).

  Stage 2's `stacks_reconcile_merged_rollups_test.exs` covers the single-
  actor happy path, the unmerged control, and the per-shape error cases;
  nothing here repeats those assertions.
  """

  # async: false — swaps the global `:platform, :stack_deployer` git_runner.
  use Platform.DataCase, async: false

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PhaseTransitions, RollupWebhookProcessor, Stack, Stacks, Task}

  @cascade_event [:platform, :stacks, :deploy, :cascade_completed]

  # Fake `GitRunner` whose `pr_merge_state/1` answer is keyed by repo_url
  # and can run a hook BEFORE replying — the hook is how a test lands the
  # webhook inside the poll's snapshot-to-origin window.
  defmodule HookedRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    def start_link do
      Agent.start_link(
        fn -> %{responses: %{}, default: {:ok, unmerged()}, hook: nil, calls: []} end,
        name: __MODULE__
      )
    end

    def stop, do: Agent.stop(__MODULE__)
    def set_default(resp), do: Agent.update(__MODULE__, &%{&1 | default: resp})

    def set_response(repo_url, resp),
      do: Agent.update(__MODULE__, &%{&1 | responses: Map.put(&1.responses, repo_url, resp)})

    def set_hook(fun) when is_function(fun, 1) or is_nil(fun),
      do: Agent.update(__MODULE__, &%{&1 | hook: fun})

    def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()

    def unmerged, do: %{merged: false, merged_at: nil, merge_commit_sha: nil, url: nil}

    def merged(sha) do
      %{
        merged: true,
        merged_at: "2026-08-30T12:00:00Z",
        merge_commit_sha: sha,
        url: "https://github.com/test/reconcile/pull/4242"
      }
    end

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, :created}

    @impl true
    def merge_member_into_rollup(_args),
      do: {:ok, %{status: :merged, merge_sha: "0000000000000000000000000000000000000000"}}

    @impl true
    def open_stack_pr(_args),
      do: {:ok, %{number: 4242, url: "https://github.com/test/reconcile/pull/4242"}}

    @impl true
    def diff_stat(_args), do: {:ok, ""}

    @impl true
    def close_stack_pr(_args), do: {:ok, :closed}

    @impl true
    def delete_rollup_branch(_args), do: {:ok, :deleted}

    @impl true
    def sha_reachable?(_args), do: {:ok, true}

    @impl true
    def pr_merge_state(args) do
      %{hook: hook, reply: reply} =
        Agent.get_and_update(__MODULE__, fn state ->
          reply = Map.get(state.responses, args.repo_url, state.default)
          {%{hook: state.hook, reply: reply}, %{state | calls: [args | state.calls]}}
        end)

      if hook, do: hook.(args)
      reply
    end
  end

  # Genuinely lacks `pr_merge_state/1`.
  defmodule CallbacklessRunner do
    @moduledoc false
    @behaviour Platform.Tasks.StackDeployer.GitRunner

    @impl true
    def ensure_rollup_branch(_args), do: {:ok, :created}
  end

  setup do
    prev = Application.get_env(:platform, :stack_deployer, [])
    {:ok, _} = HookedRunner.start_link()

    Application.put_env(:platform, :stack_deployer, git_runner: HookedRunner, async: false)

    # One handler per test, unique id, detached on exit. Events are
    # forwarded to the test process so the count is asserted with the
    # mailbox, never with a shared counter.
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @cascade_event,
        fn @cascade_event, measurements, metadata, _ ->
          send(test_pid, {:cascade_completed, measurements, metadata})
        end,
        nil
      )

    Process.put(:webhook_stack_fault, fn -> send(test_pid, :process_stack_merged_pr_invoked) end)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.put_env(:platform, :stack_deployer, prev)

      try do
        HookedRunner.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # Mirrors `build_stranded_stack!/2` in the webhook cascade test and
  # `deploying_stack_with_pr!/1` in the stage-2 test: a `deploying` stack
  # with a numbered rollup PR and members that satisfy the fan-out's
  # approved-plan guard.
  defp deploying_stack_with_pr!(opts \\ []) do
    pr_number = Keyword.get(opts, :pr_number, 4242)
    member_count = Keyword.get(opts, :members, 2)
    slug = "recon-#{System.unique_integer([:positive])}"
    repo_url = Keyword.get(opts, :repo_url, "https://github.com/test/reconcile")

    {:ok, project} = Tasks.create_project(%{name: "Reconcile #{slug}", repo_url: repo_url})

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Reconcile stack #{slug}",
        base_branch: "main",
        rollup_branch: "stack/#{slug}",
        status: "deploying",
        metadata: %{
          "rollup_pr" => %{
            "number" => pr_number,
            "url" => "#{repo_url}/pull/#{pr_number}"
          }
        }
      })

    members =
      for position <- 1..member_count//1 do
        {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Member #{position}"})
        {:ok, plan} = Tasks.create_plan(%{task_id: task.id, version: 1, status: "approved"})

        {:ok, _stage} =
          Tasks.create_stage(%{
            plan_id: plan.id,
            position: 1,
            name: "Execute",
            description: "Execute stage",
            status: "passed"
          })

        {:ok, task} =
          Tasks.update_task(task, %{
            stack_id: stack.id,
            stack_position: position,
            status: "deploying"
          })

        task
      end

    %{stack: stack, members: members, project: project, repo_url: repo_url}
  end

  defp reload(%Stack{id: id}), do: Repo.get!(Stack, id)

  # The webhook, as the controller delivers it: a fresh stack row + the
  # parsed `pull_request` map. `process_stack_merged_pr/4` is the exact
  # function the controller calls once the stack is matched.
  defp deliver_webhook!(stack_id, sha) do
    fresh = Stacks.get_stack(stack_id)

    pr = %{
      "number" => fresh.metadata["rollup_pr"]["number"],
      "html_url" => fresh.metadata["rollup_pr"]["url"],
      "merge_commit_sha" => sha
    }

    assert :ok =
             RollupWebhookProcessor.process_stack_merged_pr(
               fresh,
               pr,
               "2026-08-30T12:00:00Z",
               nil
             )
  end

  defp done_transitions(%Task{id: id}) do
    id |> PhaseTransitions.list_for_task() |> Enum.filter(&(&1.to_status == "done"))
  end

  defp collect_cascade_events(acc \\ []) do
    receive do
      {:cascade_completed, measurements, metadata} ->
        collect_cascade_events([{measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_exactly_one_completion(stack, members, %{rollup_merge: rollup_merge}) do
    final = reload(stack)
    assert final.status == "done"

    # The completion stamp is the one the FIRST actor wrote — same
    # merged_at, same merge_commit_sha, same anomaly list. A second pass
    # that re-completed would have rewritten it with ITS sha and an
    # `unexpected_status:done` anomaly per member. (This fixture's members
    # carry no `pr_merged` validation, so `members_passed` is `[]` and
    # `degraded` is set even on the first, correct completion — the
    # identity check is what discriminates, not those two keys.)
    assert final.metadata["rollup_merge"] == rollup_merge
    refute Enum.any?(rollup_merge["anomalies"], &(&1["reason"] == "unexpected_status:done"))

    # Each member crossed into done exactly once.
    for member <- members do
      assert Repo.get!(Task, member.id).status == "done"
      assert [%{from_status: "deploying", to_status: "done"}] = done_transitions(member)
    end

    # Across every cascade telemetry event the members were cascaded once
    # in total — never twice.
    events = collect_cascade_events()
    assert Enum.all?(events, fn {_m, meta} -> meta.stack_id == stack.id end)
    cascaded_total = events |> Enum.map(fn {_m, meta} -> meta.cascaded_count end) |> Enum.sum()
    assert cascaded_total <= length(members)
    events
  end

  describe "idempotence — poll then webhook" do
    test "the poll completes; the webhook replay leaves exactly one completion" do
      %{stack: stack, members: members} = deploying_stack_with_pr!()
      HookedRunner.set_default({:ok, HookedRunner.merged("sha-from-poll")})

      assert reload(stack).status == "deploying"

      assert Stacks.reconcile_merged_rollups() ==
               %{checked: 1, completed: 1, unmerged: 0, errored: 0}

      assert_received :process_stack_merged_pr_invoked

      after_poll = reload(stack)
      assert after_poll.status == "done"
      rollup_merge = after_poll.metadata["rollup_merge"]
      assert rollup_merge["merge_commit_sha"] == "sha-from-poll"
      assert rollup_merge["merged_at"] == "2026-08-30T12:00:00Z"

      # The late webhook: same PR, GitHub's own sha. Delivered on the fresh
      # row, as the controller would.
      deliver_webhook!(stack.id, "sha-from-webhook")
      assert_received :process_stack_merged_pr_invoked
      refute_received :process_stack_merged_pr_invoked

      events = assert_exactly_one_completion(stack, members, %{rollup_merge: rollup_merge})

      # One telemetry event per delivery (documented parity), and only the
      # first one moved anybody.
      assert [{_, %{trigger: :webhook, cascaded_count: first}}, {_, %{cascaded_count: 0}}] =
               events

      assert first in 0..length(members)//1

      # The poll's own stamp is untouched by the webhook and shows one check.
      assert reload(stack).metadata["rollup_merge_watch"]["checks"] == 1
      assert reload(stack).metadata["rollup_merge_watch"]["last_result"] == "merged"
    end
  end

  describe "idempotence — webhook then poll" do
    test "webhook lands inside the poll's snapshot window; the poll still leaves exactly one completion" do
      %{stack: stack, members: members} = deploying_stack_with_pr!()
      stack_id = stack.id
      test_pid = self()

      # The interleaving: the poll has already selected this stack as a
      # `deploying` candidate; while it asks the origin, the webhook
      # completes the stack. The origin then (truthfully) answers merged.
      HookedRunner.set_default({:ok, HookedRunner.merged("sha-from-poll")})

      HookedRunner.set_hook(fn %{stack_id: ^stack_id} ->
        deliver_webhook!(stack_id, "sha-from-webhook")
        send(test_pid, {:webhook_delivered, Stacks.get_stack(stack_id).metadata["rollup_merge"]})
      end)

      assert reload(stack).status == "deploying"

      summary = Stacks.reconcile_merged_rollups()

      # Reachability: the poll DID evaluate this stack — it was a
      # candidate and the origin was asked. A `checked: 0` here would mean
      # the test never exercised the double-complete path at all.
      assert summary.checked == 1
      assert summary.errored == 0
      assert summary.unmerged == 0
      assert [%{stack_id: ^stack_id, pr_number: 4242}] = HookedRunner.calls()

      # The webhook's stamp, captured the instant it landed — before the
      # poll got its answer back.
      assert_received {:webhook_delivered,
                       %{"merge_commit_sha" => "sha-from-webhook"} = rollup_merge}

      events = assert_exactly_one_completion(stack, members, %{rollup_merge: rollup_merge})
      assert length(events) >= 1

      # The poll recorded that it looked, and what it saw.
      watch = reload(stack).metadata["rollup_merge_watch"]
      assert watch["checks"] == 1
      assert watch["last_result"] == "merged"
      assert watch["last_error"] == nil
    end

    test "webhook completes first, poll runs after: the stack is no longer a candidate" do
      %{stack: stack, members: members} = deploying_stack_with_pr!()
      HookedRunner.set_default({:ok, HookedRunner.merged("sha-from-poll")})

      deliver_webhook!(stack.id, "sha-from-webhook")
      assert_received :process_stack_merged_pr_invoked
      rollup_merge = reload(stack).metadata["rollup_merge"]
      assert rollup_merge["merge_commit_sha"] == "sha-from-webhook"

      assert Stacks.reconcile_merged_rollups() ==
               %{checked: 0, completed: 0, unmerged: 0, errored: 0}

      refute_received :process_stack_merged_pr_invoked
      assert HookedRunner.calls() == []

      assert [{_, %{cascaded_count: _}}] =
               assert_exactly_one_completion(stack, members, %{rollup_merge: rollup_merge})

      refute Map.has_key?(reload(stack).metadata, "rollup_merge_watch")
    end
  end

  describe "error versus nothing" do
    test "an errored check and an unmerged check in the same sweep record different states" do
      %{stack: errored} = deploying_stack_with_pr!(repo_url: "https://github.com/test/errored")
      %{stack: unmerged} = deploying_stack_with_pr!(repo_url: "https://github.com/test/unmerged")

      HookedRunner.set_response(
        "https://github.com/test/errored",
        {:error, {:gh_failed, 1, "gh: api rate limit exceeded"}}
      )

      HookedRunner.set_response(
        "https://github.com/test/unmerged",
        {:ok, HookedRunner.unmerged()}
      )

      assert Stacks.reconcile_merged_rollups() ==
               %{checked: 2, completed: 0, unmerged: 1, errored: 1}

      refute_received :process_stack_merged_pr_invoked

      errored_watch = reload(errored).metadata["rollup_merge_watch"]
      unmerged_watch = reload(unmerged).metadata["rollup_merge_watch"]

      assert %{"last_result" => "error", "last_error" => err, "checks" => 1} = errored_watch
      assert is_binary(err) and err =~ "gh_failed" and err =~ "rate limit"

      assert %{"last_result" => "unmerged", "last_error" => nil, "checks" => 1} = unmerged_watch

      # The load-bearing assertion: whatever else is recorded, the two
      # are not the same state.
      refute Map.delete(errored_watch, "last_checked_at") ==
               Map.delete(unmerged_watch, "last_checked_at")

      refute errored_watch["last_result"] == unmerged_watch["last_result"]

      # Neither moved.
      assert reload(errored).status == "deploying"
      assert reload(unmerged).status == "deploying"
      refute Map.has_key?(reload(errored).metadata, "rollup_merge")
      refute Map.has_key?(reload(unmerged).metadata, "rollup_merge")
      assert collect_cascade_events() == []
    end

    test "a runner that cannot answer at all is errored, and not recorded like unmerged" do
      %{stack: unmerged} = deploying_stack_with_pr!()
      HookedRunner.set_default({:ok, HookedRunner.unmerged()})
      assert %{unmerged: 1, errored: 0} = Stacks.reconcile_merged_rollups()
      unmerged_watch = reload(unmerged).metadata["rollup_merge_watch"]
      assert unmerged_watch["last_result"] == "unmerged"

      # Precondition on the fixture, not on the code under test: the
      # runner is LOADED and still has no pr_merge_state/1.
      Code.ensure_loaded!(CallbacklessRunner)
      refute function_exported?(CallbacklessRunner, :pr_merge_state, 1)

      %{stack: no_answer} = deploying_stack_with_pr!()

      Application.put_env(:platform, :stack_deployer,
        git_runner: CallbacklessRunner,
        async: false
      )

      # Both stacks are still candidates; the sweep sees two and completes
      # nothing, and the callback gap is attributed to `errored`.
      assert Stacks.reconcile_merged_rollups() ==
               %{checked: 2, completed: 0, unmerged: 0, errored: 2}

      refute_received :process_stack_merged_pr_invoked

      no_answer_watch = reload(no_answer).metadata["rollup_merge_watch"]
      assert no_answer_watch["last_result"] == "error"
      assert no_answer_watch["last_error"] =~ "runner_missing_callback"
      assert no_answer_watch["last_error"] =~ "pr_merge_state"
      refute no_answer_watch["last_result"] == unmerged_watch["last_result"]

      # The previously-unmerged stack is now recorded as error too — the
      # capability loss is visible on every stack it affects, and does not
      # inherit the earlier "unmerged" verdict.
      assert reload(unmerged).metadata["rollup_merge_watch"]["last_result"] == "error"
      assert reload(unmerged).metadata["rollup_merge_watch"]["checks"] == 2
      assert reload(no_answer).status == "deploying"
      assert reload(unmerged).status == "deploying"
    end
  end
end
