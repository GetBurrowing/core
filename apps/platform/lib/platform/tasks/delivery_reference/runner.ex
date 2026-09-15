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
  """

  @typedoc "Raw commit facts, as returned by `gh api repos/<slug>/commits/<sha>`."
  @type commit :: %{optional(String.t()) => term()}

  @typedoc """
  Raw pull-request facts.

  `"state"` is GitHub's own spelling — `"OPEN"`, `"CLOSED"`, `"MERGED"`.
  `Platform.Tasks.DeliveryReference.resolve/2` accepts only `"MERGED"`.
  """
  @type pull_request :: %{optional(String.t()) => term()}

  @callback commit(slug :: String.t(), sha :: String.t()) ::
              {:ok, commit()} | {:error, :not_found} | {:error, {:unavailable, String.t()}}

  @callback pull_request(slug :: String.t(), number :: pos_integer()) ::
              {:ok, pull_request()} | {:error, :not_found} | {:error, {:unavailable, String.t()}}
end
