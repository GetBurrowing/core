defmodule Platform.Tasks.DeliveryReference.GhRunner do
  @moduledoc """
  Default `Platform.Tasks.DeliveryReference.Runner` — four read-only `gh`
  subcommands and nothing else:

      gh api repos/<slug>/commits/<sha>
      gh pr view <number> -R <slug> --json state,mergedAt,mergeCommit,url
      gh pr list -R <slug> --state merged --limit <n> --json number,title,body,mergedAt,mergeCommit,url
      gh search code --repo <slug> --json path --limit 5 -- <term>

  There is no code path here that mutates a repository.

  ## Missing binary

  `System.cmd("gh", …)` raises `ErlangError: :enoent` when the CLI is
  absent — a crash whose stacktrace reads like anything except "the
  binary is missing", and the prod image has shipped without `gh`
  before. Mirrors the `System.find_executable("gh")` guards in
  `Platform.Tasks.AutoMerger.execute_merge/3` and
  `Platform.Tasks.MergeControl.GhRunner.pr_state/1` — except that those
  return `{:error, :gh_unavailable, message}` and this returns
  `{:error, {:unavailable, message}}`, the two-tuple shape the
  `DeliveryReference.Runner` behaviour declares.

  ## Why a non-zero exit is not automatically `:not_found`

  `gh` exits non-zero for a 404 AND for a network failure, an expired
  token and a rate limit. Only the 404 wording means the object does not
  exist; everything else is `{:unavailable, _}`, because closing a task
  as delivered on "I could not check" is the failure this module exists
  to prevent.

  ## The listing commands have no `:not_found`

  `merged_pull_requests/2` and `code_search/2` return `{:ok, list}` only
  when `gh` exited 0 AND printed a JSON array. Any non-zero exit —
  including one whose wording looks like a 404 — is `{:unavailable, _}`,
  never `{:ok, []}`: an empty code search means "the defect string is
  absent" and an empty merged-PR list means "nothing shipped", so a
  failure read as empty would manufacture (or hide) fixed-but-open
  candidates. Argv building and output interpretation are public pure
  functions so tests exercise them without shelling out.

  The search term goes after `--` so a term beginning with `-` is read as
  the query, not as a flag.
  """

  @behaviour Platform.Tasks.DeliveryReference.Runner

  require Logger

  @gh_missing_message "`gh` (GitHub CLI) not found on PATH; cannot verify a delivery reference against GitHub"

  @impl true
  def commit(slug, sha) do
    case run(["api", "repos/#{slug}/commits/#{sha}"]) do
      {:ok, output} -> decode(output)
      other -> other
    end
  end

  @impl true
  def pull_request(slug, number) do
    args = [
      "pr",
      "view",
      Integer.to_string(number),
      "-R",
      slug,
      "--json",
      "state,mergedAt,mergeCommit,url"
    ]

    case run(args) do
      {:ok, output} -> decode(output)
      other -> other
    end
  end

  @merged_pr_fields "number,title,body,mergedAt,mergeCommit,url"
  @code_search_limit 5

  @impl true
  def merged_pull_requests(slug, limit)
      when is_binary(slug) and is_integer(limit) and limit > 0 do
    slug |> merged_pull_requests_args(limit) |> exec() |> merged_pull_requests_result()
  end

  @impl true
  def code_search(slug, term) when is_binary(slug) and is_binary(term) do
    slug |> code_search_args(term) |> exec() |> code_search_result()
  end

  @doc "argv for `gh pr list … --state merged` (without the `gh` binary)."
  @spec merged_pull_requests_args(String.t(), pos_integer()) :: [String.t()]
  def merged_pull_requests_args(slug, limit) when is_integer(limit) and limit > 0 do
    [
      "pr",
      "list",
      "-R",
      slug,
      "--state",
      "merged",
      "--limit",
      Integer.to_string(limit),
      "--json",
      @merged_pr_fields
    ]
  end

  @doc "argv for `gh search code` (without the `gh` binary)."
  @spec code_search_args(String.t(), String.t()) :: [String.t()]
  def code_search_args(slug, term) do
    [
      "search",
      "code",
      "--repo",
      slug,
      "--json",
      "path",
      "--limit",
      Integer.to_string(@code_search_limit),
      "--",
      term
    ]
  end

  @doc """
  Interprets a raw `gh pr list` outcome. `{:ok, output}` is decoded as a
  JSON array of maps; `{:exit, status, output}` (non-zero exit) and a
  missing binary are `{:unavailable, _}` — never `{:ok, []}`.
  """
  @spec merged_pull_requests_result(exec_result()) ::
          {:ok, [map()]} | {:error, {:unavailable, String.t()}}
  def merged_pull_requests_result({:ok, output}), do: decode_list(output)

  def merged_pull_requests_result({:exit, status, output}),
    do: exit_unavailable("gh pr list", status, output)

  def merged_pull_requests_result({:error, {:unavailable, _}} = unavailable), do: unavailable

  @doc """
  Interprets a raw `gh search code` outcome. `{:ok, output}` must be a JSON
  array of maps each carrying a string `"path"`; anything else, any
  non-zero exit and a missing binary are `{:unavailable, _}`. `{:ok, []}`
  is returned ONLY when `gh` exited 0 and printed `[]`.
  """
  @spec code_search_result(exec_result()) ::
          {:ok, [map()]} | {:error, {:unavailable, String.t()}}
  def code_search_result({:ok, output}) do
    with {:ok, hits} <- decode_list(output) do
      if Enum.all?(hits, &match?(%{"path" => path} when is_binary(path), &1)) do
        {:ok, hits}
      else
        {:error,
         {:unavailable,
          "`gh search code` hit without a string \"path\": " <> String.slice(output, 0, 500)}}
      end
    end
  end

  def code_search_result({:exit, status, output}),
    do: exit_unavailable("gh search code", status, output)

  def code_search_result({:error, {:unavailable, _}} = unavailable), do: unavailable

  @doc """
  Decodes `gh` output that must be a JSON ARRAY of objects. A JSON object,
  a scalar, an array holding a non-object, or garbage is `{:unavailable, _}`.
  """
  @spec decode_list(String.t()) :: {:ok, [map()]} | {:error, {:unavailable, String.t()}}
  def decode_list(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_map/1) do
          {:ok, list}
        else
          {:error,
           {:unavailable, "`gh` array holds a non-object: " <> String.slice(output, 0, 500)}}
        end

      _ ->
        {:error,
         {:unavailable,
          "unparseable `gh` output (expected a JSON array): " <> String.slice(output, 0, 500)}}
    end
  end

  @typedoc "What `exec/1` hands the pure result interpreters."
  @type exec_result ::
          {:ok, String.t()}
          | {:exit, non_neg_integer(), String.t()}
          | {:error, {:unavailable, String.t()}}

  defp exit_unavailable(command, status, output) do
    {:error,
     {:unavailable,
      "`#{command}` exited #{status}: " <> String.slice(String.trim(output), 0, 500)}}
  end

  defp run(args) do
    case exec(args) do
      {:exit, _exit_code, output} -> classify_failure(String.trim(output))
      other -> other
    end
  end

  # The one place `gh` is executed. Returns the raw outcome; each caller
  # decides what a non-zero exit means for its own callback.
  defp exec(args) do
    case System.find_executable("gh") do
      nil ->
        Logger.error("[delivery_reference] #{@gh_missing_message}")
        {:error, {:unavailable, @gh_missing_message}}

      gh ->
        case System.cmd(gh, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, exit_code} -> {:exit, exit_code, output}
        end
    end
  end

  # GitHub's 404 wording, across both `gh api` and `gh pr view`.
  defp classify_failure(output) do
    if output =~ ~r/404|[Nn]ot [Ff]ound|no pull requests found|could not resolve to a/i do
      {:error, :not_found}
    else
      {:error, {:unavailable, String.slice(output, 0, 500)}}
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, {:unavailable, "unparseable `gh` output: " <> String.slice(output, 0, 500)}}
    end
  end
end
