defmodule Platform.Agents.Harness do
  @moduledoc """
  The registry of harness adapters, and helpers every adapter shares.

  `adapter_for/1` is the only registry: the UI asks it and nothing else. A
  harness with no adapter (`hermes`, `deepseek`, `openclaw`, anything federated
  that stores no harness, `nil`) is `:unsupported`, and the screen says
  configuration is not available for it. There are no placeholder sections.
  """

  alias Platform.Agents.Harness.{ClaudeCode, Codex, Config}

  @adapters %{"claude_code" => ClaudeCode, "codex" => Codex}

  @doc "The adapter for a stored harness name, or `:unsupported`."
  @spec adapter_for(term()) :: {:ok, module()} | :unsupported
  def adapter_for(harness) when is_binary(harness) do
    case Map.fetch(@adapters, harness) do
      {:ok, mod} -> {:ok, mod}
      :error -> :unsupported
    end
  end

  def adapter_for(_), do: :unsupported

  @doc "Harness names that have an adapter."
  @spec supported() :: [String.t()]
  def supported, do: @adapters |> Map.keys() |> Enum.sort()

  @doc """
  The concepts the config carries that the adapter cannot render. They are
  reported to the caller, never written as empty or placeholder files.
  """
  @spec unsupported_concepts(module(), Config.t()) :: [atom()]
  def unsupported_concepts(adapter, %Config{} = config) do
    config
    |> Config.populated_concepts()
    |> Enum.reject(&(&1 in adapter.concepts()))
  end

  @doc "Which known-path tag a relative path falls under, or `nil` when it is not a known path."
  @spec path_tag(module(), String.t()) :: :plain | :secret_bearing | :secret | nil
  def path_tag(adapter, path) do
    Enum.find_value(adapter.known_paths(), fn {glob, tag} ->
      if glob_match?(glob, path), do: tag
    end)
  end

  @doc "Match a relative glob where `*` matches one path segment's characters."
  @spec glob_match?(String.t(), String.t()) :: boolean()
  def glob_match?(glob, path) do
    regex =
      glob
      |> String.split("*")
      |> Enum.map_join("[^/]+", &Regex.escape/1)

    Regex.match?(~r/\A#{regex}\z/, path)
  end

  @name_re ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @doc "Raises unless `name` is safe to use as a file or directory name."
  @spec safe_name!(String.t()) :: String.t()
  def safe_name!(name) when is_binary(name) do
    if Regex.match?(@name_re, name),
      do: name,
      else: raise(ArgumentError, "unsafe entry name: #{inspect(name)}")
  end

  @doc "The environment variable a header name is read from: `X-Api-Key` -> `X_API_KEY`."
  @spec header_env_name(String.t()) :: String.t()
  def header_env_name(header), do: header |> String.upcase() |> String.replace("-", "_")

  # ── Frontmatter markdown ───────────────────────────────────────────

  @doc "Render `%{name, description, body}` as a frontmatter markdown file."
  @spec frontmatter_doc([{String.t(), String.t()}], String.t()) :: binary()
  def frontmatter_doc(pairs, body) do
    head = Enum.map_join(pairs, "", fn {k, v} -> "#{k}: #{yaml_scalar(v)}\n" end)
    "---\n" <> head <> "---\n" <> body
  end

  defp yaml_scalar(v) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9 ,.()_\/-]*\z/, v),
      do: v,
      else: Jason.encode!(v)
  end

  @doc "Parse a frontmatter markdown file into `{%{key => value}, body}`."
  @spec parse_frontmatter(binary()) :: {map(), binary()}
  def parse_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [head, body] -> {parse_pairs(head), body}
      _ -> {%{}, "---\n" <> rest}
    end
  end

  def parse_frontmatter(other), do: {%{}, other}

  defp parse_pairs(head) do
    head
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, ":", parts: 2)
      v = String.trim(v)

      v =
        if String.starts_with?(v, "\"") do
          case Jason.decode(v) do
            {:ok, s} when is_binary(s) -> s
            _ -> v
          end
        else
          v
        end

      {k, v}
    end)
  end

  # ── Deterministic JSON ─────────────────────────────────────────────

  @doc "Pretty JSON with keys sorted at every level, newline-terminated."
  @spec encode_json(term()) :: binary()
  def encode_json(term), do: Jason.encode!(ordered(term), pretty: true) <> "\n"

  defp ordered(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {to_string(k), ordered(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(other), do: other
end
