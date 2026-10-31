defmodule Platform.Installs.Bootstrap do
  @moduledoc """
  Creates (or finds) an install's first pocket-id admin and mints a fresh
  one-time sign-in link (task 01a10315 stage 2).

  A behaviour, so tests and dev stub mode replace it
  (`config :platform, Platform.Installs, bootstrap: Module`). The real one,
  `Platform.Installs.Bootstrap.Python`, runs stage 1's
  `python3 -m burrow_install bootstrap-admin`.

  The link is a credential until used or expired (30 minutes): it is
  returned to the caller and never logged, stored or broadcast.
  """

  alias Platform.Installs.Install

  @doc """
  `secrets` carries `STATIC_API_KEY` (always) and `OIDC_CLIENT_SECRET` (when
  core's OIDC client should be registered too).
  """
  @callback admin_link(Install.t(), auth_host :: String.t(), secrets :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "The configured implementation."
  def impl,
    do:
      Keyword.get(
        Application.get_env(:platform, Platform.Installs, []),
        :bootstrap,
        __MODULE__.Python
      )
end

defmodule Platform.Installs.Bootstrap.Python do
  @moduledoc """
  `python3 -m burrow_install bootstrap-admin` against `https://<auth host>`.
  The API key, the OIDC client secret and the link travel only as 0600 files
  in a private temp dir (`Platform.Installs.Python`); stdout is one JSON
  document that names no credential.
  """

  @behaviour Platform.Installs.Bootstrap

  alias Platform.Installs.Python

  @impl true
  def admin_link(install, auth_host, secrets) do
    Python.with_private_dir(fn dir ->
      key_file = Path.join(dir, "api-key")
      link_file = Path.join(dir, "login-link")
      Python.write_private!(key_file, Map.fetch!(secrets, "STATIC_API_KEY"))

      secret_file =
        case Map.get(secrets, "OIDC_CLIENT_SECRET") do
          nil ->
            nil

          secret ->
            secret_file = Path.join(dir, "oidc-secret")
            Python.write_private!(secret_file, secret)
            secret_file
        end

      args = args(install, auth_host, key_file, link_file, secret_file)

      case Python.run(args) do
        {:error, _} = error -> error
        {_out, 0} -> read_link(link_file)
        {out, _status} -> {:error, classify(out)}
      end
    end)
  end

  @doc """
  The CLI's arguments. `--primary` always (stage 6 round 2): the link is then
  core's `https://<primary>/auth/handover?code=...`, which lands the owner in
  Burrow at `/setup/connect-ai`. `--oidc-secret-file` only with a secret
  (the `final` step registers core's OIDC client; a reveal only re-mints).
  """
  def args(install, auth_host, key_file, link_file, secret_file) do
    oidc = if secret_file, do: ["--oidc-secret-file", secret_file], else: []

    [
      "bootstrap-admin",
      "--base",
      "https://#{auth_host}",
      "--api-key-file",
      key_file,
      "--email",
      install.owner_email,
      "--link-file",
      link_file,
      "--primary",
      install.primary_host
    ] ++ oidc
  end

  defp read_link(path) do
    case File.read(path) do
      {:ok, link} -> {:ok, String.trim(link)}
      {:error, _} -> {:error, :bootstrap_no_link}
    end
  end

  # The JSON names a code and a kind, never a credential.
  defp classify(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.find_value({:bootstrap_failed, :unparsed}, fn line ->
      case Jason.decode(line) do
        {:ok, %{"ok" => false, "error" => code, "kind" => kind}} ->
          {:bootstrap_failed, "#{code}:#{kind}"}

        _ ->
          nil
      end
    end)
  end
end
