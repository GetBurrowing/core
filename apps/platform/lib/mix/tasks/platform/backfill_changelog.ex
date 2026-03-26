defmodule Mix.Tasks.Platform.BackfillChangelog do
  @moduledoc """
  Backfills changelog_entries from merged PRs in a GitHub repository.

  Fetches merged PRs via the GitHub API and inserts changelog entries using
  the same parsing logic as the webhook handler (conventional commit prefixes,
  task ID extraction from branch names).

  Idempotent — skips PRs whose pr_number already exists in changelog_entries.

  ## Usage

      mix platform.backfill_changelog
      mix platform.backfill_changelog --repo Startup-Suite/core
      mix platform.backfill_changelog --limit 50
      mix platform.backfill_changelog --dry-run

  ## Options

    * `--repo` — GitHub repo in `owner/repo` format (default: `Startup-Suite/core`)
    * `--limit` — Maximum number of PRs to fetch (default: 100)
    * `--dry-run` — Print what would be inserted without writing to DB

  ## Requirements

    Requires the `GITHUB_TOKEN` environment variable or `gh` CLI to be authenticated.
  """

  use Mix.Task

  alias Platform.Changelog
  alias Platform.Repo

  import Ecto.Query

  @shortdoc "Backfill changelog entries from GitHub merged PRs"

  @default_repo "Startup-Suite/core"
  @default_limit 100

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [repo: :string, limit: :integer, dry_run: :boolean],
        aliases: [r: :repo, l: :limit, n: :dry_run]
      )

    repo = opts[:repo] || @default_repo
    limit = opts[:limit] || @default_limit
    dry_run = opts[:dry_run] || false

    Mix.Task.run("app.start")

    # Get existing PR numbers to skip
    existing_prs =
      Repo.all(
        from(e in "changelog_entries",
          where: not is_nil(e.pr_number),
          select: e.pr_number
        )
      )
      |> MapSet.new()

    Mix.shell().info("Fetching merged PRs from #{repo} (limit: #{limit})...")
    Mix.shell().info("Already have #{MapSet.size(existing_prs)} PRs in changelog")

    case fetch_merged_prs(repo, limit) do
      {:ok, prs} ->
        Mix.shell().info("Fetched #{length(prs)} merged PRs from GitHub")

        new_prs = Enum.reject(prs, fn pr -> MapSet.member?(existing_prs, pr["number"]) end)

        Mix.shell().info(
          "#{length(new_prs)} new PRs to backfill (#{length(prs) - length(new_prs)} already exist)"
        )

        inserted =
          Enum.reduce(new_prs, 0, fn pr, count ->
            case process_pr(pr, dry_run) do
              :ok -> count + 1
              :skip -> count
            end
          end)

        if dry_run do
          Mix.shell().info("\n[DRY RUN] Would insert #{inserted} changelog entries")
        else
          Mix.shell().info("\nInserted #{inserted} changelog entries")
        end

      {:error, reason} ->
        Mix.shell().error("Failed to fetch PRs: #{reason}")
    end
  end

  defp process_pr(pr, dry_run) do
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

    if dry_run do
      task_note = if task_id, do: " → task:#{String.slice(task_id, 0, 8)}", else: ""

      Mix.shell().info(
        "  [DRY RUN] PR ##{pr["number"]}: #{cleaned_title} [#{Enum.join(tags, ", ")}]#{task_note}"
      )

      :ok
    else
      case Changelog.create_entry(attrs) do
        {:ok, _entry} ->
          Mix.shell().info("  ✓ PR ##{pr["number"]}: #{cleaned_title}")
          :ok

        {:error, changeset} ->
          errors = inspect(changeset.errors)
          Mix.shell().info("  ✗ PR ##{pr["number"]}: #{errors}")
          :skip
      end
    end
  end

  defp fetch_merged_prs(repo, limit) do
    # Use gh CLI which handles auth automatically
    pages = ceil(limit / 100)

    prs =
      Enum.reduce_while(1..pages, [], fn page, acc ->
        per_page = min(100, limit - length(acc))

        case System.cmd("gh", [
               "api",
               "/repos/#{repo}/pulls",
               "--method",
               "GET",
               "-f",
               "state=closed",
               "-f",
               "sort=updated",
               "-f",
               "direction=desc",
               "-f",
               "per_page=#{per_page}",
               "-f",
               "page=#{page}"
             ]) do
          {json, 0} ->
            case Jason.decode(json) do
              {:ok, pulls} ->
                merged = Enum.filter(pulls, fn pr -> pr["merged_at"] != nil end)
                all = acc ++ merged

                if length(pulls) < per_page or length(all) >= limit do
                  {:halt, all}
                else
                  {:cont, all}
                end

              {:error, _} ->
                {:halt, acc}
            end

          {error, _code} ->
            {:halt, {:error, error}}
        end
      end)

    case prs do
      {:error, _} = err -> err
      list when is_list(list) -> {:ok, Enum.take(list, limit)}
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
