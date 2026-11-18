defmodule Platform.Mail.Account do
  @moduledoc """
  An org-scoped mail account (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6).

  Holds relay and mailbox settings plus the policy toggles the send and read
  paths enforce. **There is no secret field.** Passwords live in the Vault at
  scope `{:integration, account.id}`; `smtp_secret_slug` / `imap_secret_slug`
  only name the credential. See `Platform.Mail`.

  Defaults fail closed: `internal_only` is true and `read_enabled` is false.
  An empty `read_folders` list means "all folders except Sent, Drafts, Trash,
  Junk/Spam and All Mail" (plus Starred/`\\Flagged` and `\\Archive`) once
  reading is on; see `Platform.Mail.Inbound.select_folders/2`.

  ## Well-known ports pin the tls mode

  A port whose protocol is fixed refuses the mismatched mode, with the error
  on the tls field: SMTP 465 is implicit TLS (not `"starttls"`) and 587 is
  STARTTLS (not `"tls"`); IMAP 993 is implicit TLS (only `"tls"`) and 143 is
  never `"tls"`. Every other port is unconstrained. Measured cause (a production
  install, 2026-09-24): smtp.gmail.com:465 with `"starttls"` failed every delivery
  with `{:network_failure, ..., {:error, :closed}}`. The check reads the
  merged fields, so an existing row with a bad pairing fails on its next edit.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @tls_modes ~w(tls starttls none)

  @owner_kinds ~w(unassigned personal shared)

  @type t :: %__MODULE__{}

  schema "mail_accounts" do
    belongs_to(:org, Platform.Tenancy.Org)
    field(:name, :string)

    field(:smtp_host, :string)
    field(:smtp_port, :integer)
    field(:smtp_tls, :string, default: "starttls")
    field(:username, :string)

    field(:imap_host, :string)
    field(:imap_port, :integer)
    field(:imap_tls, :string)

    field(:send_enabled, :boolean, default: true)
    field(:internal_only, :boolean, default: true)
    field(:read_enabled, :boolean, default: false)
    field(:read_folders, {:array, :string}, default: [])

    belongs_to(:inbound_space, Platform.Chat.Space)

    field(:rate_limit_per_hour, :integer, default: 60)
    field(:smtp_secret_slug, :string)
    field(:imap_secret_slug, :string)
    field(:archived_at, :utc_datetime_usec)

    # Mailbox ownership (task 01a1ea5b stage 1). Set ONLY through
    # `Platform.Mail.Ownership.set_owner/3` (audited, admin only), never cast
    # by `changeset/2`. `"unassigned"` is readable by nobody.
    field(:owner_kind, :string, default: "unassigned")
    belongs_to(:owner_user, Platform.Accounts.User)
    field(:digest_opt_in, :boolean, default: false)

    has_many(:senders, Platform.Mail.Sender)

    timestamps()
  end

  @editable ~w(name smtp_host smtp_port smtp_tls username imap_host imap_port imap_tls
               send_enabled internal_only read_enabled read_folders inbound_space_id
               rate_limit_per_hour)a

  @doc "Accepted `owner_kind` values."
  @spec owner_kinds() :: [String.t()]
  def owner_kinds, do: @owner_kinds

  @doc """
  Changeset for the ownership fields, used ONLY by
  `Platform.Mail.Ownership.set_owner/3` and `set_digest_opt_in/3`. `owner_user_id` is set iff the kind
  is `"personal"` (the DB check `mail_accounts_owner_user_iff_personal` holds
  the same rule).
  """
  @spec ownership_changeset(t(), map()) :: Ecto.Changeset.t()
  def ownership_changeset(%__MODULE__{} = account, attrs) do
    account
    |> cast(attrs, [:owner_kind, :owner_user_id, :digest_opt_in])
    |> validate_required([:owner_kind])
    |> validate_inclusion(:owner_kind, @owner_kinds)
    |> check_constraint(:owner_kind, name: :mail_accounts_owner_kind_check)
    |> check_constraint(:owner_user_id, name: :mail_accounts_owner_user_iff_personal)
    |> foreign_key_constraint(:owner_user_id)
  end

  @doc "Tls modes accepted for `smtp_tls` and `imap_tls`."
  @spec tls_modes() :: [String.t()]
  def tls_modes, do: @tls_modes

  @doc """
  Changeset for the admin-editable fields. `org_id`, the secret slugs and
  `archived_at` are set by `Platform.Mail`, never cast from attrs. The
  ownership fields (`owner_kind`, `owner_user_id`, `digest_opt_in`) are not
  cast here either: they change only through `Platform.Mail.Ownership`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = account, attrs) do
    account
    |> cast(attrs, @editable)
    |> validate_required([:name, :smtp_tls])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:smtp_tls, @tls_modes)
    |> validate_inclusion(:imap_tls, @tls_modes)
    |> validate_number(:smtp_port, greater_than: 0, less_than: 65_536)
    |> validate_number(:imap_port, greater_than: 0, less_than: 65_536)
    |> validate_number(:rate_limit_per_hour, greater_than: 0)
    |> validate_port_tls()
    |> unique_constraint([:org_id, :name])
    |> check_constraint(:smtp_tls, name: :mail_accounts_smtp_tls_check)
    |> check_constraint(:imap_tls, name: :mail_accounts_imap_tls_check)
    |> check_constraint(:rate_limit_per_hour, name: :mail_accounts_rate_limit_positive)
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:inbound_space_id)
  end

  @smtp_pairing "must match the port: port 465 uses tls; port 587 uses starttls"
  @imap_pairing "must match the port: port 993 uses tls; port 143 uses starttls or none"

  defp validate_port_tls(changeset) do
    smtp = {get_field(changeset, :smtp_port), get_field(changeset, :smtp_tls)}
    imap = {get_field(changeset, :imap_port), get_field(changeset, :imap_tls)}

    changeset
    |> then(&if(smtp_mismatch?(smtp), do: add_error(&1, :smtp_tls, @smtp_pairing), else: &1))
    |> then(&if(imap_mismatch?(imap), do: add_error(&1, :imap_tls, @imap_pairing), else: &1))
  end

  defp smtp_mismatch?({465, "starttls"}), do: true
  defp smtp_mismatch?({587, "tls"}), do: true
  defp smtp_mismatch?(_), do: false

  defp imap_mismatch?({993, tls}), do: tls != "tls"
  defp imap_mismatch?({143, "tls"}), do: true
  defp imap_mismatch?(_), do: false
end
