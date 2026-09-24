defmodule Platform.Responsibilities.Handlers.ExperimentsLabelSignal do
  @moduledoc """
  Registration for `experiments.label_signal` (task 01a0d415 stage 3, the
  experimentation-layer ADR-0052): the blind labeler's responsibility, bundled in
  the `scientist` role.

  The row exists so `Platform.Roles.assignee_for("experiments.label_signal")`
  resolves (the labeler's agent comes from it) and so Control Center → Roles
  shows the Scientist's bundle. The Router never fires it: labelling is
  driven by `Platform.Experiments.Signals.MailSubscriber`, one call per
  inbound mail, through `Platform.Experiments.Labeler` — a tool-less call
  that must not go through the Router's tool-bearing dispatch.

  ## Spec

    * `key` — `"experiments.label_signal"`
    * `trigger_kind` — `event_topic` bound to the null topic
      `platform.experiments.mail_subscriber_only`. Nothing broadcasts to it,
      so the Router's subscription is a no-op (the same trick as
      `Platform.Responsibilities.Handlers.SecurityCveScan`, ADR-0043).
    * `scope` — `global` (experiments may be install-wide)
    * `default_prompt_template` — `"experiments.labeler.v1"`, seeded by
      `20260924190000_seed_experiments_labeler_prompt.exs`.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "experiments.label_signal"
  @feature "experiments"
  @topic "platform.experiments.mail_subscriber_only"
  @template_slug "experiments.labeler.v1"

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The null topic — no publisher ever broadcasts to it."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

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
          "label" => "string",
          "subject_id" => "string | null",
          "confidence" => "number",
          "reason" => "string"
        },
        default_prompt_template: @template_slug,
        cost_profile: "high_freq_low_cost",
        metadata: %{
          "owner" => "platform.experiments",
          "role" => "scientist",
          "executor" => "platform.experiments.mail_subscriber"
        }
      }
    ]
  end

  @impl true
  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    Logger.warning(
      "[experiments.label_signal] the Router should never fire this row (null topic); " <>
        "labelling runs through Platform.Experiments.Signals.MailSubscriber."
    )

    :ok
  end
end
