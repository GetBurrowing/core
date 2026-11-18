defmodule Platform.Feedback.ClassifierRoute do
  @moduledoc """
  Whether the feedback intake classifier can decide anything (task 01a1e670
  stage 1).

  A thin wrapper: the assignee is `Platform.Roles.assignee_for("feedback.intake")`
  (a `responsibility_overrides` row first, else the role holder), and whether
  that agent has a model is `Platform.Agents.ModelRoute.endpoint/1`. This
  module holds no endpoint rule of its own.

  `health/0` is bounded for `admin_health` and Control Center: a status, a
  reason, the agent's display name, whether an override is in force, and
  record counts. Never the agent's base_url, model, vault_key or any token.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.ModelRoute
  alias Platform.Feedback.IntakeRecord
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Roles.ResponsibilityOverride

  @responsibility_key "feedback.intake"

  @type status :: :ok | {:off, :no_assignee} | {:off, :no_endpoint}

  @doc "The responsibility key the classifier resolves its agent through."
  def responsibility_key, do: @responsibility_key

  @doc "`:ok`, `{:off, :no_assignee}` or `{:off, :no_endpoint}`."
  @spec status() :: status()
  def status, do: status_for(Roles.assignee_for(@responsibility_key))

  defp status_for(nil), do: {:off, :no_assignee}

  defp status_for(agent) do
    case ModelRoute.endpoint(agent) do
      {:ok, _} -> :ok
      {:error, :no_endpoint} -> {:off, :no_endpoint}
    end
  end

  @doc """
  `%{status, reason, agent_name, overridden?, pending, exhausted}`.

  `status` is `"ok"` or `"off"`; `reason` is nil, `"no_assignee"` or
  `"no_endpoint"`. `pending` counts pending records; `exhausted` counts the
  pending records whose `attempts` reached `Intake.max_attempts/0`.
  """
  @spec health() :: map()
  def health do
    agent = Roles.assignee_for(@responsibility_key)

    {status, reason} =
      case status_for(agent) do
        :ok -> {"ok", nil}
        {:off, reason} -> {"off", Atom.to_string(reason)}
      end

    %{
      status: status,
      reason: reason,
      agent_name: agent && agent.name,
      overridden?: overridden?(),
      pending: pending_count(),
      exhausted: exhausted_count()
    }
  end

  defp overridden? do
    Repo.exists?(
      from(o in ResponsibilityOverride, where: o.responsibility_key == ^@responsibility_key)
    )
  end

  # Pending records the retry sweep has stopped retrying.
  defp exhausted_count do
    max = Platform.Feedback.Intake.max_attempts()

    Repo.aggregate(
      from(r in IntakeRecord, where: r.status == "pending" and r.attempts >= ^max),
      :count
    )
  end

  defp pending_count do
    Repo.aggregate(from(r in IntakeRecord, where: r.status == "pending"), :count)
  end
end
