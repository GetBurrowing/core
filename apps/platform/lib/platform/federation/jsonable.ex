defmodule Platform.Federation.Jsonable do
  @moduledoc """
  The JSON-safe projection of a tool handler's data and the error envelope a
  refusal reaches a caller in. Extracted from `PlatformWeb.MCPController`
  (task 01a114a8 stage 2) so that `burrow_run`'s inner calls
  (`Platform.CodeMode.Bindings`) hand a script exactly what `/mcp` hands a
  client. The reasoning behind each clause is in `MCPController`'s comments
  above `error_content/1`.
  """

  @doc """
  The `%{error, code, recoverable, suggestion, ...}` envelope for a handler's
  `{:error, reason}`. Every key the handler set is carried; nil values are
  dropped; `error` is always a string.
  """
  @spec error_envelope(term()) :: map()
  def error_envelope(%Ecto.Changeset{} = changeset),
    do: %{error: inspect(changeset.errors)}

  def error_envelope(reason) when is_map(reason) and not is_struct(reason) do
    reason
    |> Map.drop([:error])
    |> Map.new(fn {key, value} -> {key, encodable(value)} end)
    |> Map.put(:error, error_message(reason))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def error_envelope(reason) when is_binary(reason), do: %{error: reason}
  def error_envelope(reason), do: %{error: inspect(reason)}

  # `error` is always a string, whatever the handler put there — a client
  # branching on `code` still needs something human-readable to log.
  defp error_message(%{error: message}) when is_binary(message), do: message
  defp error_message(%{error: %Ecto.Changeset{} = changeset}), do: inspect(changeset.errors)
  defp error_message(%{error: nil} = reason), do: inspect(reason)
  defp error_message(%{error: other}), do: inspect(other)
  defp error_message(reason), do: inspect(reason)

  @doc """
  `value` with everything `Jason` cannot encode replaced: lists and plain maps
  recurse, structs are kept only when they implement `Jason.Encoder`
  (`DateTime` and friends do), unencodable keys and leaves become `inspect/1`
  strings.
  """
  @spec encodable(term()) :: term()
  def encodable(value) when is_atom(value) or is_binary(value) or is_number(value), do: value
  def encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)

  # `Jason.Encoder` sets `@fallback_to_any true`, so `impl_for/1` never
  # returns nil for a struct: one with no encoder of its own resolves to
  # `Jason.Encoder.Any`, whose `encode/2` raises. That module is the
  # "not encodable" answer, not nil (the Elixir 1.20 type checker flagged
  # the old `if impl_for(value)` test as always true).
  def encodable(%_{} = value) do
    case Jason.Encoder.impl_for(value) do
      Jason.Encoder.Any -> inspect(value)
      _encoder -> value
    end
  end

  def encodable(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {encodable_key(key), encodable(val)} end)

  def encodable(value), do: inspect(value)

  # Jason encodes atom, binary and numeric keys; anything else (a tuple key,
  # a pid) would raise mid-encode, which is the 500 again.
  defp encodable_key(key) when is_atom(key) or is_binary(key) or is_number(key), do: key
  defp encodable_key(key), do: inspect(key)
end
