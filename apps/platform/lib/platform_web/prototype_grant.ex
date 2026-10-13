defmodule PlatformWeb.PrototypeGrant do
  @moduledoc """
  The per-request capability for a prototype bundle (ADR 0057 Decision 1).

  A sandboxed bundle document has an opaque origin, so every request it makes
  (its own `./app.js`, an in-frame link to `./b.html`) is cross-site for
  `SameSite=Lax` and carries no session cookie. Measured in the stage-1
  spike (headless Chrome 147): the framing navigation carries the cookie,
  and every subresource and in-frame navigation after it carries none. So
  the entry request, which DOES carry the session, mints this grant after
  its membership check, and every later request presents it in the path.

  The token is a `Phoenix.Token` bound to user, prototype and version, valid
  for `max_age/0` seconds. Verification checks all three bindings; the
  controller re-runs the membership check for the user on every request.

  HONEST LIMIT: it is a bearer capability. Anyone holding a live grant URL
  can read that ONE version until it expires or the minting user leaves the
  org; the server cannot tell who is presenting it.
  """

  @salt "prototype grant v1"
  # One hour. Long enough for a review session in one tab, short enough that
  # a URL pasted into a chat stops working the same afternoon.
  @max_age 3600

  @doc "Seconds a grant stays valid."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc """
  Mint a grant. `opts` are passed to `Phoenix.Token.sign/4` (tests use
  `:signed_at` to mint an expired one).
  """
  @spec sign(binary(), binary(), integer(), keyword()) :: String.t()
  def sign(user_id, prototype_id, version, opts \\ []) do
    Phoenix.Token.sign(
      PlatformWeb.Endpoint,
      @salt,
      %{"u" => user_id, "p" => prototype_id, "v" => version},
      opts
    )
  end

  @doc """
  The user id a grant was minted for, if it is unexpired AND bound to exactly
  this prototype and version; otherwise `:error`.
  """
  @spec verify(String.t(), binary(), integer()) :: {:ok, binary()} | :error
  def verify(token, prototype_id, version) when is_binary(token) do
    case Phoenix.Token.verify(PlatformWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{"u" => user_id, "p" => ^prototype_id, "v" => ^version}} when is_binary(user_id) ->
        {:ok, user_id}

      _ ->
        :error
    end
  end

  def verify(_token, _prototype_id, _version), do: :error
end
