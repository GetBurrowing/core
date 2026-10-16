defmodule Platform.Social.ToolchainTest do
  @moduledoc """
  `Platform.Social.Toolchain` (Social 5/7): a missing binary and an ffmpeg
  without libass each give the readable error the clip row will carry.
  Stubs are shell scripts in a tmp dir; config is restored after each test.
  """
  use ExUnit.Case, async: false

  alias Platform.Social.{Renderer, Toolchain}

  @keys [:ffmpeg_path, :ffprobe_path, :yt_dlp_path]

  setup do
    saved = Enum.map(@keys, &{&1, Application.get_env(:social, &1)})
    dir = Path.join(System.tmp_dir!(), "social-toolchain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      Enum.each(saved, fn
        {k, nil} -> Application.delete_env(:social, k)
        {k, v} -> Application.put_env(:social, k, v)
      end)
    end)

    %{dir: dir}
  end

  defp stub!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  @filters_without_libass """
  Filters:
   T.. = Timeline support
   ... aformat           A->A       Convert the input audio to one of the specified formats.
   ... scale             V->V       Scale the input video size and/or convert the image format.
   ... crop              V->V       Crop the input video.
  """

  @filters_with_libass @filters_without_libass <>
                         " ... ass               V->V       Render ASS subtitles onto input video using the libass library.\n" <>
                         " ... subtitles         V->V       Render text subtitles onto input video using the libass library.\n"

  test "a configured path that does not exist reads as not found", %{dir: dir} do
    Application.put_env(:social, :ffmpeg_path, Path.join(dir, "no-such-ffmpeg"))
    assert Toolchain.ffmpeg_path() == nil
    assert {:error, "ffmpeg not found on this node"} = Toolchain.fetch(:ffmpeg)
    assert {:error, "ffmpeg not found on this node"} = Toolchain.probe()
    assert {:error, "ffmpeg not found on this node"} = Toolchain.capabilities()

    Application.put_env(:social, :yt_dlp_path, Path.join(dir, "nope"))
    assert {:error, "yt-dlp is not installed on this node"} = Toolchain.fetch(:yt_dlp)
  end

  test "an ffmpeg whose filter list has no subtitles filter gives the libass error", %{dir: dir} do
    filters = Path.join(dir, "filters.txt")
    File.write!(filters, @filters_without_libass)
    Application.put_env(:social, :ffmpeg_path, stub!(dir, "ffmpeg", "cat #{filters}"))
    Application.put_env(:social, :ffprobe_path, stub!(dir, "ffprobe", "exit 0"))

    assert {:error,
            "ffmpeg on this node lacks libass (no subtitles filter); captions cannot be burned in"} =
             Toolchain.probe()

    # the renderer's preflight reports the same, and render/1 fails cleanly
    assert {:error, msg} =
             Renderer.Ffmpeg.render(%{
               source_path: Path.join(dir, "x.mp4"),
               start_s: 0.0,
               end_s: 1.0,
               words: [],
               out_path: Path.join(dir, "out.mp4")
             })

    assert msg =~ "lacks libass"
  end

  test "an ffmpeg with libass and the bundled font passes", %{dir: dir} do
    filters = Path.join(dir, "filters.txt")
    File.write!(filters, @filters_with_libass)
    Application.put_env(:social, :ffmpeg_path, stub!(dir, "ffmpeg", "cat #{filters}"))
    Application.put_env(:social, :ffprobe_path, stub!(dir, "ffprobe", "exit 0"))
    assert :ok = Toolchain.probe()
  end

  test "an ffmpeg that fails to list filters is a readable error", %{dir: dir} do
    Application.put_env(:social, :ffmpeg_path, stub!(dir, "ffmpeg", "echo boom >&2; exit 3"))
    Application.put_env(:social, :ffprobe_path, stub!(dir, "ffprobe", "exit 0"))
    assert {:error, "ffmpeg on this node failed to list its filters"} = Toolchain.probe()
  end

  test "the bundled caption font and its licence ship in priv/fonts" do
    assert File.regular?(Path.join(Platform.Social.Brand.fonts_dir(), "PublicSans-Black.ttf"))

    assert File.read!(Application.app_dir(:social, "priv/font_licenses/PublicSans-OFL.txt")) =~
             "SIL Open Font License"
  end

  test "the renderer is chosen by config, read on every call" do
    saved = Application.get_env(:social, :renderer)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:social, :renderer, saved),
        else: Application.delete_env(:social, :renderer)
    end)

    Application.delete_env(:social, :renderer)
    assert Renderer.impl() == Renderer.Ffmpeg
    Application.put_env(:social, :renderer, Renderer.Fake)
    assert Renderer.impl() == Renderer.Fake
  end
end
