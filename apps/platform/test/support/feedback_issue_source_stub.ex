defmodule Platform.Test.FeedbackIssueSourceStub do
  @moduledoc """
  A `Platform.Feedback.IssueSource` for tests (task 01a1e670 stage 2),
  installed through `:feedback_intake_issue_source`. Every fetch sends
  `{:issue_source_fetch, repository, issue_number}` to the installing test
  process and answers with the planted fun.

  Application env, so it works from a sweeper or Task process. Tests using
  it must be `async: false`.
  """

  @behaviour Platform.Feedback.IssueSource

  @env_key :feedback_issue_source_stub

  @doc "Install the stub answering with `answer` (a 2-arity fun) and restore on exit."
  def install!(answer \\ fn _repo, _number -> {:error, :issue_not_found} end)
      when is_function(answer, 2) do
    previous = Application.fetch_env(:platform, :feedback_intake_issue_source)
    Application.put_env(:platform, :feedback_intake_issue_source, __MODULE__)
    Application.put_env(:platform, @env_key, %{pid: self(), answer: answer})

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:platform, @env_key)

      case previous do
        {:ok, value} -> Application.put_env(:platform, :feedback_intake_issue_source, value)
        :error -> Application.delete_env(:platform, :feedback_intake_issue_source)
      end
    end)

    :ok
  end

  @doc "Replace the answer fun without reinstalling."
  def answer!(answer) when is_function(answer, 2) do
    env = Application.fetch_env!(:platform, @env_key)
    Application.put_env(:platform, @env_key, %{env | answer: answer})
  end

  @doc "An answer serving exactly the given issues, keyed by issue number."
  def serving(issues) when is_list(issues) do
    by_number = Map.new(issues, &{&1.issue_number, &1})

    fn _repo, number ->
      case Map.fetch(by_number, number) do
        {:ok, issue} -> {:ok, issue}
        :error -> {:error, :issue_not_found}
      end
    end
  end

  @impl true
  def fetch(repository, issue_number) do
    case Application.get_env(:platform, @env_key) do
      %{pid: pid, answer: answer} ->
        send(pid, {:issue_source_fetch, repository, issue_number})
        answer.(repository, issue_number)

      nil ->
        {:error, :fetch_unavailable}
    end
  end
end
