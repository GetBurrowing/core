defmodule Platform.Chat.Canvas.Kinds.Embed do
  @moduledoc """
  Sandboxed inline-HTML mockup leaf.

  Renders an `<iframe srcdoc=...>` with the most-restrictive sandbox
  (`sandbox=""` — no scripts, no same-origin, no forms, no popups, no
  top-level navigation). Intended for design mockups and static HTML
  previews authored by agents; the empty-sandbox attribute is the
  primary defence and `validate_props/1` provides defence-in-depth by
  rejecting `srcdoc` payloads that contain `<script` substrings or
  exceed a hard size cap.

  ## Props

    * `srcdoc` (string, required) — full HTML document to render in the
      sandboxed iframe. Capped at 256 KB and may not contain `<script`
      (case-insensitive).
    * `height` (integer, optional, default 400) — iframe height in
      pixels. Must lie in `100..2000`.
  """

  use Platform.Chat.Canvas.Kind

  @max_srcdoc_bytes 256 * 1024
  @default_height 400
  @min_height 100
  @max_height 2000

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["srcdoc"],
      "properties" => %{
        "srcdoc" => %{
          "type" => "string",
          "description" =>
            "Full HTML document rendered inside a sandboxed iframe. " <>
              "Maximum 256 KB; may not contain <script tags (case-insensitive)."
        },
        "height" => %{
          "type" => "integer",
          "minimum" => @min_height,
          "maximum" => @max_height,
          "description" => "Iframe height in pixels (default 400)."
        }
      }
    }
  end

  @impl true
  def validate_props(props) when is_map(props) do
    with :ok <- validate_srcdoc(Map.get(props, "srcdoc")),
         :ok <- validate_height(Map.get(props, "height")) do
      :ok
    end
  end

  defp validate_srcdoc(srcdoc) when is_binary(srcdoc) do
    cond do
      byte_size(srcdoc) > @max_srcdoc_bytes ->
        {:error, "srcdoc exceeds maximum size of 256KB"}

      String.contains?(String.downcase(srcdoc), "<script") ->
        {:error, "srcdoc may not contain <script tags"}

      true ->
        :ok
    end
  end

  defp validate_srcdoc(_), do: :ok

  defp validate_height(nil), do: :ok

  defp validate_height(height) when is_integer(height) do
    if height in @min_height..@max_height do
      :ok
    else
      {:error, "height must be between 100 and 2000 pixels"}
    end
  end

  defp validate_height(_), do: :ok

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}

    height =
      case props["height"] do
        h when is_integer(h) and h >= @min_height and h <= @max_height -> h
        _ -> @default_height
      end

    assigns =
      assigns
      |> assign(:srcdoc, props["srcdoc"] || "")
      |> assign(:iframe_style, "width: 100%; height: #{height}px; border: 0;")

    ~H"""
    <div class="overflow-hidden rounded-xl border border-base-300">
      <iframe srcdoc={@srcdoc} sandbox="" style={@iframe_style}></iframe>
    </div>
    """
  end
end
