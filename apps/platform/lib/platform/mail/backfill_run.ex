defmodule Platform.Mail.BackfillRun do
  @moduledoc """
  One admin-triggered backfill of one mail account (task
  01a13ba5-42a7-7000-8f2b-4c63003f3f92 stage 1).

  Inserted `running` by `Platform.Mail.start_backfill/4`, advanced by
  `Platform.Mail.Inbound.Backfill`, and read by `Platform.Mail.latest_backfill/2`.
  The row, not any process state, is the record of progress, so a reload or
  a second device sees the same run.

    * `total` — UIDs selected for import so far (grows folder by folder, so
      the UI shows it as an approximation while running);
    * `imported` — rows the run actually wrote;
    * `already_present` — selected messages that were already stored (by the
      live poller or an earlier run); a re-run reads "0 new, N already here";
    * `folders` — folders the run read;
    * `skipped_folders` — `"<folder> (<reason>)"` for each folder it did not
      read: `all-mail` (a `\\All` folder), `not-yet-polled` (no cursor),
      `uidvalidity-changed`, `examine-failed`.

  At most one `running` row per account (partial unique index
  `mail_backfill_runs_one_running_per_account`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(running done failed)

  @type t :: %__MODULE__{}

  schema "mail_backfill_runs" do
    belongs_to(:account, Platform.Mail.Account)
    belongs_to(:org, Platform.Tenancy.Org)
    field(:requested_by_user_id, :binary_id)
    field(:window_days, :integer)
    field(:since_date, :date)
    field(:status, :string, default: "running")
    field(:total, :integer, default: 0)
    field(:imported, :integer, default: 0)
    field(:already_present, :integer, default: 0)
    field(:folders, {:array, :string}, default: [])
    field(:skipped_folders, {:array, :string}, default: [])
    field(:error, :string)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)

    timestamps()
  end

  @doc "The statuses a run can be in."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc false
  def start_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :account_id,
      :org_id,
      :requested_by_user_id,
      :window_days,
      :since_date,
      :started_at
    ])
    |> validate_required([:account_id, :org_id, :window_days, :since_date, :started_at])
    |> put_change(:status, "running")
    |> unique_constraint(:account_id, name: :mail_backfill_runs_one_running_per_account)
  end

  @doc false
  def progress_changeset(%__MODULE__{} = run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :total,
      :imported,
      :already_present,
      :folders,
      :skipped_folders,
      :error,
      :finished_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> force_change(:updated_at, DateTime.utc_now())
  end
end
