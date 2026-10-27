defmodule Platform.Agents.ConfigFiles.Redaction do
  @moduledoc """
  What a config read may show, and how a redacted write keeps the secrets.

  * A SECRET path (`.env*`, `*.credentials.json`, `.claude/.credentials.json`,
    `.codex/auth.json`) shows names only: one name per line.
  * A secret-bearing path (`.mcp.json`, settings files, `.codex/config.toml`)
    goes through the adapter's `redact/2`: values become `[redacted]`, `${REF}`
    environment references stay.
  * Everything else is shown as stored.

  `apply/3` is the one function both backends call, so the host backend's
  second pass and the store backend's only pass are the same code.
  """

  alias Platform.Agents.Harness
  alias Platform.Agents.Harness.Codex

  @marker "[redacted]"

  @doc "The placeholder a redacted value is replaced with."
  def marker, do: @marker

  @doc "True for a file that holds secrets and is shown by name only."
  @spec secret_path?(String.t()) :: boolean()
  def secret_path?(path) when is_binary(path) do
    base = Path.basename(path)

    String.starts_with?(base, ".env") or String.ends_with?(base, "credentials.json") or
      path in [".claude/.credentials.json", ".codex/auth.json"]
  end

  @doc """
  `{content_to_show, secret_names}` for `path`. `adapter` may be nil for a
  harness with no adapter, in which case only the secret-path rule applies.
  """
  @spec apply(module() | nil, String.t(), binary()) :: {binary(), [String.t()]}
  def apply(adapter, path, content) when is_binary(content) do
    cond do
      secret_path?(path) -> names_only(path, content)
      adapter == nil -> {content, []}
      Harness.path_tag(adapter, path) == :secret -> names_only(path, content)
      Harness.path_tag(adapter, path) == :secret_bearing -> adapter.redact(path, content)
      true -> {content, []}
    end
  end

  @doc "Names only, one per line."
  @spec names_only(String.t(), binary()) :: {binary(), [String.t()]}
  def names_only(path, content) do
    names =
      if String.ends_with?(path, ".json") do
        case Jason.decode(content) do
          {:ok, %{} = m} -> leaf_names(m, [])
          _ -> []
        end
      else
        env_names(content)
      end

    names = names |> Enum.uniq() |> Enum.sort()
    {Enum.map_join(names, "", &(&1 <> "\n")), names}
  end

  # `NAME=value` lines. Content with no `=` at all is already names-only (the
  # host redacted it to one name per line), so its identifier lines are the
  # names; a bare line is never taken from a file that has assignments.
  defp env_names(content) do
    lines = String.split(content, "\n")

    if String.contains?(content, "=") do
      for line <- lines,
          [_, name] <- [Regex.run(~r/\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/, line)],
          do: name
    else
      for line <- lines, Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, line), do: line
    end
  end

  defp leaf_names(map, prefix) do
    Enum.flat_map(map, fn
      {k, %{} = v} -> leaf_names(v, prefix ++ [k])
      {k, _} -> [Enum.join(prefix ++ [k], ".")]
    end)
  end

  @doc """
  Put the stored secret values back where `new` carries the `[redacted]`
  placeholder. `{:error, :unresolved_redaction}` when a placeholder has no
  stored counterpart (it would otherwise be saved as a literal value).
  """
  @spec restore(String.t(), binary(), binary() | nil) :: {:ok, binary()} | {:error, term()}
  def restore(path, new, old) do
    if String.contains?(new, @marker) do
      do_restore(path, new, old)
    else
      {:ok, new}
    end
  end

  defp do_restore(path, new, old) do
    toml? = String.ends_with?(path, ".toml")

    with {:ok, n} <- decode(path, new),
         {:ok, o} <- if(is_nil(old), do: {:ok, %{}}, else: decode(path, old)),
         {:ok, merged} <- merge(n, o) do
      {:ok, if(toml?, do: Codex.encode(merged), else: Harness.encode_json(merged))}
    end
  end

  defp decode(path, bin) do
    if String.ends_with?(path, ".toml") do
      Toml.decode(bin)
      |> case do
        {:ok, m} -> {:ok, m}
        _ -> {:error, :invalid_toml}
      end
    else
      case Jason.decode(bin) do
        {:ok, %{} = m} -> {:ok, m}
        _ -> {:error, :invalid_json}
      end
    end
  end

  defp merge(new, old) when is_map(new) do
    Enum.reduce_while(new, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case merge_value(v, Map.get(old, k)) do
        {:ok, nv} -> {:cont, {:ok, Map.put(acc, k, nv)}}
        error -> {:halt, error}
      end
    end)
  end

  defp merge_value(@marker, nil), do: {:error, :unresolved_redaction}
  defp merge_value(@marker, old), do: {:ok, old}
  defp merge_value(%{} = v, old), do: merge(v, if(is_map(old), do: old, else: %{}))
  defp merge_value(v, _), do: {:ok, v}

  @doc """
  Merge one secret `value` into `content` (nil when the file is new) at
  `pointer`: a variable name for an env file, a `/`-separated path for JSON or
  TOML. The value appears only in the returned binary.
  """
  @spec put_secret(String.t(), binary() | nil, String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def put_secret(path, content, pointer, value)
      when is_binary(pointer) and is_binary(value) do
    cond do
      value == "" or byte_size(value) > 4096 -> {:error, :invalid_value}
      String.starts_with?(Path.basename(path), ".env") -> put_env(content || "", pointer, value)
      String.ends_with?(path, [".json", ".toml"]) -> put_nested(path, content, pointer, value)
      true -> {:error, :not_a_secret_file}
    end
  end

  defp put_env(content, name, value) do
    cond do
      not Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name) ->
        {:error, :invalid_pointer}

      String.contains?(value, ["\n", "\r", "\0"]) ->
        {:error, :invalid_value}

      true ->
        line = "#{name}=#{value}"
        re = ~r/\A\s*(?:export\s+)?#{Regex.escape(name)}\s*=/
        lines = String.split(content, "\n", trim: false)

        {out, found?} =
          Enum.map_reduce(lines, false, fn l, found ->
            if Regex.match?(re, l), do: {line, true}, else: {l, found}
          end)

        out = if found?, do: out, else: Enum.reject(out, &(&1 == "")) ++ [line]
        {:ok, Enum.join(out, "\n") |> String.trim_trailing("\n") |> Kernel.<>("\n")}
    end
  end

  defp put_nested(path, content, pointer, value) do
    segments = pointer |> String.split("/", trim: true)

    with true <- segments != [] or {:error, :invalid_pointer},
         {:ok, doc} <- if(is_nil(content), do: {:ok, %{}}, else: decode(path, content)) do
      doc = put_in_path(doc, segments, value)

      {:ok,
       if(String.ends_with?(path, ".toml"), do: Codex.encode(doc), else: Harness.encode_json(doc))}
    end
  end

  defp put_in_path(map, [key], value), do: Map.put(map, key, value)

  defp put_in_path(map, [key | rest], value) do
    child =
      case Map.get(map, key) do
        %{} = m -> m
        _ -> %{}
      end

    Map.put(map, key, put_in_path(child, rest, value))
  end
end
