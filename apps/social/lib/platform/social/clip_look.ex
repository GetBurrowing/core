defmodule Platform.Social.ClipLook do
  @moduledoc """
  A clip's look in Clip Studio (task 01a16661-e234, Clip Studio 1/9): caption
  style, hook title, outro, music and reframe, as the studio edits them.

  A look is a string-keyed map. `default/0` is the show default the studio
  prototype ships (prototype 01a16628 v2, app.js `SHOW_DEFAULT`). A profile
  stores its own default in `show_look` and a clip stores its look in
  `look`; both may be partial (or `%{}`), and `effective/1` deep-merges one
  over `default/0`.

  Burrow does not render a studio look itself: the clip runner drives
  htc-clip-tool, whose profile keys differ. `delta/2` gives the leaves a
  look changes against a base, and `to_clip_overrides/1` translates such a
  delta into clip profile keys (`"mapped"`) plus the studio keys clip has
  no equivalent for (`"unmapped"`), which the runner reports rather than
  inventing a key.

  ## Studio key to clip profile key

  Read from htc-clip-tool 5896057 (clip 0.9.0):
  `clip-agent/src/clip_agent/config.py` `CaptionConfig`, `ReframeConfig`,
  `AudioConfig`; `captions.py` `HOOK_TITLE_FONT`; and
  `profiles/how-to-computer.toml`, which extends `podcast`. MusicConfig is verified
  from upstream 82ef513; older installs with the same 0.9.0 version lack it, so the
  canonical runner checks the music.enabled configuration contract before use.

  | studio key    | clip profile key | translation |
  |---------------|------------------|-------------|
  | cap.preset    | captions.preset | same values (legacy visual presets) |
  | cap.style     | captions.style | plain, phrase-pop or karaoke; an explicit finalize --captions overrides saved process-time style |
  | cap.font      | captions.font | Anton -> Anton-Regular.ttf; Inter SemiBold -> Inter-SemiBold.ttf. PARTIAL: Inter Black and Georgia Bold are not bundled (fonts/ holds only Anton-Regular and Inter-SemiBold), so they go in unmapped |
  | cap.size      | captions.size_frac | size / 100 (5.8 -> 0.058, the HTC value) |
  | cap.color     | captions.primary_color | hex |
  | cap.outline   | captions.stroke_frac | false -> 0.0; true -> leave the profile's value (HTC 0.006). PARTIAL: no boolean key, so a true in a delta is listed in unmapped |
  | cap.hl        | captions.highlight_color | hex. PARTIAL: 'none' has no equivalent, so it goes in unmapped |
  | cap.vpos      | captions.vpos | same |
  | title.secs    | captions.hook_title_seconds (+ captions.hook_title = true) | seconds |
  | title.font    | NO EQUIVALENT | hook title font is the constant HOOK_TITLE_FONT |
  | title.size    | NO EQUIVALENT | |
  | title.box     | NO EQUIVALENT | captions.bg_box is for captions, not the hook title |
  | title.twoLine | NO EQUIVALENT | |
  | outro         | NO EQUIVALENT | no end card or outro key in clip 0.9.0 |
  | music_track.file_id | music.path | project-owned Files id resolved privately by the runner into a disposable local download |
  | music_track.gain_db | music.level_db | -60..0 dB background gain, independent of speech loudness |
  | music_track.muted | music.enabled | inverted; retains selected asset and gain while muted |
  | music (legacy boolean) | NO EQUIVALENT | kept only to read historical looks; never implies an audio asset |
  | level (legacy) | NO EQUIVALENT | historical field only; audio.target_lufs is speech delivery loudness, never music gain |
  | reframe       | reframe.mode | shots -> shots, splits -> split, fit -> fit |
  | cutaways      | NO EQUIVALENT | |
  """

  @presets ~w(bold-pop podcast-clean speaker-color)
  @styles ~w(plain phrase-pop karaoke subtle)
  @templates ~w(legacy chrome-hook neon-broadcast arcade-punch)
  @fonts ["Anton", "Inter Black", "Inter SemiBold", "Georgia Bold"]
  @reframes ~w(shots splits fit)

  @default %{
    "cap" => %{
      "preset" => "bold-pop",
      "font" => "Anton",
      "size" => 5.8,
      "color" => "#FFFFFF",
      "outline" => true,
      "hl" => "#FFE000",
      "vpos" => 0.66
    },
    "title" => %{
      "font" => "Anton",
      "size" => 24,
      "box" => false,
      "twoLine" => true,
      "secs" => 3.0
    },
    "outro" => true,
    "music" => true,
    "level" => -18,
    "reframe" => "shots",
    "cutaways" => true
  }

  @clip_fonts %{"Anton" => "Anton-Regular.ttf", "Inter SemiBold" => "Inter-SemiBold.ttf"}
  @clip_reframes %{"shots" => "shots", "splits" => "split", "fit" => "fit"}
  @no_equivalent ~w(title.font title.size title.box title.twoLine outro music level cutaways)

  @type look :: %{optional(String.t()) => term()}

  @doc "The show default: prototype 01a16628 v2 `SHOW_DEFAULT`, string keys."
  @spec default() :: look()
  def default, do: @default

  @doc "Accepted caption presets."
  @spec presets() :: [String.t()]
  def presets, do: @presets

  @doc "Renderer-supported caption styles; independent of legacy visual presets."
  def styles, do: @styles

  def headline_templates, do: @templates

  @doc "Explicit opt-in show defaults. Existing and queued clip looks are never rewritten."
  def chrome_hook_defaults(look \\ %{}) do
    look =
      Map.put(
        look || %{},
        "title",
        Map.drop((look || %{})["title"] || %{}, ~w(emphasis emphasis_text))
      )

    merge(look, %{
      "title" => %{"template" => "chrome-hook", "enabled" => true, "secs" => 3.5},
      "cap" => %{"style" => "subtle"}
    })
  end

  def caption_style(look), do: get_in(look || %{}, ["cap", "style"]) || "phrase-pop"

  @doc "Accepted fonts (caption and title)."
  @spec fonts() :: [String.t()]
  def fonts, do: @fonts

  @doc """
  Checks a (possibly partial) look. Unknown keys and bad values are refused.
  Atom keys are accepted and returned as strings.

  Returns `{:ok, look}` or `{:error, [message]}`.
  """
  @spec validate(term()) :: {:ok, look()} | {:error, [String.t()]}
  def validate(look) when is_map(look) do
    look = stringify(look)

    errors =
      Enum.flat_map(look, fn
        {"cap", cap} -> section("cap", cap, &cap_error/2)
        {"title", title} -> section("title", title, &title_error/2)
        {"music_track", track} -> section("music_track", track, &music_error/2)
        {key, value} -> List.wrap(top_error(key, value))
      end)

    case errors do
      [] -> {:ok, look}
      errors -> {:error, errors}
    end
  end

  def validate(_), do: {:error, ["a look must be a map"]}

  defp section(name, value, check) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> check.(k, v) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&"#{name}.#{&1}")
  end

  defp section(name, _value, _check), do: ["#{name} must be a map"]

  defp cap_error("preset", v),
    do: unless(v in @presets, do: "preset must be one of #{list(@presets)}")

  defp cap_error("style", v),
    do: unless(v in @styles, do: "style must be one of #{list(@styles)}")

  defp cap_error("font", v), do: font_error(v)

  defp cap_error("size", v),
    do: unless(num?(v) and v > 0 and v <= 20, do: "size must be > 0 and <= 20")

  defp cap_error("color", v), do: unless(hex?(v), do: "color must be #RRGGBB")
  defp cap_error("outline", v), do: bool_error("outline", v)
  defp cap_error("hl", v), do: unless(hex?(v) or v == "none", do: "hl must be #RRGGBB or none")

  defp cap_error("vpos", v),
    do: unless(num?(v) and v > 0 and v < 1, do: "vpos must be between 0 and 1")

  defp cap_error(k, _), do: "#{k} is not a look key"

  defp title_error("template", v),
    do: unless(v in @templates, do: "template is unsupported")

  defp title_error("enabled", v), do: bool_error("enabled", v)

  defp title_error("emphasis", v),
    do:
      unless(
        is_list(v) and length(v) <= 100 and Enum.all?(v, &(is_integer(&1) and &1 >= 0)) and
          length(Enum.uniq(v)) == length(v),
        do: "emphasis must be unique nonnegative word positions"
      )

  defp title_error("emphasis_text", v),
    do:
      unless(is_binary(v) and String.length(v) <= 500,
        do: "emphasis_text must be at most 500 characters"
      )

  defp title_error("font", v), do: font_error(v)

  defp title_error("size", v),
    do: unless(num?(v) and v > 0 and v <= 200, do: "size must be > 0 and <= 200")

  defp title_error("box", v), do: bool_error("box", v)
  defp title_error("twoLine", v), do: bool_error("twoLine", v)

  defp title_error("secs", v),
    do: unless(num?(v) and v >= 0 and v <= 600, do: "secs must be 0..600")

  defp title_error(k, _), do: "#{k} is not a look key"

  defp music_error("file_id", nil), do: nil

  defp music_error("file_id", v),
    do: unless(Platform.UUID.valid?(v), do: "file_id must be a UUID or nil")

  defp music_error("gain_db", v),
    do: unless(num?(v) and v >= -60 and v <= 0, do: "gain_db must be -60..0")

  defp music_error("muted", v), do: bool_error("muted", v)
  defp music_error(k, _), do: "#{k} is not a music key"

  defp top_error(k, v) when k in ~w(outro music cutaways), do: bool_error(k, v)

  defp top_error("level", v),
    do: unless(num?(v) and v >= -30 and v <= -6, do: "level must be -30..-6")

  defp top_error("reframe", v),
    do: unless(v in @reframes, do: "reframe must be one of #{list(@reframes)}")

  defp top_error(k, _), do: "#{k} is not a look key"

  defp font_error(v), do: unless(v in @fonts, do: "font must be one of #{list(@fonts)}")
  defp bool_error(k, v), do: unless(is_boolean(v), do: "#{k} must be true or false")

  defp num?(v), do: is_number(v)
  defp hex?(v), do: is_binary(v) and Regex.match?(~r/\A#[0-9A-Fa-f]{6}\z/, v)
  defp list(values), do: Enum.join(values, ", ")

  @doc "Deep-merges a stored look (nil or `%{}` allowed) over `default/0`."
  @spec effective(look() | nil) :: look()
  def effective(nil), do: @default
  def effective(look) when is_map(look), do: deep_merge(@default, stringify(look))

  @doc "Deep-merges `over` onto `base` (either may be nil or partial)."
  @spec merge(look() | nil, look() | nil) :: look()
  def merge(base, over), do: deep_merge(stringify(base || %{}), stringify(over || %{}))

  defp deep_merge(base, over) do
    Map.merge(base, over, fn
      _k, %{} = b, %{} = o -> deep_merge(b, o)
      _k, _b, o -> o
    end)
  end

  @doc """
  The leaves of `look` that differ from `base`, as a nested map. Numbers
  compare by value (24 == 24.0). Identical looks give `%{}`.
  """
  @spec delta(look() | nil, look() | nil) :: look()
  def delta(look, base) do
    look = stringify(look || %{})
    base = stringify(base || %{})

    Enum.reduce(look, %{}, fn {key, value}, acc ->
      case {value, Map.get(base, key)} do
        {%{} = v, %{} = b} ->
          case delta(v, b) do
            empty when empty == %{} -> acc
            d -> Map.put(acc, key, d)
          end

        {v, b} ->
          if Map.has_key?(base, key) and v == b, do: acc, else: Map.put(acc, key, v)
      end
    end)
  end

  @doc """
  Translates a delta into clip profile overrides:
  `%{"mapped" => %{"captions.size_frac" => 0.07, ...}, "unmapped" => ["outro", ...]}`.
  See the moduledoc's table. `unmapped` is sorted.
  """
  @spec to_clip_overrides(look() | nil) :: %{String.t() => term()}
  def to_clip_overrides(delta) do
    {mapped, unmapped} =
      delta
      |> Kernel.||(%{})
      |> stringify()
      |> leaves([])
      |> Enum.reduce({%{}, []}, fn {path, value}, {mapped, unmapped} ->
        case translate(path, value) do
          {:mapped, pairs} -> {Map.merge(mapped, Map.new(pairs)), unmapped}
          :unmapped -> {mapped, [path | unmapped]}
        end
      end)

    mapped =
      case get_in(delta || %{}, ["title", "enabled"]) do
        enabled when is_boolean(enabled) -> Map.put(mapped, "captions.hook_title", enabled)
        _ -> mapped
      end

    %{"mapped" => mapped, "unmapped" => Enum.sort(unmapped)}
  end

  defp leaves(map, prefix) do
    Enum.flat_map(map, fn
      {k, %{} = v} -> leaves(v, prefix ++ [k])
      {k, v} -> [{Enum.join(prefix ++ [k], "."), v}]
    end)
  end

  # Music is resolved as a complete asset contract in ClipJobs.payload, never
  # imported into a persistent show profile with a disposable local path.
  defp translate("music_track.file_id", _), do: {:mapped, []}
  defp translate("music_track.gain_db", _), do: {:mapped, []}
  defp translate("music_track.muted", _), do: {:mapped, []}

  defp translate("cap.style", v), do: {:mapped, [{"captions.style", v}]}

  defp translate("cap.preset", v), do: {:mapped, [{"captions.preset", v}]}

  defp translate("cap.font", v) do
    case Map.fetch(@clip_fonts, v) do
      {:ok, file} -> {:mapped, [{"captions.font", file}]}
      :error -> :unmapped
    end
  end

  defp translate("cap.size", v) when is_number(v),
    do: {:mapped, [{"captions.size_frac", Float.round(v / 100, 6)}]}

  defp translate("cap.color", v), do: {:mapped, [{"captions.primary_color", v}]}
  defp translate("cap.outline", false), do: {:mapped, [{"captions.stroke_frac", 0.0}]}
  defp translate("cap.hl", "none"), do: :unmapped
  defp translate("cap.hl", v), do: {:mapped, [{"captions.highlight_color", v}]}
  defp translate("cap.vpos", v), do: {:mapped, [{"captions.vpos", v}]}

  defp translate("title.template", _), do: {:mapped, []}
  defp translate("title.enabled", v), do: {:mapped, [{"captions.hook_title", v}]}
  defp translate("title.emphasis", _), do: {:mapped, []}
  defp translate("title.emphasis_text", _), do: {:mapped, []}

  defp translate("title.secs", v),
    do: {:mapped, [{"captions.hook_title_seconds", v}, {"captions.hook_title", true}]}

  defp translate("reframe", v) do
    case Map.fetch(@clip_reframes, v) do
      {:ok, mode} -> {:mapped, [{"reframe.mode", mode}]}
      :error -> :unmapped
    end
  end

  defp translate(path, _v) when path in @no_equivalent, do: :unmapped
  defp translate(_path, _v), do: :unmapped

  defp stringify(%{} = map) when not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(other), do: other
end
