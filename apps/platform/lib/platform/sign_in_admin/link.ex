defmodule Platform.SignInAdmin.Link do
  @moduledoc """
  A one-time sign-in link minted for a user by `Platform.SignInAdmin`.

  `url` and `code` are credentials: anyone holding either can sign in as the
  user until `expires_at`. `inspect/1` therefore prints neither, which keeps
  them out of LiveView crash reports (those print socket assigns), logs and
  `IO.inspect` output. Read the fields directly where the link is shown.
  """
  @enforce_keys [:url, :code, :expires_at]
  defstruct [:url, :code, :expires_at]

  @type t :: %__MODULE__{url: String.t(), code: String.t(), expires_at: DateTime.t()}

  defimpl Inspect do
    def inspect(%{expires_at: expires_at}, _opts),
      do: "#SignInAdmin.Link<url: redacted, code: redacted, expires_at: #{expires_at}>"
  end
end
