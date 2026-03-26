defmodule PlatformWeb.GithubWebhookController do
  @moduledoc """
  Receives GitHub webhook events and creates changelog entries for merged PRs.

  Listens for `pull_request` events with `action: "closed"` and `merged: true`.
  Parses conventional commit prefixes, extracts task IDs from branch names,
  and inserts changelog entries.
  """

  use PlatformWeb, :controller

  alias Platform.Changelog

  require Logger

  def handle(conn, %{"action" => "closed", "pull_request" => pr} = _params) do
    if pr["merged"] do
      process_merged_pr(conn, pr)
    else
      conn |> put_status(:ok) |> json(%{status: "ignored", reason: "not merged"})
    end
  end

  def handle(conn, _params) do
    conn |> put_status(:ok) |> json(%{status: "ignored", reason: "not a relevant event"})
  end

  defp process_merged_pr(conn, pr) do
    raw_title = pr["title"] || ""
    {cleaned_title, tags} = Changelog.parse_title(raw_title)

    branch = get_in(pr, ["head", "ref"])
    body = pr["body"]

    task_id =
      Changelog.extract_task_id_from_branch(branch) ||
        Changelog.extract_task_id_from_body(body)

    merged_at = parse_datetime(pr["merged_at"])

    description =
      case body do
        body when is_binary(body) and byte_size(body) > 0 ->
          body |> String.slice(0, 500) |> String.trim()

        _ ->
          nil
      end

    attrs = %{
      title: cleaned_title,
      description: description,
      pr_number: pr["number"],
      pr_url: pr["html_url"],
      commit_sha: pr["merge_commit_sha"],
      author: get_in(pr, ["user", "login"]),
      task_id: task_id,
      tags: tags,
      merged_at: merged_at
    }

    case Changelog.create_entry(attrs) do
      {:ok, entry} ->
        Logger.info("[Changelog] Created entry for PR ##{entry.pr_number}: #{entry.title}")
        conn |> put_status(:created) |> json(%{status: "created", id: entry.id})

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
            end)
          end)

        Logger.warning("[Changelog] Failed to create entry: #{inspect(errors)}")
        conn |> put_status(:unprocessable_entity) |> json(%{status: "error", errors: errors})
    end
  end

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
