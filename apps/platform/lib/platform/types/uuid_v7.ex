defmodule Platform.Types.UUIDv7 do
  @moduledoc """
  UUIDv7 Ecto type (RFC 9562).

  Drop-in replacement for `Ecto.UUID` that generates time-sortable IDs.
  Lexicographic sort of UUIDv7 strings = chronological order.

      @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  """

  use Ecto.Type

  @impl true
  def type, do: :uuid

  @impl true
  def cast(<<_::288>> = raw_hex) do
    case Ecto.UUID.cast(raw_hex) do
      {:ok, uuid} -> {:ok, uuid}
      _ -> :error
    end
  end

  def cast(<<_::64, ?-, _::32, ?-, _::32, ?-, _::32, ?-, _::96>> = uuid) do
    {:ok, String.downcase(uuid)}
  end

  def cast(_), do: :error

  @impl true
  def load(<<_::128>> = raw_binary) do
    Ecto.UUID.load(raw_binary)
  end

  def load(_), do: :error

  @impl true
  def dump(uuid), do: Ecto.UUID.dump(uuid)

  @impl true
  def autogenerate, do: generate()

  @doc "Generate a UUIDv7 string (48-bit ms timestamp + random)."
  @spec generate() :: String.t()
  def generate do
    timestamp_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _::6>> = :crypto.strong_rand_bytes(10)

    <<timestamp_ms::big-48, 0b0111::4, rand_a::12, 0b10::2, rand_b::62>>
    |> encode()
  end

  defp encode(<<a::32, b::16, c::16, d::16, e::48>>) do
    hex(a, 8) <>
      "-" <> hex(b, 4) <> "-" <> hex(c, 4) <> "-" <> hex(d, 4) <> "-" <> hex(e, 12)
  end

  defp hex(int, pad) do
    int
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(pad, "0")
  end
end
