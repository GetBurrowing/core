defmodule Mix.Tasks.Platform.GenInstallIdentity do
  @moduledoc """
  Create this install's federation identity if it does not exist yet, and
  print its signing-key fingerprint (task 01a0d90f stage 2, ADR 0054).

  ## Usage

      mix platform.gen_install_identity

  Prints ONE line: the sha256 fingerprint of the current public key, which
  admins compare out of band when accepting a peer relationship. Unlike
  `mix platform.gen_vapid_keys`, it prints no private half: the private key
  is generated inside `Platform.Federation.Peers.InstallIdentity` and goes
  straight into `Platform.Vault`, so there is nothing for an operator to copy
  and nothing to land in shell history or a terminal scrollback.

  Idempotent: a second run prints the same fingerprint.
  """

  use Mix.Task

  alias Platform.Federation.Peers.InstallIdentity

  @shortdoc "Create the federation install identity and print its fingerprint"

  @requirements ["app.start"]

  @impl true
  def run(_args) do
    %{fingerprint: fingerprint} = InstallIdentity.ensure!()
    Mix.shell().info(fingerprint)
  end
end
