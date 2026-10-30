defmodule Platform.Social.ClipCaptionPreviews do
  @moduledoc "Actual CLI renders of one authorized excerpt, never simulated caption motion."
  @manifest Path.expand(
              "../../../../../docs/integrations/clip-captions/preview-assets.json",
              __DIR__
            )
  @external_resource @manifest
  @metadata @manifest
            |> File.read!()
            |> Jason.decode!()
            |> Map.take(~w(version cli_version renderer_contract))

  def metadata, do: @metadata

  @styles [
    {"plain", "Plain", "A steady, readable caption"},
    {"phrase-pop", "Phrase pop", "Short phrases replace together"},
    {"karaoke", "Karaoke", "Text color follows each word"},
    {"type-on", "Type-on", "Words appear as they're spoken"},
    {"focus-word", "Focus word", "A soft pill follows each word"},
    {"editorial-punch", "Editorial punch", "Phrases rise, then hold"}
  ]

  def cards do
    Enum.map(@styles, fn {style, name, description} ->
      root = "/images/caption-previews/v1/#{style}"

      %{
        style: style,
        name: name,
        description: description,
        video: root <> ".mp4",
        frames: Enum.map(~w(entry mid hold), &{&1, root <> "-#{&1}.jpg"})
      }
    end)
  end

  def label(nil), do: "Existing render (style not recorded)"

  def label(style),
    do: Enum.find_value(@styles, style, fn {s, name, _} -> if s == style, do: name end)

  def version_label(render), do: label(get_in(render.look || %{}, ["cap", "style"]))
end
