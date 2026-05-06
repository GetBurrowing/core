defmodule Platform.Tasks.ValidationRegistry do
  @moduledoc """
  Typed validation definitions for the plan engine.

  Each validation kind has a deterministic evaluation path and metadata
  describing how it should be resolved. The engine itself does not care
  *how* a result arrives — it only needs pass/fail from `evaluate_validation/2`.
  This registry provides the catalogue of known kinds and their properties.
  """

  @type kind :: String.t()

  @type definition :: %{
          kind: kind(),
          label: String.t(),
          deterministic: boolean(),
          description: String.t()
        }

  @definitions [
    %{
      kind: "ci_check",
      label: "CI Check",
      deterministic: true,
      description: "Poll CI status via GitHub API"
    },
    %{
      kind: "ci_passed",
      label: "CI Passed",
      deterministic: true,
      description: "Auto-evaluated by GitHub CI webhook on check_suite/workflow_run completion"
    },
    %{
      kind: "pr_merged",
      label: "PR Merged",
      deterministic: false,
      description: "PR merge gate — manual or auto-merge depending on project config"
    },
    %{
      kind: "lint_pass",
      label: "Lint Pass",
      deterministic: true,
      description: "Check runner exit code for linting"
    },
    %{
      kind: "type_check",
      label: "Type Check",
      deterministic: true,
      description: "Check runner exit code for type checking"
    },
    %{
      kind: "test_pass",
      label: "Test Pass",
      deterministic: true,
      description: "Check runner exit code and parse test results"
    },
    %{
      kind: "code_review",
      label: "Code Review",
      deterministic: false,
      description: "Delegate to LLM agent for code review"
    },
    %{
      kind: "manual_approval",
      label: "Manual Approval",
      deterministic: false,
      description: "Wait for human gate in Review domain"
    },
    %{
      kind: "e2e_behavior",
      label: "E2E Behavior",
      deterministic: false,
      description:
        "Planner-authored behavioral script executed by the review agent in a dev environment"
    }
  ]

  @kinds Enum.map(@definitions, & &1.kind)
  @by_kind Map.new(@definitions, &{&1.kind, &1})

  @doc "List all known validation kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Get the definition for a validation kind."
  @spec get(kind()) :: {:ok, definition()} | {:error, :unknown_kind}
  def get(kind) when kind in @kinds, do: {:ok, @by_kind[kind]}
  def get(_kind), do: {:error, :unknown_kind}

  @doc "Check whether a kind is known."
  @spec valid_kind?(kind()) :: boolean()
  def valid_kind?(kind), do: kind in @kinds

  @doc "Check whether a kind has a deterministic evaluation path."
  @spec deterministic?(kind()) :: boolean()
  def deterministic?(kind) do
    case get(kind) do
      {:ok, %{deterministic: det}} -> det
      _ -> false
    end
  end

  @doc "Return all definitions."
  @spec all() :: [definition()]
  def all, do: @definitions
end
