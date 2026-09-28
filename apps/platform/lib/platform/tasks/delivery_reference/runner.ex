defmodule Platform.Tasks.DeliveryReference.Runner do
  @moduledoc """
  The one seam through which `Platform.Tasks.DeliveryReference` reaches
  GitHub. Mirrors `Platform.Tasks.MergeControl.Runner`: a behaviour with
  read-only callbacks, pinned in tests through application env so no
  suite has to shell out to `gh`.

  Both callbacks distinguish THREE outcomes, and the third is the reason
  this behaviour exists:

    * `{:ok, map}` — GitHub answered and the object exists.
    * `{:error, :not_found}` — GitHub answered and the object does not exist.
    * `{:error, {:unavailable, message}}` — we could not ask. A missing
      `gh` binary, a network failure, an auth failure.

  `{:unavailable, _}` must never be collapsed into `:not_found`: "I could
  not check" is not "it does not exist", and a delivery reference closed
  on the second reading of the first would record shipped work against an
  unverified sha.

  ## The two listing callbacks (task 01a044b0)

  `merged_pull_requests/2` and `code_search/2` feed a read-only sweep that
  matches open tickets against merged work. They have no `:not_found`
  outcome: a list that GitHub answered is `{:ok, list}`, and `{:ok, []}`
  means GitHub answered and found nothing. Every failure — missing
  binary, non-zero exit (whatever its wording), unparseable output — is
  `{:error, {:unavailable, message}}`. Collapsing a failure into `{:ok, []}`
  is the dangerous direction here: an empty code search reads as "the
  defect string is gone" and an empty merged-PR list reads as "nothing
  shipped", so a failure would manufacture or hide candidates.

  Both are `@optional_callbacks`, so runners that only verify a single
  reference (the test stubs) keep compiling. Callers must check
  `function_exported?/3` before calling them.
  """

  @typedoc "Raw commit facts, as returned by `gh api repos/<slug>/commits/<sha>`."
  @type commit :: %{optional(String.t()) => term()}

  @typedoc """
  Raw pull-request facts.

  `"state"` is GitHub's own spelling — `"OPEN"`, `"CLOSED"`, `"MERGED"`.
  `Platform.Tasks.DeliveryReference.resolve/2` accepts only `"MERGED"`.
  """
  @type pull_request :: %{optional(String.t()) => term()}

  @typedoc """
  One merged pull request, as returned by `gh pr list --state merged --json
  number,title,body,mergedAt,mergeCommit,url`.
  """
  @type merged_pull_request :: %{optional(String.t()) => term()}

  @typedoc "One code-search hit. Carries at least `\"path\"`."
  @type code_search_hit :: %{required(String.t()) => term()}

  @callback commit(slug :: String.t(), sha :: String.t()) ::
              {:ok, commit()} | {:error, :not_found} | {:error, {:unavailable, String.t()}}

  @callback pull_request(slug :: String.t(), number :: pos_integer()) ::
              {:ok, pull_request()} | {:error, :not_found} | {:error, {:unavailable, String.t()}}

  @callback merged_pull_requests(slug :: String.t(), limit :: pos_integer()) ::
              {:ok, [merged_pull_request()]} | {:error, {:unavailable, String.t()}}

  @callback code_search(slug :: String.t(), term :: String.t()) ::
              {:ok, [code_search_hit()]} | {:error, {:unavailable, String.t()}}

  @optional_callbacks merged_pull_requests: 2, code_search: 2
end
