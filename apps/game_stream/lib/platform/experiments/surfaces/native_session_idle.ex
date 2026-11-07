defmodule Platform.Experiments.Surfaces.NativeSessionIdle do
  @moduledoc "Idle timeout variants; record idle server-seconds/player-minute and reconnect success."
  @behaviour Platform.Experiments.Surface
  def key, do: "game_stream.native_idle"
  def subject_type, do: "channel"
  def path, do: :dispatch
  def targets, do: ["native_session.start"]

  def variants,
    do: [%{"idle_timeout_s" => 300}, %{"idle_timeout_s" => 600}, %{"idle_timeout_s" => 900}]

  def payload_schema,
    do: %{
      "type" => "object",
      "required" => ["idle_timeout_s"],
      "properties" => %{"idle_timeout_s" => %{"type" => "integer", "enum" => [300, 600, 900]}},
      "additionalProperties" => false
    }

  def validate_payload(%{"idle_timeout_s" => n} = p)
      when map_size(p) == 1 and n in [300, 600, 900], do: {:ok, p}

  def validate_payload(_), do: {:error, ["idle_timeout_s must be 300, 600 or 900"]}
  def control_payload(_, _opts \\ []), do: {:ok, %{"idle_timeout_s" => 600}}
  def subject_attributes(_), do: %{}
end
