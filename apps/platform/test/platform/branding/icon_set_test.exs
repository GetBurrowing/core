defmodule Platform.Branding.IconSetTest do
  @moduledoc """
  Task 01a0879a stage 2 — deriving seven PWA icon variants from one upload.

  What these tests are for, in the order the stage's risk runs:

    1. ALL SEVEN EXIST, at the right pixel dimensions, and decode as real
       images of the type their key claims. A derivation that silently
       produced six would surface as one blank glyph on one platform.
    2. THE MASKABLE VARIANT IS NOT A COPY. This is the defect the stage
       exists to fix, so it gets two independent assertions: the bytes
       differ from `icon_512`, AND the padding is real, proven by SAMPLING
       corner pixels. Byte-inequality alone also passes on a meaningless
       re-encode, which is exactly the vacuous shape to avoid — the fixture
       is chosen so a maskable corner is `background_color` while the `any`
       output's corner is the mark's own colour.
    3. EVERY OUTPUT IS OPAQUE. A transparent icon lands on a
       launcher-supplied plate on one OS and on the user's wallpaper on
       another.
    4. `favicon_ico` IS A REAL ICO CONTAINER, not a PNG wearing a `.ico`
       name. Asserted on the container's own bytes.
    5. BAD INPUT PRODUCES A USER-FACING ERROR, NOT A CRASH.

  ## Why the fixtures are generated rather than committed

  Every assertion here is about a RELATION between an input's pixels and an
  output's pixels (the corner of a maskable is the ground; the corner of an
  `any` is the mark). A committed binary fixture hides the input's pixels
  from the reader, so the assertion becomes unreadable and un-retargetable.
  Generating flat-colour sources in `setup` keeps the discriminating
  property visible in the test source. Vix builds the input; the code under
  test is `IconSet`, not `Vix`.
  """
  use ExUnit.Case, async: true

  alias Platform.Branding.IconSet
  alias Vix.Vips.Image, as: VImage
  alias Vix.Vips.Operation

  # The mark and the ground are deliberately different, saturated, and
  # neither is a neutral that a re-encode could drift into.
  @mark_rgb [255, 0, 0]
  @ground_hex "#00ff00"
  @ground_rgb [0, 255, 0]

  # variant => the square canvas it must occupy.
  @expected_sizes %{
    icon_192: 192,
    icon_512: 512,
    icon_512_maskable: 512,
    apple_touch: 180,
    favicon_32: 32,
    favicon_16: 16
  }

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp solid_png(width, height, rgb) do
    {:ok, one} = Operation.black(1, 1)
    {:ok, coloured} = Operation.linear(one, [1.0, 1.0, 1.0], Enum.map(rgb, &(&1 * 1.0)))
    {:ok, cast} = Operation.cast(coloured, :VIPS_FORMAT_UCHAR)
    {:ok, tiled} = Operation.embed(cast, 0, 0, width, height, extend: :VIPS_EXTEND_COPY)
    {:ok, srgb} = Operation.colourspace(tiled, :VIPS_INTERPRETATION_sRGB)
    {:ok, bytes} = VImage.write_to_buffer(srgb, ".png")
    bytes
  end

  defp decode!(bytes) do
    {:ok, image} = VImage.new_from_buffer(bytes)
    image
  end

  defp pixel(bytes, x, y) do
    {:ok, values} = Operation.getpoint(decode!(bytes), x, y)
    values |> Enum.take(3) |> Enum.map(&round/1)
  end

  defp derive!(source_bytes, ground \\ @ground_hex) do
    assert {:ok, set} = IconSet.derive({:binary, source_bytes}, ground)
    set
  end

  setup do
    %{square: solid_png(600, 600, @mark_rgb)}
  end

  # ── Shape of the output ────────────────────────────────────────────────

  describe "derive/2 produces the full set" do
    test "all seven variants are present and nothing else is", %{square: square} do
      set = derive!(square)

      assert Enum.sort(Map.keys(set)) == Enum.sort(Platform.Branding.variants())
      assert map_size(set) == 7
      assert Enum.all?(Map.values(set), &(is_binary(&1) and byte_size(&1) > 0))
    end

    test "each PNG variant decodes at exactly its declared square size", %{square: square} do
      set = derive!(square)

      for {variant, size} <- @expected_sizes do
        image = decode!(Map.fetch!(set, variant))

        assert {VImage.width(image), VImage.height(image)} == {size, size},
               "#{variant} is #{VImage.width(image)}x#{VImage.height(image)}, expected #{size}²"
      end
    end

    test "each PNG variant really is a PNG, per its own magic bytes", %{square: square} do
      set = derive!(square)

      for {variant, _size} <- @expected_sizes do
        assert <<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>> = Map.fetch!(set, variant),
               "#{variant} does not carry the PNG signature"
      end
    end

    test "no output carries an alpha channel", %{square: square} do
      set = derive!(square)

      for {variant, _size} <- @expected_sizes do
        refute VImage.has_alpha?(decode!(Map.fetch!(set, variant))),
               "#{variant} kept an alpha channel; a transparent icon is composited " <>
                 "differently on every launcher"
      end
    end

    test "a source WITH transparency is flattened onto the ground, not kept" do
      {:ok, opaque} = VImage.new_from_buffer(solid_png(600, 600, @mark_rgb))
      {:ok, alpha} = Operation.bandjoin_const(opaque, [0.0])
      {:ok, transparent} = VImage.write_to_buffer(alpha, ".png")

      set = derive!(transparent)
      icon_512 = Map.fetch!(set, :icon_512)

      refute VImage.has_alpha?(decode!(icon_512))
      assert pixel(icon_512, 256, 256) == @ground_rgb
    end
  end

  # ── The maskable variant, which is why this stage exists ───────────────

  describe "icon_512_maskable is a distinct rendering, not a copy of icon_512" do
    test "its bytes differ from icon_512", %{square: square} do
      set = derive!(square)

      refute Map.fetch!(set, :icon_512_maskable) == Map.fetch!(set, :icon_512),
             "the maskable variant is byte-identical to the `any` variant — this is the " <>
               "exact defect the shipped manifest.json has, listing one file under both purposes"
    end

    test "the padding is REAL: a maskable corner is the ground, an `any` corner is the mark",
         %{square: square} do
      set = derive!(square)
      maskable = Map.fetch!(set, :icon_512_maskable)
      any = Map.fetch!(set, :icon_512)

      # The discriminating pair. Byte-inequality above also passes on a
      # meaningless re-encode; this does not.
      assert pixel(maskable, 2, 2) == @ground_rgb
      assert pixel(any, 2, 2) == @mark_rgb

      # ...and all four corners, so a rule that padded one edge only fails.
      for {x, y} <- [{2, 2}, {509, 2}, {2, 509}, {509, 509}] do
        assert pixel(maskable, x, y) == @ground_rgb,
               "maskable corner #{x},#{y} is not the background colour"
      end

      # The mark still occupies the centre — a padding rule that shrank it
      # to nothing would satisfy every corner assertion above.
      assert pixel(maskable, 256, 256) == @mark_rgb
    end

    test "the ground bleeds to the very edge, with no unpainted border", %{square: square} do
      maskable = derive!(square) |> Map.fetch!(:icon_512_maskable)

      for {x, y} <- [{0, 0}, {511, 0}, {0, 511}, {511, 511}, {256, 0}, {0, 256}] do
        assert pixel(maskable, x, y) == @ground_rgb,
               "edge pixel #{x},#{y} is not the background colour; a launcher mask crops " <>
                 "into this region and would expose it"
      end
    end

    test "the safe zone is 80% of the side, not merely 'some' padding", %{square: square} do
      maskable = derive!(square) |> Map.fetch!(:icon_512_maskable)

      # 80% of 512 is 409.6px centred, so the mark spans roughly x=51..460.
      # Just inside the safe zone is mark; just outside it is ground.
      assert pixel(maskable, 60, 256) == @mark_rgb
      assert pixel(maskable, 451, 256) == @mark_rgb
      assert pixel(maskable, 40, 256) == @ground_rgb
      assert pixel(maskable, 471, 256) == @ground_rgb
    end

    test "the ground follows background_color rather than being hardcoded", %{square: square} do
      maskable = derive!(square, "#0000ff") |> Map.fetch!(:icon_512_maskable)

      assert pixel(maskable, 2, 2) == [0, 0, 255]
    end
  end

  # ── The ICO container ──────────────────────────────────────────────────

  describe "favicon_ico" do
    test "starts with the ICONDIR signature and declares one 32x32 entry", %{square: square} do
      ico = derive!(square) |> Map.fetch!(:favicon_ico)

      assert <<0, 0, 1, 0, count::little-16, rest::binary>> = ico
      assert count == 1

      assert <<width::8, height::8, colours::8, _reserved::8, planes::little-16, bpp::little-16,
               length::little-32, offset::little-32, payload::binary>> = rest

      assert {width, height} == {32, 32}
      assert colours == 0
      assert planes == 1
      assert bpp == 32
      assert offset == 22
      assert length == byte_size(payload)
    end

    test "its payload is the derived 32px PNG itself, byte for byte", %{square: square} do
      set = derive!(square)
      <<_header::binary-size(22), payload::binary>> = Map.fetch!(set, :favicon_ico)

      assert payload == Map.fetch!(set, :favicon_32)
    end

    test "it is NOT the PNG under another name", %{square: square} do
      ico = derive!(square) |> Map.fetch!(:favicon_ico)

      refute match?(<<0x89, "PNG", _::binary>>, ico),
             "favicon_ico begins with the PNG signature, so it is a renamed PNG. " <>
               "The extension is what content_type_for_key/1 reads back, so this ships " <>
               "a PNG served as image/x-icon."
    end

    test "ico_from_png/2 encodes 256 as the byte 0 and refuses anything larger" do
      assert {:ok, <<0, 0, 1, 0, 1, 0, 0, 0, _::binary>>} = IconSet.ico_from_png("payload", 256)
      assert {:error, {:invalid_ico_size, 257}} = IconSet.ico_from_png("payload", 257)
      assert {:error, {:invalid_ico_size, 0}} = IconSet.ico_from_png("payload", 0)
    end
  end

  # ── Non-square input: letterboxed, never stretched ─────────────────────

  describe "a non-square source" do
    test "is letterboxed on the ground, preserving aspect ratio" do
      wide = solid_png(1200, 600, @mark_rgb)
      icon_512 = derive!(wide) |> Map.fetch!(:icon_512)

      # A 2:1 source scaled to fit 512 is 512x256, centred: rows 0..127 and
      # 384..511 are ground, the middle band is mark.
      assert pixel(icon_512, 256, 4) == @ground_rgb
      assert pixel(icon_512, 256, 507) == @ground_rgb
      assert pixel(icon_512, 256, 256) == @mark_rgb

      # Full width, so a stretch-to-fill would look identical at the centre
      # and different here. Left and right edges are the mark.
      assert pixel(icon_512, 2, 256) == @mark_rgb
      assert pixel(icon_512, 509, 256) == @mark_rgb
    end

    test "a tall source letterboxes on the other axis" do
      tall = solid_png(600, 1200, @mark_rgb)
      icon_512 = derive!(tall) |> Map.fetch!(:icon_512)

      assert pixel(icon_512, 4, 256) == @ground_rgb
      assert pixel(icon_512, 507, 256) == @ground_rgb
      assert pixel(icon_512, 256, 256) == @mark_rgb
      assert pixel(icon_512, 256, 2) == @mark_rgb
    end

    test "is still opaque and still the right size" do
      wide = solid_png(1200, 600, @mark_rgb)
      set = derive!(wide)

      for {variant, size} <- @expected_sizes do
        image = decode!(Map.fetch!(set, variant))
        assert {VImage.width(image), VImage.height(image)} == {size, size}
        refute VImage.has_alpha?(image)
      end
    end
  end

  # ── Rejected input ─────────────────────────────────────────────────────

  describe "input that cannot produce a good icon" do
    test "a source under 512px on a side is refused, with the measurement in the message" do
      small = solid_png(400, 600, @mark_rgb)

      assert {:error, {:source_too_small, 400, 600} = reason} =
               IconSet.derive({:binary, small}, @ground_hex)

      message = IconSet.error_message(reason)
      assert message =~ "400"
      assert message =~ "600"
      assert message =~ "512"
    end

    test "exactly 512px on both sides is accepted — the boundary is inclusive" do
      assert {:ok, set} = IconSet.derive({:binary, solid_png(512, 512, @mark_rgb)}, @ground_hex)
      assert map_size(set) == 7
    end

    test "a file that is not an image errors rather than raising" do
      assert {:error, :unreadable_image} =
               IconSet.derive({:binary, "this is not an image, it is a sentence"}, @ground_hex)

      assert IconSet.error_message(:unreadable_image) =~ "could not be read as an image"
    end

    test "an empty upload errors rather than raising" do
      assert {:error, :unreadable_image} = IconSet.derive({:binary, ""}, @ground_hex)
    end

    test "a missing path errors rather than raising" do
      assert {:error, :unreadable_image} =
               IconSet.derive({:path, "/nonexistent/does-not-exist.png"}, @ground_hex)
    end

    test "a malformed background colour is rejected before any work is done", %{square: square} do
      for bad <- ["171b25", "#171b2", "#gggggg", "red", nil] do
        assert {:error, {:invalid_colour, ^bad}} = IconSet.derive({:binary, square}, bad)
      end

      assert IconSet.error_message({:invalid_colour, "red"}) =~ "hex colour"
    end

    test "error_message/1 never leaks a raw term for an unexpected reason" do
      message = IconSet.error_message({:some_internal_thing, %{}})

      assert message == "The icon could not be processed. Try a different image."
    end
  end

  # ── Source-shape parity ────────────────────────────────────────────────

  describe "source forms" do
    test "{:path, _} and {:binary, _} produce the same seven outputs", %{square: square} do
      path =
        Path.join(System.tmp_dir!(), "icon_set_test_#{System.unique_integer([:positive])}.png")

      File.write!(path, square)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, from_path} = IconSet.derive({:path, path}, @ground_hex)
      assert {:ok, from_binary} = IconSet.derive({:binary, square}, @ground_hex)

      assert from_path == from_binary
    end

    test "derivation is deterministic for the same bytes", %{square: square} do
      assert derive!(square) == derive!(square)
    end
  end
end
