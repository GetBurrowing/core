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

  That is what this does. `rand_a` is a 12-bit counter shared by every
  process on the node: it restarts at 0 in each new millisecond and
  increases by one per id, so two ids from the same millisecond compare in
  the order they were generated, from any process. The millisecond and the
  counter advance together as one atomic word, so no process can see a
  millisecond without its counter (the comment above `next_stamp/1` has
  the two earlier designs and why each failed).

  **This was previously random, and the moduledoc claimed sortability it
  did not deliver.** Callers believed it: five separate sites asserted or
  relied on `earlier.id < later.id` and passed only because CI ran on a
  host slow enough to put the writes in different milliseconds. A faster
  runner failed all five (task `01a0506e`).

  ### What happens at the edges

  `rand_a` is 12 bits, so at most **4096 ids fit in one millisecond**.
  The 4097th takes the next millisecond as its timestamp instead of
  wrapping the counter (RFC 9562 §6.2 allows advancing the timestamp when
  the counter is exhausted). The same rule covers a clock that reads
  earlier than the last id issued (a process descheduled after reading
  the clock, or the system clock stepping back): the id takes the last
  issued millisecond, never an older one. So ids from one node are
  strictly increasing in generation order, and the embedded timestamp can
  run ahead of the wall clock only while more than 4096 ids per
  millisecond are being minted. Uniqueness never depended on the counter:
  `rand_b` remains 62 random bits.

  One exception, at boot: the counter is created lazily on the first call,
  and two processes racing that very first call can each create one. Only
  the ids those racing first calls mint can tie on the counter; every
  later call reads the one stored counter.

  Ordering across NODES is only as good as their clocks: the counter is
  per node.
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
  depend on the counter.
  """
  @spec generate() :: String.t()
  def generate do
    {timestamp_ms, counter} = next_stamp(System.system_time(:millisecond))

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
  # The second attempt kept the millisecond and the sequence in two atomics
  # slots and reset them with two writes (`compare_exchange` the ms, then
  # `put` the sequence to 0). That is a race, not a reset: a process that read
  # the new ms between the two writes skipped the reset and drew from the OLD
  # millisecond's sequence (say 300), then the reset landed and its next id in
  # the same millisecond drew 1, so one process's own ids sorted backwards.
  # CI caught it three times (task 01a13aac).
  #
  # Now the millisecond and the sequence are ONE 64-bit word,
  # `ms <<< 16 ||| seq`, advanced by a single `compare_exchange` retry loop,
  # so no process can observe one half of the reset without the other.
  #
  # The word's millisecond is also the id's timestamp, and it never goes
  # backwards:
  #
  #   * a caller whose clock read is OLDER than the word's millisecond (it was
  #     descheduled across a millisecond boundary after reading the clock, or
  #     the system clock stepped back) takes the word's millisecond, not its
  #     own. Stamping its own older millisecond with the newer millisecond's
  #     sequence would sort it before ids it minted earlier;
  #   * when 4096 ids have been drawn in one millisecond the word moves on to
  #     the next millisecond (RFC 9562 §6.2: the timestamp may be advanced
  #     when the counter is exhausted) instead of wrapping the 12-bit field.
  #
  # So every id from this node is strictly greater than the one before it,
  # whichever process minted it. The timestamp runs ahead of the wall clock
  # only while more than 4096 ids per millisecond are being minted.
  @counter_key {__MODULE__, :stamp}
  @counter_bits 12
  @counter_max Bitwise.bsl(1, @counter_bits) - 1
  @seq_bits 16
  @seq_mask Bitwise.bsl(1, @seq_bits) - 1

  # Returns `{timestamp_ms, counter}` for the next id.
  defp next_stamp(now_ms) do
    ref = counter_ref()
    advance(ref, :atomics.get(ref, 1), now_ms)
  end

  defp advance(ref, old, now_ms) do
    old_ms = Bitwise.bsr(old, @seq_bits)
    seq = Bitwise.band(old, @seq_mask)

    new =
      cond do
        now_ms > old_ms -> Bitwise.bsl(now_ms, @seq_bits)
        seq < @counter_max -> old + 1
        true -> Bitwise.bsl(old_ms + 1, @seq_bits)
      end

    case :atomics.compare_exchange(ref, 1, old, new) do
      :ok -> {Bitwise.bsr(new, @seq_bits), Bitwise.band(new, @seq_mask)}
      current -> advance(ref, current, now_ms)
    end
  end

  # Created on first use rather than at boot, so this type carries no
  # supervision requirement and stays usable from scripts, releases and tests.
  defp counter_ref do
    case :persistent_term.get(@counter_key, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :persistent_term.put(@counter_key, ref)
        ref

      ref ->
        ref
    end
  end
end
