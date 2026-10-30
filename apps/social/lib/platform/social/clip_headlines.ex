defmodule Platform.Social.ClipHeadlines do
  @moduledoc """
  Enqueue-time template inputs and content-free immutable output receipts.
  Wording remains in a private, content-addressed runner artifact, never a mutable review pointer.
  Historical snapshots without provenance.headline remain unknown.
  """
  @renderer "b36d7ec515da07e5e432d1eca57c639ecc6007126cc68110d1bb367c99b45d84"
  @logo "7cbddeac97ad8fe3aa53e867cf0e5648329f500e528f2302e1b2ebcba8bf767f"
  @font "a4ba3a92350ebb031da0cb47630ac49eb265082ca1bc0450442f4a83ab947cab"

  def snapshot(look) do
    title = look["title"] || %{}
    template = title["template"] || "legacy"
    seconds = title["secs"] || 3.0
    emphasis = title["emphasis"] || []
    text = title["emphasis_text"]

    cond do
      template == "legacy" and not Map.has_key?(title, "template") ->
        {:ok, nil}

      template not in Platform.Social.ClipLook.headline_templates() ->
        {:error, :headline_template_invalid}

      not is_number(seconds) or seconds <= 0.5 or seconds > 6 ->
        {:error, :headline_timing_invalid}

      emphasis != [] and not valid_emphasis?(emphasis, text) ->
        {:error, :headline_emphasis_stale}

      true ->
        {:ok,
         %{
           "version" => 1,
           "template" => template,
           "revision" => 1,
           "renderer_sha256" => @renderer,
           "assets" => %{
             "logo_sha256" => @logo,
             "font_sha256" => @font,
             "provenance" =>
               "official HowToComputer_JR channel; assets-manifest.json v1; HTC use only; Anton OFL-1.1"
           },
           "timing" => %{
             "entrance_s" => if(template == "legacy", do: 0.0, else: 0.2),
             "hold_s" => if(template == "legacy", do: seconds, else: seconds - 0.45),
             "exit_s" => if(template == "legacy", do: 0.0, else: 0.25),
             "total_s" => seconds
           },
           "emphasis" => emphasis,
           "emphasis_text" => text
         }}
    end
  end

  def valid_emphasis?(indices, text) when is_list(indices) and is_binary(text) do
    count = length(String.split(text))

    length(Enum.uniq(indices)) == length(indices) and
      Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < count))
  end

  def valid_emphasis?([], _), do: true
  def valid_emphasis?(_, _), do: false

  def receipt(nil, _), do: {:ok, nil}

  def receipt(contract, receipt) when is_map(receipt) do
    content = receipt["content"] || %{}
    expected = Map.drop(contract, ["emphasis_text"])

    if is_map(content) and Map.take(receipt, Map.keys(expected)) == expected and
         Enum.sort(Map.keys(receipt)) ==
           Enum.sort(Map.keys(expected) ++ ["content", "output_sha256"]) and
         hash?(content["sha256"]) and
         content == %{
           "artifact" => "sha256:" <> content["sha256"],
           "sha256" => content["sha256"]
         } and
         hash?(receipt["output_sha256"]),
       do: {:ok, receipt},
       else: {:error, :headline_receipt_invalid}
  end

  def receipt(_, _), do: {:error, :headline_receipt_required}
  defp hash?(v), do: is_binary(v) and Regex.match?(~r/\A[0-9a-f]{64}\z/, v)
end
