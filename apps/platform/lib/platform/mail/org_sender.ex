defmodule Platform.Mail.OrgSender do
  @moduledoc """
  Which `(account, sender key)` an org's system mail goes out under (task
  01a1a933 stage 1).

  The booking confirmation (`Platform.Calendar.BookingConfirmation`), the
  cancellation notice (`Platform.Meetings.CancellationMail`) and the meeting
  invite email all need a sender the system may use for an org. Before this
  module each read a deploy-time app-env map inline; a hosted install has no
  such map, so none of them could send. `resolve/2` is now the one place
  that answers, in this order:

    1. `Platform.Mail.Config.enabled?/0` false -> `{:skip, :mail_disabled}`.
    2. An explicit app-env entry for the org in
       `config :platform, :calendar_booking_mail_senders, %{org_id =>
       %{account_id: uuid, sender_key: key}}` wins. Kept for back-compat
       and read here only.
    3. Otherwise the org's non-archived, `send_enabled` accounts
       (`Platform.Mail.list_accounts/1`) that carry a sender with the
       well-known key `meetings_sender_key/0`. Exactly one such account wins;
       none is `{:skip, :no_sender}`; more than one is
       `{:skip, :ambiguous_sender}`.

  An admin opts an org in from the Email module: add a sender with key
  `"meetings"` to the account the org's meeting mail should come from.

  It never falls back to the org's first account or an account's first
  sender, and never invents a platform address: a sender is either named
  for this purpose or there is none. `Platform.Mail.Dispatch` still applies
  the account's policy (send toggle, internal-only, rate limit) to every
  draft queued under the result.
  """

  alias Platform.Mail
  alias Platform.Mail.Account
  alias Platform.Mail.Config
  alias Platform.Mail.Sender

  @meetings_sender_key "meetings"
  @purposes [:meetings]
  @app_env_key :calendar_booking_mail_senders

  @type purpose :: :meetings
  @type sender :: %{account_id: binary(), sender_key: String.t()}
  @type skip_reason :: :mail_disabled | :no_sender | :ambiguous_sender | :no_org

  @doc "The sender key an admin adds to an account to make it the org's meeting sender."
  @spec meetings_sender_key() :: String.t()
  def meetings_sender_key, do: @meetings_sender_key

  @doc """
  Resolve the sender the system uses for `org_id`'s `purpose` mail.

  Returns `{:ok, %{account_id: uuid, sender_key: key}}` or `{:skip, reason}`
  with `reason` one of `:mail_disabled`, `:no_sender`, `:ambiguous_sender`
  or `:no_org` (no org id given).
  """
  @spec resolve(binary() | nil, purpose()) :: {:ok, sender()} | {:skip, skip_reason()}
  def resolve(org_id, purpose) when purpose in @purposes do
    cond do
      not Config.enabled?() -> {:skip, :mail_disabled}
      not is_binary(org_id) -> {:skip, :no_org}
      true -> configured(org_id) || discovered(org_id, purpose)
    end
  end

  defp configured(org_id) do
    case Application.get_env(:platform, @app_env_key, %{}) do
      %{^org_id => %{account_id: account_id, sender_key: sender_key}} ->
        {:ok, %{account_id: account_id, sender_key: sender_key}}

      _ ->
        nil
    end
  end

  defp discovered(org_id, :meetings) do
    matches =
      for %Account{send_enabled: true} = account <- Mail.list_accounts(org_id),
          %Sender{key: @meetings_sender_key} <- account.senders,
          do: account.id

    case matches do
      [account_id] -> {:ok, %{account_id: account_id, sender_key: @meetings_sender_key}}
      [] -> {:skip, :no_sender}
      [_ | _] -> {:skip, :ambiguous_sender}
    end
  end
end
