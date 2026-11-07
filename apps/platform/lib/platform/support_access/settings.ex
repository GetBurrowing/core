defmodule Platform.SupportAccess.Settings do
  @moduledoc """
  The `install_support_access_settings` singleton (task 01a1b362 stage 1,
  ADR 0059): the install owner's switch for vendor support access. The
  `Platform.Chat.LinkUnfurls.Settings` shape: one row, enforced by a DB CHECK
  and a unique index, seeded by the migration, read fresh with `get/0`.

  ## Default

  The migration seeds `enabled` from the env `SUPPORT_ACCESS_DEFAULT`:
  exactly `on` seeds true, anything else (or nothing) seeds false. Nothing in
  code defaults it on.

  ## Off means off

  `update/2` turning the switch off, in ONE transaction: writes the row,
  writes `support.access_changed`, and ends every active support session
  (`Platform.SupportAccess.end_all_in_transaction/2`, reason
  `access_turned_off`). After the commit, and before `update/2` returns, it
  disconnects the ended sessions' sockets and rewrites the host state file.
  A state file write failure does not undo the toggle: it is recorded on the
  row (`state_file_error`) for the owner's Support card and the sweeper
  retries every tick.

  `update/2` re-checks `Platform.Access.authorize_install/1`, because a route
  gate is not an authorization boundary for a context function. A vendor
  support user is refused even while it holds install admin: the switch is
  the owner's.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.SupportAccess

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "install_support_access_settings" do
    field(:singleton, :boolean, default: true)
    field(:enabled, :boolean, default: false)
    belongs_to(:updated_by_user, User)
    field(:state_file_error, :string)
    field(:state_file_written_at, :utc_datetime_usec)
    field(:shell_events_offset, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The singleton row, read fresh."
  @spec get() :: t()
  def get, do: Repo.one!(from(s in __MODULE__, limit: 1))

  @doc "Whether the owner has vendor support access on."
  @spec enabled?() :: boolean()
  def enabled?, do: get().enabled

  @doc """
  Update the settings (`%{enabled: boolean}`). Install admin only, and never
  a vendor support user.
  """
  @spec update(any(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update(actor, attrs) do
    with :ok <- refuse_support_vendor(actor),
         :ok <- Access.authorize_install(actor) do
      now = DateTime.utc_now()

      result =
        Repo.transaction(fn ->
          current = Repo.one!(from(s in __MODULE__, limit: 1, lock: "FOR UPDATE"))

          changeset =
            current
            |> changeset(attrs)
            |> put_change(:updated_by_user_id, actor_id(actor))

          case Repo.update(changeset) do
            {:ok, updated} ->
              ended =
                if current.enabled != updated.enabled do
                  SupportAccess.audit("support.access_changed", %{
                    actor_id: actor_id(actor),
                    actor_type: "user",
                    action: "access_changed",
                    resource_type: "install_support_access_settings",
                    resource_id: updated.id,
                    metadata: %{"from" => current.enabled, "to" => updated.enabled}
                  })

                  if updated.enabled,
                    do: [],
                    else: SupportAccess.end_all_in_transaction(:access_turned_off, now)
                else
                  []
                end

              {updated, ended}

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      case result do
        {:ok, {_updated, ended}} ->
          SupportAccess.after_sessions_ended(ended)
          SupportAccess.StateFile.write()
          if ended == [], do: SupportAccess.broadcast_changed()
          {:ok, get()}

        {:error, _} = error ->
          error
      end
    end
  end

  defp refuse_support_vendor(%User{support_vendor: true}), do: {:error, :unauthorized}
  defp refuse_support_vendor(_), do: :ok

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_), do: nil

  @doc false
  def changeset(%__MODULE__{} = settings, attrs) do
    settings
    |> cast(attrs, [:enabled])
    |> validate_required([:enabled])
  end

  @doc false
  # Bookkeeping writes by the state file writer and the shell event ingest.
  # Not owner-facing and not audited, and deliberately leaves `updated_at`
  # alone: that stamps the owner's last toggle, with `updated_by_user_id`.
  def put_bookkeeping(fields) when is_list(fields) do
    from(s in __MODULE__, where: s.singleton == true)
    |> Repo.update_all(set: fields)

    :ok
  end
end
