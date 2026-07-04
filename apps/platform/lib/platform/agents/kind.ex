defmodule Platform.Agents.Kind do
  @moduledoc """
  Canonical resolver for an agent's runtime "kind" (task 019f2566 stage 3).

  Every dispatch site — external HTTP call, federated Claude runtime,
  local BEAM built-in — has to make routing decisions off the same
  three-way axis. This module is the single source of truth for that
  classification so prompt builders, dispatchers, and telemetry
  emitters all agree on the atom they use.

  ## Kinds

    * `:ext_single_responsibility` — external HTTP endpoint, single-
      responsibility narrow agent. Hermione's shape:
      `%Agent{kind: "external"}` (llama.cpp / OpenAI-compat / Ollama).
      These agents don't accept templated meta-instructions; they run
      the exact prompt they're handed.

    * `:fed_conversational` — federated conversational Claude runtime.
      Dalton's shape: `%Agent{kind: "native", runtime_type: "external"}`
      (native agent that delegates its turn to an external Claude via
      the OpenClaw bridge). These agents CAN split work off to
      subagents via the Task tool, so templated preambles that tell
      them to do so are meaningful and useful.

    * `:loc_built_in` — local built-in agent running in the platform's
      BEAM runtime (`%Agent{kind: "native", runtime_type: "built_in"}`).
      Default classification for anything that doesn't match the
      external-HTTP or federated-Claude shapes.

  ## Why here vs `agent_data.ex:agent_kind_pill/1`

  The Control Center's `agent_kind_pill/1` renders a three-letter UI
  label ("EXT" / "FED" / "LOC"). This module returns the semantic
  atom, decoupled from any UI concern. `agent_kind_pill/1` could be
  reimplemented on top of `classify/1` and a small map — task 019f2566
  stage 3 leaves that consolidation for a follow-up (the UI helper
  ships nil / non-Agent inputs to "LOC", which is a pill-fallback
  convention the resolver's `:loc_built_in` default doesn't share).

  ## Accepted shapes

  Accepts a `%Platform.Agents.Agent{}` struct OR a plain map that
  carries `:kind` / `:runtime_type` (atom keys) or `"kind"` /
  `"runtime_type"` (string keys). Missing / nil / unrecognised input
  falls through to `:loc_built_in`.
  """

  alias Platform.Agents.Agent

  @type kind :: :ext_single_responsibility | :fed_conversational | :loc_built_in

  @doc """
  Classify an agent into one of the three canonical kinds.

  ## Examples

      iex> Platform.Agents.Kind.classify(%Platform.Agents.Agent{kind: "external"})
      :ext_single_responsibility

      iex> Platform.Agents.Kind.classify(%Platform.Agents.Agent{kind: "native", runtime_type: "external"})
      :fed_conversational

      iex> Platform.Agents.Kind.classify(%Platform.Agents.Agent{kind: "native", runtime_type: "built_in"})
      :loc_built_in

      iex> Platform.Agents.Kind.classify(nil)
      :loc_built_in
  """
  @spec classify(Agent.t() | map() | nil) :: kind()
  def classify(%Agent{kind: "external"}), do: :ext_single_responsibility
  def classify(%Agent{runtime_type: "external"}), do: :fed_conversational
  def classify(%Agent{}), do: :loc_built_in

  def classify(%{} = attrs) do
    case {fetch_string(attrs, :kind), fetch_string(attrs, :runtime_type)} do
      {"external", _} -> :ext_single_responsibility
      {_, "external"} -> :fed_conversational
      _ -> :loc_built_in
    end
  end

  def classify(_), do: :loc_built_in

  defp fetch_string(map, key) when is_atom(key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> Map.get(map, Atom.to_string(key))
    end
  end
end
