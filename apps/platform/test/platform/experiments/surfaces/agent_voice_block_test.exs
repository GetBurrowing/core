defmodule Platform.Experiments.Surfaces.AgentVoiceBlockTest do
  @moduledoc "Task 01a1b6ff stage 1: the `agents.voice_block` surface."

  use ExUnit.Case, async: true

  alias Platform.Agents.VoiceBlock
  alias Platform.Agents.VoiceCheck
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.AgentVoiceBlock, as: S

  test "is registered with its key, subject, path and one target" do
    assert Surfaces.get("agents.voice_block") == S
    assert S in Surfaces.core_surfaces()
    assert S.key() == "agents.voice_block"
    assert S.subject_type() == "agent"
    assert S.path() == :dispatch
    assert S.targets() == ["agents.voice_block"]
    assert {:ok, _} = Jason.encode(S.payload_schema())
  end

  test "the control is the voice block text and the default banned list" do
    assert {:ok, %{"block" => block, "banned" => banned} = control} =
             S.control_payload("agents.voice_block")

    assert map_size(control) == 2
    assert block == VoiceBlock.text()
    assert banned == VoiceCheck.default_banned()
  end

  test "validate_payload accepts the control unchanged" do
    {:ok, control} = S.control_payload("agents.voice_block")
    assert S.validate_payload(control) == {:ok, control}
  end

  test "validate_payload accepts a variant block and a shorter list" do
    payload = %{"block" => "## How you talk\n\nVARIANT", "banned" => ["delve"]}
    assert S.validate_payload(payload) == {:ok, payload}
  end

  test "validate_payload refuses a block without the marker heading" do
    assert {:error, [message]} =
             S.validate_payload(%{"block" => "How you talk\n\nx", "banned" => []})

    assert message =~ "## How you talk"

    assert {:error, [_]} =
             S.validate_payload(%{"block" => "intro\n## How you talk\n", "banned" => []})
  end

  test "validate_payload refuses an unknown key" do
    {:ok, control} = S.control_payload("agents.voice_block")

    assert {:error, ["unknown keys: \"model\""]} =
             S.validate_payload(Map.put(control, "model", "big"))
  end

  test "validate_payload refuses a non-list banned and a bad entry" do
    block = VoiceBlock.text()

    assert {:error, ["banned must be a list of strings"]} =
             S.validate_payload(%{"block" => block, "banned" => "delve"})

    assert {:error, ["banned must be a list of strings"]} =
             S.validate_payload(%{"block" => block})

    assert {:error, ["banned must contain only non-empty strings"]} =
             S.validate_payload(%{"block" => block, "banned" => ["delve", " "]})

    assert {:error, ["banned must contain only non-empty strings"]} =
             S.validate_payload(%{"block" => block, "banned" => [7]})
  end

  test "validate_payload enforces the size bounds" do
    long = "## How you talk\n" <> String.duplicate("x", 8000)

    assert {:error, ["block must be at most 8000 characters"]} =
             S.validate_payload(%{"block" => long, "banned" => []})

    many = Enum.map(1..201, &"phrase #{&1}")

    assert {:error, ["banned must have at most 200 phrases"]} =
             S.validate_payload(%{"block" => VoiceBlock.text(), "banned" => many})

    assert {:ok, _} =
             S.validate_payload(%{
               "block" => VoiceBlock.text(),
               "banned" => Enum.take(many, 200)
             })
  end

  test "validate_payload refuses a non-map" do
    assert {:error, [_]} = S.validate_payload("x")
    assert {:error, [_]} = S.validate_payload(nil)
  end
end
