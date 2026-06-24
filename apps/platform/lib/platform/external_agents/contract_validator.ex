defmodule Platform.ExternalAgents.ContractValidator do
  @moduledoc """
  Validate an external-agent response against a responsibility's
  declared `output_contract`.

  Stub for ADR-0041 M6 stage 5 — supports the two contract kinds the
  dispatcher needs today:

    * `:freeform` / `nil` / `%{}` — always passes; returns the raw
      string content as-is.
    * `:json` / `%{"type" => "object"}` — `Jason.decode/1` the string;
      success returns the decoded map, failure returns
      `{:error, {:contract_violation, :invalid_json}}`.

  Future contract kinds (JSON Schema, regex, length bounds, etc.) land
  alongside the responsibilities that need them.
  """

  @type contract :: nil | map() | atom()
  @type validation_result :: {:ok, String.t() | map()} | {:error, {:contract_violation, atom()}}

  @doc """
  Validate `parsed_string` against `contract`.

  See module doc for the supported contract shapes.
  """
  @spec validate(String.t(), contract()) :: validation_result()
  def validate(parsed_string, contract) when is_binary(parsed_string) do
    case classify(contract) do
      :freeform ->
        {:ok, parsed_string}

      :json ->
        case Jason.decode(parsed_string) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, {:contract_violation, :invalid_json}}
        end

      :unknown ->
        # Forward-compatible: an unrecognised contract shape isn't a
        # violation per se — newer dispatchers will handle it. For now
        # we treat it as freeform so we don't break responsibilities
        # whose contract has fields we don't yet know about.
        {:ok, parsed_string}
    end
  end

  def validate(_other, _contract), do: {:error, {:contract_violation, :invalid_payload}}

  # ── Private ─────────────────────────────────────────────────────────────

  defp classify(nil), do: :freeform
  defp classify(:freeform), do: :freeform
  defp classify(:json), do: :json
  defp classify(""), do: :freeform

  defp classify(map) when is_map(map) and map_size(map) == 0, do: :freeform

  defp classify(%{"type" => "object"}), do: :json
  defp classify(%{type: "object"}), do: :json
  defp classify(%{"type" => "json"}), do: :json
  defp classify(%{type: :json}), do: :json
  defp classify(%{"kind" => "json"}), do: :json
  defp classify(%{kind: :json}), do: :json
  defp classify(%{"format" => "json"}), do: :json
  defp classify(%{format: :json}), do: :json

  defp classify(%{"type" => "freeform"}), do: :freeform
  defp classify(%{type: :freeform}), do: :freeform

  defp classify(_other), do: :unknown
end
