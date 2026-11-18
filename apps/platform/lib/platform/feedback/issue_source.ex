defmodule Platform.Feedback.IssueSource do
  @moduledoc """
  Where the feedback intake's retry sweep re-reads a pending issue (task
  01a1e670 stage 2).

  `Platform.Feedback.IntakeRecord` stores no issue text, so a pending record
  can only be re-classified by fetching the issue again. An implementation
  returns the same normalized, bounded shape the webhook produces
  (`Platform.Feedback.Intake.extract_issue/1`), held in memory only.

  `{:error, :fetch_unavailable}` means this node cannot fetch at all (no
  credential, or a repository it may not read); the sweep gives the attempt
  back. Any other error consumes the attempt.

  Selected by `config :platform, :feedback_intake_issue_source` (default
  `Platform.Feedback.IssueSource.GithubApp`).
  """

  alias Platform.Feedback.Classifier

  @callback fetch(repository :: String.t(), issue_number :: pos_integer()) ::
              {:ok, Classifier.issue()} | {:error, atom()}

  @doc "The configured implementation."
  @spec impl() :: module()
  def impl do
    Application.get_env(
      :platform,
      :feedback_intake_issue_source,
      Platform.Feedback.IssueSource.GithubApp
    )
  end

  @doc "Fetch through the configured implementation."
  @spec fetch(String.t(), pos_integer()) :: {:ok, Classifier.issue()} | {:error, atom()}
  def fetch(repository, issue_number), do: impl().fetch(repository, issue_number)
end
