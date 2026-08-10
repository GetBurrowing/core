defmodule Platform.Responsibilities.RoleTrigger do
  @moduledoc """
  Builds chat-trigger regexes that address a ROLE, never an agent — any agent
  handle in a trigger regex is a bug by construction, because the handle
  outlives the person exactly once and then lies.

  Role keys are a closed roster (`Platform.Roles.Role.valid_keys/0`) and do not
  change when the agent filling the role changes, so a role-derived token stays
  correct across every reassignment with no new runtime machinery. This module
  is pure: it performs NO `Repo` access, because `register/0` runs at boot,
  before any role assignment is knowable.

  Sibling guard: `test/platform/responsibilities/chat_trigger_names_a_role_test.exs`
  asserts no registered chat pattern names an agent slug.
  """

  alias Platform.Roles.Role

  @doc """
  Returns the regex SOURCE (a string, not a compiled `Regex`) for a chat
  trigger addressed at `role_key` followed by `verb_pattern`.

      iex> Platform.Responsibilities.RoleTrigger.chat_regex("designer", "spec")
      "(?i)@designer\\\\s+spec\\\\b"

  Options:

    * `:trailing` — a regex fragment appended verbatim, LAST. Callers that scan
      positional captures (see `design_critique.ex`) depend on their trailing
      group remaining the final group in the pattern.

  Raises `ArgumentError` for an unknown `role_key`: a typo must fail the build,
  not silently register a trigger that can never match.
  """
  @spec chat_regex(String.t(), String.t(), keyword()) :: String.t()
  def chat_regex(role_key, verb_pattern, opts \\ [])
      when is_binary(role_key) and is_binary(verb_pattern) and is_list(opts) do
    unless role_key in Role.valid_keys() do
      raise ArgumentError,
            "unknown role key #{inspect(role_key)} in chat trigger; " <>
              "a chat trigger addresses a role, never an agent. Valid keys: " <>
              Enum.join(Role.valid_keys(), ", ")
    end

    trailing = Keyword.get(opts, :trailing, "")

    "(?i)@" <> role_key <> "\\s+" <> verb_pattern <> "\\b" <> trailing
  end
end
