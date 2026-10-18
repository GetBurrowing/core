defmodule Platform.Memory.Insights.Parser do
  @moduledoc """
  Parses `<synthesis-insight>` blocks out of journal text. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 1.

  ## Grammar

      <synthesis-insight action="page_edit|briefing|question|task"
                         confidence="high|medium|low"
                         evidence="…" source="…" addressee="…" target="…">
        …body…
      </synthesis-insight>

  Attributes may appear in any order. `action` and `confidence` are
  required and enum-validated. `evidence`, `source`, `addressee` and
  `target` are optional and kept verbatim.

  A `page_edit` body must carry at least one hunk,
  `<old>…</old><new>…</new>` (whitespace between the two tags allowed). The
  hunks are lifted into `action["hunks"]`, in order; the body text is kept
  whole, hunks included, so `block_hash` covers the edit itself.

  ## Skips

  An unknown `action`, a missing or unknown `confidence`, an empty body, or
  a `page_edit` with no hunk is SKIPPED with a `Logger.warning`, never
  raised, so one malformed block cannot poison a dreaming run (the posture
  the retired `Platform.Memory.Proposals` took for `<synthesis-proposal>`).

  `block_hash` is the lowercase hex sha256 of the trimmed body.
  """

  require Logger

  alias Platform.Memory.Insight

  @block_regex ~r/<synthesis-insight([^>]*)>([\s\S]*?)<\/synthesis-insight>/
  @attr_regex ~r/(\w+)\s*=\s*"([^"]*)"/
  @hunk_regex ~r/<old>([\s\S]*?)<\/old>\s*<new>([\s\S]*?)<\/new>/

  @type parsed :: %{
          action_type: String.t(),
          confidence: String.t(),
          evidence: String.t() | nil,
          source_ref: String.t() | nil,
          body: String.t(),
          block_hash: String.t(),
          action: map()
        }

  @doc "Every well-formed block in `content`, in document order."
  @spec parse(String.t() | nil) :: [parsed()]
  def parse(nil), do: []

  def parse(content) when is_binary(content) do
    @block_regex
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_full, attr_string, body] ->
      case parse_block(attr_string, body) do
        {:ok, parsed} -> [parsed]
        {:error, reason} -> log_skip(reason, attr_string, body)
      end
    end)
  end

  @doc "sha256 of `body`, lowercase hex."
  @spec hash(String.t()) :: String.t()
  def hash(body) when is_binary(body),
    do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  defp parse_block(attr_string, body) do
    attrs = extract_attrs(attr_string)
    trimmed = String.trim(body)

    with {:ok, action_type} <- fetch_enum(attrs, "action", Insight.action_types()),
         {:ok, confidence} <- fetch_enum(attrs, "confidence", Insight.confidences()),
         :ok <- validate_body(trimmed),
         {:ok, hunks} <- hunks(action_type, trimmed) do
      {:ok,
       %{
         action_type: action_type,
         confidence: confidence,
         evidence: blank_to_nil(attrs["evidence"]),
         source_ref: blank_to_nil(attrs["source"]),
         body: trimmed,
         block_hash: hash(trimmed),
         action: action_map(attrs, hunks)
       }}
    end
  end

  defp hunks("page_edit", body) do
    case Regex.scan(@hunk_regex, body) do
      [] -> {:error, "page_edit without an <old>/<new> hunk"}
      found -> {:ok, Enum.map(found, fn [_, old, new] -> %{"old" => old, "new" => new} end)}
    end
  end

  defp hunks(_action_type, _body), do: {:ok, nil}

  defp action_map(attrs, hunks) do
    %{"target" => blank_to_nil(attrs["target"]), "addressee" => blank_to_nil(attrs["addressee"])}
    |> then(fn map -> if hunks, do: Map.put(map, "hunks", hunks), else: map end)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp extract_attrs(attr_string) do
    @attr_regex
    |> Regex.scan(attr_string)
    |> Map.new(fn [_full, k, v] -> {k, v} end)
  end

  defp fetch_enum(attrs, key, allowed) do
    case Map.get(attrs, key) do
      nil -> {:error, "missing #{key}"}
      val -> if val in allowed, do: {:ok, val}, else: {:error, "invalid #{key}=#{inspect(val)}"}
    end
  end

  defp validate_body(""), do: {:error, "empty body"}
  defp validate_body(_), do: :ok

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp log_skip(reason, attr_string, body) do
    Logger.warning(
      "[memory.insights] skipped malformed synthesis-insight block: #{reason} " <>
        "attrs=#{inspect(String.slice(attr_string, 0, 80))} " <>
        "body_preview=#{inspect(String.slice(body, 0, 80))}"
    )

    []
  end
end
