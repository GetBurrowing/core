defmodule Platform.InstructionPacks.Manifest do
  @moduledoc """
  Strict, bounded data-only instruction manifest. Canonical signing bytes are
  JSON arrays with fixed field order, never map iteration order. Entry ordering
  is signed. Text is inert here: this module never evaluates templates or code.
  """
  @max_bytes 1_048_576
  @fields ~w(pack_id version schema_version minimum_client_version published_at previous_digest changelog entries)
  @entry_fields ~w(type target content)
  @types ~w(role_prompt skill_markdown prompt_template setup_dialogue)
  @slug ~r/\A[a-z0-9][a-z0-9_.-]{0,127}\z/
  @digest ~r/\A[0-9a-f]{64}\z/

  def max_bytes, do: @max_bytes

  def validate(manifest) when is_map(manifest) do
    with true <- Map.keys(manifest) |> Enum.sort() == Enum.sort(@fields),
         true <- slug?(manifest["pack_id"]),
         true <-
           is_integer(manifest["version"]) and manifest["version"] > 0 and
             manifest["version"] <= 9_223_372_036_854_775_807,
         true <- manifest["schema_version"] === 1,
         {:ok, _} <- Version.parse(manifest["minimum_client_version"] || ""),
         {:ok, _, 0} <- DateTime.from_iso8601(manifest["published_at"] || ""),
         true <- valid_previous?(manifest),
         true <- text?(manifest["changelog"], 4096),
         true <- entries?(manifest["entries"]),
         true <- byte_size(canonical(manifest)) <= @max_bytes do
      {:ok, manifest}
    else
      _ -> {:error, :invalid_manifest}
    end
  rescue
    _ -> {:error, :invalid_manifest}
  end

  def validate(_), do: {:error, :invalid_manifest}

  def canonical(m) do
    Jason.encode!([
      "burrow-instruction-pack-v1",
      Enum.map(@fields -- ["entries"], &m[&1]),
      Enum.map(m["entries"], fn e -> Enum.map(@entry_fields, &e[&1]) end)
    ])
  end

  def digest(m), do: :crypto.hash(:sha256, canonical(m)) |> Base.encode16(case: :lower)

  defp valid_previous?(%{"version" => 1, "previous_digest" => nil}), do: true

  defp valid_previous?(%{"version" => v, "previous_digest" => d}) when v > 1 and is_binary(d),
    do: Regex.match?(@digest, d)

  defp valid_previous?(_), do: false

  defp entries?(es) when is_list(es) and length(es) in 1..100 do
    Enum.all?(es, fn
      e when is_map(e) ->
        Enum.sort(Map.keys(e)) == Enum.sort(@entry_fields) and
          e["type"] in @types and slug?(e["target"]) and text?(e["content"], 65_536)

      _ ->
        false
    end) and Enum.uniq_by(es, &{&1["type"], &1["target"]}) == es
  end

  defp entries?(_), do: false
  defp slug?(s) when is_binary(s), do: String.valid?(s) and Regex.match?(@slug, s)
  defp slug?(_), do: false

  defp text?(s, limit) when is_binary(s),
    do: byte_size(s) in 1..limit and String.valid?(s) and not String.contains?(s, <<0>>)

  defp text?(_, _), do: false
end
