defmodule Platform.Agents.TeamCheck.Classifier do
  @moduledoc """
  Classify one agent's evidence into why it is stuck (task 01a1b6de stage 3).

  A PURE function: no Repo, no PubSub, no HTTP and no model call. Everything
  it reads arrives in the evidence map `Platform.Agents.TeamCheck` builds from
  real rows (federation presence, `runtime_events`), so the same evidence
  always yields the same class.

  ## Classes, in precedence order

    * `:offline` — no presence beyond `offline_after_seconds`. Wins over EVERY
      text class: an agent whose last blocker said 403 but which has not been
      seen since is offline, and asking someone to grant access to a process
      that is not running fixes nothing.
    * `:access` — 403 / permission denied / read-only / not a collaborator.
    * `:credentials` — 401 / expired or invalid token / auth failed.
    * `:toolchain` — command not found / missing mix, elixir or node / not
      installed.
    * `:spend_consent` — credits / quota / payment / needs approval to spend.
    * `:ok` — present, and no open failure matched a class. Open failures that
      match nothing are named in the evidence rather than dropped.

  Among text classes the NEWEST open failure that matches any class decides;
  within one failure's text the order above decides.

  Core records no git-push result of its own: a refused push reaches core
  only as the text of an `execution.blocked` row (`description`,
  `required_capability`), which is what the patterns read.

  ## Who fixes it

  Every non-`:ok` class names a fixer: the agent's sponsoring human when the
  agent is bound to one (its runtime's `owner_user_id`), else the install
  owner. Granting anything is out of scope here; the classifier only names
  who can.
  """

  @type class :: :offline | :access | :credentials | :toolchain | :spend_consent | :ok
  @type person :: %{id: String.t(), name: String.t()} | nil
  @type failure :: %{
          required(:event_type) => String.t(),
          required(:text) => String.t(),
          required(:occurred_at) => DateTime.t()
        }
  @type evidence :: %{
          required(:presence) => %{
            required(:online) => boolean(),
            optional(:last_seen_at) => DateTime.t() | nil,
            optional(:source) => atom()
          },
          required(:now) => DateTime.t(),
          required(:offline_after_seconds) => non_neg_integer(),
          optional(:failures) => [failure()],
          optional(:sponsor) => person(),
          optional(:owner) => person()
        }
  @type result :: %{
          class: class(),
          evidence: String.t(),
          basis: String.t(),
          fixer: person(),
          action: String.t() | nil
        }

  @classes [:offline, :access, :credentials, :toolchain, :spend_consent, :ok]

  # Order is precedence within one failure's text.
  @patterns [
    access:
      ~r/\b403\b|permission denied|permission to .* denied|forbidden|read[- ]only|not a collaborator|access denied|write access|not authori[sz]ed to (push|write)/i,
    credentials:
      ~r/\b401\b|(expired|invalid|revoked|bad) (token|credentials?|password)|token (has )?expired|auth(entication)? failed|unauthori[sz]ed|could not read username|login required/i,
    toolchain:
      ~r/command not found|not installed|executable not found|missing (mix|elixir|erlang|node|npm|git)\b|\b(mix|elixir|erl|node|npm)\b[^.]*\bnot found/i,
    spend_consent:
      ~r/\bcredits?\b|quota|\b402\b|payment required|billing|approval to spend|spend(ing)? (limit|cap|approval)/i
  ]

  @actions %{
    offline: "bring its runtime back online",
    access: "grant it the access it was refused",
    credentials: "refresh or replace its credentials",
    toolchain: "install the missing tool where it runs",
    spend_consent: "approve the spend or top up its credits"
  }

  @evidence_max 200

  @doc "Every class `classify/1` can return."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc """
  Classify `evidence` (see `t:evidence/0`). Returns the class, a ONE-line
  evidence string, the person who can fix it and what they should do
  (`fixer`/`action` are nil for `:ok`), and `basis`: the STABLE part of the
  state the class was read from (task 01a1b6de stage 4). Unlike `evidence`
  it carries no age that grows between checks, so the unblock ask's state
  fingerprint changes only when the state does: for `:offline` the last
  seen instant (or "never"), for a text class the deciding failure's type
  and text.
  """
  @spec classify(evidence()) :: result()
  def classify(%{presence: presence, now: now, offline_after_seconds: threshold} = evidence) do
    failures = evidence |> Map.get(:failures, []) |> List.wrap() |> newest_first()

    case offline(presence, now, threshold) do
      {:offline, line, basis} ->
        result(:offline, line, basis, evidence)

      :present ->
        case first_text_class(failures) do
          {class, failure} ->
            line = "#{failure.event_type}: #{failure.text}"
            result(class, line, line, evidence)

          nil ->
            result(:ok, ok_line(failures), "ok", evidence)
        end
    end
  end

  @doc "The class one failure text matches, or nil."
  @spec text_class(String.t() | nil) :: class() | nil
  def text_class(text) when is_binary(text) do
    Enum.find_value(@patterns, fn {class, regex} -> if Regex.match?(regex, text), do: class end)
  end

  def text_class(_), do: nil

  defp offline(%{online: true}, _now, _threshold), do: :present

  defp offline(presence, now, threshold) do
    case Map.get(presence, :last_seen_at) do
      %DateTime{} = seen ->
        age = DateTime.diff(now, seen, :second)

        if age > threshold do
          {:offline,
           "not connected; last seen #{age_words(age)} ago (#{DateTime.to_iso8601(seen)})",
           "offline: last seen #{DateTime.to_iso8601(seen)}"}
        else
          :present
        end

      _ ->
        {:offline, "not connected and never seen#{source_words(presence)}", "offline: never seen"}
    end
  end

  defp first_text_class(failures) do
    Enum.find_value(failures, fn failure ->
      case text_class(failure.text) do
        nil -> nil
        class -> {class, failure}
      end
    end)
  end

  defp ok_line([]), do: "present; no open failures"

  defp ok_line([newest | _] = failures) do
    "present; #{length(failures)} open failure(s) matched no class, newest " <>
      "#{newest.event_type}: #{newest.text}"
  end

  defp result(:ok, line, basis, _evidence),
    do: %{class: :ok, evidence: one_line(line), basis: basis, fixer: nil, action: nil}

  defp result(class, line, basis, evidence) do
    %{
      class: class,
      evidence: one_line(line),
      basis: basis,
      fixer: Map.get(evidence, :sponsor) || Map.get(evidence, :owner),
      action: Map.fetch!(@actions, class)
    }
  end

  defp newest_first(failures) do
    Enum.sort_by(failures, & &1.occurred_at, {:desc, DateTime})
  end

  defp one_line(text) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(text) > @evidence_max do
      String.slice(text, 0, @evidence_max - 1) <> "…"
    else
      text
    end
  end

  defp source_words(%{source: :no_runtime}), do: " (no runtime is registered for it)"
  defp source_words(%{source: :external_probe}), do: " (no successful fire or probe)"
  defp source_words(_), do: ""

  defp age_words(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp age_words(seconds) when seconds < 172_800, do: "#{div(seconds, 3600)}h"
  defp age_words(seconds), do: "#{div(seconds, 86_400)}d"
end
