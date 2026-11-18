defmodule Platform.Feedback.IntakeRetryTest do
  @moduledoc """
  `Platform.Feedback.Intake.retry_pending/1` (task 01a1e670 stage 2): the
  bounded sweep that re-fetches and re-classifies pending intake records.

  Every test also asserts `role_assignments` is unchanged (C6): the sweep
  reads who classifies, it never re-pins a role.

  async: false — the provider, disposition adapter, issue source and
  feedback policy are installed through Application env.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Platform.Feedback.ClassifierRoute
  alias Platform.Feedback.Intake
  alias Platform.Feedback.IntakeRecord
  alias Platform.Repo
  alias Platform.Roles.RoleAssignment
  alias Platform.Tasks
  alias Platform.Test.FeedbackIntakeStub, as: Stub
  alias Platform.Test.FeedbackIssueSourceStub, as: Source

  @feedback_repo "GetBurrowing/core"
  @title "RETRY-TITLE-CANARY card position lost after reload"
  @body "RETRY-BODY-CANARY Expected the card to stay. Observed it returns to the top."

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Intake retry #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/acme/retry-#{System.unique_integer([:positive])}"
      })

    :ok = Stub.install!(reply: Stub.json(Stub.verdict()), project_id: project.id)
    agent = Stub.classifier_agent!()
    :ok = Source.install!()

    %{project: project, agent: agent, roles: role_snapshot()}
  end

  defp role_snapshot do
    from(r in RoleAssignment, order_by: r.role_key, select: {r.role_key, r.agent_id})
    |> Repo.all()
  end

  defp assert_roles_unchanged(ctx), do: assert(role_snapshot() == ctx.roles)

  defp issue(overrides \\ %{}) do
    Map.merge(
      %{
        repository: @feedback_repo,
        issue_number: System.unique_integer([:positive]),
        title: @title,
        body: @body
      },
      overrides
    )
  end

  # A pending record, as a stuck install has them: the first delivery's
  # classifier call failed. The issue source then serves the issue for the
  # retry.
  defp pending!(issue) do
    Stub.reply!(fn _c, _m, _o -> {:error, :timeout} end)

    capture_log(fn ->
      assert {:ok, %{outcome: :pending, note: "provider_failed"}} = Intake.process(issue)
    end)

    Stub.reply!(Stub.json(Stub.verdict()))
    Source.answer!(Source.serving([issue]))
    drain(:feedback_classifier_called)
    record!(issue)
  end

  defp record!(issue) do
    from(r in IntakeRecord,
      where: r.repository_identity == ^issue.repository and r.issue_number == ^issue.issue_number
    )
    |> Repo.one!()
  end

  defp make_due!(record) do
    from(r in IntakeRecord, where: r.id == ^record.id)
    |> Repo.update_all(set: [next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)])
  end

  defp drain(tag, acc \\ 0) do
    receive do
      msg when is_tuple(msg) and elem(msg, 0) == tag -> drain(tag, acc + 1)
    after
      0 -> acc
    end
  end

  describe "C1: idempotency is the existing decision path" do
    test "two serial sweeps on an accept record file one task and dispose once", ctx do
      issue = issue()
      pending!(issue)

      capture_log(fn ->
        assert {:ok, %{claimed: 1, outcomes: [:task_filed]}} = Intake.retry_pending()
        assert {:ok, %{claimed: 0, outcomes: []}} = Intake.retry_pending()
      end)

      assert %IntakeRecord{status: "decided", verdict: "accept_bug"} = record!(issue)
      assert [_one] = Stub.external_tasks(issue.repository, issue.issue_number)
      assert drain(:feedback_disposition) == 1
      assert_roles_unchanged(ctx)
    end

    test "two concurrent sweeps on an accept record file one task and dispose once", ctx do
      issue = issue()
      pending!(issue)

      capture_log(fn ->
        [a, b] = for _ <- 1..2, do: Elixir.Task.async(fn -> Intake.retry_pending() end)
        Elixir.Task.await_many([a, b], 15_000)
      end)

      assert %IntakeRecord{status: "decided"} = record!(issue)
      assert [_one] = Stub.external_tasks(issue.repository, issue.issue_number)
      assert drain(:feedback_disposition) == 1
      assert drain(:feedback_classifier_called) == 1
      assert_roles_unchanged(ctx)
    end

    test "decided records are never selected", ctx do
      issue = issue()
      assert {:ok, %{outcome: :task_filed}} = capture_ok(fn -> Intake.process(issue) end)
      drain(:feedback_disposition)

      capture_log(fn -> assert {:ok, %{claimed: 0}} = Intake.retry_pending() end)

      assert drain(:issue_source_fetch) == 0
      assert drain(:feedback_classifier_called) == 1
      assert_roles_unchanged(ctx)
    end
  end

  describe "C2: the attempt cap" do
    test "an always-failing provider stops at max_attempts and is then never called", ctx do
      issue = issue()
      record = pending!(issue)
      Stub.reply!(fn _c, _m, _o -> {:error, :timeout} end)
      max = Intake.max_attempts()

      capture_log(fn ->
        for _ <- 1..(max + 3) do
          make_due!(record)
          Intake.retry_pending()
        end
      end)

      assert drain(:feedback_classifier_called) == max
      assert drain(:issue_source_fetch) == max

      assert %IntakeRecord{status: "pending", note: "provider_failed", attempts: ^max} =
               record!(issue)

      assert ClassifierRoute.health().exhausted >= 1

      # And after the cap, further due sweeps make no provider call at all.
      capture_log(fn ->
        make_due!(record)
        Intake.retry_pending()
      end)

      assert drain(:feedback_classifier_called) == 0
      assert drain(:issue_source_fetch) == 0
      assert_roles_unchanged(ctx)
    end

    test "a claimed record waits out its backoff before the next attempt", ctx do
      issue = issue()
      pending!(issue)
      Stub.reply!(fn _c, _m, _o -> {:error, :timeout} end)

      capture_log(fn ->
        Intake.retry_pending()
        Intake.retry_pending()
      end)

      record = record!(issue)
      assert record.attempts == 1
      assert DateTime.diff(record.next_attempt_at, record.last_attempt_at) == 300
      assert drain(:feedback_classifier_called) == 1
      assert_roles_unchanged(ctx)
    end

    test "the backoff is 5m, 15m, 1h, 4h, 12h" do
      assert Enum.map(1..6, &Intake.backoff_seconds/1) ==
               [300, 900, 3_600, 14_400, 43_200, 43_200]
    end

    test "reset_exhausted re-arms stopped records", ctx do
      issue = issue()
      record = pending!(issue)
      max = Intake.max_attempts()

      from(r in IntakeRecord, where: r.id == ^record.id)
      |> Repo.update_all(set: [attempts: max, next_attempt_at: DateTime.utc_now()])

      assert Intake.reset_exhausted() >= 1
      assert %IntakeRecord{attempts: 0, next_attempt_at: nil} = record!(issue)
      assert_roles_unchanged(ctx)
    end
  end

  describe "C3: classifier off" do
    test "no assignee: no fetch, no attempt consumed", ctx do
      issue = issue()
      pending!(issue)
      Platform.Roles.unassign_role("triage_officer")
      ctx = %{ctx | roles: role_snapshot()}

      assert {:ok, %{skipped: :classifier_off}} = Intake.retry_pending()
      assert drain(:issue_source_fetch) == 0
      assert %IntakeRecord{attempts: 0, next_attempt_at: nil} = record!(issue)
      assert_roles_unchanged(ctx)
    end

    test "a no-endpoint assignee: no fetch, no attempt consumed", ctx do
      issue = issue()
      pending!(issue)

      native =
        %Platform.Agents.Agent{}
        |> Platform.Agents.Agent.changeset(%{
          slug: "retry-native-#{System.unique_integer([:positive])}",
          name: "Native holder",
          status: "active"
        })
        |> Repo.insert!()

      {:ok, _} = Platform.Roles.set_override("feedback.intake", native.id)

      saved = System.get_env("OLLAMA_BASE_URL")
      System.delete_env("OLLAMA_BASE_URL")
      on_exit(fn -> if saved, do: System.put_env("OLLAMA_BASE_URL", saved) end)

      assert {:ok, %{skipped: :classifier_off}} = Intake.retry_pending()
      assert drain(:issue_source_fetch) == 0
      assert drain(:feedback_classifier_called) == 0
      assert %IntakeRecord{attempts: 0} = record!(issue)
      assert_roles_unchanged(ctx)
    end
  end

  describe "fetch outcomes" do
    test "fetch_unavailable gives the attempt back and leaves the note", ctx do
      issue = issue()
      pending!(issue)
      Source.answer!(fn _r, _n -> {:error, :fetch_unavailable} end)

      capture_log(fn -> Intake.retry_pending() end)

      assert drain(:issue_source_fetch) == 1

      assert %IntakeRecord{
               attempts: 0,
               next_attempt_at: nil,
               last_attempt_at: nil,
               note: "provider_failed"
             } = record!(issue)

      assert_roles_unchanged(ctx)
    end

    test "any other fetch error consumes the attempt and leaves the note", ctx do
      issue = issue()
      pending!(issue)
      Source.answer!(fn _r, _n -> {:error, :issue_not_found} end)

      capture_log(fn -> Intake.retry_pending() end)

      assert %IntakeRecord{attempts: 1, note: "provider_failed", status: "pending"} =
               record!(issue)

      assert drain(:feedback_classifier_called) == 0
      assert_roles_unchanged(ctx)
    end
  end

  describe "redelivery" do
    test "redelivery resets attempts", ctx do
      issue = issue()
      pending!(issue)
      Stub.reply!(fn _c, _m, _o -> {:error, :timeout} end)

      capture_log(fn -> Intake.retry_pending() end)
      assert %IntakeRecord{attempts: 1, deliveries: 1} = record!(issue)

      capture_log(fn -> Intake.process(issue) end)

      assert %IntakeRecord{attempts: 0, next_attempt_at: nil, deliveries: 2} = record!(issue)
      assert_roles_unchanged(ctx)
    end

    test "a retry is not a delivery: deliveries does not move", ctx do
      issue = issue()
      pending!(issue)
      Stub.reply!(fn _c, _m, _o -> {:error, :timeout} end)

      capture_log(fn -> Intake.retry_pending() end)
      assert %IntakeRecord{deliveries: 1} = record!(issue)
      assert_roles_unchanged(ctx)
    end
  end

  describe "C5: no issue text persisted or logged" do
    test "a retried decision logs and stores no title or body", ctx do
      issue = issue()
      pending!(issue)

      log =
        capture_all_logs(fn ->
          assert {:ok, %{claimed: 1, outcomes: [:task_filed]}} = Intake.retry_pending()
        end)

      assert log =~ "[Feedback.Intake]"
      refute log =~ "RETRY-TITLE-CANARY"
      refute log =~ "RETRY-BODY-CANARY"

      record = record!(issue)
      refute inspect(record) =~ "CANARY"

      assert record.content_sha256 ==
               :crypto.hash(:sha256, [issue.title, <<0>>, issue.body])
               |> Base.encode16(case: :lower)

      assert_roles_unchanged(ctx)
    end
  end

  defp capture_ok(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:capture_ok, fun.()}) end)

    receive do
      {:capture_ok, value} -> value
    end
  end

  defp capture_all_logs(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug], fun)
    after
      Logger.configure(level: previous)
    end
  end
end
