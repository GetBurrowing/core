defmodule Platform.Feedback.IntakeSweeperTest do
  @moduledoc """
  `Platform.Feedback.IntakeSweeper` (task 01a1e670 stage 2): a per-case
  instance at a 50ms tick drives one pending record to a decision, and does
  nothing while the feedback policy is off.

  async: false — Application env stubs, and a sweeper process allowed into
  this test's sandbox.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Feedback.Intake
  alias Platform.Feedback.IntakeRecord
  alias Platform.Feedback.IntakeSweeper
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Test.FeedbackIntakeStub, as: Stub
  alias Platform.Test.FeedbackIssueSourceStub, as: Source

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Intake sweeper #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/acme/sweeper-#{System.unique_integer([:positive])}"
      })

    :ok = Stub.install!(reply: fn _c, _m, _o -> {:error, :timeout} end, project_id: project.id)
    Stub.classifier_agent!()
    :ok = Source.install!()

    issue = %{
      repository: "GetBurrowing/core",
      issue_number: System.unique_integer([:positive]),
      title: "Sweeper card position lost",
      body: "Expected it to stay. Observed it moves."
    }

    capture_log(fn ->
      assert {:ok, %{outcome: :pending, note: "provider_failed"}} = Intake.process(issue)
    end)

    Stub.reply!(Stub.json(Stub.verdict()))
    Source.answer!(Source.serving([issue]))
    %{issue: issue}
  end

  defp start_sweeper! do
    name = :"intake_sweeper_#{System.unique_integer([:positive])}"
    pid = start_supervised!({IntakeSweeper, name: name, tick_interval_ms: 50})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    pid
  end

  defp record!(issue), do: Repo.get_by!(IntakeRecord, issue_number: issue.issue_number)

  test "a 50ms instance drives one pending record to a decision", %{issue: issue} do
    capture_log(fn ->
      pid = start_sweeper!()
      assert_receive {:feedback_disposition, _disposition, _opts}, 5_000
      # Park the sweeper BETWEEN ticks before stopping it: killing it inside a
      # query would take the shared sandbox connection down with it.
      :ok = :sys.suspend(pid)
      stop_supervised!(IntakeSweeper)
    end)

    assert %IntakeRecord{status: "decided", verdict: "accept_bug"} = record!(issue)
    assert [_one] = Stub.external_tasks(issue.repository, issue.issue_number)
  end

  test "a disabled policy sweeps nothing", %{issue: issue} do
    Application.put_env(:platform, :feedback_policy, "disabled")

    assert IntakeSweeper.sweep() == :disabled
    refute_received {:issue_source_fetch, _, _}
    assert %IntakeRecord{status: "pending", attempts: 0} = record!(issue)
  end
end
