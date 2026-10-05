defmodule Platform.Experiments.Surfaces.ProductDocsPreamble do
  @moduledoc """
  The `dispatch.product_docs_preamble` surface: which Burrow product doc
  pages (`burrow/page/*`) ride in a task dispatch's org preamble. Task
  01a10a44 stage 2.

  Resolved per task by `Platform.Org.PreambleBuilder` when it assembles the
  `:org` map of a dispatch context. An experiment can therefore vary the
  product pages an agent sees (none, the index, the index plus a topic) as
  data, with no deploy.

  ## Target

  The only target is `"dispatch.preamble"` (`targets/0`).

  ## Payload

  `%{"keys" => [file_key]}`, each key a `burrow/page/<name>.md` path. An
  empty list is a legitimate arm: no product pages. The builder still loads
  only pages whose frontmatter carries `preamble: true`, so a key naming a
  page without the flag contributes nothing.

  The control is `%{"keys" => ["burrow/page/index.md"]}`, the behaviour with
  no experiment at all (`default_keys/0`).
  """

  @behaviour Platform.Experiments.Surface

  alias Platform.Experiments.Surfaces.DispatchPrompt

  @target "dispatch.preamble"
  @default_keys ["burrow/page/index.md"]
  @max_keys 20
  @key_re ~r/\Aburrow\/page\/[A-Za-z0-9][A-Za-z0-9_.\-\/]*\.md\z/

  @impl true
  def key, do: "dispatch.product_docs_preamble"

  @impl true
  def subject_type, do: "task"

  @impl true
  def path, do: :dispatch

  @doc "The read point this surface is resolved at."
  @impl true
  def targets, do: [@target]

  @doc "The resolution target, `\"dispatch.preamble\"`."
  @spec target() :: String.t()
  def target, do: @target

  @doc "The control arm's keys: the product pages a dispatch carries with no experiment."
  @spec default_keys() :: [String.t()]
  def default_keys, do: @default_keys

  @impl true
  def payload_schema do
    %{
      "type" => "object",
      "required" => ["keys"],
      "properties" => %{
        "keys" => %{
          "type" => "array",
          "maxItems" => @max_keys,
          "items" => %{"type" => "string", "pattern" => "^burrow/page/.+\\.md$"},
          "description" =>
            "burrow/page/*.md file keys to carry in the dispatch preamble. [] carries none. " <>
              "The control is [\"burrow/page/index.md\"]."
        }
      }
    }
  end

  @impl true
  def validate_payload(payload) when is_map(payload) do
    keys = Map.get(payload, "keys", Map.get(payload, :keys))
    unknown = Enum.reject(Map.keys(payload), &(to_string(&1) == "keys"))

    errors =
      keys_errors(keys) ++
        if(unknown == [],
          do: [],
          else: [
            "unknown keys: #{unknown |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")}"
          ]
        )

    case errors do
      [] -> {:ok, %{"keys" => Enum.uniq(keys)}}
      errors -> {:error, errors}
    end
  end

  def validate_payload(_payload), do: {:error, ["payload must be an object"]}

  defp keys_errors(keys) when is_list(keys) do
    cond do
      length(keys) > @max_keys ->
        ["keys must list at most #{@max_keys} pages"]

      Enum.all?(keys, &(is_binary(&1) and Regex.match?(@key_re, &1))) ->
        []

      true ->
        ["every key must be a burrow/page/<name>.md path"]
    end
  end

  defp keys_errors(_keys), do: ["keys must be a list of burrow/page/<name>.md paths"]

  @impl true
  def control_payload(_target, _opts \\ []), do: {:ok, %{"keys" => @default_keys}}

  @impl true
  defdelegate subject_attributes(task_id), to: DispatchPrompt
end
