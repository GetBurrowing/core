defmodule PlatformWeb.ControlCenter.NativeStatus do
  @moduledoc """
  What a row (and the managed-agent detail header) on Agent Resources shows,
  derived from one directory entry (task 01a10322 stage 4).

  Pure: no socket, no DB. `PlatformWeb.ControlCenter.AgentData.list_agents/0`
  attaches the inputs (`:managed?`, `:desired_state`, `:observed`,
  `:host_connected?`, `:runtime_label`), and this module turns them into the
  design canvas's states table (01a10325-8f2d-7001-b858-b92639451ceb):

  | State            | Tag                              | Row button        |
  |------------------|----------------------------------|-------------------|
  | Running          | none                             | none              |
  | Starting         | "Starting", base-content/60      | disabled, same width |
  | Stopped          | "Stopped", base-content/60       | Start             |
  | Crashed          | error icon + "Crashed"           | Restart           |
  | Needs login      | "Needs login", warning fill      | Log in            |
  | Restart to apply | "Restart to apply", lowest       | Restart           |

  Tags appear on exceptions only, and at most one shows: the order above
  (needs login, crashed, stopped / starting, restart to apply) is the
  priority. Green is never the only signal: every state that is not running
  carries words.

  Two inputs the canvas does not name, and what they read as (listed as
  deviations in the stage 4 PR):

    * no observation, desired `stopped`: "Stopped", with Start. The person
      chose stopped, and Start works whether or not a host is connected (the
      desire is recorded and converged when one joins);
    * no observation, desired `running`, no host connected: "Host offline",
      with no button, because nothing on this page can fix it.
  """

  @type tone :: :warning | :error | :muted
  @type action :: :log_in | :start | :restart | :starting | nil
  @type view :: %{
          state: atom(),
          tag: {tone(), String.t()} | nil,
          action: action(),
          running?: boolean()
        }

  @doc "The row view for one directory entry."
  @spec row(map()) :: view()
  def row(%{managed?: true} = entry), do: managed(entry)

  def row(%{runtime_type: "external"} = entry) do
    if entry[:running?] do
      quiet(:running, true) |> with_agent_status(entry)
    else
      %{quiet(:offline, false) | tag: {:muted, "Offline"}} |> with_agent_status(entry)
    end
  end

  def row(entry) do
    if entry[:running?] do
      quiet(:running, true) |> with_agent_status(entry)
    else
      label = entry |> Map.get(:runtime_status, :idle) |> humanize()
      %{quiet(:idle, false) | tag: {:muted, label}} |> with_agent_status(entry)
    end
  end

  @doc """
  The managed-agent view: the observed state the host reported, falling back
  to the desired state when the host has reported nothing.
  """
  @spec managed(map()) :: view()
  def managed(entry) do
    observed = Map.get(entry, :observed)

    case observed && observed.state do
      :needs_login ->
        # Log in opens the detail pane's login steps (stage 6). The login
        # page the host reported is deliberately not carried into the view.
        %{quiet(:needs_login, false) | tag: {:warning, "Needs login"}, action: :log_in}

      :crashed ->
        %{quiet(:crashed, false) | tag: {:error, "Crashed"}, action: :restart}

      :stopped ->
        stopped()

      :starting ->
        starting()

      :running ->
        if restart_to_apply?(entry) do
          %{quiet(:running, true) | tag: {:muted, "Restart to apply"}, action: :restart}
        else
          quiet(:running, true)
        end

      nil ->
        cond do
          Map.get(entry, :desired_state) != "running" -> stopped()
          Map.get(entry, :host_connected?) -> starting()
          true -> %{quiet(:host_offline, false) | tag: {:muted, "Host offline"}}
        end
    end
  end

  @doc """
  True when the running agent has not picked up a saved file. `AgentData`
  derives `:restart_to_apply?` with `Platform.Agents.NativeAgents.restart_to_apply?/2`
  (stored versions against the host's `files_applied`), so this stays pure.
  """
  @spec restart_to_apply?(map() | nil) :: boolean()
  def restart_to_apply?(%{restart_to_apply?: true}), do: true
  def restart_to_apply?(_), do: false

  @doc """
  Which of the detail header's three buttons are enabled, for a managed view.
  Disabled at the boundaries, never hidden. `in_flight?` is true while a
  Restart this page sent has not been answered.
  """
  @spec header_buttons(view(), boolean(), boolean()) :: %{
          start: boolean(),
          restart: boolean(),
          stop: boolean()
        }
  def header_buttons(%{state: state}, host_connected?, in_flight?) do
    cond do
      in_flight? or not host_connected? ->
        %{start: false, restart: false, stop: false}

      state == :stopped ->
        %{start: true, restart: false, stop: false}

      state == :crashed ->
        %{start: false, restart: true, stop: true}

      state == :starting ->
        %{start: false, restart: false, stop: true}

      true ->
        %{start: false, restart: true, stop: true}
    end
  end

  @doc "The harness as the meta line names it."
  @spec harness_label(String.t() | nil) :: String.t()
  def harness_label("codex"), do: "Codex CLI"
  def harness_label(_), do: "Claude Code"

  @doc "The host's reported capability profile, as the header names it."
  @spec profile_label(String.t() | nil) :: String.t() | nil
  def profile_label("full_machine"), do: "Full machine"
  def profile_label("contained"), do: "Contained"
  def profile_label(nil), do: nil
  def profile_label(other) when is_binary(other), do: humanize(other)

  @doc """
  The row's one meta line: "Claude Code on this server · <model>" for a
  native agent, "Federated from <runtime>" for a federated one, the primary
  model and source for a built-in one.
  """
  @spec meta_line(map()) :: String.t()
  def meta_line(%{managed?: true} = entry) do
    base = harness_label(Map.get(entry, :harness)) <> " on this server"

    case Map.get(entry, :primary_model) do
      model when is_binary(model) and model not in ["", "no primary model"] ->
        base <> " · " <> model

      _ ->
        base
    end
  end

  def meta_line(%{runtime_type: "external"} = entry) do
    "Federated from " <> (Map.get(entry, :runtime_label) || "an unknown runtime")
  end

  # Built-in agents keep the two facts their old pills carried, the model and
  # where the agent is defined, in the one line.
  def meta_line(entry) do
    [
      Map.get(entry, :primary_model) || "no primary model",
      entry |> Map.get(:source_label) |> source_label()
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp source_label(label) when is_binary(label),
    do: PlatformWeb.ControlCenter.Helpers.humanize_value(label)

  defp source_label(_), do: nil

  defp stopped, do: %{quiet(:stopped, false) | tag: {:muted, "Stopped"}, action: :start}
  defp starting, do: %{quiet(:starting, false) | tag: {:muted, "Starting"}, action: :starting}

  defp quiet(state, running?),
    do: %{state: state, tag: nil, action: nil, running?: running?}

  # A paused or archived agent says so when nothing louder applies.
  defp with_agent_status(%{tag: nil} = view, %{status: status})
       when is_binary(status) and status != "active",
       do: %{view | tag: {:muted, humanize(status)}}

  defp with_agent_status(view, _entry), do: view

  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  defp humanize(value) when is_binary(value) do
    value |> String.replace(["_", "-"], " ") |> String.capitalize()
  end
end
