defmodule Platform.Federation.OwnerHandleTest do
  # async: false — the module reads from Application env which is global state.
  # Multiple test modules touching :federation_owner_handle_keys would race.
  use ExUnit.Case, async: false

  alias Platform.Federation.OwnerHandle

  @user_id "01900000-0000-7000-8000-000000000001"
  @other_user_id "01900000-0000-7000-8000-000000000002"
  @peer_org_a "org-aaaaaaaaaaaaa"
  @peer_org_b "org-bbbbbbbbbbbbb"
  @salt_a "salt-aaaaaaaaaaaaaaaa"
  @salt_b "salt-bbbbbbbbbbbbbbbb"

  # 32-byte keys generated at module-compile time; stable for the test run.
  @key_v1 :crypto.strong_rand_bytes(32)
  @key_v2 :crypto.strong_rand_bytes(32)

  setup do
    Application.put_env(:platform, :federation_owner_handle_keys, %{
      1 => @key_v1,
      2 => @key_v2
    })

    on_exit(fn ->
      Application.delete_env(:platform, :federation_owner_handle_keys)
    end)

    :ok
  end

  describe "for/4 — handle generation" do
    test "is stable: same inputs always produce same handle" do
      h1 = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      h2 = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      assert h1 == h2
    end

    test "diverges per peer_org_id (per-peer divergence is the core anti-correlation property)" do
      h_a = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      h_b = OwnerHandle.for(@user_id, @salt_a, @peer_org_b, 1)
      refute h_a == h_b
    end

    test "diverges per user_id" do
      h1 = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      h2 = OwnerHandle.for(@other_user_id, @salt_a, @peer_org_a, 1)
      refute h1 == h2
    end

    test "diverges per user_salt (RTBF mechanism: salt rotation revokes the handle)" do
      h_old = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      h_new = OwnerHandle.for(@user_id, @salt_b, @peer_org_a, 1)
      refute h_old == h_new
    end

    test "diverges per key_version (secret rotation use case)" do
      h_v1 = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      h_v2 = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 2)
      refute h_v1 == h_v2
    end

    test "produces fixed-length url-safe base64 (HMAC-SHA256 → 32 bytes → 43 chars unpadded)" do
      handle = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      assert byte_size(handle) == 43
      assert handle =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "is opaque: handle does not contain the user_id as a substring" do
      handle = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      refute String.contains?(handle, @user_id)
    end

    test "is resistant to component boundary swap (length-prefixed encoding)" do
      # Without length-prefixing, ("AB", "", "CD") could be re-parsed as
      # ("A", "BCD") and produce the same digest. Length-prefixing eliminates
      # this entire class of attack.
      h1 = OwnerHandle.for("AB", @salt_a, "CD", 1)
      h2 = OwnerHandle.for("A", @salt_a, "BCD", 1)
      refute h1 == h2
    end

    test "raises ArgumentError on empty user_id" do
      assert_raise ArgumentError, ~r/user_id must be non-empty/, fn ->
        OwnerHandle.for("", @salt_a, @peer_org_a, 1)
      end
    end

    test "raises ArgumentError on empty peer_org_id" do
      assert_raise ArgumentError, ~r/peer_org_id must be non-empty/, fn ->
        OwnerHandle.for(@user_id, @salt_a, "", 1)
      end
    end

    test "accepts empty user_salt (pre-rotation users have empty salt)" do
      # Users created before salt-issuance shipped have an empty salt. They
      # still get a deterministic handle; rotation populates a real salt later.
      handle = OwnerHandle.for(@user_id, "", @peer_org_a, 1)
      assert is_binary(handle)
      assert byte_size(handle) == 43
    end

    test "raises a clear error when key_version is not configured" do
      assert_raise RuntimeError, ~r/Owner handle key v99 not configured/, fn ->
        OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 99)
      end
    end

    test "raises a clear error when configured key is shorter than 32 bytes" do
      Application.put_env(:platform, :federation_owner_handle_keys, %{1 => "short"})

      assert_raise RuntimeError, ~r/shorter than 32 bytes/, fn ->
        OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      end
    end

    test "raises FunctionClauseError on non-binary user_id" do
      assert_raise FunctionClauseError, fn ->
        OwnerHandle.for(nil, @salt_a, @peer_org_a, 1)
      end
    end

    test "raises FunctionClauseError on non-positive key_version" do
      assert_raise FunctionClauseError, fn ->
        OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 0)
      end
    end
  end

  describe "verify/5 — handle verification under versioned key registry" do
    test "returns {:ok, version} on a handle issued under the listed version" do
      handle = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      assert {:ok, 1} = OwnerHandle.verify(handle, @user_id, @salt_a, @peer_org_a, [1])
    end

    test "matches the correct version when registry has multiple keys" do
      handle_v1 = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      handle_v2 = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 2)

      assert {:ok, 1} = OwnerHandle.verify(handle_v1, @user_id, @salt_a, @peer_org_a, [1, 2])
      assert {:ok, 2} = OwnerHandle.verify(handle_v2, @user_id, @salt_a, @peer_org_a, [1, 2])
    end

    test "returns :error when handle does not match any listed version" do
      forged = String.duplicate("A", 43)
      assert :error = OwnerHandle.verify(forged, @user_id, @salt_a, @peer_org_a, [1, 2])
    end

    test "returns :error when handle was issued under a deprecated version not in the accepted list" do
      handle_v1 = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      # During post-rotation soak, only v2 is accepted; v1 handles are invalid.
      assert :error = OwnerHandle.verify(handle_v1, @user_id, @salt_a, @peer_org_a, [2])
    end

    test "returns :error when handle is well-formed but verifies against a different (user, salt, peer_org) tuple" do
      handle = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)

      # Wrong user
      assert :error = OwnerHandle.verify(handle, @other_user_id, @salt_a, @peer_org_a, [1])
      # Wrong salt (RTBF: post-rotation, the old handle no longer verifies)
      assert :error = OwnerHandle.verify(handle, @user_id, @salt_b, @peer_org_a, [1])
      # Wrong peer
      assert :error = OwnerHandle.verify(handle, @user_id, @salt_a, @peer_org_b, [1])
    end

    test "returns :error when handle is byte-tampered" do
      handle = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)

      tampered =
        String.replace(handle, ~r/^./, fn first ->
          if first == "A", do: "B", else: "A"
        end)

      assert :error = OwnerHandle.verify(tampered, @user_id, @salt_a, @peer_org_a, [1])
    end

    test "returns :error with empty key_versions list" do
      handle = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      assert :error = OwnerHandle.verify(handle, @user_id, @salt_a, @peer_org_a, [])
    end

    test "uses constant-time comparison (delegates to Plug.Crypto.secure_compare)" do
      # We can't directly assert timing properties, but we can confirm the
      # function returns the same shape regardless of where the mismatch is.
      handle = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)

      first_byte_diff = "B" <> binary_part(handle, 1, 42)

      last_byte_diff =
        binary_part(handle, 0, 42) <> if String.last(handle) == "A", do: "B", else: "A"

      assert :error = OwnerHandle.verify(first_byte_diff, @user_id, @salt_a, @peer_org_a, [1])
      assert :error = OwnerHandle.verify(last_byte_diff, @user_id, @salt_a, @peer_org_a, [1])
    end
  end

  describe "generate_salt/0" do
    test "produces a 43-char URL-safe base64 string (32 bytes of randomness)" do
      salt = OwnerHandle.generate_salt()
      assert byte_size(salt) == 43
      assert salt =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "is statistically distinct across calls (1000 collisions check)" do
      salts = for _ <- 1..1000, do: OwnerHandle.generate_salt()
      assert MapSet.new(salts) |> MapSet.size() == 1000
    end

    test "rotated salt produces a different handle for the same user (RTBF closure)" do
      salt_old = OwnerHandle.generate_salt()
      salt_new = OwnerHandle.generate_salt()

      handle_old = OwnerHandle.for(@user_id, salt_old, @peer_org_a, 1)
      handle_new = OwnerHandle.for(@user_id, salt_new, @peer_org_a, 1)

      refute handle_old == handle_new
    end
  end

  describe "cross-peer divergence — anti-correlation property" do
    test "the same (user, salt) under two different peers produces unrelated handles" do
      h_to_peer_a = OwnerHandle.for(@user_id, @salt_a, @peer_org_a, 1)
      h_to_peer_b = OwnerHandle.for(@user_id, @salt_a, @peer_org_b, 1)

      # Per-peer divergence: peers cannot trivially correlate the same user
      # across them by comparing handles. This is the passive-collusion defense.
      refute h_to_peer_a == h_to_peer_b

      # And neither handle should be a transformation of the other
      # (no shared prefix, no string match).
      refute String.contains?(h_to_peer_a, h_to_peer_b)
      refute String.contains?(h_to_peer_b, h_to_peer_a)
    end
  end
end
