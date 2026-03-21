defmodule Platform.Tasks.DeployTarget do
  @moduledoc """
  Validates and normalizes deploy target configuration maps.

  A deploy target represents a deployment destination stored in a project's
  `deploy_config.deploy_targets` list. Each target has a name, type, and
  type-specific config map.

  ## Supported types

    * `"docker_compose"` — Docker Compose stack on a remote host
    * `"fly"` — Fly.io application
    * `"k8s"` — Kubernetes cluster
    * `"static"` — Static file hosting (S3, Cloudflare Pages, etc.)

  Unknown types are allowed and pass through validation with no required
  config keys, enabling extensibility without code changes.
  """

  @type t :: %{String.t() => term()}

  @known_types ~w(docker_compose fly k8s static)

  @required_config %{
    "docker_compose" => ~w(host stack_path),
    "fly" => ~w(app),
    "k8s" => ~w(cluster namespace),
    "static" => ~w(bucket)
  }

  @doc """
  Validates a deploy target map.

  Returns `{:ok, target}` with the target normalized (string keys, config
  defaults applied) or `{:error, reason}`.

  ## Examples

      iex> DeployTarget.validate(%{"name" => "prod", "type" => "fly", "config" => %{"app" => "my-app"}})
      {:ok, %{"name" => "prod", "type" => "fly", "config" => %{"app" => "my-app"}}}

      iex> DeployTarget.validate(%{"name" => "prod", "type" => "fly", "config" => %{}})
      {:error, {:missing_config_keys, ["app"]}}
  """
  @spec validate(map()) :: {:ok, t()} | {:error, term()}
  def validate(target) when is_map(target) do
    target = normalize_keys(target)

    with :ok <- check_required_fields(target),
         :ok <- check_config_keys(target) do
      {:ok, target}
    end
  end

  def validate(_), do: {:error, :invalid_target}

  @doc """
  Validates a deploy target, raising on failure.
  """
  @spec validate!(map()) :: t()
  def validate!(target) do
    case validate(target) do
      {:ok, t} -> t
      {:error, reason} -> raise ArgumentError, "invalid deploy target: #{inspect(reason)}"
    end
  end

  @doc "Returns the list of known deploy target type strings."
  @spec known_types() :: [String.t()]
  def known_types, do: @known_types

  # ── Private ───────────────────────────────────────────────────────────────

  defp normalize_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp check_required_fields(target) do
    missing =
      ~w(name type config)
      |> Enum.reject(&Map.has_key?(target, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_fields, keys}}
    end
  end

  defp check_config_keys(%{"type" => type, "config" => config}) when is_map(config) do
    required = Map.get(@required_config, type, [])

    missing =
      required
      |> Enum.reject(&Map.has_key?(config, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_config_keys, keys}}
    end
  end

  defp check_config_keys(%{"config" => _}), do: {:error, :config_must_be_map}
  defp check_config_keys(_), do: {:error, {:missing_fields, ["config"]}}
end
