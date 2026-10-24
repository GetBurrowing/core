defmodule Platform.Social.CoverImage do
  @moduledoc """
  The pixel size of an uploaded cover image (task 01a165ec stage 4), read
  from the PNG or JPEG header, so the picker can say "Instagram will crop
  this to 9:16" for an image of another shape. Advisory only: an image whose
  size cannot be read is never refused here (the one cover rule,
  `Platform.Social.Cover`, decides what is accepted).
  """

  @doc "`{width, height}` from PNG or JPEG bytes, or nil."
  @spec dimensions(binary()) :: {pos_integer(), pos_integer()} | nil
  def dimensions(
        <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _len::32, "IHDR", w::32, h::32, _::binary>>
      )
      when w > 0 and h > 0,
      do: {w, h}

  def dimensions(<<0xFF, 0xD8, rest::binary>>), do: jpeg(rest)
  def dimensions(_bytes), do: nil

  @doc """
  Whether the image is 9:16 (within 1%). An unreadable size answers true,
  so no crop note is shown on a guess.
  """
  @spec nine_sixteen?(binary()) :: boolean()
  def nine_sixteen?(bytes) do
    case dimensions(bytes) do
      {w, h} -> abs(w / h - 9 / 16) <= 0.01 * (9 / 16)
      nil -> true
    end
  end

  # Walk the JPEG segments to the first start-of-frame (SOF0..SOF15, not
  # DHT C4, JPG C8 or DAC CC), whose payload carries height then width.
  defp jpeg(<<0xFF, marker, _len::16, _p, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC] and w > 0 and h > 0,
       do: {w, h}

  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  defp jpeg(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD9 or marker == 0x01,
    do: jpeg(rest)

  defp jpeg(<<0xFF, _marker, len::16, rest::binary>>) when len >= 2 do
    skip = len - 2

    case rest do
      <<_::binary-size(^skip), tail::binary>> -> jpeg(tail)
      _ -> nil
    end
  end

  defp jpeg(_), do: nil
end
