defmodule Platform.Installs.Render do
  @moduledoc """
  Renders an install's cloud-init (task 01a10315 stage 2).

  A behaviour, so tests and dev stub mode replace it
  (`config :platform, Platform.Installs, render: Module`). The real one is
  `Platform.Installs.Render.Python`; `manifest/2` builds the manifest TOML it
  renders and is pure.
  """

  alias Platform.Installs.Install

  @type result :: %{user_data: String.t(), secrets: %{String.t() => String.t()}}

  @doc """
  Render `install` with `ssh_public_key` in its manifest. `secrets` holds
  exactly the two values core keeps for the hand-over and the bootstrap:
  `STATIC_API_KEY` and `OIDC_CLIENT_SECRET`.
  """
  @callback render(Install.t(), ssh_public_key :: String.t()) ::
              {:ok, result()} | {:error, term()}

  @doc "The configured implementation."
  def impl,
    do: Keyword.get(Application.get_env(:platform, Platform.Installs, []), :render, __MODULE__.Python)

  @doc "The registry the images are pulled from (`images.registry`)."
  def image_registry,
    do:
      Keyword.get(
        Application.get_env(:platform, Platform.Installs, []),
        :image_registry,
        "ghcr.io/getburrowing"
      )

  @doc """
  The install manifest (schema v1, `deployment/schema/install-manifest.md`).

  Strings are written as JSON strings, which are valid TOML basic strings.
  The business name was already checked against the renderer's
  `install.org_name` rule by `Platform.Installs.create/2`.
  """
  @spec manifest(Install.t(), String.t()) :: String.t()
  def manifest(%Install{} = install, ssh_public_key) do
    q = &Jason.encode!/1

    """
    # Rendered by Platform.Installs for install #{install.id}.
    schema_version = 1

    [install]
    name = #{q.(install.slug)}
    size_tier = "medium"
    hosted = true
    org_name = #{q.(install.business_name)}

    [domain]
    primary = #{q.(install.primary_host)}
    tls = "acme"
    acme_email = #{q.(install.owner_email)}

    [host]
    ssh_authorized_key = #{q.(ssh_public_key)}

    [services]
    files = true
    memory = true
    embeddings = true
    voice = false

    [auth]
    mode = "bundled-pocket-id"

    [images]
    registry = #{q.(image_registry())}
    source = "registry"

    [agents]
    profile = "full_machine"

    [push]
    vapid = "generate-on-host"
    """
  end
end

defmodule Platform.Installs.Render.Python do
  @moduledoc """
  The real renderer: `python3 -m burrow_install render <manifest> --out <dir>
  --registry-auth <file>` in a private temp dir (`Platform.Installs.Python`).

  `images.source = "registry"` pulls private images, so the render needs a
  docker `config.json`: the shared vault slug `install-registry-pull-auth`.
  The droplet's root (the customer) can read it at `/root/.docker/config.json`,
  so it must be a read-only pull token. A missing slug is
  `{:error, :registry_auth_missing}`.

  Of the rendered files only `user-data` and two values of `secrets.env`
  (`STATIC_API_KEY`, `OIDC_CLIENT_SECRET`) are read; the directory is removed
  in an `after` block.
  """

  @behaviour Platform.Installs.Render

  alias Platform.Installs.Python
  alias Platform.Installs.Render

  @registry_auth_slug "install-registry-pull-auth"
  @accessor {:system, "installs-provisioner"}
  @kept ~w(STATIC_API_KEY OIDC_CLIENT_SECRET)

  @impl true
  def render(install, ssh_public_key) do
    with {:ok, auth} <- registry_auth() do
      Python.with_private_dir(fn dir ->
        manifest = Path.join(dir, "install.toml")
        auth_file = Path.join(dir, "registry-auth.json")
        out = Path.join(dir, "out")
        File.write!(manifest, Render.manifest(install, ssh_public_key))
        Python.write_private!(auth_file, auth)

        case Python.run(["render", manifest, "--out", out, "--registry-auth", auth_file]) do
          {:error, _} = error -> error
          {_output, 0} -> read_render(out)
          # The CLI prints error lines and file NAMES, never a value.
          {output, _status} -> {:error, {:render_failed, first_line(output)}}
        end
      end)
    end
  end

  defp registry_auth do
    case Platform.Vault.get(@registry_auth_slug, accessor: @accessor) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:error, :not_found} -> {:error, :registry_auth_missing}
      {:ok, _} -> {:error, :registry_auth_missing}
      {:error, reason} -> {:error, {:registry_auth, reason}}
    end
  end

  @doc false
  def read_render(out) do
    with {:ok, user_data} <- File.read(Path.join(out, "user-data")),
         {:ok, env} <- File.read(Path.join(out, "secrets.env")) do
      secrets =
        env
        |> String.split("\n")
        |> Enum.flat_map(fn line ->
          case String.split(line, "=", parts: 2) do
            [name, value] when name in @kept -> [{name, value}]
            _ -> []
          end
        end)
        |> Map.new()

      if Map.keys(secrets) |> Enum.sort() == Enum.sort(@kept) do
        {:ok, %{user_data: user_data, secrets: secrets}}
      else
        {:error, :render_incomplete}
      end
    else
      {:error, _} -> {:error, :render_incomplete}
    end
  end

  defp first_line(output), do: output |> String.split("\n", parts: 2) |> hd()
end
