defmodule Platform.Tasks.DeployResolver do
  @moduledoc """
  Resolves deploy targets from project config and converts them into
  context items and runner environment variables.

  Deploy targets live in `project.deploy_config["deploy_targets"]` as a
  list of validated target maps (see `Platform.Tasks.DeployTarget`).

  ## Flow

  1. `resolve/2` — looks up a named target from a project's deploy config
  2. `to_context_items/1` — converts the target into key-value pairs for
     the ETS context plane
  3. `to_env/2` — converts the target (+ optional credential lease) into
     OS environment variables for the runner process
  4. `lease_for_target/3` — creates a `CredentialLease` pre-loaded with
     deploy target env vars
  """

  alias Platform.Execution.CredentialLease
  alias Platform.Tasks.{DeployTarget, Project}

  @doc """
  Resolves a named deploy target from the project's deploy config.

  Returns `{:ok, validated_target}` or `{:error, reason}`.
  """
  @spec resolve(Project.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resolve(%Project{deploy_config: deploy_config}, target_name) do
    targets = get_targets(deploy_config)

    case Enum.find(targets, &(&1["name"] == target_name)) do
      nil ->
        {:error, {:target_not_found, target_name}}

      target ->
        DeployTarget.validate(target)
    end
  end

  @doc """
  Converts a deploy target into context items for the ETS context plane.

  Returns a list of `{key, value}` tuples suitable for `Context.put_item/4`.

  ## Example

      iex> DeployResolver.to_context_items(%{"name" => "prod", "type" => "docker_compose", "config" => %{"host" => "x"}})
      [{"deploy.target.name", "prod"}, {"deploy.target.type", "docker_compose"}, {"deploy.target.config.host", "x"}]
  """
  @spec to_context_items(map()) :: [{String.t(), String.t()}]
  def to_context_items(%{"name" => name, "type" => type, "config" => config}) do
    base = [
      {"deploy.target.name", name},
      {"deploy.target.type", type}
    ]

    config_items =
      config
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> {"deploy.target.config.#{k}", encode_value(v)} end)

    base ++ config_items
  end

  @doc """
  Converts a deploy target (+ optional credential lease) into environment
  variables for the runner process.

  Produces `DEPLOY_*` prefixed variables. If a credential lease is provided,
  its env vars are merged in (lease vars take precedence for overlapping keys).
  """
  @spec to_env(map(), CredentialLease.t() | nil) :: %{String.t() => String.t()}
  def to_env(target, lease \\ nil)

  def to_env(%{"name" => name, "type" => type, "config" => config}, lease) do
    base = %{
      "DEPLOY_TARGET_NAME" => name,
      "DEPLOY_TARGET_TYPE" => type
    }

    config_env =
      config
      |> Enum.into(%{}, fn {k, v} ->
        env_key = "DEPLOY_#{String.upcase(to_string(k))}"
        {env_key, encode_value(v)}
      end)

    env = Map.merge(base, config_env)

    if lease do
      lease_env = CredentialLease.to_env(lease)
      Map.merge(env, lease_env)
    else
      env
    end
  end

  @doc """
  Creates a `CredentialLease` with `:custom` kind pre-loaded with deploy
  target environment variables.

  Options are forwarded to `CredentialLease.lease/2` (e.g. `:ttl`).
  """
  @spec lease_for_target(map(), String.t(), keyword()) ::
          {:ok, CredentialLease.t()} | {:error, term()}
  def lease_for_target(target, run_id, opts \\ []) do
    env = to_env(target)

    credentials =
      Enum.into(env, %{}, fn {k, v} -> {String.to_atom(k), v} end)

    CredentialLease.lease(
      :custom,
      Keyword.merge(opts, run_id: run_id, credentials: Map.to_list(credentials))
    )
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp get_targets(%{"deploy_targets" => targets}) when is_list(targets), do: targets
  defp get_targets(_), do: []

  defp encode_value(v) when is_binary(v), do: v
  defp encode_value(v) when is_boolean(v), do: to_string(v)
  defp encode_value(v) when is_number(v), do: to_string(v)
  defp encode_value(v), do: Jason.encode!(v)
end
