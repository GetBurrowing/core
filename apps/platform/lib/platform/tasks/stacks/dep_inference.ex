defmodule Platform.Tasks.Stacks.DepInference do
  @moduledoc """
  Turn a task stack + its members into a validated list of within-stack
  dependency edges.

  Public API is a single call: `infer_edges/2`. The module is stateless —
  one LLM round-trip per call. Retry policy is caller-side (stage 3 wires
  a bounded retry in `Platform.Tasks.Stacks.start_planning/1`).

  ## Flow

    1. Render `stacks.dep_inference.v1` via
       `Platform.Orchestration.PromptTemplates.render_template/2` with
       assigns `%{stack_name, stack_description, members_json}` where
       `members_json` is `Jason.encode!` of the member `[%{id, title,
       description}, ...]` list.
    2. Call the configured adapter (see below). Adapter returns the raw
       response body as a string.
    3. Parse the body with `Jason.decode/1`. Expect a top-level object
       with an `"edges"` key holding a list of `%{"from_task_id",
       "to_task_id", "reason"}` maps.
    4. Reject malformed entries (missing keys, wrong types), self-edges
       (`from_task_id == to_task_id`), and orphan-ids (either endpoint
       not in the members list). Empty result is legitimate.

  ## Return shape

  `{:ok, [%{from_task_id: uuid, to_task_id: uuid, reason: string}]}` on
  success (list may be empty). `{:error, atom}` on terminal failure:

    * `:parse_failed` — response body was not valid JSON, or the
      top-level shape was wrong (missing `"edges"` list).
    * `:empty_response` — adapter returned an empty (or whitespace-only)
      body.
    * `:adapter_failed` — the adapter itself returned an error tuple,
      or the prompt template was not seeded / renderable.

  ## Adapter seam

  The adapter is resolved from application env at call time via
  `Application.get_env(:platform, :dep_inference_adapter,
  AnthropicAdapter)`. Test env overrides this in `config/test.exs`
  to point at `StubAdapter`; the stub reads its canned response from
  the process dictionary so a test case controls the LLM output.

  ## No new schema

  The task brief's `stack_dependencies` shape is an abstraction — the
  actual persistence lives in the JSONB `tasks.dependencies` column
  and flows through `Platform.Tasks.Stacks.add_dependency_edge/4`,
  which already runs DAG validation + cross-stack guards. This module
  intentionally does NOT write anything — stage 3 does the persistence.

  Introduced in task 019f487d stage 2 (ADR 0045).
  """

  require Logger

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Tasks.Stack

  @adapter_env_key :dep_inference_adapter
  @template_slug "stacks.dep_inference.v1"

  @type edge :: %{
          from_task_id: binary(),
          to_task_id: binary(),
          reason: String.t()
        }

  @type infer_error :: :parse_failed | :empty_response | :adapter_failed

  @spec infer_edges(Stack.t(), [struct()]) :: {:ok, [edge]} | {:error, infer_error}
  def infer_edges(%Stack{} = stack, members) when is_list(members) do
    assigns = %{
      stack_name: stack.name || "",
      stack_description: stack.description || "",
      members_json: encode_members(members)
    }

    with {:ok, prompt} <- render_prompt(assigns),
         {:ok, body} <- call_adapter(prompt),
         {:ok, edges} <- parse_edges(body, members) do
      {:ok, edges}
    end
  end

  # ── Prompt rendering ────────────────────────────────────────────────

  defp render_prompt(assigns) do
    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, prompt} when is_binary(prompt) and prompt != "" ->
        {:ok, prompt}

      other ->
        # Template not seeded or renderer raised — surface as
        # :adapter_failed so the caller's retry / fallback path fires.
        Logger.warning(
          "[Stacks.DepInference] prompt template render failed (slug=#{@template_slug}, result=#{inspect(other)})"
        )

        {:error, :adapter_failed}
    end
  end

  defp encode_members(members) do
    members
    |> Enum.map(fn member ->
      %{
        id: fetch_field(member, :id) || "",
        title: fetch_field(member, :title) || "",
        description: fetch_field(member, :description) || ""
      }
    end)
    |> Jason.encode!()
  end

  defp fetch_field(%_{} = struct, key), do: Map.get(struct, key)

  defp fetch_field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp fetch_field(_, _), do: nil

  # ── Adapter call ────────────────────────────────────────────────────

  defp call_adapter(prompt) do
    adapter = Application.get_env(:platform, @adapter_env_key, __MODULE__.AnthropicAdapter)

    case adapter.chat(prompt, []) do
      {:ok, body} when is_binary(body) ->
        {:ok, body}

      {:ok, other} ->
        Logger.warning(
          "[Stacks.DepInference] adapter returned non-binary body (adapter=#{inspect(adapter)}, body=#{inspect(other)})"
        )

        {:error, :adapter_failed}

      {:error, reason} ->
        Logger.warning(
          "[Stacks.DepInference] adapter error (adapter=#{inspect(adapter)}, reason=#{inspect(reason)})"
        )

        {:error, :adapter_failed}
    end
  rescue
    error ->
      Logger.warning(
        "[Stacks.DepInference] adapter raised #{inspect(error.__struct__)}: #{Exception.message(error)}"
      )

      {:error, :adapter_failed}
  end

  # ── Response parsing ────────────────────────────────────────────────

  defp parse_edges(body, members) when is_binary(body) do
    case String.trim(body) do
      "" ->
        Logger.warning("[Stacks.DepInference] empty adapter response body")
        {:error, :empty_response}

      trimmed ->
        decode_and_validate(trimmed, members)
    end
  end

  defp decode_and_validate(trimmed, members) do
    case Jason.decode(trimmed) do
      {:ok, %{"edges" => edges}} when is_list(edges) ->
        member_ids =
          members
          |> Enum.map(&fetch_field(&1, :id))
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        filtered =
          edges
          |> Enum.map(&normalize_edge/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.reject(&invalid_edge?(&1, member_ids))

        {:ok, filtered}

      {:ok, other} ->
        Logger.warning(
          "[Stacks.DepInference] parse failed: top-level shape missing `edges` list (got=#{inspect(other)})"
        )

        {:error, :parse_failed}

      {:error, decode_error} ->
        Logger.warning(
          "[Stacks.DepInference] parse failed: Jason.decode error (#{inspect(decode_error)})"
        )

        {:error, :parse_failed}
    end
  end

  defp normalize_edge(%{
         "from_task_id" => from,
         "to_task_id" => to,
         "reason" => reason
       })
       when is_binary(from) and is_binary(to) and is_binary(reason) do
    %{from_task_id: from, to_task_id: to, reason: reason}
  end

  defp normalize_edge(_), do: nil

  defp invalid_edge?(%{from_task_id: from, to_task_id: to}, member_ids) do
    from == to or
      not MapSet.member?(member_ids, from) or
      not MapSet.member?(member_ids, to)
  end
end
