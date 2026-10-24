defmodule Platform.Social.PostingSlot do
  @moduledoc """
  One weekly posting slot on a `Platform.Social.Account` (Social authoring
  4/11): `weekday` 1..7 (ISO, Monday is 1) and `time` `"HH:MM"` (24h), both
  in the PROFILE's timezone (`profile.timezone`). `Platform.Social.Slots`
  turns them into UTC instants.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{weekday: 1..7, time: String.t()}

  @time ~r/\A([01]\d|2[0-3]):[0-5]\d\z/

  @primary_key false
  embedded_schema do
    field(:weekday, :integer)
    field(:time, :string)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = slot, attrs) do
    slot
    |> cast(attrs, [:weekday, :time])
    |> validate_required([:weekday, :time])
    |> validate_inclusion(:weekday, 1..7)
    |> validate_format(:time, @time, message: "must be HH:MM (24 hour)")
  end

  @doc "The slot's local `Time`."
  @spec local_time(t()) :: Time.t()
  def local_time(%__MODULE__{time: <<h::binary-size(2), ":", m::binary-size(2)>>}),
    do: Time.new!(String.to_integer(h), String.to_integer(m), 0)

  @doc "Short weekday names, Monday first."
  @spec weekday_names() :: [{1..7, String.t()}]
  def weekday_names,
    do: [{1, "Mon"}, {2, "Tue"}, {3, "Wed"}, {4, "Thu"}, {5, "Fri"}, {6, "Sat"}, {7, "Sun"}]

  @doc "\"Mon 09:00\""
  @spec label(t()) :: String.t()
  def label(%__MODULE__{weekday: d, time: t}) do
    {_, name} = List.keyfind(weekday_names(), d, 0, {d, "?"})
    "#{name} #{t}"
  end
end
