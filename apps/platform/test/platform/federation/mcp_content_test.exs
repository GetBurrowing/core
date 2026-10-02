defmodule Platform.Federation.McpContentTest do
  # async: false — several tests put_env :mcp_image_block_max_bytes.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Platform.Federation.McpContent

  # A real 1x1 RGBA PNG (68 bytes), generated with zlib + struct.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="
       )
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, "rest-of-jpeg">>
  @gif87 "GIF87a" <> <<1, 0, 1, 0, 0, 0, 0>>
  @gif89 "GIF89a" <> <<1, 0, 1, 0, 0, 0, 0>>
  @webp "RIFF" <> <<26, 0, 0, 0>> <> "WEBPVP8 " <> "payload"

  defp result_for(content_type, bytes) do
    %{
      content_type: content_type,
      byte_size: byte_size(bytes),
      data_base64: Base.encode64(bytes),
      filename: "f"
    }
  end

  defp offer(content_type, bytes) do
    content_type |> result_for(bytes) |> McpContent.offer_image(:data_base64, bytes)
  end

  defp with_cap(cap) do
    previous = Application.fetch_env(:platform, :mcp_image_block_max_bytes)
    Application.put_env(:platform, :mcp_image_block_max_bytes, cap)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :mcp_image_block_max_bytes, value)
        :error -> Application.delete_env(:platform, :mcp_image_block_max_bytes)
      end
    end)
  end

  describe "offer_image/3 — allowlisted magic" do
    for {label, bytes, declared, mime} <- [
          {"PNG", Macro.escape(@png), "image/png", "image/png"},
          {"JPEG", Macro.escape(@jpeg), "image/jpeg", "image/jpeg"},
          {"GIF87a", Macro.escape(@gif87), "image/gif", "image/gif"},
          {"GIF89a", Macro.escape(@gif89), "image/gif", "image/gif"},
          {"WebP", Macro.escape(@webp), "image/webp", "image/webp"}
        ] do
      test "#{label} gets the marker with the sniffed mime" do
        bytes = unquote(bytes)
        result = offer(unquote(declared), bytes)

        assert result[McpContent.marker_key()] == %{
                 field: :data_base64,
                 mime_type: unquote(mime)
               }

        refute Map.has_key?(result, :image_block_skipped)
        # The base64 stays for in-process callers.
        assert Base.decode64!(result.data_base64) == bytes
      end
    end

    test "the sniffed type wins over the declared content_type" do
      result = offer("image/png", @jpeg)
      assert result[McpContent.marker_key()].mime_type == "image/jpeg"
    end

    test "declared type is matched case-insensitively and ignores parameters" do
      result = offer("IMAGE/PNG; charset=binary", @png)
      assert result[McpContent.marker_key()].mime_type == "image/png"
    end
  end

  describe "offer_image/3 — declared image, not eligible" do
    test "image/svg+xml is skipped with a reason" do
      svg = ~s(<svg xmlns="http://www.w3.org/2000/svg"/>)
      result = offer("image/svg+xml", svg)

      refute Map.has_key?(result, McpContent.marker_key())
      assert result.image_block_skipped =~ "image/svg+xml"
      assert Base.decode64!(result.data_base64) == svg
    end

    test "garbage bytes declared image/png are skipped with a reason" do
      result = offer("image/png", "not a png")

      refute Map.has_key?(result, McpContent.marker_key())
      assert result.image_block_skipped =~ "not PNG, JPEG, GIF or WebP"
    end
  end

  describe "offer_image/3 — size cap" do
    test "defaults to 3,750,000 bytes" do
      with_cap(:unused)
      Application.delete_env(:platform, :mcp_image_block_max_bytes)
      assert McpContent.image_block_max_bytes() == 3_750_000
      # 3,750,000 raw bytes is exactly 5,000,000 base64 chars.
      assert div(3_750_000, 3) * 4 == 5_000_000
    end

    test "exactly at the cap is eligible" do
      with_cap(byte_size(@png))
      result = offer("image/png", @png)

      assert result[McpContent.marker_key()].mime_type == "image/png"
      refute Map.has_key?(result, :image_block_skipped)
    end

    test "one byte over the cap is skipped, naming size and cap" do
      cap = byte_size(@png) - 1
      with_cap(cap)
      result = offer("image/png", @png)

      refute Map.has_key?(result, McpContent.marker_key())
      assert result.image_block_skipped =~ "#{byte_size(@png)} bytes"
      assert result.image_block_skipped =~ "#{cap}-byte"
    end
  end

  describe "offer_image/3 — non-image content types" do
    # Positive control: the SAME PNG bytes under non-image declared types
    # must leave the map exactly as it came in. If offer_image keyed on
    # the sniff alone, these would gain the marker and fail.
    for content_type <- ["application/pdf", "text/plain", "application/octet-stream"] do
      test "#{content_type} is returned unchanged (full-map equality)" do
        input = result_for(unquote(content_type), @png)
        assert McpContent.offer_image(input, :data_base64, @png) == input
      end
    end

    test "a nil content_type is returned unchanged" do
      input = result_for(nil, @png)
      assert McpContent.offer_image(input, :data_base64, @png) == input
    end
  end

  describe "split/1" do
    test "lifts the marked field out of a well-formed result" do
      result = offer("image/png", @png)
      b64 = Base.encode64(@png)

      assert {:image, rest, ^b64, "image/png"} = McpContent.split(result)
      assert rest == %{content_type: "image/png", byte_size: byte_size(@png), filename: "f"}
    end

    test "a result without the marker passes through unchanged" do
      input = result_for("application/pdf", "pdf")
      assert McpContent.split(input) == {:none, input}
    end

    test "non-maps pass through" do
      assert McpContent.split("text") == {:none, "text"}
      assert McpContent.split([1, 2]) == {:none, [1, 2]}
    end

    for {label, marker, extra} <- [
          {"marker is not a map", "oops", %{}},
          {"field is absent from the result", %{field: :missing, mime_type: "image/png"}, %{}},
          {"field value is not binary", %{field: :blob, mime_type: "image/png"}, %{blob: 42}},
          {"mime_type is missing", %{field: :data_base64}, %{}}
        ] do
      test "malformed marker (#{label}) is dropped with a warning, never raises" do
        input =
          "image/png"
          |> result_for(@png)
          |> Map.merge(unquote(Macro.escape(extra)))
          |> Map.put(McpContent.marker_key(), unquote(Macro.escape(marker)))

        log =
          capture_log(fn ->
            assert {:none, rest} = McpContent.split(input)
            send(self(), {:rest, rest})
          end)

        assert_received {:rest, rest}
        assert rest == Map.delete(input, McpContent.marker_key())
        assert log =~ "malformed"
      end
    end
  end

  describe "strip/1" do
    test "removes the marker and keeps everything else" do
      result = offer("image/png", @png)
      assert McpContent.strip(result) == result_for("image/png", @png)
    end

    test "non-maps pass through" do
      assert McpContent.strip(nil) == nil
      assert McpContent.strip("x") == "x"
    end
  end
end
