defmodule Platform.Social.Toolchain do
  @moduledoc """
  Where the clip pipeline's external binaries are, and whether this node can
  burn captions (task 01a140a9-69b7, Social 5/7).

  Each path is `config :social, :ffmpeg_path | :ffprobe_path | :yt_dlp_path`
  when set, else the `SOCIAL_FFMPEG_PATH` / `SOCIAL_FFPROBE_PATH` /
  `SOCIAL_YT_DLP_PATH` environment variable (read here, at runtime, as ADR
  0055 § 8 has a module do for its own settings), else
  `System.find_executable/1` (core's precedent:
  `Platform.Tasks.AutoMerger`'s `gh` guard). Config is read on every call, so
  a test can point a path at a stub.

  `capabilities/0` is `:ok` only when ffmpeg and ffprobe run, ffmpeg's
  `-filters` list has `subtitles` and `ass` (libass; Homebrew's default
  formula is built without it), and the bundled caption font exists. The
  probe result is cached per boot in `:persistent_term`, keyed by the
  configured paths, so changing a path re-probes.

  Errors are plain English for the clip row's `error`:
  "ffmpeg not found on this node", "ffmpeg on this node lacks libass (no
  subtitles filter); captions cannot be burned in".
  """

  alias Platform.Social.Brand

  @probe_timeout_ms 15_000

  @doc "The ffmpeg path, or nil."
  @spec ffmpeg_path() :: String.t() | nil
  def ffmpeg_path, do: path(:ffmpeg_path, "SOCIAL_FFMPEG_PATH", "ffmpeg")

  @doc "The ffprobe path, or nil."
  @spec ffprobe_path() :: String.t() | nil
  def ffprobe_path, do: path(:ffprobe_path, "SOCIAL_FFPROBE_PATH", "ffprobe")

  @doc "The yt-dlp path, or nil."
  @spec yt_dlp_path() :: String.t() | nil
  def yt_dlp_path, do: path(:yt_dlp_path, "SOCIAL_YT_DLP_PATH", "yt-dlp")

  # A configured path must exist and be a file; a missing one reads as "not
  # found" rather than falling back to PATH, so a bad config is visible.
  defp path(key, env, name) do
    case Application.get_env(:social, key) || System.get_env(env) do
      nil -> System.find_executable(name)
      "" -> System.find_executable(name)
      configured -> if File.regular?(configured), do: configured, else: nil
    end
  end

  @doc "`{:ok, path}` or `{:error, \"<name> not found on this node\"}`."
  @spec fetch(:ffmpeg | :ffprobe | :yt_dlp) :: {:ok, String.t()} | {:error, String.t()}
  def fetch(:ffmpeg), do: found(ffmpeg_path(), "ffmpeg not found on this node")
  def fetch(:ffprobe), do: found(ffprobe_path(), "ffprobe not found on this node")
  def fetch(:yt_dlp), do: found(yt_dlp_path(), "yt-dlp is not installed on this node")

  defp found(nil, message), do: {:error, message}
  defp found(path, _message), do: {:ok, path}

  @doc """
  `:ok` when this node can render captioned clips, else `{:error, readable}`.
  Cached per boot per configured path set.
  """
  @spec capabilities() :: :ok | {:error, String.t()}
  def capabilities do
    key = {__MODULE__, :capabilities, ffmpeg_path(), ffprobe_path(), font_path()}

    case :persistent_term.get(key, :unprobed) do
      :unprobed ->
        result = probe()
        :persistent_term.put(key, result)
        result

      result ->
        result
    end
  end

  @doc "Probes without the cache."
  @spec probe() :: :ok | {:error, String.t()}
  def probe do
    with {:ok, ffmpeg} <- fetch(:ffmpeg),
         {:ok, _ffprobe} <- fetch(:ffprobe),
         {:ok, filters} <- filters(ffmpeg),
         :ok <- libass(filters) do
      font()
    end
  end

  defp filters(ffmpeg) do
    task = Task.async(fn -> safe_cmd(ffmpeg, ["-hide_banner", "-filters"]) end)

    case Task.yield(task, @probe_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, out}
      {:ok, {_out, :enoent}} -> {:error, "ffmpeg not found on this node"}
      {:ok, {_out, _status}} -> {:error, "ffmpeg on this node failed to list its filters"}
      _ -> {:error, "ffmpeg on this node did not answer within #{div(@probe_timeout_ms, 1000)}s"}
    end
  end

  defp safe_cmd(cmd, args) do
    System.cmd(cmd, args, stderr_to_stdout: true)
  rescue
    _ -> {"", :enoent}
  end

  defp libass(filters) do
    names =
      filters
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case String.split(line, ~r/\s+/, trim: true) do
          [_flags, name | _] -> [name]
          _ -> []
        end
      end)

    if "subtitles" in names and "ass" in names,
      do: :ok,
      else:
        {:error,
         "ffmpeg on this node lacks libass (no subtitles filter); captions cannot be burned in"}
  end

  defp font do
    if File.regular?(font_path()),
      do: :ok,
      else: {:error, "the caption font #{Path.basename(font_path())} is missing from this build"}
  end

  defp font_path do
    font = Brand.defaults()["font"]
    Path.join(Brand.fonts_dir(), Brand.font_file(font))
  end
end
