defmodule Platform.Mail.Imap.Client do
  @moduledoc """
  The seam between the IMAP poller and an IMAP library (task
  01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 3).

  The poller (`Platform.Mail.Inbound`) only ever calls these six functions, and
  none of them can change a mailbox: there is no select, store, copy, move,
  expunge or delete here. `examine/2` is IMAP EXAMINE (read-only select) and
  `fetch_raw/2` must fetch with `BODY.PEEK[]` so `\\Seen` is never set.

  Implementations: `Platform.Mail.Imap.WireClient` (production) and
  `Platform.Mail.Imap.FakeClient` (test/support, in memory). The module in
  use is `config :platform, Platform.Mail.Inbound, client: ...`.
  """

  @type conn :: term()
  @type folder :: String.t()
  @type connect_params :: %{
          required(:host) => String.t(),
          required(:port) => pos_integer() | nil,
          required(:tls) => String.t() | nil,
          required(:username) => String.t() | nil,
          required(:password) => String.t()
        }

  @doc "Open and authenticate a connection."
  @callback connect(connect_params()) :: {:ok, conn()} | {:error, term()}

  @doc "IMAP LIST: every folder with its flags (e.g. `\"\\\\Noselect\"`)."
  @callback list_folders(conn()) :: {:ok, [{folder(), [String.t()]}]} | {:error, term()}

  @doc """
  IMAP EXAMINE `folder` read-only. Returns its UIDVALIDITY and the highest UID
  that currently exists (0 for an empty folder).
  """
  @callback examine(conn(), folder()) ::
              {:ok, uidvalidity :: non_neg_integer(), max_uid :: non_neg_integer()}
              | {:error, term()}

  @doc "UIDs strictly greater than `uid` in the examined folder, ascending."
  @callback uids_after(conn(), non_neg_integer()) :: {:ok, [pos_integer()]} | {:error, term()}

  @doc "The raw RFC 5322 bytes of message `uid`, fetched without setting \\\\Seen."
  @callback fetch_raw(conn(), pos_integer()) :: {:ok, binary()} | {:error, term()}

  @doc "Close the connection. Always safe to call."
  @callback logout(conn()) :: :ok
end
