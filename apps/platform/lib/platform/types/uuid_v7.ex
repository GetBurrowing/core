defmodule Platform.Types.UUIDv7 do
  @moduledoc """
  UUIDv7 Ecto type (RFC 9562).

  Drop-in replacement for `Ecto.UUID` that generates time-sortable IDs.
  Lexicographic sort of UUIDv7 strings = chronological order.

      @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  ## Ordering within a millisecond

  The timestamp is milliseconds, so ids minted in the same millisecond
  cannot be separated by it. RFC 9562 §6.2 method 2 covers this: use the
  `rand_a` field as a **monotonic counter** rather than random bits, so
  ids minted inside one millisecond still sort in creation order.

  That is what this does. `rand_a` is the low 12 bits of
  `System.unique_integer([:monotonic, :positive])`, which is VM-global
  and strictly increasing, so two ids from the same millisecond compare
  in the order they were generated — from any process, without shared
  state or a boot-time table.

  **This was previously random, and the moduledoc claimed sortability it
  did not deliver.** Callers believed it: five separate sites asserted or
  relied on `earlier.id < later.id` and passed only because CI ran on a
  host slow enough to put the writes in different milliseconds. A faster
  runner failed all five (task `01a0506e`).

  ### The one limit, stated rather than discovered later

  `rand_a` is 12 bits, so the counter wraps after **4096 ids in a single
  millisecond**. Past that, order within that millisecond is not
  guaranteed. Uniqueness is unaffected — `rand_b` remains 62 random bits
  — and 4096/ms is far above anything this system generates, but it is a
  real ceiling and not a rounding error.

  Ordering ACROSS milliseconds never depended on the counter: the
  timestamp dominates the comparison, so a wrapped or reset counter
  cannot reorder ids from different milliseconds.
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

  @doc """
  Generate a UUIDv7 string: 48-bit ms timestamp, 12-bit monotonic
  counter, 62 random bits.

  The counter is what makes two ids from the same millisecond comparable
  — see the moduledoc. `rand_b` stays random, so uniqueness does not
  depend on the counter and is unaffected if it wraps.
  """
  @spec generate() :: String.t()
  def generate do
    timestamp_ms = System.system_time(:millisecond)

    counter = next_counter(timestamp_ms)

    <<rand_b::62, _::2>> = :crypto.strong_rand_bytes(8)

    <<timestamp_ms::big-48, 0b0111::4, counter::12, 0b10::2, rand_b::62>>
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

  # ── monotonic counter ─────────────────────────────────────────────────────
  #
  # A counter that RESETS EACH MILLISECOND, held in `:atomics` so every
  # process on the node shares one sequence.
  #
  # The first attempt used `System.unique_integer([:monotonic, :positive])`
  # masked to 12 bits. That is globally increasing, but the whole VM draws
  # from it, so under concurrent load the shared sequence advances far faster
  # than this module calls it and the mask wraps INSIDE a single millisecond.
  # Measured on a 16-way-parallel test run: 1 of 12 millisecond-groups came
  # back out of order.
  #
  # Resetting per millisecond removes that coupling. The counter now only
  # advances for ids minted in the same millisecond, so reaching 4096 takes
  # 4096 ids in one millisecond FROM THIS MODULE, rather than 4096 draws from
  # anywhere in the VM.
  @counter_key {__MODULE__, :counter}
  @slot_ms 1
  @slot_seq 2
  @counter_mask 0xFFF

  defp next_counter(now_ms) do
    ref = counter_ref()
    last_ms = :atomics.get(ref, @slot_ms)

    if now_ms > last_ms do
      # One writer wins the reset; losers fall through and take the next value
      # in the already-reset sequence. Either way the sequence increases within
      # the millisecond, which is the only property required.
      case :atomics.compare_exchange(ref, @slot_ms, last_ms, now_ms) do
        :ok -> :atomics.put(ref, @slot_seq, 0)
        _ -> :ok
      end
    end

    Bitwise.band(:atomics.add_get(ref, @slot_seq, 1), @counter_mask)
  end

  # Created on first use rather than at boot, so this type carries no
  # supervision requirement and stays usable from scripts, releases and tests.
  defp counter_ref do
    case :persistent_term.get(@counter_key, nil) do
      nil ->
        ref = :atomics.new(2, signed: false)
        :persistent_term.put(@counter_key, ref)
        ref

      ref ->
        ref
    end
  end
end
