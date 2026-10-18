defmodule Platform.Social.Brand do
  @moduledoc """
  A profile's clip branding (task 01a140a9-69b7, Social 5/7): the caption
  and end-card values the renderer burns into a clip, as per-profile DATA.

  **PROVISIONAL.** Every default below is a neutral placeholder from design
  canvas 01a140fc-14a9 ("Palette (provisional, until HTC brand values
  arrive)"). Harper still owes HTC's colours, typeface, logo and end-card
  text; when they arrive they go into `social_profiles.brand` for the HTC
  profile, and no code changes. The clip carries the CUSTOMER's brand, so no
  Burrow token colour appears here.

  `resolve/1` merges a profile's `brand` map over `defaults/0`;
  `channel_url` defaults to the profile's `home_url`. Nothing outside
  `defaults/0` hard-codes a colour, font or end-card string.

  `changeset/3` validates a brand map before it is stored: colours are
  `#RRGGBB`, `end_card_text` must clear WCAG AA (4.5:1) on
  `end_card_ground` (the canvas: "Must clear AA on the end card ground"),
  `outline_px` is 0..8, the font is one this module bundles, and
  `logo_file_id` must name a file in core's Files (`Platform.Files.get_file/2`)
  in the profile's org.
  """

  import Ecto.Changeset

  @defaults %{
    "caption_text" => "#FFFFFF",
    "caption_outline" => "#000000",
    "outline_px" => 3,
    "highlight" => "#FFD400",
    "end_card_ground" => "#111111",
    "end_card_text" => "#FFFFFF",
    "font" => "public_sans_black",
    "logo_file_id" => nil,
    "channel_name" => "Channel name",
    "handle" => nil,
    "cta" => "Full episode on YouTube",
    "channel_url" => nil
  }

  # Bundled fonts: key => {family name libass matches, file under priv/fonts}.
  @fonts %{"public_sans_black" => {"Public Sans Black", "PublicSans-Black.ttf"}}

  @colour_keys ~w(caption_text caption_outline highlight end_card_ground end_card_text)
  @text_keys ~w(channel_name handle cta channel_url)
  @aa 4.5

  @type t :: %{String.t() => term()}

  @doc "The provisional placeholders (string keys)."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc "Bundled font keys."
  @spec fonts() :: [String.t()]
  def fonts, do: Map.keys(@fonts)

  @doc "The font family name libass should match for a bundled font key."
  @spec font_family(String.t()) :: String.t()
  def font_family(key), do: @fonts |> Map.fetch!(key) |> elem(0)

  @doc "The font file name under `priv/fonts` for a bundled font key."
  @spec font_file(String.t()) :: String.t()
  def font_file(key), do: @fonts |> Map.fetch!(key) |> elem(1)

  @doc "The directory holding the bundled fonts."
  @spec fonts_dir() :: String.t()
  def fonts_dir, do: Application.app_dir(:social, "priv/fonts")

  @doc """
  The effective brand for a profile: its `brand` map over `defaults/0`, with
  `channel_url` falling back to `home_url`. Unknown keys are dropped; a nil
  value in the profile keeps the default.
  """
  @spec resolve(map() | nil) :: t()
  def resolve(nil), do: resolve(%{})

  def resolve(profile) when is_map(profile) do
    overrides =
      (Map.get(profile, :brand) || %{})
      |> stringify()
      |> Map.take(Map.keys(@defaults))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    @defaults
    |> Map.put("channel_url", Map.get(profile, :home_url))
    |> Map.merge(overrides)
  end

  @doc """
  Validates the `:brand` change on a profile changeset. `org_id` is the
  profile's org, used to check `logo_file_id`.
  """
  @spec validate(Ecto.Changeset.t(), Ecto.UUID.t() | nil) :: Ecto.Changeset.t()
  def validate(%Ecto.Changeset{} = changeset, org_id) do
    case get_change(changeset, :brand) do
      nil -> changeset
      brand -> brand |> errors(org_id) |> Enum.reduce(changeset, &add_brand_error/2)
    end
  end

  defp add_brand_error(message, changeset), do: add_error(changeset, :brand, message)

  @doc "Every problem with a brand map, as readable messages (`[]` when valid)."
  @spec errors(map(), Ecto.UUID.t() | nil) :: [String.t()]
  def errors(brand, org_id) when is_map(brand) do
    brand = stringify(brand)
    merged = Map.merge(@defaults, Map.reject(brand, fn {_k, v} -> is_nil(v) end))

    unknown =
      case Map.keys(brand) -- Map.keys(@defaults) do
        [] -> []
        keys -> ["unknown brand keys: #{Enum.join(Enum.sort(keys), ", ")}"]
      end

    colours =
      for key <- @colour_keys, Map.has_key?(brand, key), not hex?(brand[key]) do
        "#{key} must be a #RRGGBB colour"
      end

    texts =
      for key <- @text_keys,
          Map.has_key?(brand, key),
          not (is_nil(brand[key]) or (is_binary(brand[key]) and String.length(brand[key]) <= 120)) do
        "#{key} must be text of at most 120 characters"
      end

    outline =
      case brand["outline_px"] do
        nil -> []
        n when is_integer(n) and n >= 0 and n <= 8 -> []
        _ -> ["outline_px must be a whole number from 0 to 8"]
      end

    font =
      case brand["font"] do
        nil ->
          []

        key ->
          if key in fonts(), do: [], else: ["font must be one of: #{Enum.join(fonts(), ", ")}"]
      end

    contrast =
      if hex?(merged["end_card_text"]) and hex?(merged["end_card_ground"]) do
        ratio = contrast_ratio(merged["end_card_text"], merged["end_card_ground"])

        if ratio < @aa,
          do: [
            "end_card_text #{merged["end_card_text"]} on end_card_ground #{merged["end_card_ground"]} " <>
              "is #{Float.round(ratio, 2)}:1; it must clear WCAG AA (4.5:1)"
          ],
          else: []
      else
        []
      end

    unknown ++
      colours ++ texts ++ outline ++ font ++ contrast ++ logo(brand["logo_file_id"], org_id)
  end

  defp logo(nil, _org_id), do: []

  defp logo(id, org_id) when is_binary(id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %{} = file <- Platform.Files.get_file(id),
         true <- file_org(file) == org_id and not is_nil(org_id) do
      if String.starts_with?(file.content_type || "", "image/"),
        do: [],
        else: ["logo_file_id must be an image file"]
    else
      _ -> ["logo_file_id must name a file in the profile's org"]
    end
  end

  defp logo(_id, _org_id), do: ["logo_file_id must name a file in the profile's org"]

  defp file_org(%{project_id: project_id}) when is_binary(project_id) do
    case Platform.Tasks.get_project(project_id) do
      %{org_id: org_id} -> org_id
      _ -> nil
    end
  end

  defp file_org(_), do: nil

  @doc "Whether `value` is a `#RRGGBB` colour."
  @spec hex?(term()) :: boolean()
  def hex?(value) when is_binary(value), do: Regex.match?(~r/\A#[0-9A-Fa-f]{6}\z/, value)
  def hex?(_), do: false

  @doc "The WCAG 2.x contrast ratio between two `#RRGGBB` colours."
  @spec contrast_ratio(String.t(), String.t()) :: float()
  def contrast_ratio(a, b) do
    [la, lb] = [luminance(a), luminance(b)]
    (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
  end

  defp luminance("#" <> hex) do
    [r, g, b] =
      for <<pair::binary-size(2) <- hex>> do
        c = String.to_integer(pair, 16) / 255
        if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
