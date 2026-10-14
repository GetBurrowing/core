defmodule Mix.Tasks.Platform.PushRelayInstall do
  @moduledoc """
  Register or revoke an install allowed to use this install's push relay
  (task 01a1261e stage 2). Run on the RELAY install.

  ## Usage

      mix platform.push_relay_install --name "Acme" --host suite.acme.example
      mix platform.push_relay_install --revoke <install id>

  Registering prints the install id and its credential ONCE. Only the
  credential's SHA-256 is stored, so it cannot be shown again: set it on the
  registering install as `PUSH_RELAY_CREDENTIAL` (or the Vault slug
  `push-relay-credential`) together with `PUSH_RELAY_URL`. Revoking makes
  the credential a 401 at once.
  """

  use Mix.Task

  alias Platform.Push.RelayServer

  @shortdoc "Register or revoke a push relay install"

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [name: :string, host: :string, revoke: :string])

    Mix.Task.run("app.start")

    case opts do
      [revoke: id] -> revoke(id)
      _ -> register(opts[:name], opts[:host])
    end
  end

  defp register(name, host) when is_binary(name) and is_binary(host) do
    case RelayServer.create_install(name, host) do
      {:ok, install, credential} ->
        Mix.shell().info("""

        Push relay install registered
        =============================

        id:   #{install.id}
        name: #{install.name}
        host: #{install.host}

        PUSH_RELAY_CREDENTIAL=#{credential}

        Shown once; only its hash is stored. Set it on #{install.host}
        with PUSH_RELAY_URL pointing at this install.
        """)

      {:error, changeset} ->
        Mix.raise("could not register: #{inspect(Keyword.keys(changeset.errors))}")
    end
  end

  defp register(_name, _host),
    do: Mix.raise("usage: mix platform.push_relay_install --name <name> --host <host>")

  defp revoke(id) do
    case RelayServer.revoke_install(id) do
      {:ok, install} -> Mix.shell().info("revoked #{install.id} (#{install.host})")
      {:error, :not_found} -> Mix.raise("no push relay install #{id}")
    end
  end
end
