defmodule Platform.Vault.Encryption do
  @moduledoc """
  Cloak Vault for application-level field encryption.

  Configured at runtime via the VAULT_MASTER_KEY environment variable.
  In production, VAULT_MASTER_KEY must be set. In dev/test, a random key
  is generated automatically if the variable is not set.
  """

  use Cloak.Vault, otp_app: :platform
end
