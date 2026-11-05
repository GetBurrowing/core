defmodule Platform.Chat.LinkUnfurls.Settings do
  @moduledoc """
  The `install_link_unfurl_settings` singleton (task 01a1a944 stage 3): this
  install's switch for link previews. Mirrors `Platform.Prototypes.Settings`:
  one row, enforced by a DB CHECK and a unique index, seeded by the
  migration, never on the orgs table. There is no per-org settings column,
  so "orgs can disable previews" is delivered as this install-level switch.

  Read fresh at call time (`get/0`), so turning previews off takes effect on
  the next message with no restart.

  ## Fields

    * `enabled`: default `true`. While off, a posted or edited message makes
      no `Platform.Chat.LinkUnfurls.ensure/2` call and creates no
      `link_unfurls` row. Previews ALREADY stored still render: turning the
      switch off stops new fetches, it does not hide what readers have
      already seen. An author hides one message's preview with
      `Platform.Chat.hide_link_unfurls/2`.

  `update/2` re-checks `Platform.Access.authorize_install/1`, because a route
  gate is not an authorization boundary for a context function.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Repo

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "install_link_unfurl_settings" do
    field(:singleton, :boolean, default: true)
    field(:enabled, :boolean, default: true)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The singleton row, read fresh."
  @spec get() :: t()
  def get, do: Repo.one!(from(s in __MODULE__, limit: 1))

  @doc "Whether new messages unfurl their outside links."
  @spec enabled?() :: boolean()
  def enabled?, do: get().enabled

  @doc "Update the settings. Install (root) admin only."
  @spec update(any(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update(actor, attrs) do
    with :ok <- Access.authorize_install(actor) do
      get() |> changeset(attrs) |> Repo.update()
    end
  end

  @doc false
  def changeset(%__MODULE__{} = settings, attrs) do
    settings
    |> cast(attrs, [:enabled])
    |> validate_required([:enabled])
  end
end
