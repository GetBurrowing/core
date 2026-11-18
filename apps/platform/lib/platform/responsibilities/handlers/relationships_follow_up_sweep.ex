defmodule Platform.Responsibilities.Handlers.RelationshipsFollowUpSweep do
  @moduledoc """
  `relationships.follow_up_sweep`: the relationship steward's weekday look at
  client and partner relationships. The one key in the `relationship_steward`
  bundle.

  ## What it keeps track of

    * **follow-ups owed** — a client or partner wrote and nobody answered;
    * **quiet threads** — a relationship that used to talk and went silent for
      `quiet_days/0` days;
    * **commitments from meetings** — what we said we would do in a meeting
      that ended in the last `window_days/0` days, and whether it happened.

  It keeps its ledger in its private memory namespace and drafts the
  follow-ups that are due.

  ## Trigger

  A Router cron, `0 8 * * 1-5` UTC (weekdays 08:00), `global` scope. Gated on
  the `relationship_steward` role having an assignee: an unassigned steward
  is `{:ok, :unfilled}` and reads nothing. Assignment is the enable signal.

  ## It drafts; a human sends

  The steward works for ONE person, the role's escalation human
  (`Platform.SuperAgents.escalate_user_id/1`), and reports to them in its DM.
  Mail reaches it only through the `mail` bundle, whose read tools honour the
  per-mailbox grants of the mail-privacy work (an agent reads only a mailbox
  its owner granted it) and whose write tools write DRAFTS: there is no agent
  send tool anywhere on the tool surface (`Platform.Federation.MailDraftTools`).
  Every draft lands in the org's Drafts tab for a person to read, edit and
  send. The prompt (`relationships.follow_up_sweep.v1`) says so too, but the
  guarantee is the missing tool, not the prompt.

  With no escalation human configured there is nobody to work for:
  `gather_context/2` returns `{:handled, %{parked: :no_escalate_user}}` and
  nothing is dispatched.

  ## Context, scoped to the person it works for

  The meetings it is told about are the ones its escalation human can see
  (`Platform.Meetings.list_meetings_for_user/1`) that ended inside the window.
  Nothing install-wide is read on its behalf.

  ## Tool bundles

  `tool_bundles/0`: `context_read` (meeting spaces, messages, calendar),
  `mail` (granted inbound reads and drafts, no send), `memory` (its ledger)
  and `messaging` (its report in the DM).

  ## Output (external runtimes only)

  `{"summary", "follow_ups", "quiet_threads", "commitments", "draft_ids"}`.
  When drafts were written, ONE question goes to the escalation human: the
  drafts wait for them to send.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Accounts
  alias Platform.Meetings
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.SuperAgents

  @key "relationships.follow_up_sweep"
  @feature "relationships"
  @role "relationship_steward"
  @template_slug "relationships.follow_up_sweep.v1"
  @cron_expression "0 8 * * 1-5"
  @escalation_prefix "Relationship steward: "
  @tool_bundles ~w(context_read mail memory messaging)
  @window_days 7
  @quiet_days 14
  @meeting_cap 20

  @system "You are the Relationship Steward. You keep track of client and partner " <>
            "relationships for one person. You draft; a person sends. You never send mail."

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The role key."
  @spec role() :: String.t()
  def role, do: @role

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @doc "The registered cron expression (weekdays 08:00 UTC)."
  @spec cron_expression() :: String.t()
  def cron_expression, do: @cron_expression

  @doc "The tool bundles the steward's runtime needs."
  @spec tool_bundles() :: [String.t()]
  def tool_bundles, do: @tool_bundles

  @doc "Days back the sweep reads meetings and follow-ups."
  @spec window_days() :: pos_integer()
  def window_days, do: @window_days

  @doc "Days of silence after which a relationship reads as quiet."
  @spec quiet_days() :: pos_integer()
  def quiet_days, do: @quiet_days

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        trigger_config: %{"expression" => @cron_expression},
        scope: "global",
        context_provided: ["meetings", "report_space_id", "window_days", "quiet_days"],
        output_contract: %{
          "summary" => "string",
          "follow_ups" => "list[object]",
          "quiet_threads" => "list[object]",
          "commitments" => "list[object]",
          "draft_ids" => "list[string]"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.relationship_steward",
          "status" => "active",
          "role" => @role,
          "tool_bundles" => @tool_bundles
        }
      }
    ]
  end

  @doc """
  Switches the steward on for one agent: assigns `relationship_steward` and
  records the person it works for. See `Platform.SuperAgents.provision/3`.
  """
  @spec provision(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def provision(attrs), do: SuperAgents.provision(@role, __MODULE__, attrs)

  @impl true
  def gather_context(%Responsibility{} = responsibility, trigger_meta) do
    gather_context(responsibility, trigger_meta, [])
  end

  @doc "`gather_context/2` with `opts[:now]` fixing the clock (tests)."
  @spec gather_context(Responsibility.t(), map(), keyword()) ::
          {:ok, map()} | {:handled, map()}
  def gather_context(%Responsibility{} = responsibility, _trigger_meta, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with user_id when is_binary(user_id) <- SuperAgents.escalate_user_id(responsibility),
         %{} = user <- Accounts.get_user(user_id),
         agent_id when is_binary(agent_id) <- assignee_id(),
         {:ok, %{space_id: space_id}} <- SuperAgents.dm(agent_id, user_id) do
      {:ok,
       %{
         meetings: meetings_text(user, now),
         report_space_id: space_id,
         window_days: Integer.to_string(@window_days),
         quiet_days: Integer.to_string(@quiet_days)
       }}
    else
      nil ->
        Logger.warning("[#{@key}] parked: no escalation human (or no assignee) configured")
        {:handled, %{parked: :no_escalate_user}}

      other ->
        Logger.warning("[#{@key}] parked: #{inspect(other)}")
        {:handled, %{parked: :no_report_space}}
    end
  end

  @impl true
  def build_prompt(context) when is_map(context) do
    assigns =
      Map.new(~w(meetings report_space_id window_days quiet_days)a, fn key ->
        {Atom.to_string(key), to_string(Map.get(context, key, ""))}
      end)

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, body} when is_binary(body) and body != "" ->
        {:ok, %{system: @system, user: body}}

      _ ->
        case PromptTemplates.render_default(@template_slug, assigns) do
          {:ok, body} -> {:ok, %{system: @system, user: body}}
          {:error, _} -> {:error, :template_missing}
        end
    end
  end

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(%Responsibility{} = responsibility, output, _trigger_meta) do
    with {:ok, decoded} <- SuperAgents.decode(output) do
      drafts = decoded |> Map.get("draft_ids", []) |> List.wrap() |> Enum.filter(&is_binary/1)

      if drafts != [] and is_binary(assignee_id()) do
        SuperAgents.escalate(
          assignee_id(),
          SuperAgents.escalate_user_id(responsibility),
          "#{length(drafts)} follow-up draft(s) are waiting for you to send",
          detail:
            to_string(decoded["summary"] || "") <>
              "\n\nOpen Email, then Drafts. Nothing has been sent.",
          prefix: @escalation_prefix,
          source: "relationship_steward"
        )
      end

      :ok
    end
  rescue
    error ->
      Logger.warning("[#{@key}] handle_output raised: #{Exception.message(error)}")
      {:error, :handle_output_failed}
  end

  # ── internals ──

  defp assignee_id do
    case Roles.assignee_for(@key) do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp meetings_text(user, now) do
    since = DateTime.add(now, -@window_days * 86_400, :second)

    user
    |> Meetings.list_meetings_for_user()
    |> Enum.filter(fn m ->
      match?(%DateTime{}, m.ended_at) and DateTime.compare(m.ended_at, since) != :lt
    end)
    |> Enum.sort_by(& &1.ended_at, {:desc, DateTime})
    |> Enum.take(@meeting_cap)
    |> case do
      [] ->
        "(no meetings ended in the last #{@window_days} days)"

      meetings ->
        Enum.map_join(meetings, "\n", fn m ->
          "- #{m.name || "Untitled meeting"} (meeting #{m.id}, ended " <>
            "#{Calendar.strftime(m.ended_at, "%Y-%m-%d")}" <>
            if(m.chat_space_id, do: ", space #{m.chat_space_id})", else: ")")
        end)
    end
  rescue
    error ->
      Logger.warning("[#{@key}] meetings read failed: #{Exception.message(error)}")
      "(meetings could not be read this run)"
  end
end
