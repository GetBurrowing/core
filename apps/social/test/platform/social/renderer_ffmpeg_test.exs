defmodule Platform.Social.RendererFfmpegTest do
  @moduledoc """
  The real ffmpeg renderer (Social 5/7), end to end on a generated fixture.
  Tagged `:ffmpeg`: `test/test_helper.exs` excludes it on a node whose
  ffmpeg lacks libass (CI's image has no ffmpeg at all).
  """
  use ExUnit.Case, async: false

  alias Platform.Social.{Brand, Renderer, Toolchain}

  @moduletag :ffmpeg
  @moduletag timeout: 300_000

  setup do
    dir = Path.join(System.tmp_dir!(), "social-render-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    source = Path.join(dir, "source.mp4")

    {_, 0} =
      System.cmd(
        Toolchain.ffmpeg_path(),
        ~w(-hide_banner -y -f lavfi -i testsrc2=s=1920x1080:r=30:d=6 -f lavfi -i sine=f=440:d=6
           -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest) ++ [source],
        stderr_to_stdout: true
      )

    %{dir: dir, source: source}
  end

  defp input(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        source_path: ctx.source,
        start_s: 1.0,
        end_s: 4.0,
        words: [
          %{w: "Three", start_s: 1.2, end_s: 2.0},
          %{w: "word", start_s: 2.0, end_s: 3.0},
          %{w: "clip.", start_s: 3.0, end_s: 3.9}
        ],
        brand: Brand.resolve(%{home_url: nil, brand: %{"handle" => "@show"}}),
        out_path: Path.join(ctx.dir, "out.mp4")
      },
      overrides
    )
  end

  test "renders 1s-4s as a 1080x1920 H.264+AAC clip of 3s plus the 2s card", ctx do
    assert {:ok, out} = Renderer.Ffmpeg.render(input(ctx))
    assert out.width == 1080 and out.height == 1920
    assert_in_delta out.duration_s, 5.0, 0.1
    assert out.byte_size == File.stat!(out.path).size
    # the per-render work directory (the ASS scripts) is removed
    assert Path.wildcard(Path.join(ctx.dir, "render-*")) == []

    {:ok, probe} = Renderer.Ffmpeg.probe(out.path)
    assert probe.video_codec == "h264"
    assert probe.audio_codec == "aac"
  end

  test "a clip ending past the source is refused with both numbers", ctx do
    assert {:error, msg} = Renderer.Ffmpeg.render(input(ctx, %{end_s: 25.0}))
    assert msg == "the clip ends at 25.0s but the source video is only 6.0s long"
    refute File.exists?(Path.join(ctx.dir, "out.mp4"))
  end

  test "an unreadable source is a readable error, not a raise", ctx do
    bad = Path.join(ctx.dir, "bad.mp4")
    File.write!(bad, "not a video")
    assert {:error, msg} = Renderer.Ffmpeg.render(input(ctx, %{source_path: bad}))
    assert is_binary(msg)
  end
end
