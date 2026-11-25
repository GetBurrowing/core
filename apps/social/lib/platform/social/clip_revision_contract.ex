defmodule Platform.Social.ClipRevisionContract do
  @moduledoc "Bounded external-render facts and stable submission identities; source provenance remains an exporter claim."
  import Bitwise
  @namespace "fcf6651709fb4cf986f0de81a35a8798"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @hash ~r/\A[0-9a-f]{64}\z/

  def uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
  def hash?(value), do: is_binary(value) and Regex.match?(@hash, value)

  def submission_id(request, clip, base, hash) do
    if Enum.all?([request, clip, base], &uuid?/1) and hash?(hash) do
      namespace = Base.decode16!(@namespace, case: :lower)
      name = Enum.join([request, clip, base, hash], "\n")
      <<a::32, b::16, c::16, d::16, e::48, _::binary>> = :crypto.hash(:sha, namespace <> name)

      bytes =
        <<a::32, b::16, bor(band(c, 0x0FFF), 0x5000)::16, bor(band(d, 0x3FFF), 0x8000)::16,
          e::48>>

      hex = Base.encode16(bytes, case: :lower)

      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
        e::binary-size(12)>> = hex

      {:ok, Enum.join([a, b, c, d, e], "-")}
    else
      {:error, :invalid_identity}
    end
  end

  @upload_keys ~w(request_id base_render_id submission_id sha256 byte_size duration_s width height)
  def upload_input(attrs) when is_map(attrs) do
    with {:ok, attrs} <- string_keys(attrs),
         :ok <-
           fields(
             attrs,
             @upload_keys,
             ~w(request_id base_render_id submission_id sha256 byte_size)
           ),
         {:ok, full} <-
           return_input(
             Map.merge(
               %{
                 "file_id" => "00000000-0000-4000-8000-000000000000",
                 "duration_s" => 1.0,
                 "width" => 1,
                 "height" => 1
               },
               attrs
             )
           ) do
      {:ok, Map.take(full, Map.keys(attrs))}
    end
  end

  def upload_input(_), do: {:error, :invalid}

  @return_keys ~w(file_id request_id base_render_id submission_id sha256 byte_size duration_s width height fps provenance)
  def return_input(attrs) when is_map(attrs) do
    with {:ok, attrs} <- string_keys(attrs),
         {:ok, attrs} <- expand_output(attrs),
         :ok <-
           fields(
             attrs,
             @return_keys,
             ~w(file_id request_id base_render_id submission_id sha256 byte_size duration_s width height)
           ),
         true <-
           Enum.all?(~w(file_id request_id base_render_id submission_id), &uuid?(attrs[&1])) ||
             {:error, :invalid_identity},
         true <- hash?(attrs["sha256"]) || {:error, :invalid_identity},
         true <-
           Enum.all?(~w(width height byte_size), &positive_int?(attrs[&1])) ||
             {:error, :invalid_media_facts},
         true <- positive_seconds?(attrs["duration_s"]) || {:error, :invalid_media_facts},
         true <-
           (not Map.has_key?(attrs, "fps") or positive_fps?(attrs["fps"])) ||
             {:error, :invalid_media_facts},
         {:ok, provenance} <- provenance(Map.get(attrs, "provenance")) do
      attrs = Map.update!(attrs, "duration_s", &(&1 * 1.0))

      attrs =
        if Map.has_key?(attrs, "fps"), do: Map.update!(attrs, "fps", &(&1 * 1.0)), else: attrs

      {:ok, if(provenance, do: Map.put(attrs, "provenance", provenance), else: attrs)}
    end
  end

  def return_input(_), do: {:error, :invalid}

  defp expand_output(%{"output" => output} = attrs) when is_map(output) do
    with :ok <-
           fields(
             attrs,
             ~w(file_id request_id base_render_id submission_id output provenance),
             ~w(output)
           ),
         :ok <-
           fields(
             output,
             ~w(sha256 bytes duration_s width height fps),
             ~w(sha256 bytes duration_s width height)
           ) do
      {:ok,
       attrs
       |> Map.delete("output")
       |> Map.merge(output |> Map.delete("bytes") |> Map.put("byte_size", output["bytes"]))}
    end
  end

  defp expand_output(%{"output" => _}), do: {:error, :invalid_media_facts}
  defp expand_output(attrs), do: {:ok, attrs}

  defp provenance(nil), do: {:ok, nil}

  defp provenance(p) when is_map(p) do
    with {:ok, json} <- Jason.encode(p),
         true <- byte_size(json) <= 32_768,
         :ok <-
           fields(
             p,
             ~w(provided_by tool_version episode_code source_fingerprint requested_range edited_range exported),
             ~w(provided_by tool_version source_fingerprint requested_range edited_range exported)
           ),
         true <- p["provided_by"] == "exporter",
         true <- text?(p["tool_version"], 128),
         true <-
           text?(p["source_fingerprint"], 256) and
             not String.contains?(p["source_fingerprint"], ["/", "\\"]),
         true <-
           not Map.has_key?(p, "episode_code") or
             (text?(p["episode_code"], 128) and String.length(p["episode_code"]) <= 32),
         {:ok, requested} <- interval(p["requested_range"]),
         {:ok, edited} <- interval(p["edited_range"]),
         {:ok, exported} <- exported(p["exported"]) do
      {:ok,
       p
       |> Map.put("requested_range", requested)
       |> Map.put("edited_range", edited)
       |> Map.put("exported", exported)}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp provenance(_), do: {:error, :invalid_provenance}

  defp exported(p) when is_map(p) do
    with :ok <-
           fields(
             p,
             ~w(continuous start_s end_s handle_before_s handle_after_s spans),
             ~w(continuous handle_before_s handle_after_s spans)
           ),
         true <- is_boolean(p["continuous"]),
         true <- seconds?(p["handle_before_s"]) and seconds?(p["handle_after_s"]),
         spans when is_list(spans) and length(spans) in 1..256 <- p["spans"],
         {:ok, spans} <- intervals(spans),
         true <- export_range?(p, spans) do
      result =
        p
        |> Map.put("spans", spans)
        |> Map.update!("handle_before_s", &(&1 * 1.0))
        |> Map.update!("handle_after_s", &(&1 * 1.0))

      {:ok,
       if(p["continuous"],
         do: result |> Map.update!("start_s", &(&1 * 1.0)) |> Map.update!("end_s", &(&1 * 1.0)),
         else: result
       )}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp exported(_), do: {:error, :invalid_provenance}

  defp export_range?(%{"continuous" => true} = p, [span]),
    do:
      seconds?(p["start_s"]) and seconds?(p["end_s"]) and p["start_s"] == span["start_s"] and
        p["end_s"] == span["end_s"]

  defp export_range?(%{"continuous" => false} = p, spans),
    do: length(spans) > 1 and not Map.has_key?(p, "start_s") and not Map.has_key?(p, "end_s")

  defp export_range?(_, _), do: false

  defp intervals(spans) do
    Enum.reduce_while(spans, {:ok, []}, fn span, {:ok, acc} ->
      case interval(span) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp interval(p) when is_map(p) do
    with :ok <- fields(p, ~w(start_s end_s), ~w(start_s end_s)),
         true <- seconds?(p["start_s"]) and seconds?(p["end_s"]) and p["end_s"] > p["start_s"] do
      {:ok, %{"start_s" => p["start_s"] * 1.0, "end_s" => p["end_s"] * 1.0}}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp interval(_), do: {:error, :invalid_provenance}

  defp fields(map, allowed, required) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)) and Enum.all?(required, &Map.has_key?(map, &1)),
      do: :ok,
      else: {:error, :field_not_allowed}
  end

  defp string_keys(map) do
    if Enum.all?(Map.keys(map), &(is_binary(&1) or is_atom(&1))) do
      normalized = Map.new(map, fn {k, v} -> {to_string(k), v} end)
      if map_size(normalized) == map_size(map), do: {:ok, normalized}, else: {:error, :invalid}
    else
      {:error, :invalid}
    end
  end

  defp positive_int?(v), do: is_integer(v) and v > 0 and v <= 9_223_372_036_854_775_807
  defp seconds?(v), do: is_number(v) and v >= 0 and v <= 1_000_000_000

  defp positive_fps?(value) when is_number(value) and value > 0 do
    try do
      value * 1.0 > 0
    rescue
      ArithmeticError -> false
    end
  end

  defp positive_fps?(_), do: false
  defp positive_seconds?(v), do: seconds?(v) and v > 0

  defp text?(v, max),
    do: is_binary(v) and String.valid?(v) and byte_size(v) > 0 and byte_size(v) <= max
end
