defmodule Platform.Tasks.DeliveryReference do
  @moduledoc """
  A delivery reference — the sha or merged PR that says shipped work
  shipped — parsed strictly and resolved against a real repository.

  ## Why this is a separate module

  `Platform.Tasks.close_as_delivered/3` deliberately accepts any non-blank
  string, and its own suite closes rows with the literal reference
  `"sha"`. That is correct for a human operator console, where the person
  clicking the button is the verification. Tightening
  `close_as_delivered/3` would break those intentional assertions.

  The teeth therefore live HERE, and are enforced by the MCP wrapper
  only: an agent closing a row must hand over something that names a real
  object, because an agent has no judgement the string can borrow.

  ## Parsing is whole-string, on purpose

  `parse/1` trims and then matches the WHOLE string. It never scans a
  longer string for an embedded token — a scan would admit arbitrary
  prose the moment it happened to contain a hex-looking word
  (`"the deadbeef branch shipped"`), which is exactly the class of
  reference this module exists to refuse.

  ## A URL names its own repository, and we do not ignore it

  `https://github.com/someone/else/pull/3` carries an owner/repo of its
  own. Stage 1 of this task parsed those two URL forms with a regex that
  accepted ANY owner/repo and then resolved the extracted number against
  the PROJECT's repository — so that URL would have resolved against
  *this* project's PR #3, a different object entirely, and closed a task
  citing a reference that names something else. That is a wrong-row
  attribution on a code path whose whole purpose is to say "this shipped".

  So `parse/1` keeps the slug it read, and `resolve/2` REFUSES with
  `{:error, {:foreign_repo, named, project}}` when the two differ.
  Recording the mismatch instead of refusing was considered and rejected:
  a stamp carrying two slugs just moves the decision to whoever reads it
  later, which is how a bad attribution gets laundered into a confident
  record.

  Comparison is `RepoRef.same?/2`, so case and `.git`/scheme spelling do
  not manufacture a mismatch.

  ## Resolution has three outcomes, not two

  `{:error, {:unavailable, message}}` is distinct from
  `{:error, :not_found}` and must never be collapsed into it. "I could
  not check" is not "it does not exist"; collapsing them would let a
  missing `gh` binary or an expired token read as a bad reference — or,
  worse in the other direction, let a caller retry-until-green.
  """

  alias Platform.Tasks.DeliveryReference.GhRunner
  alias Platform.Tasks.RepoRef

  @enforce_keys [:kind, :value, :raw]
  defstruct [:kind, :value, :raw, :slug]

  @typedoc """
  A parsed reference.

    * `:kind` — `:sha` or `:pr`.
    * `:value` — the bare sha (downcased) for `:sha`; the PR number as an
      integer for `:pr`.
    * `:raw` — the trimmed string the caller supplied, preserved so error
      messages quote what the human actually typed.
    * `:slug` — the `"owner/name"` the reference NAMED, for the two URL
      spellings that carry one; `nil` for a bare sha or `#1018`, which
      name no repository at all. See "A URL names its own repository".
  """
  @type t :: %__MODULE__{
          kind: :sha | :pr,
          value: String.t() | pos_integer(),
          raw: String.t(),
          slug: String.t() | nil
        }

  @default_runner GhRunner

  # A GitHub abbreviated sha is at least 7 characters; a full one is 40.
  @sha ~r/\A[0-9a-fA-F]{7,40}\z/
  @hash_number ~r/\A#(\d+)\z/
  @pr_url ~r/\Ahttps:\/\/github\.com\/([A-Za-z0-9][A-Za-z0-9._-]*)\/([A-Za-z0-9][A-Za-z0-9._-]*)\/pull\/(\d+)\z/
  @commit_url ~r/\Ahttps:\/\/github\.com\/([A-Za-z0-9][A-Za-z0-9._-]*)\/([A-Za-z0-9][A-Za-z0-9._-]*)\/commit\/([0-9a-fA-F]{7,40})\z/

  @doc """
  The configured `Platform.Tasks.DeliveryReference.Runner`.

  Public so tests can pin a stub without mutating application env from an
  async case — same seam, and same reason, as
  `Platform.Tasks.MergeControl.runner/0`.
  """
  @spec runner() :: module()
  def runner do
    :platform
    |> Application.get_env(:delivery_reference, [])
    |> Keyword.get(:runner, @default_runner)
  end

  @doc """
  Parse a delivery reference, or refuse.

  Accepts exactly four spellings, after `String.trim/1`:

      b85a4a96                                              # 7–40 hex chars
      #1018
      https://github.com/Startup-Suite/core/pull/1018
      https://github.com/Startup-Suite/core/commit/b85a4a96…

  Anything else is `{:error, :unparseable}`.

  ## Examples

      iex> {:ok, ref} = Platform.Tasks.DeliveryReference.parse("  #1018 ")
      iex> {ref.kind, ref.value}
      {:pr, 1018}

      iex> Platform.Tasks.DeliveryReference.parse("shipped last week")
      {:error, :unparseable}
  """
  @spec parse(term()) :: {:ok, t()} | {:error, :unparseable}
  def parse(binary) when is_binary(binary) do
    raw = String.trim(binary)

    cond do
      raw == "" ->
        {:error, :unparseable}

      Regex.match?(@sha, raw) ->
        {:ok, %__MODULE__{kind: :sha, value: String.downcase(raw), raw: raw}}

      captures = Regex.run(@hash_number, raw) ->
        pr(captures, raw)

      captures = Regex.run(@pr_url, raw) ->
        pr(captures, raw)

      captures = Regex.run(@commit_url, raw) ->
        [_, owner, name, sha] = captures

        {:ok,
         %__MODULE__{
           kind: :sha,
           value: String.downcase(sha),
           raw: raw,
           slug: owner <> "/" <> name
         }}

      true ->
        {:error, :unparseable}
    end
  end

  def parse(_), do: {:error, :unparseable}

  # `#1018` names no repository; the URL form names one and we keep it.
  defp pr([_, digits], raw), do: pr_struct(digits, raw, nil)
  defp pr([_, owner, name, digits], raw), do: pr_struct(digits, raw, owner <> "/" <> name)

  defp pr_struct(digits, raw, slug) do
    case Integer.parse(digits) do
      {n, ""} when n > 0 -> {:ok, %__MODULE__{kind: :pr, value: n, raw: raw, slug: slug}}
      _ -> {:error, :unparseable}
    end
  end

  @doc """
  Resolve a parsed reference against the repository at `repo_url`.

  A `:sha` resolves when the commit exists. A `:pr` resolves ONLY when
  its state is `MERGED` — an open PR, or one closed without merging, is
  `{:error, :not_merged}`, because "there was a PR" is not "it shipped".

  A reference that NAMES a repository (either URL form) is refused with
  `{:error, {:foreign_repo, named_slug, project_slug}}` when that
  repository is not the project's — see the moduledoc.

  `{:ok, map}` always carries `"kind"`, `"value"`, `"url"` and
  `"resolved_at"`, plus `"merge_commit"` for a PR.
  """
  @spec resolve(t(), term()) ::
          {:ok, map()}
          | {:error,
             :not_found
             | :not_merged
             | {:unavailable, String.t()}
             | {:foreign_repo, String.t(), String.t()}}
  def resolve(%__MODULE__{} = ref, repo_url) do
    case RepoRef.normalize(repo_url) do
      {:ok, slug} ->
        # The slug check runs BEFORE any lookup: a foreign URL must not
        # even be answered against this project's repository, or the
        # answer itself is the wrong-row attribution.
        if is_nil(ref.slug) or RepoRef.same?(ref.slug, slug) do
          do_resolve(ref, slug)
        else
          {:error, {:foreign_repo, ref.slug, slug}}
        end

      :error ->
        {:error,
         {:unavailable,
          "cannot resolve a GitHub repository from #{inspect(repo_url)}; " <>
            "the project has no usable repo_url, so the reference could not be checked"}}
    end
  end

  defp do_resolve(%__MODULE__{kind: :sha, value: sha} = ref, slug) do
    case runner().commit(slug, sha) do
      {:ok, commit} ->
        {:ok,
         %{
           "kind" => "sha",
           "value" => commit["sha"] || sha,
           "url" => commit["html_url"] || "https://github.com/#{slug}/commit/#{sha}",
           "resolved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
           "raw" => ref.raw
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_resolve(%__MODULE__{kind: :pr, value: number} = ref, slug) do
    case runner().pull_request(slug, number) do
      {:ok, %{"state" => "MERGED"} = pr} ->
        {:ok,
         %{
           "kind" => "pr",
           "value" => number,
           "url" => pr["url"] || "https://github.com/#{slug}/pull/#{number}",
           "merge_commit" => merge_commit(pr),
           "merged_at" => pr["mergedAt"],
           "resolved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
           "raw" => ref.raw
         }}

      {:ok, %{}} ->
        {:error, :not_merged}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `mergeCommit` is `{"oid": "…"}` on a merged PR and `null` otherwise.
  defp merge_commit(%{"mergeCommit" => %{"oid" => oid}}) when is_binary(oid), do: oid
  defp merge_commit(%{"mergeCommit" => oid}) when is_binary(oid), do: oid
  defp merge_commit(_), do: nil
end
