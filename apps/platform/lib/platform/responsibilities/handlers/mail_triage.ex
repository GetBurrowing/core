defmodule Platform.Responsibilities.Handlers.MailTriage do
  @moduledoc """
  Registration for `mail.triage` (task 01a1f426 stage 1): the morning
  briefing's mail triage. Mirrors the other registration-only handlers
  whose work runs outside the Router (`ExperimentsLabelSignal`,
  `FeedbackIntake`).

  The row exists so `Platform.Roles.assignee_for("mail.triage")` resolves
  (the triage agent comes from it, through a responsibility override or a
  role bundle) and so Control Center shows the key. The Router never fires
  it: triage runs through `Platform.Mail.Triage`, a tool-less classifier
  call per (reader, email) that must not go through the Router's
  tool-bearing dispatch.

  ## Spec

    * `key` — `"mail.triage"`
    * `trigger_kind` — `event_topic` bound to the null topic
      `platform.mail.triage_only`. Nothing broadcasts to it, so the
      Router's subscription is a no-op.
    * `scope` — `global`
    * `default_prompt_template` — `"mail.triage.classify.v1"`, seeded by
      `20261119150100_seed_mail_triage_classify_prompt.exs`.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "mail.triage"
  @feature "mail"
  @topic "platform.mail.triage_only"
  @template_slug "mail.triage.classify.v1"

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
          "tier" => "string",
          "needs" => "string",
          "why" => "string",
          "next_step" => "string | null"
        },
        default_prompt_template: @template_slug,
        cost_profile: "high_freq_low_cost",
        metadata: %{
          "owner" => "platform.mail",
          "executor" => "platform.mail.triage"
        }
      }
    ]
  end

  @impl true
  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def build_prompt(_context), do: {:error, :no_build_prompt}

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    Logger.warning(
      "[mail.triage] the Router should never fire this row (null topic); " <>
        "triage runs through Platform.Mail.Triage."
    )

    :ok
  end
end
