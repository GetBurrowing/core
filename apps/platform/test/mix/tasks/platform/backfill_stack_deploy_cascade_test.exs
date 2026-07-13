defmodule Mix.Tasks.Platform.BackfillStackDeployCascadeTest do
  @moduledoc """
  Tests for the stack-deploy-cascade backfill Mix task
  (task `019f5bc4-3521` stage 4).

  The task is exercised via its public `do_run/1` entry point rather
  than `run/1` — `run/1` calls `Mix.Task.run("app.start")`, and the
  Platform app is already booted by `Platform.DataCase`. Driving
  `do_run/1` directly keeps the test loop fast and side-effect-free.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, warn: false
  import ExUnit.CaptureIO

  alias Mix.Tasks.Platform.BackfillStackDeployCascade
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stacks, Task}

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Backfill Cascade #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/backfill-cascade"
      })

    %{project: project}
  end

  describe "do_run/1 — stranded-stack query" do
    test "finds stacks stuck at done with deploying members", %{project: project} do
      # Stranded shape: stack at done, one member still deploying.
      stranded = stranded_stack_fixture(project, ["deploying", "in_review", "done"])

      # Fully-done stack — should NOT be picked up.
      done = done_stack_fixture(project, ["done", "done"])

      # Non-done stack (rollup PR still open). Even with a deploying
      # member, the query excludes it because `s.status == "done"` is
      # the invariant that pins the "stranded" signature.
      _in_flight = in_flight_stack_fixture(project, ["deploying"])

      output = capture_io(fn -> assert BackfillStackDeployCascade.do_run([]) == :ok end)

      # The scan header proves the query saw exactly one stack. We
      # avoid asserting on the stranded-stack's 8-char prefix directly
      # because UUIDv7 timestamps make sibling stack prefixes
      # collide, so a prefix-negation against `done`/`in_flight` would
      # false-positive. Members' post-cascade statuses (below) prove
      # only the stranded stack was cascaded.
      assert output =~ "scanning: 1 stranded stack(s)"
      # Members: t1 (deploying) + t2 (in_review) cascaded, t3 stayed
      # done — advanced == 2, skipped == 0.
      assert output =~ "complete: 1 stacks cascaded, 2 members advanced, 0 skipped"

      stranded_members = Stacks.members(stranded)
      assert Enum.all?(stranded_members, &(&1.status == "done"))

      done_members = Stacks.members(done)
      assert Enum.all?(done_members, &(&1.status == "done"))
    end

    test "no stranded stacks: prints a friendly no-op summary and returns :ok" do
      output = capture_io(fn -> assert BackfillStackDeployCascade.do_run([]) == :ok end)

      assert output =~ "no stranded stacks found"
      assert output =~ "complete: 0 stacks cascaded, 0 members advanced, 0 skipped"
    end
  end

  describe "do_run/1 — --dry-run" do
    test "--dry-run reports without cascading or emitting telemetry", %{project: project} do
      stranded = stranded_stack_fixture(project, ["deploying", "in_review"])

      # Attach a telemetry handler and fail if it fires — dry-run must
      # NEVER call `cascade_members_to_done/2`, so no event should ever
      # arrive at this test pid.
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :deploy, :cascade_completed]
        ])

      output =
        capture_io(fn ->
          assert BackfillStackDeployCascade.do_run(dry_run: true) == :ok
        end)

      assert output =~ "[DRY-RUN]"
      assert output =~ String.slice(stranded.id, 0, 8)
      assert output =~ "2 member(s) would cascade"

      # Members' statuses must be UNCHANGED (still deploying / in_review).
      members = Stacks.members(stranded)
      statuses = members |> Enum.map(& &1.status) |> Enum.sort()
      assert statuses == ["deploying", "in_review"]

      refute_received {[:platform, :stacks, :deploy, :cascade_completed], ^ref, _measurements,
                       _metadata}

      :telemetry.detach(ref)
    end
  end

  describe "do_run/1 — real run" do
    test "cascades stranded stacks + emits :cascade_completed with trigger: :backfill", %{
      project: project
    } do
      stranded = stranded_stack_fixture(project, ["deploying", "in_review"])

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :deploy, :cascade_completed]
        ])

      output = capture_io(fn -> assert BackfillStackDeployCascade.do_run([]) == :ok end)

      assert output =~ "cascaded=2 skipped=0"
      assert output =~ "complete: 1 stacks cascaded, 2 members advanced, 0 skipped"

      # Members all landed at `done`.
      members = Stacks.members(stranded)
      assert Enum.all?(members, &(&1.status == "done"))

      # Exactly one telemetry event, tagged with the backfill trigger.
      assert_receive {[:platform, :stacks, :deploy, :cascade_completed], ^ref, measurements,
                      metadata}

      assert measurements.count == 1
      assert measurements.member_count == 2
      assert metadata.cascaded_count == 2
      assert metadata.skipped_count == 0
      assert metadata.trigger == :backfill
      assert metadata.stack_id == stranded.id

      # No second event.
      refute_received {[:platform, :stacks, :deploy, :cascade_completed], ^ref, _m2, _md2}

      :telemetry.detach(ref)
    end
  end

  describe "do_run/1 — idempotency (acceptance criterion 4)" do
    test "no-op on all-done stacks: the query excludes them entirely", %{project: project} do
      # First run: cascade the stranded stack, everyone lands at done.
      _stranded = stranded_stack_fixture(project, ["deploying"])
      capture_io(fn -> BackfillStackDeployCascade.do_run([]) end)

      # Second run: the same stack is now fully done, so the stranded-
      # stack query returns []. No telemetry, friendly summary line.
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :deploy, :cascade_completed]
        ])

      output = capture_io(fn -> assert BackfillStackDeployCascade.do_run([]) == :ok end)

      assert output =~ "no stranded stacks found"
      assert output =~ "complete: 0 stacks cascaded, 0 members advanced, 0 skipped"

      refute_received {[:platform, :stacks, :deploy, :cascade_completed], ^ref, _measurements,
                       _metadata}

      :telemetry.detach(ref)
    end
  end

  describe "do_run/1 — --stack-id filter" do
    test "restricts the cascade to the specified stack even when others are stranded", %{
      project: project
    } do
      target = stranded_stack_fixture(project, ["deploying"])
      other = stranded_stack_fixture(project, ["deploying", "in_review"])

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :stacks, :deploy, :cascade_completed]
        ])

      output =
        capture_io(fn ->
          assert BackfillStackDeployCascade.do_run(stack_id: target.id) == :ok
        end)

      # NB: `short/1` truncates to 8 chars but two UUIDv7s minted
      # milliseconds apart share their leading timestamp bytes, so we
      # can't use a prefix-negation to prove the other stack was
      # excluded. Prove it via (a) the scan header saying only ONE
      # stack was seen and (b) the member-status snapshot below.
      assert output =~ "scanning: 1 stranded stack(s)"
      assert output =~ "complete: 1 stacks cascaded, 1 members advanced, 0 skipped"

      # Target flipped, other untouched.
      target_members = Stacks.members(target)
      other_members = Stacks.members(other)
      assert Enum.all?(target_members, &(&1.status == "done"))
      other_statuses = other_members |> Enum.map(& &1.status) |> Enum.sort()
      assert other_statuses == ["deploying", "in_review"]

      # Exactly one telemetry event — for target, not other.
      assert_receive {[:platform, :stacks, :deploy, :cascade_completed], ^ref, _m1, metadata}

      assert metadata.stack_id == target.id
      refute_received {[:platform, :stacks, :deploy, :cascade_completed], ^ref, _m2, _md2}

      :telemetry.detach(ref)
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # Stack stuck in the exact PR #531 shape: stack row at `"done"` with
  # the rollup_pr metadata already stamped, plus N members at the given
  # `member_statuses`.
  #
  # We build in three phases because `Stacks.add_task/2` fires
  # `recompute_stack_status/1` on each attach and overwrites the
  # stack's status based on the current member statuses. Ordering:
  # (1) create stack with a benign initial status; (2) attach members
  # while stamping their real statuses; (3) force stack status +
  # metadata to the stranded shape via raw Repo update, past the
  # recompute path.
  defp stranded_stack_fixture(project, member_statuses) do
    slug = "stranded-" <> short_id()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Stranded #{slug}",
        rollup_branch: "stack/" <> slug
      })

    seed_members(project, stack, member_statuses)

    force_stack_state!(stack, %{
      status: "done",
      metadata: %{
        "rollup_pr" => %{
          "number" => 999,
          "url" => "https://github.com/x/y/pull/999",
          "opened_at" => "2026-07-13T06:00:00Z",
          "merged_at" => "2026-07-13T06:10:00Z"
        }
      }
    })
  end

  # Stack that is fully wound up — every member landed at `"done"`.
  # Used to confirm the stranded-stack query DOESN'T pick it up.
  defp done_stack_fixture(project, member_statuses) do
    slug = "done-" <> short_id()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "Done #{slug}",
        rollup_branch: "stack/" <> slug
      })

    seed_members(project, stack, member_statuses)
    force_stack_state!(stack, %{status: "done"})
  end

  # Stack whose rollup PR hasn't merged yet — stack.status != "done" —
  # even a deploying member here must NOT be considered stranded.
  defp in_flight_stack_fixture(project, member_statuses) do
    slug = "inflight-" <> short_id()

    {:ok, stack} =
      Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "In flight #{slug}",
        rollup_branch: "stack/" <> slug
      })

    seed_members(project, stack, member_statuses)
    force_stack_state!(stack, %{status: "deploying"})
  end

  defp seed_members(project, stack, statuses) do
    statuses
    |> Enum.with_index()
    |> Enum.each(fn {status, idx} ->
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "M#{idx + 1} #{short_id()}"
        })

      {:ok, attached} = Stacks.add_task(stack, task)
      set_task_status(attached, status)
    end)
  end

  # Bypass the status-transition guards to seed arbitrary starting
  # statuses (e.g. `"deploying"`) that the normal transition_task path
  # wouldn't let us reach without a full plan/stage/validation walk.
  defp set_task_status(%Task{id: id}, status) do
    Task
    |> Repo.get!(id)
    |> Ecto.Changeset.change(status: status)
    |> Repo.update!()
  end

  # Bypass Stack.changeset validation + skip `recompute_stack_status/1`
  # so we can force the stack into the post-rollup-merge shape without
  # rerunning the recompute logic that would flip it back based on
  # current member statuses.
  defp force_stack_state!(%Platform.Tasks.Stack{id: id}, attrs) do
    Platform.Tasks.Stack
    |> Repo.get!(id)
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp short_id do
    Ecto.UUID.generate() |> String.slice(0, 8)
  end
end
