defmodule Platform.Meetings.OpenQuestionPilot.ImpSmokeTest do
  @moduledoc """
  Compile gate for the Imp pilot (task 01a0e8b5 stage 1): the dependency
  resolved, compiled (erlexec's C++ port, jaxon's NIF) and its modules load
  in core's BEAM.
  """
  use ExUnit.Case, async: true

  test "Imp loads" do
    assert Code.ensure_loaded?(Imp)
  end

  test "Imp.LM.Static loads" do
    assert Code.ensure_loaded?(Imp.LM.Static)
  end

  test "the Imp application is part of the build" do
    assert {:ok, vsn} = :application.get_key(:imp, :vsn)
    assert Version.match?(to_string(vsn), "~> 0.6")
  end
end
