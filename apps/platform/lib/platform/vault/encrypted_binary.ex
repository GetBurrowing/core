defmodule Platform.Vault.EncryptedBinary do
  @moduledoc """
  Ecto type for transparently encrypting and decrypting binary fields.

  Usage in schemas:

      field :secret_value, Platform.Vault.EncryptedBinary

  Values are encrypted with AES-GCM via `Platform.Vault.Encryption` before
  being written to the database, and decrypted transparently on read.
  """

  use Cloak.Ecto.Binary, vault: Platform.Vault.Encryption
end
