defmodule Platform.Social.SourcesTest do
  @moduledoc """
  Clip sources (Social 5/7): the Files source end to end through core's
  Files API; YouTube through stub yt-dlp scripts (never the network); the
  deferred meeting-recording source's refusal.
  """
  use Platform.DataCase, async: false

  import Platform.SocialFixtures

  alias Platform.Social.Source

  setup do
    saved = Application.get_env(:social, :yt_dlp_path)
    dir = Path.join(System.tmp_dir!(), "social-sources-#{unique()}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)

      if saved,
        do: Application.put_env(:social, :yt_dlp_path, saved),
        else: Application.delete_env(:social, :yt_dlp_path)
    end)

    %{dir: dir}
  end

  defp stub!(dir, body) do
    path = Path.join(dir, "yt-dlp-stub")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  describe "Source.File" do
    test "copies the video out of Files and parses the transcript", ctx do
      world = render_world!(video_bytes: "the video bytes #{unique()}")
      clip = file_clip!(world, 4.0, 12.0)
      assert Source.for_clip(clip) == Source.File

      work = Path.join(ctx.dir, "job")
      File.mkdir_p!(work)

      assert {:ok, %{video_path: path, segments: segments, offset_s: +0.0}} =
               Source.File.fetch(clip, world.profile, work)

      assert File.read!(path) =~ "the video bytes"
      assert Path.extname(path) == ".mp4"
      assert length(segments) == 5
      assert hd(segments).text == "Welcome back to the show everyone."
    end

    test "a file outside the profile's project is refused by name", ctx do
      world = render_world!()
      clip = file_clip!(world, 4.0, 12.0)
      elsewhere = project!(world.org_id)

      other =
        stored_file!(elsewhere, "WEBVTT\n\n00:00.000 --> 00:01.000\nhi\n", "t.vtt", "text/vtt")

      assert {:error, "the transcript is not in the profile's project"} =
               Source.File.fetch(%{clip | transcript_file_id: other.id}, world.profile, ctx.dir)
    end

    test "a transcript of an unsupported type is refused readably", ctx do
      world = render_world!()
      txt = stored_file!(world.project, "plain words #{unique()}", "notes.txt", "text/plain")
      clip = file_clip!(world, 4.0, 12.0)

      assert {:error, msg} =
               Source.File.fetch(%{clip | transcript_file_id: txt.id}, world.profile, ctx.dir)

      assert msg =~ "VTT, SRT or JSON"
    end
  end

  describe "Source.YouTube" do
    defp yt_clip,
      do: %{
        source_url: "https://www.youtube.com/watch?v=abc",
        requested_start_s: 30.0,
        requested_end_s: 90.0,
        start_s: 30.0,
        end_s: 90.0
      }

    test "missing yt-dlp", ctx do
      Application.put_env(:social, :yt_dlp_path, Path.join(ctx.dir, "nope"))

      assert {:error, "yt-dlp is not installed on this node"} =
               Source.YouTube.fetch(yt_clip(), %{}, ctx.dir)
    end

    test "a bot check reads as YouTube refusing the node", ctx do
      stub =
        stub!(
          ctx.dir,
          "echo \"ERROR: [youtube] abc: Sign in to confirm you're not a bot.\" >&2; exit 1"
        )

      Application.put_env(:social, :yt_dlp_path, stub)

      assert {:error,
              "YouTube refused this node (bot check); upload the video and transcript to Files and use a file source"} =
               Source.YouTube.fetch(yt_clip(), %{}, ctx.dir)
    end

    test "passes the section, subtitle and extractor arguments; reads the downloaded files",
         ctx do
      args_file = Path.join(ctx.dir, "args.txt")
      vtt = "WEBVTT\n\n00:00:26.000 --> 00:00:31.000\nHello there friends.\n"
      File.write!(Path.join(ctx.dir, "fixture.vtt"), vtt)

      stub =
        stub!(ctx.dir, """
        printf '%s\\n' "$@" > #{args_file}
        out=""
        while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; fi; shift; done
        base=$(dirname "$out")
        echo video > "$base/source.mp4"
        cp #{Path.join(ctx.dir, "fixture.vtt")} "$base/source.en.vtt"
        """)

      Application.put_env(:social, :yt_dlp_path, stub)
      work = Path.join(ctx.dir, "job")
      File.mkdir_p!(work)

      assert {:ok, %{video_path: video, segments: [seg], offset_s: 25.0}} =
               Source.YouTube.fetch(yt_clip(), %{}, work)

      assert Path.basename(video) == "source.mp4"
      assert seg.text == "Hello there friends."

      args = File.read!(args_file)
      assert args =~ "*25.00-95.00"
      assert args =~ "--write-auto-subs"
      assert args =~ "youtube:player_client=android"
      assert args =~ "bv*[height<=1080]+ba/b[height<=1080]"
    end

    test "no subtitles is a readable error", ctx do
      stub =
        stub!(ctx.dir, """
        out=""
        while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; fi; shift; done
        echo video > "$(dirname "$out")/source.mp4"
        """)

      Application.put_env(:social, :yt_dlp_path, stub)

      assert {:error, msg} = Source.YouTube.fetch(yt_clip(), %{}, ctx.dir)
      assert msg =~ "no English subtitles"
    end
  end

  test "meeting recordings are deferred with a readable refusal" do
    assert {:error, msg} = Source.MeetingRecording.fetch(%{}, %{}, "/tmp")
    assert msg =~ "meeting recordings are not a clip source yet"
    assert msg =~ "use it as a file source"
  end
end
