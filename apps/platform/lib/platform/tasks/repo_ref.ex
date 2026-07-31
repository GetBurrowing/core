defmodule Platform.Tasks.RepoRef do
  @moduledoc """
  Canonical GitHub repository identity — the `"owner/name"` slug.

  The same repository reaches this system in at least five spellings, and
  two of them arrive on the SAME code path:

    * `project.repo_url` is stored as `https://github.com/Owner/Name`
    * GitHub webhooks deliver `repository.full_name` as the bare
      `Owner/Name`

  A deploy gate that has to decide "did the PR that just merged belong to
  the repo this gate is watching?" therefore cannot compare the two
  strings it is handed. This module is the one place that answers that,
  so the four consumers (`DeployStageBuilder`, the GitHub webhook
  controller, `AutoMerger`, `HeartbeatScheduler`) do not each grow their
  own `String.replace/3` chain and drift apart — the second
  independently-drifting derivation that `PlanEngine`'s `skip_reason/1`
  comment argues against.

  ## Accepted spellings

      https://github.com/Owner/Name
      https://github.com/Owner/Name/
      https://github.com/Owner/Name.git
      git@github.com:Owner/Name.git
      ssh://git@github.com/Owner/Name.git
      Owner/Name

  Anything else — a non-GitHub host, a bare word, a URL with extra path
  segments (`.../tree/main`), `nil`, `""` — is `:error`. Refusing is
  deliberate: a slug guessed out of an unrecognized string would be a
  gate that silently watches the wrong repository, which is strictly
  worse than a gate that admits it cannot resolve one.

  ## Case

  `normalize/1` PRESERVES the case it was given, so error messages and
  dispatch prompts read the way a human wrote the config. `same?/2`
  compares case-insensitively, because GitHub owner and repository names
  are case-insensitive for lookup (`startup-suite/core` and
  `Startup-Suite/core` are the same repository).
  """

  # Owner: GitHub allows alphanumerics and single hyphens.
  # Name: alphanumerics plus `.`, `_`, `-`.
  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @doc """
  Normalize any accepted spelling to the canonical `"owner/name"` slug.

  Returns `{:ok, slug}` or `:error`. Never raises.

  ## Examples

      iex> Platform.Tasks.RepoRef.normalize("https://github.com/Startup-Suite/core.git")
      {:ok, "Startup-Suite/core"}

      iex> Platform.Tasks.RepoRef.normalize("git@github.com:Startup-Suite/core.git")
      {:ok, "Startup-Suite/core"}

      iex> Platform.Tasks.RepoRef.normalize("not a repo")
      :error
  """
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(value) when is_binary(value) do
    value
    |> String.trim()
    |> strip_scheme()
    |> strip_host()
    |> case do
      :error -> :error
      path -> split_slug(path)
    end
  end

  def normalize(_), do: :error

  @doc """
  Whether two repository references name the same GitHub repository.

  Normalizes both sides, then compares case-insensitively. Returns
  `false` — never raises, never `true` — when either side is
  unnormalizable, including `nil`. A "same repo" answer must be earned by
  two resolvable identities; `nil == nil` is not an identity.

  ## Examples

      iex> Platform.Tasks.RepoRef.same?("https://github.com/Startup-Suite/Core", "startup-suite/core")
      true

      iex> Platform.Tasks.RepoRef.same?(nil, nil)
      false
  """
  @spec same?(term(), term()) :: boolean()
  def same?(left, right) do
    case {normalize(left), normalize(right)} do
      {{:ok, a}, {:ok, b}} -> String.downcase(a) == String.downcase(b)
      _ -> false
    end
  end

  @doc """
  `normalize/1` returning the slug directly, or `nil` when unresolvable.

  For call sites that store the slug in a map and want the absence to be
  representable (a declared repo we could not resolve keeps its
  `repo_url` and carries a `nil` slug, so nothing downstream can match it
  by accident).
  """
  @spec slug(term()) :: String.t() | nil
  def slug(value) do
    case normalize(value) do
      {:ok, slug} -> slug
      :error -> nil
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp strip_scheme("https://" <> rest), do: rest
  defp strip_scheme("http://" <> rest), do: rest
  defp strip_scheme("ssh://" <> rest), do: rest
  defp strip_scheme("git://" <> rest), do: rest
  defp strip_scheme(other), do: other

  # `git@github.com:Owner/Name` — the SCP-style spelling git remotes use.
  defp strip_host("git@github.com:" <> rest), do: rest
  # `ssh://git@github.com/Owner/Name` — scheme already stripped above.
  defp strip_host("git@github.com/" <> rest), do: rest
  defp strip_host("github.com/" <> rest), do: rest
  defp strip_host("www.github.com/" <> rest), do: rest

  defp strip_host(other) do
    # Only the bare `Owner/Name` form survives here. Anything that still
    # looks host-qualified (`gitlab.com/a/b`, `github.example.com/a/b`)
    # is refused rather than guessed at.
    if String.contains?(other, ["://", "@", "github.com"]) or host_qualified?(other) do
      :error
    else
      other
    end
  end

  defp host_qualified?(value) do
    case String.split(value, "/", parts: 2) do
      [first, _rest] -> String.contains?(first, ".") and not String.starts_with?(first, ".")
      _ -> false
    end
  end

  defp split_slug(path) do
    path
    |> String.trim_trailing("/")
    |> String.split("/")
    |> case do
      [owner, name] -> build_slug(owner, name)
      _ -> :error
    end
  end

  defp build_slug(owner, name) do
    name = String.replace_suffix(name, ".git", "")

    if Regex.match?(@segment, owner) and Regex.match?(@segment, name) do
      {:ok, owner <> "/" <> name}
    else
      :error
    end
  end
end
