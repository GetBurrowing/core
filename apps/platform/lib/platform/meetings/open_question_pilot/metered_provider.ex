defmodule Platform.Meetings.OpenQuestionPilot.MeteredProvider do
  @moduledoc """
  Arm A's side of the pilot's one instrument (task 01a0e8b5): a provider
  module with `Platform.Agents.Providers.Ollama.chat/3`'s contract that
  forwards to `OpenQuestionPilot.Meter.chat/5` with purpose `:prompt_arm`.

  It is handed to `IntentClassifier.decide/1` as `:provider_module`, so
  arm A walks production's provider-call -> parse -> gates path unchanged.
  `decide/1` takes a MODULE, not a struct, so the meter is bound to the
  calling process with `bind/1` (`decide/1` calls its provider inline).
  """

  alias Platform.Meetings.OpenQuestionPilot.Meter

  @key :open_question_pilot_meter

  @doc "Bind `meter` to the calling process; returns the previous binding."
  def bind(%Meter{} = meter), do: Process.put(@key, meter)

  @doc "Remove the calling process's binding."
  def unbind, do: Process.delete(@key)

  def chat(credentials, messages, opts \\ []) do
    meter =
      Process.get(@key) ||
        raise ArgumentError, "OpenQuestionPilot.MeteredProvider called with no meter bound"

    Meter.chat(meter, :prompt_arm, credentials, messages, opts)
  end
end
