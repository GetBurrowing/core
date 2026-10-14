defmodule Platform.Responsibilities.TaskTriageRetireTest do
  @moduledoc """
  `tasks.triage` is retired from dispatch (task 01a0b4d1) without deleting
  the row or its prompt template.

  ## What this file proves

  The key keeps `trigger_kind: "cron"` and its `0 9 * * 1-5` expression, so
  the Router still computes next-fire times for it. The veto happens at FIRE
  time: `Router.fire_trigger/3` short-circuits on `metadata["dispatch"] ==
  "inert"` before assignee resolution. So the assertions are on
  `fire_trigger`'s return and the Router's log line — never on the row being
  "unscheduled", which it is not.

  ## Why each test has a control

    * T1 fires `tasks.weekly_review` (same `Providers.Tasks` feature, same
      cron trigger kind, same assignee wiring, same instant) alongside the
      triage fire. Without it, `{:ok, :placeholder}` on triage would also be
      satisfied by a Router that refused everything.
    * T2 asserts the prod-shaped row is NOT inert before the boot-path
      register pass, so the post-pass assertion is shown to be caused by
      the pass rather than by the fixture.
    * T3 is a PRESERVATION guard, not a detector: it is green before and
      after the fix, and exists so the retire path cannot quietly become a
      delete path.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Cron
  alias Platform.Responsibilities.Handlers.TaskTriage
  alias Platform.Responsibilities.Handlers.TaskWeeklyReview
  alias Platform.Responsibilities.Providers
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role

  @placeholder_log "[ResponsibilityRouter] placeholder responsibility=tasks.triage"

  # A Monday, 09:00:00Z — exactly an instant `0 9 * * 1-5` fires at.
  @monday_nine ~U[2026-09-28 09:00:00Z]

  # The metadata production carried, before this task's deploy.
  @old_prod_metadata %{
    "role" => "triage_officer",
    "owner" => "platform.tasks",
    "status" => "placeholder"
  }

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :task_triage_retire_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
    Logger.put_module_level(Router, :info)

    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    Application.put_env(:platform, :task_triage_retire_capture_pid, self())

    on_exit(fn ->
      Logger.delete_module_level(Router)

      if previous do
        Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
      else
        Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end

      Application.delete_env(:platform, :task_triage_retire_capture_pid)
    end)

    :ok
  end

  describe "T1: the cron fire is refused, with a live sibling as control" do
    test "tasks.triage returns :placeholder while tasks.weekly_review dispatches" do
      [triage_spec] = TaskTriage.register()
      [weekly_spec] = TaskWeeklyReview.register()

      {:ok, triage_row} = Responsibilities.upsert_by_key(triage_spec)
      {:ok, weekly_row} = Responsibilities.upsert_by_key(weekly_spec)

      # Both keys to one role, one native assignee (role_assignments is
      # unique on role_key, so the second key rides the same assignment).
      _agent = wire_native_assignee([triage_row.key, weekly_row.key])

      # PREMISE: the instant really is one the triage expression fires at.
      # (`Cron` returns microsecond precision {0, 6}, so compare, not ==.)
      {:ok, spec} = Cron.parse(triage_row.trigger_config["expression"])
      {:ok, next} = Cron.next_fire_after(~U[2026-09-28 08:59:00Z], spec)
      assert DateTime.compare(next, @monday_nine) == :eq

      log =
        capture_log([level: :info], fn ->
          assert Router.fire_trigger(triage_row, %{kind: :cron, fired_at: @monday_nine}, %{}) ==
                   {:ok, :placeholder}
        end)

      assert log =~ @placeholder_log
      refute_received {:captured_signal, %{metadata: %{responsibility_key: "tasks.triage"}}}

      # CONTROL: same instant, same wiring, same feature provider.
      assert {:ok, :dispatched} =
               Router.fire_trigger(weekly_row, %{kind: :cron, fired_at: @monday_nine}, %{})

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == "tasks.weekly_review"
    end
  end

  describe "T2: the boot-path register pass corrects a pre-existing prod-shaped row" do
    test "an old-metadata row becomes inert, keeps its id and its enabled flag" do
      [triage_spec] = TaskTriage.register()

      old_row = insert_prod_shaped_row!(triage_spec)

      assert old_row.enabled == true
      refute Map.has_key?(old_row.metadata, "dispatch")
      _agent = wire_native_assignee([old_row.key])

      # BEFORE the pass: the prod row is not inert — this is the defect.
      refute Router.fire_trigger(old_row, %{kind: :cron, fired_at: @monday_nine}, %{}) ==
               {:ok, :placeholder}

      assert {:ok, _rows} = Responsibilities.register(Providers.Tasks)

      after_pass = Responsibilities.get_by_key("tasks.triage")
      assert after_pass.id == old_row.id
      assert after_pass.enabled == true
      assert after_pass.metadata["dispatch"] == "inert"

      assert Router.fire_trigger(after_pass, %{kind: :cron, fired_at: @monday_nine}, %{}) ==
               {:ok, :placeholder}

      # Idempotent: a second boot leaves it inert, same row.
      assert {:ok, _rows} = Responsibilities.register(Providers.Tasks)
      again = Responsibilities.get_by_key("tasks.triage")
      assert again.id == old_row.id
      assert again.metadata["dispatch"] == "inert"

      assert Router.fire_trigger(again, %{kind: :cron, fired_at: @monday_nine}, %{}) ==
               {:ok, :placeholder}
    end
  end

  describe "T3: the row, the template and the handler survive (preservation guard)" do
    test "retire does not delete: row, cron shape, template and handler are all still there" do
      assert {:ok, _rows} = Responsibilities.register(Providers.Tasks)

      row = Responsibilities.get_by_key("tasks.triage")
      assert row
      assert row.default_prompt_template == "tasks.triage.v1"
      assert row.trigger_kind == "cron"
      assert row.enabled == true

      template = PromptTemplates.get_template_by_slug("tasks.triage.v1")
      assert template
      assert template.content =~ "propose a priority pass"

      assert Providers.Tasks.handler_for("tasks.triage") ==
               Platform.Responsibilities.Handlers.TaskTriage
    end
  end

  # Writes the row the way production had it: the real spec, but with
  # the pre-fix metadata and enabled=true. Goes through the same upsert so
  # a row the test DB may already hold is overwritten rather than duplicated;
  # `enabled` is set explicitly because upsert deliberately preserves it.
  defp insert_prod_shaped_row!(spec) do
    {:ok, row} = Responsibilities.upsert_by_key(Map.put(spec, :metadata, @old_prod_metadata))

    row
    |> Ecto.Changeset.change(enabled: true, metadata: @old_prod_metadata)
    |> Repo.update!()
  end

  defp wire_native_assignee(responsibility_keys) do
    role_key = "historian"

    Repo.insert!(
      %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    Enum.each(responsibility_keys, fn key ->
      %Platform.Roles.RoleResponsibility{}
      |> Platform.Roles.RoleResponsibility.changeset(%{
        role_key: role_key,
        responsibility_key: key
      })
      |> Repo.insert!()
    end)

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "triage-retire-#{System.unique_integer([:positive])}",
        name: "Triage Retire Assignee",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end
end
