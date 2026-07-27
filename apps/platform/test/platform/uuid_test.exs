defmodule Platform.UUIDTest do
  @moduledoc """
  The canonical boundary predicate's contract.

  The load-bearing case is `"rejects a raw 16-byte binary"`. A suite that only
  exercises `"higgins"` and a valid UUID passes against a bare
  `Ecto.UUID.cast/1` predicate — i.e. against the bug this module exists to
  prevent — so it would be vacuous. Do not delete that test.
  """
  use ExUnit.Case, async: true

  alias Platform.Types.UUIDv7

  doctest Platform.UUID

  # A 16-character slug. `Ecto.UUID.cast/1` hex-encodes it into a well-formed
  # UUID string; `Ecto.UUID.dump/1` then rejects the original. The gap.
  @sixteen_char_slug "higginshigginsxx"

  @invalid [
    "system",
    "system:auto",
    "higgins",
    "",
    @sixteen_char_slug,
    # 36 characters, correct dash layout, non-hex digits
    "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz",
    # 36 characters, no structure at all
    String.duplicate("z", 36),
    # a UUID with the dashes stripped (32 chars) — cast/1 rejects, and so must we
    "0195f6c3000070008000000000000000",
    nil,
    :system,
    42,
    %{id: "nope"},
    ["0195f6c3-0000-7000-8000-000000000000"]
  ]

  describe "valid?/1" do
    test "accepts a canonical generated UUID" do
      assert Platform.UUID.valid?(UUIDv7.generate())
    end

    test "accepts an upper-cased canonical UUID" do
      uuid = UUIDv7.generate()

      assert Platform.UUID.valid?(String.upcase(uuid))
    end

    test "rejects a raw 16-byte binary — the Ecto.UUID.cast/1 gap" do
      raw = :crypto.strong_rand_bytes(16)

      # Precondition: this is exactly the input a bare cast-based guard waves
      # through. If Ecto ever tightens cast/1 this assertion tells us the gap
      # closed upstream, rather than silently making our test vacuous.
      assert {:ok, _hex} = Ecto.UUID.cast(raw)
      assert :error = Ecto.UUID.dump(raw)

      refute Platform.UUID.valid?(raw)
    end

    test "rejects a 16-character slug, which cast/1 also hex-encodes" do
      assert {:ok, "68696767-696e-7368-6967-67696e737878"} =
               Ecto.UUID.cast(@sixteen_char_slug)

      assert :error = Ecto.UUID.dump(@sixteen_char_slug)

      refute Platform.UUID.valid?(@sixteen_char_slug)
    end

    for value <- @invalid do
      test "rejects #{inspect(value)}" do
        refute Platform.UUID.valid?(unquote(Macro.escape(value)))
      end
    end
  end

  describe "cast/1" do
    test "returns the downcased UUID for a canonical value" do
      uuid = UUIDv7.generate()

      assert {:ok, ^uuid} = Platform.UUID.cast(uuid)
      assert {:ok, ^uuid} = Platform.UUID.cast(String.upcase(uuid))
    end

    for value <- @invalid do
      test "returns :error for #{inspect(value)}" do
        assert :error = Platform.UUID.cast(unquote(Macro.escape(value)))
      end
    end

    test "returns :error for a raw 16-byte binary" do
      assert :error = Platform.UUID.cast(:crypto.strong_rand_bytes(16))
    end

    test "agrees with valid?/1 on every probe" do
      for value <- probes() do
        assert Platform.UUID.valid?(value) == match?({:ok, _}, Platform.UUID.cast(value)),
               "valid?/1 and cast/1 disagreed on #{inspect(value)}"
      end
    end
  end

  describe "agreement with the primary-key types actually in use" do
    # The sweep guards lookups against schemas keyed on BOTH
    # `Platform.Types.UUIDv7` (e.g. Accounts.User) and bare `:binary_id`
    # (backed by `Ecto.UUID`). The predicate is only safe as a universal guard
    # if it is a SUBSET of both — anything it admits must be castable and
    # dumpable by both, or Repo still raises behind the guard.
    test "anything valid?/1 admits is accepted by Ecto.UUID and Platform.Types.UUIDv7" do
      for value <- probes(), Platform.UUID.valid?(value) do
        assert match?({:ok, _}, Ecto.UUID.cast(value)),
               "Ecto.UUID.cast/1 rejected #{inspect(value)}"

        assert match?({:ok, _}, Ecto.UUID.dump(value)),
               "Ecto.UUID.dump/1 rejected #{inspect(value)}"

        assert match?({:ok, _}, UUIDv7.cast(value)),
               "Platform.Types.UUIDv7.cast/1 rejected #{inspect(value)}"

        assert match?({:ok, _}, UUIDv7.dump(value)),
               "Platform.Types.UUIDv7.dump/1 rejected #{inspect(value)}"
      end
    end

    test "the probe set actually contains admitted values" do
      # Guards the loop above against passing vacuously on an all-invalid set.
      assert Enum.count(probes(), &Platform.UUID.valid?/1) >= 2
    end
  end

  describe "Platform.Analytics.UsageEvent.valid_uuid?/1 delegation" do
    test "stays behaviourally identical to the canonical predicate" do
      for value <- probes() do
        assert Platform.Analytics.UsageEvent.valid_uuid?(value) ==
                 Platform.UUID.valid?(value),
               "delegation drifted on #{inspect(value)}"
      end
    end
  end

  defp probes do
    uuid = UUIDv7.generate()

    [uuid, String.upcase(uuid), Ecto.UUID.generate(), :crypto.strong_rand_bytes(16)] ++ @invalid
  end
end
