defmodule Platform.Execution.CredentialLease do
  @moduledoc """
  Short-lived, scoped credentials leased into a run for its duration.

  ## Design

  ADR 0011 specifies that runner credentials must be:

    - short-lived (leased per-run, not ambient container state)
    - scoped to the minimum permissions needed for the run
    - revocable: the platform can invalidate a lease before the run ends

  A `CredentialLease` is an in-memory token envelope. In the MVP it wraps
  application-config credentials. Later iterations can draw tokens from
  `Platform.Vault` (short-lived GitHub App installations, OIDC tokens, etc.).

  ## Lease kinds

    * `:github` — a GitHub token scoped to a single repository for read/push
    * `:model`  — an API key or JWT for a specific model provider (OpenAI, Anthropic…)
    * `:custom` — arbitrary named credentials for third-party integrations

  ## Usage

      # Lease GitHub credentials for a run
      {:ok, lease} = CredentialLease.lease(:github, run_id: run.id, repo: "owner/repo")

      # Extract the raw credential for injection into the child process env
      env = CredentialLease.to_env(lease)

      # Revoke a lease before the run ends
      :ok = CredentialLease.revoke(lease)

  ## Security note

  The current MVP reads credentials from application config (`config :platform,
  :execution`). The Vault-based leasing path is tracked in ADR 0011 Follow-Up
  item #3 and will replace this without changing the external contract.
  """

  @enforce_keys [:id, :kind, :run_id]
  defstruct id: nil,
            kind: nil,
            run_id: nil,
            repo: nil,
            credentials: %{},
            issued_at: nil,
            expires_at: nil,
            revoked_at: nil

  @type kind :: :github | :model | :custom

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          run_id: String.t(),
          repo: String.t() | nil,
          credentials: map(),
          issued_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil
        }

  # Default lease TTL: 2 hours (ample for typical coding runs)
  @default_ttl_seconds 7_200

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Issue a new credential lease of `kind` for `run_id`.

  Options:
    - `:repo`     — GitHub `"owner/repo"` slug (required for `:github` kind)
    - `:ttl`      — lease lifetime in seconds (default: #{@default_ttl_seconds})
    - `:provider` — model provider atom (`:anthropic`, `:openai`, …) for `:model` kind

  Returns `{:ok, lease}` or `{:error, reason}`.

  The `credentials` map is populated from application config for MVP. Future
  revisions will draw from `Platform.Vault`.
  """
  @spec lease(kind(), keyword()) :: {:ok, t()} | {:error, term()}
  def lease(kind, opts \\ []) do
    run_id = Keyword.fetch!(opts, :run_id)
    ttl = Keyword.get(opts, :ttl, @default_ttl_seconds)

    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl, :second)

    with {:ok, credentials} <- resolve_credentials(kind, opts) do
      lease = %__MODULE__{
        id: generate_id(),
        kind: kind,
        run_id: to_string(run_id),
        repo: Keyword.get(opts, :repo),
        credentials: credentials,
        issued_at: now,
        expires_at: expires_at,
        revoked_at: nil
      }

      {:ok, lease}
    end
  end

  @doc """
  Returns an OS-level environment variable map for the lease.

  These variables are meant to be injected into the child process env so the
  runner can authenticate without needing the lease struct itself.

  GitHub leases inject: `GITHUB_TOKEN`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
  `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL`.

  Model leases inject the provider-specific key variable, e.g. `ANTHROPIC_API_KEY`
  or `OPENAI_API_KEY`.
  """
  @spec to_env(t()) :: %{String.t() => String.t()}
  def to_env(%__MODULE__{kind: :github, credentials: creds}) do
    env = %{}

    env =
      case Map.get(creds, :token) do
        nil -> env
        token -> Map.put(env, "GITHUB_TOKEN", token)
      end

    env =
      case Map.get(creds, :author_name) do
        nil -> env
        name -> Map.merge(env, %{"GIT_AUTHOR_NAME" => name, "GIT_COMMITTER_NAME" => name})
      end

    env =
      case Map.get(creds, :author_email) do
        nil -> env
        email -> Map.merge(env, %{"GIT_AUTHOR_EMAIL" => email, "GIT_COMMITTER_EMAIL" => email})
      end

    env
  end

  def to_env(%__MODULE__{kind: :model, credentials: creds}) do
    provider = Map.get(creds, :provider, :openai)
    key = Map.get(creds, :api_key)

    if key do
      var = model_env_var(provider)
      %{var => key}
    else
      %{}
    end
  end

  def to_env(%__MODULE__{kind: :custom, credentials: creds}) do
    Map.new(creds, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  @doc """
  Marks the lease as revoked.

  The returned struct records the revocation timestamp. Callers are responsible
  for clearing the corresponding env vars from any running process; the lease
  struct itself is the audit record.
  """
  @spec revoke(t()) :: {:ok, t()}
  def revoke(%__MODULE__{} = lease) do
    {:ok, %__MODULE__{lease | revoked_at: DateTime.utc_now()}}
  end

  @doc "Returns true if the lease is still valid (not expired and not revoked)."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{revoked_at: revoked_at}) when not is_nil(revoked_at), do: false

  def valid?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :lt
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolve_credentials(:github, opts) do
    config =
      :platform
      |> Application.get_env(:execution, [])
      |> Keyword.get(:github_credentials, [])

    token =
      Keyword.get(opts, :github_token) ||
        Keyword.get(config, :token) ||
        System.get_env("GITHUB_TOKEN")

    author_name =
      Keyword.get(opts, :author_name) ||
        Keyword.get(config, :author_name) ||
        System.get_env("GIT_AUTHOR_NAME") ||
        "Suite Runner"

    author_email =
      Keyword.get(opts, :author_email) ||
        Keyword.get(config, :author_email) ||
        System.get_env("GIT_AUTHOR_EMAIL") ||
        "runner@suite.local"

    if token do
      {:ok,
       %{
         token: token,
         author_name: author_name,
         author_email: author_email
       }}
    else
      {:error, :missing_github_token}
    end
  end

  defp resolve_credentials(:model, opts) do
    provider = Keyword.get(opts, :provider, :openai)

    config =
      :platform
      |> Application.get_env(:execution, [])
      |> Keyword.get(:model_credentials, [])

    api_key =
      Keyword.get(opts, :api_key) ||
        Keyword.get(config, provider) ||
        provider_env_key(provider)

    {:ok, %{provider: provider, api_key: api_key}}
  end

  defp resolve_credentials(:custom, opts) do
    credentials =
      opts
      |> Keyword.get(:credentials, %{})
      |> Enum.into(%{})

    {:ok, credentials}
  end

  defp resolve_credentials(kind, _opts) do
    {:error, {:unknown_credential_kind, kind}}
  end

  defp provider_env_key(:anthropic), do: System.get_env("ANTHROPIC_API_KEY")
  defp provider_env_key(:openai), do: System.get_env("OPENAI_API_KEY")
  defp provider_env_key(_), do: nil

  defp model_env_var(:anthropic), do: "ANTHROPIC_API_KEY"
  defp model_env_var(:openai), do: "OPENAI_API_KEY"
  defp model_env_var(provider), do: "#{String.upcase(to_string(provider))}_API_KEY"

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
