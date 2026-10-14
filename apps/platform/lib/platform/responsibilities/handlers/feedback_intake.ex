defmodule Platform.Responsibilities.Handlers.FeedbackIntake do
  @moduledoc """
  Registration for `feedback.intake` (task 01a11ec3 stage 3): the dedicated
  external-feedback intake responsibility, bundled in the `triage_officer`
  role. It is NOT the janitor and shares no code path with it.

  ## The Router never dispatches it

  Intake is driven by signed GitHub `issues` deliveries
  (`PlatformWeb.GithubWebhookController` → `Platform.Feedback.Intake`), and
  the classification is a tool-less call (`Platform.Feedback.Classifier`).
  A Router fire would hand an agent the issue through its ordinary,
  tool-bearing runtime — exactly the authority this boundary withholds.

  So the row is bound to the null topic `#{"platform.feedback.intake_only"}`
  (nothing broadcasts to it; the same arrangement as
  `Handlers.ExperimentsLabelSignal`), `build_prompt/1` refuses, and
  `handle_output/3` refuses. The row exists so `Roles.assignee_for/1` can name
  the agent whose MODEL classifies, and so Control Center shows the
  responsibility and its capability set.

  ## Capabilities

  `metadata["capabilities"]` mirrors `Platform.Feedback.Intake.capabilities/0`
  — the complete list. `metadata["denied"]` names what the runtime never
  receives. Both are descriptive: the enforcement is that intake runs in
  server code with no tool surface, never that a list is consulted.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "feedback.intake"
  @feature "feedback"
  @topic "platform.feedback.intake_only"
  @template_slug "feedback.intake.v1"

  @denied ~w(repository_checkout repository_write planning execution shell deploy secret_read github_broad promote_from_quarantine)

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The null topic — no publisher ever broadcasts to it."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The capabilities the intake runtime is never given."
  @spec denied_capabilities() :: [String.t()]
  def denied_capabilities, do: @denied

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        trigger_config: %{"topic" => @topic},
        scope: "global",
        context_provided: [],
        output_contract: %{
          "verdict" => "string",
          "reason_code" => "string",
          "summary" => "string | null",
          "confidence" => "number",
          "duplicate_of" => "integer | null"
        },
        default_prompt_template: @template_slug,
        cost_profile: "high_freq_low_cost",
        metadata: %{
          "owner" => "platform.feedback",
          "role" => "triage_officer",
          "executor" => "platform.feedback.intake",
          "capabilities" => Platform.Feedback.Intake.capabilities(),
          "denied" => @denied
        }
      }
    ]
  end

  @impl true
  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @doc """
  Refuses: the Router must never build a dispatch prompt for intake. The
  error is propagated by the Router, so a stray fire aborts instead of
  falling back to the template render.
  """
  @impl true
  @spec build_prompt(map()) :: {:error, :feedback_intake_not_router_dispatched}
  def build_prompt(_context), do: {:error, :feedback_intake_not_router_dispatched}

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    Logger.warning(
      "[feedback.intake] the Router should never fire this row (null topic); " <>
        "intake runs through Platform.Feedback.Intake. Output discarded."
    )

    {:error, :feedback_intake_not_router_dispatched}
  end
end
