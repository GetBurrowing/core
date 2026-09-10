defmodule Platform.Branding.IconSet do
  @moduledoc """
  Derives the SEVEN icon variants this install serves from ONE uploaded
  square (task `01a0879a` stage 2).

  One upload, seven outputs. The admin is not asked to produce a favicon,
  an apple-touch icon and a maskable Android icon by hand; those are
  mechanical transforms of a single source and are done here.

  ## Every output is OPAQUE. Deliberately.

  Home screens sit on arbitrary wallpaper. A transparent PNG gets a
  launcher-supplied plate on one OS and nothing at all on another, so the
  mark lands on a surface nobody designed and looks different on every
  device. Every variant is therefore flattened onto an opaque ground in the
  install's `background_color` before it is written, and the tests assert
  no output carries an alpha channel.

  ## The maskable variant is NOT a copy of `icon_512`

  This is the defect the stage exists to fix. The shipped static
  `manifest.json` lists `/images/icon-512.png` twice — once as `any`, once
  as `maskable` — and one file cannot do both jobs:

    * Android crops a `maskable` icon to the launcher's shape (circle,
      squircle, rounded square, teardrop — the OEM picks). Only the inner
      **80% diameter** of the canvas is guaranteed to survive the crop, so
      a full-bleed mark loses its edges.
    * An `any` icon is composited as-is. A mark pre-shrunk to 80% looks
      shrunken and floating everywhere it is used at full bleed.

  So `icon_512_maskable` scales the source to 80% of the canvas, centres
  it, and composites it on a ground that BLEEDS TO THE EDGE in
  `background_color`. It differs from `icon_512` in both dimensions of the
  guarantee: different bytes, and visibly padded. The test proves the second
  by SAMPLING corner pixels — byte-inequality on its own also passes on a
  meaningless re-encode.

  ## A non-square source is LETTERBOXED, not rejected and not stretched

  Given a non-square upload we scale it to fit and centre it on the opaque
  ground, which is the same operation the maskable path already performs
  with a different scale factor. The alternative considered was rejecting
  the upload. Letterboxing wins because the failure it replaces is silent:
  a stretched logo is a quality regression nobody files a bug for, whereas
  a letterboxed one is visibly correct and the admin can re-crop if they
  care. `#{inspect(__MODULE__)}` never distorts aspect ratio.

  A source smaller than `#{512}px` on either side IS rejected, because
  every output at or above 512 would then be an upscale — a blurry icon is
  the same silent regression, and here we cannot fix it by composing.

  ## `favicon_ico` is a real ICO container

  libvips does not write ICO. Renaming a PNG to `.ico` is not an option:
  the extension is what `IconStorage.content_type_for_key/1` reads back, so
  a PNG served as `image/x-icon` is a different bug wearing the same
  filename.

  The ICO format legally permits a PNG payload inside a directory entry —
  every browser from IE11 on reads it — so we write the 6-byte `ICONDIR`
  plus 16-byte `ICONDIRENTRY` header around the already-derived 32×32 PNG
  bytes. Hand-rolled rather than a hex dependency: it is ~10 lines of
  struct-packed binary, fully unit-testable, and the maintained-encoder
  search turns up nothing that is both current and narrower than this.
  """

  alias Vix.Vips.Image, as: VImage
  alias Vix.Vips.Operation

  @min_source_px 512

  # The maskable safe zone. Android guarantees only the inner 80% DIAMETER
  # of the canvas survives the launcher's mask, so the mark occupies 80% of
  # a side and the remaining 10% per edge is sacrificial ground.
  @maskable_scale 0.8

  @typedoc "The variants `derive/2` produces, keyed as in `Platform.Branding.variants/0`."
  @type variant ::
          :icon_192
          | :icon_512
          | :icon_512_maskable
          | :apple_touch
          | :favicon_32
          | :favicon_16
          | :favicon_ico

  # variant => {canvas px, fraction of the canvas the mark occupies}
  @png_variants [
    {:icon_192, 192, 1.0},
    {:icon_512, 512, 1.0},
    {:icon_512_maskable, 512, @maskable_scale},
    {:apple_touch, 180, 1.0},
    {:favicon_32, 32, 1.0},
    {:favicon_16, 16, 1.0}
  ]

  @doc "The smallest source side `derive/2` accepts."
  @spec min_source_px() :: pos_integer()
  def min_source_px, do: @min_source_px

  @doc """
  Derives all seven variants.

  `source` is `{:binary, bytes}` or `{:path, path}`. `background_color` is a
  6-digit hex string (`"#171b25"`) — the install's manifest background, so
  the padding matches the splash screen rather than introducing a second
  colour.

  Returns `{:ok, %{variant => binary()}}` with all seven keys, or
  `{:error, reason}`. Pass the reason to `error_message/1` for user-facing
  copy; nothing here raises on bad input.
  """
  @spec derive({:binary, binary()} | {:path, Path.t()}, String.t()) ::
          {:ok, %{variant() => binary()}} | {:error, term()}
  def derive(source, background_color) do
    with {:ok, rgb} <- parse_hex_colour(background_color),
         {:ok, image} <- open(source),
         :ok <- validate_dimensions(image),
         {:ok, base} <- to_srgb(image),
         {:ok, pngs} <- derive_pngs(base, rgb),
         {:ok, ico} <- ico_from_png(Map.fetch!(pngs, :favicon_32), 32) do
      {:ok, Map.put(pngs, :favicon_ico, ico)}
    end
  end

  @doc """
  User-facing copy for a `derive/2` error.

  Every branch names what the admin should do differently. `derive/2` is
  reached from an admin upload form, so an `{:error, %Vix.Vips.Image{}}`
  tuple leaking into a flash message is a bug in itself.
  """
  @spec error_message(term()) :: String.t()
  def error_message({:source_too_small, width, height}) do
    "That image is #{width}×#{height}. It must be at least " <>
      "#{@min_source_px}×#{@min_source_px} — anything smaller would have to be " <>
      "upscaled to fill the 512px icon and would look blurry."
  end

  def error_message(:unreadable_image),
    do: "That file could not be read as an image. Upload a PNG, JPEG, WebP, GIF or HEIC."

  def error_message({:invalid_colour, value}),
    do: "#{inspect(value)} is not a 6-digit hex colour such as #171b25."

  def error_message(_other),
    do: "The icon could not be processed. Try a different image."

  # ── Derivation ────────────────────────────────────────────────

  defp derive_pngs(base, rgb) do
    Enum.reduce_while(@png_variants, {:ok, %{}}, fn {variant, size, scale}, {:ok, acc} ->
      case render(base, rgb, size, scale) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(acc, variant, bytes)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Scale to fit `size * scale`, flatten any alpha onto the ground, then
  # embed centred on a full `size` canvas whose extension is that same
  # ground. With `scale == 1.0` and a square source the embed is a no-op;
  # with a non-square source it letterboxes; with the maskable scale it
  # produces the safe-zone padding. One code path, three behaviours,
  # because they are the same operation.
  defp render(base, rgb, size, scale) do
    inner = max(round(size * scale), 1)

    with {:ok, thumb} <- Operation.thumbnail_image(base, inner, height: inner),
         {:ok, opaque} <- flatten(thumb, rgb),
         {:ok, canvas} <- centre(opaque, size, rgb) do
      VImage.write_to_buffer(canvas, ".png")
    end
  end

  defp flatten(image, rgb) do
    if VImage.has_alpha?(image) do
      Operation.flatten(image, background: rgb)
    else
      {:ok, image}
    end
  end

  defp centre(image, size, rgb) do
    width = VImage.width(image)
    height = VImage.height(image)

    if width == size and height == size do
      {:ok, image}
    else
      Operation.embed(image, div(size - width, 2), div(size - height, 2), size, size,
        extend: :VIPS_EXTEND_BACKGROUND,
        background: rgb
      )
    end
  end

  defp to_srgb(image), do: Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)

  defp open({:binary, bytes}) when is_binary(bytes), do: wrap_open(VImage.new_from_buffer(bytes))
  defp open({:path, path}) when is_binary(path), do: wrap_open(VImage.new_from_file(path))
  defp open(_), do: {:error, :unreadable_image}

  defp wrap_open({:ok, %VImage{} = image}), do: {:ok, image}
  defp wrap_open(_), do: {:error, :unreadable_image}

  defp validate_dimensions(image) do
    width = VImage.width(image)
    height = VImage.height(image)

    if width >= @min_source_px and height >= @min_source_px do
      :ok
    else
      {:error, {:source_too_small, width, height}}
    end
  end

  defp parse_hex_colour("#" <> hex = value) when byte_size(hex) == 6 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<r, g, b>>} -> {:ok, [r, g, b]}
      :error -> {:error, {:invalid_colour, value}}
    end
  end

  defp parse_hex_colour(value), do: {:error, {:invalid_colour, value}}

  # ── ICO container ─────────────────────────────────────────────

  @doc """
  Wraps already-encoded PNG bytes in a single-entry ICO container.

  Public so the ICO header can be unit-tested against a known payload
  without running a full derivation.

  Layout (little-endian throughout, per the Windows `ICONDIR` /
  `ICONDIRENTRY` structures):

    * `ICONDIR` — reserved `0`, type `1` (icon, not cursor), image count.
    * `ICONDIRENTRY` — width and height as SINGLE BYTES, where `0` means
      256; colour count `0` (not paletted); reserved `0`; colour planes
      `1`; bits per pixel `32`; payload length; payload offset.

  The payload here is the PNG itself, which the format permits and every
  browser from IE11 on decodes.
  """
  @spec ico_from_png(binary(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def ico_from_png(png, size) when is_binary(png) and size in 1..256 do
    # A 256px side is encoded as the byte 0; nothing larger fits the field.
    dimension = if size == 256, do: 0, else: size
    offset = 6 + 16

    header =
      <<0::little-16, 1::little-16, 1::little-16, dimension::8, dimension::8, 0::8, 0::8,
        1::little-16, 32::little-16, byte_size(png)::little-32, offset::little-32>>

    {:ok, header <> png}
  end

  def ico_from_png(_png, size), do: {:error, {:invalid_ico_size, size}}
end
