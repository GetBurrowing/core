defmodule Platform.Mobile.PushPublicKey do
  @moduledoc """
  The one validation of a device's `push_public_key` (task 01a1261e), shared
  by `Platform.Mobile.ApnsDevice` and `Platform.Mobile.FcmDevice` so the two
  device tables cannot disagree about what a key is.

  A key is optional (nil or absent passes: a build that sends none registers
  as before). When present it must be base64url without padding decoding to
  exactly 32 bytes, an X25519 public key (`Platform.Push.Seal.valid_public_key?/1`).
  The error message never echoes the value.
  """

  import Ecto.Changeset

  @doc "Validate `:push_public_key` on `changeset`."
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(%Ecto.Changeset{} = changeset) do
    validate_change(changeset, :push_public_key, fn :push_public_key, value ->
      if Platform.Push.Seal.valid_public_key?(value),
        do: [],
        else: [push_public_key: "must be a base64url X25519 public key"]
    end)
  end
end
