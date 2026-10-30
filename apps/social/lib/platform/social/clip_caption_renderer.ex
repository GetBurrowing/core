defmodule Platform.Social.ClipCaptionRenderer do
  @moduledoc """
  Server-owned qualification of the canonical caption renderer. Operators install
  the pinned tool/helper, run docs/integrations/clip-captions/verify_install.py,
  then configure the resulting receipt under :clip_caption_renderer. A browser
  cannot qualify a renderer. Missing or mismatched receipts keep new styles
  unavailable; legacy jobs retain their existing behavior. Receipts contain no
  credentials, source URLs or transcript content.
  """
  alias Platform.Social.ClipLook

  @legacy ~w(plain phrase-pop karaoke)
  @renderer "9074e59c4c38ddcfafd804f66cd72958cb3e28e3a992426c10e0446de53dbdd4"
  @temporal "385f5e446c09bd06bb5fb11aaa4228fa95e47fa808e1c1d750bf6633d039aee7"
  @helper "523cbac53ff053a3d72a92b4075b653829e827e0f2ade54d63ff84f0795e01ce"

  @doc "Selectable styles for the current server-configured executable/helper."
  def styles, do: if(receipt(), do: ClipLook.styles(), else: @legacy)

  @doc "A safe, validated qualification receipt, or nil. Never reads caller input."
  def receipt do
    case Application.get_env(:platform, :clip_caption_renderer) do
      %{
        "caption_treatments" => 1,
        "renderer_sha256" => @renderer,
        "temporal_sha256" => @temporal,
        "helper_sha256" => @helper,
        "executable_sha256" => executable,
        "caption_styles" => styles
      } = value
      when is_binary(executable) and is_list(styles) ->
        if Regex.match?(~r/\A[0-9a-f]{64}\z/, executable) and
             Enum.all?(ClipLook.styles(), &(&1 in styles)) do
          Map.take(
            value,
            ~w(caption_treatments renderer_sha256 temporal_sha256 helper_sha256 executable_sha256 caption_styles)
          )
        end

      _ ->
        nil
    end
  end

  @doc "Reject unsupported new styles before enqueueing; legacy snapshots stay valid."
  def qualify(look) do
    style = ClipLook.caption_style(look)

    cond do
      style in @legacy -> {:ok, nil}
      style in ClipLook.styles() and receipt() != nil -> {:ok, receipt()}
      true -> {:error, :caption_renderer_unavailable}
    end
  end
end
