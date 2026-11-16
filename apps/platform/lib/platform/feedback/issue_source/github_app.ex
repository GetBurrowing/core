defmodule Platform.Feedback.IssueSource.GithubApp do
  @moduledoc """
  The default `Platform.Feedback.IssueSource`: one GET through the feedback
  GitHub App (`Platform.Feedback.GithubPublisher.GithubApp.fetch_issue/2`,
  an `issues: "read"` token on the one configured repository), normalized
  by `Platform.Feedback.Intake.extract_issue/1` exactly as a webhook
  delivery is, so title and body get the same byte bound and a pull request
  is refused the same way.
  """

  @behaviour Platform.Feedback.IssueSource

  alias Platform.Feedback.GithubPublisher.GithubApp
  alias Platform.Feedback.Intake

  @impl true
  def fetch(repository, issue_number) do
    with {:ok, payload} <- GithubApp.fetch_issue(repository, issue_number) do
      case Intake.extract_issue(%{
             "action" => "opened",
             "issue" => payload,
             "repository" => %{"full_name" => repository}
           }) do
        {:ok, %{issue_number: ^issue_number} = issue} -> {:ok, issue}
        {:ok, _other} -> {:error, :publisher_bad_response}
        {:ignored, reason} -> {:error, reason}
      end
    end
  end
end
