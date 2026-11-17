defmodule Platform.SignIn.DurableLink do
  @moduledoc """
  The long-lived sign-in link a new install's "ready" email (and an invite
  email) carries: `<primary host>/auth/link?token=<token>`.

  pocket-id's one-time code lives 30 minutes (`Platform.SignInAdmin.PocketId`),
  far too short for an email that is opened hours or days later. The link
  therefore carries a signed token instead, and
  `PlatformWeb.AuthController.link/2` turns it into a FRESH one-time code on
  every click, then runs the same OIDC hand-over as `/auth/handover`. The
  code is never stored or emailed; only the token is.

  ## Security model

  The link is MULTI-USE and the holder's email inbox is the credential, the
  same trade Slack and Notion magic links make: anyone who can read the
  email can sign in as that person until the token expires. Two things end
  it early or on time:

    * `max_age/0` (14 days) after signing, enforced by `Phoenix.Token`.
    * The user being archived. `Platform.SignInAdmin.disable/2` archives the
      Burrow user (reason "sign-in disabled"), so one `archived_at` check
      covers both "archived" and "disabled" and needs no pocket-id call. A
      user with no `oidc_sub` cannot be signed in either.

  The token is signed, not encrypted: it carries the user id and the purpose
  (`:handover` for an install owner, `:invite` for an invited member), which
  are not secrets. It is bound to `PlatformWeb.Endpoint`'s `secret_key_base`,
  so rotating that key revokes every outstanding link.
  """

  alias Platform.Accounts

  @salt "durable sign-in link v1"

  # 14 days: long enough for a person who was away from their desk (leave,
  # a long weekend, a slow hand-off of the invite), short enough that a stale
  # inbox is not a permanent key.
  @max_age 14 * 24 * 60 * 60

  @purposes [:handover, :invite]

  @type purpose :: :handover | :invite

  @doc "Seconds a link stays valid."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc """
  The absolute link for `user`, on the install's primary host. `opts` are
  passed to `Phoenix.Token.sign/4` (tests use `:signed_at` to mint an
  expired one).
  """
  @spec url(Accounts.User.t(), purpose(), keyword()) :: String.t()
  def url(%{id: user_id}, purpose, opts \\ []) when purpose in @purposes do
    token =
      Phoenix.Token.sign(
        PlatformWeb.Endpoint,
        @salt,
        %{"u" => user_id, "p" => Atom.to_string(purpose)},
        opts
      )

    PlatformWeb.Endpoint.url() <> "/auth/link?" <> URI.encode_query(%{"token" => token})
  end

  @doc """
  Check `token` and the user it names.

  Returns `{:ok, %{user_id: id, purpose: purpose, user: user}}`, or
  `{:error, reason}` where reason is `:invalid` (malformed or tampered),
  `:expired`, `:not_found`, `:archived` (archived or sign-in disabled) or
  `:no_identity` (no pocket-id identity to sign in with).
  """
  @spec verify(term()) :: {:ok, map()} | {:error, atom()}
  def verify(token) when is_binary(token) do
    with {:ok, %{"u" => user_id, "p" => purpose}} <-
           Phoenix.Token.verify(PlatformWeb.Endpoint, @salt, token, max_age: @max_age),
         {:ok, purpose} <- parse_purpose(purpose),
         {:ok, user} <- load_user(user_id) do
      {:ok, %{user_id: user.id, purpose: purpose, user: user}}
    else
      {:error, reason} when reason in [:expired, :invalid] -> {:error, reason}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :invalid}

  defp parse_purpose(purpose) do
    case Enum.find(@purposes, &(Atom.to_string(&1) == purpose)) do
      nil -> {:error, :invalid}
      found -> {:ok, found}
    end
  end

  defp load_user(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :not_found}
      %{archived_at: %DateTime{}} -> {:error, :archived}
      %{oidc_sub: sub} when not is_binary(sub) or sub == "" -> {:error, :no_identity}
      user -> {:ok, user}
    end
  end
end
