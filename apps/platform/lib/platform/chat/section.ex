defmodule Platform.Chat.Section do
  @moduledoc """
  A channel sidebar section — the admin-curated default grouping (chat sidebar
  v2, Stage 2). One row per org; `org_id` is the section's owning org and the
  default-grouping key (a channel renders under the section whose `org_id`
  matches `chat_spaces.org_id`). `color` is a scope token in CSS form
  (e.g. `wayne-tech`); `position` is the admin default order.

  ## `name` is a label override, not a copy of the org name

  `name` is a nullable, sidebar-only LABEL OVERRIDE (task 01a08212). `nil`
  means "follow the org": the header renders the org's CURRENT name, read at
  query time into the virtual `org_name` field by
  `Platform.Chat.Sidebar.list_default_sections/0` and
  `list_active_default_sections/0`. Always render through `display_name/1`,
  never `section.name` directly.

  It used to store a copy of the org name taken at creation, and renaming the
  org left the section naming the old one forever. Deriving the header from
  the org means an org rename needs no sync step here, whatever path performs
  it (today only direct SQL; a future admin or MCP rename likewise needs
  nothing). Do not add one.

  Per-user reordering/hiding lives in `users.preferences` (Stage 3), not here.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "channel_sections" do
    field(:org_id, :binary_id)
    field(:name, :string)
    field(:color, :string)
    field(:position, :integer, default: 0)

    # The owning org's current name, selected by the Sidebar list queries.
    # Never persisted; `nil` on a struct loaded any other way.
    field(:org_name, :string, virtual: true)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(section, attrs) do
    section
    |> cast(attrs, [:org_id, :name, :color, :position])
    |> normalise_name()
    |> validate_required([:org_id])
    |> foreign_key_constraint(:org_id)
    |> unique_constraint(:org_id)
  end

  @doc """
  The header text for a section: its trimmed label override when one is set,
  else the owning org's current name (`org_name`). `nil` only when both are
  absent, i.e. a following section loaded without its org.
  """
  @spec display_name(map()) :: String.t() | nil
  def display_name(section) do
    case section |> Map.get(:name) |> blank_to_nil() do
      nil -> Map.get(section, :org_name)
      name -> name
    end
  end

  # A blank or whitespace label is no label: it clears the override so the
  # section follows its org again.
  defp normalise_name(changeset) do
    case fetch_change(changeset, :name) do
      {:ok, name} -> put_change(changeset, :name, blank_to_nil(name))
      :error -> changeset
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
