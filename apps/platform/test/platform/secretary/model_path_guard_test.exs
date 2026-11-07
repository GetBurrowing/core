defmodule Platform.Secretary.ModelPathGuardTest do
  @moduledoc """
  The secretary has ONE model path, the agent host's tool-less one-shot
  (task 01a1b721 stage 2). This scans `lib/platform/secretary/**` and the
  `oneshot/3` section of `lib/platform/agent_host.ex` for a reference to any
  module that reaches a model another way: the API-key tool-less chat, a
  direct provider, an HTTP client, an external agent, or the
  responsibilities Router and its agent responder (which put every
  person's batch into one long-lived session with chat-write tools).

  M11: `alias Platform.Agents.ToollessChat` in `secretary/model/host.ex`
  turns this red.
  """
  use ExUnit.Case, async: true

  @forbidden ~r/ToollessChat|Agents\.Providers\.|\bReq\.|ExternalAgents|Responsibilities\.Router|AgentResponder/

  @root Path.expand("../../..", __DIR__)

  defp secretary_files do
    Path.join(@root, "lib/platform/secretary/**/*.ex") |> Path.wildcard()
  end

  defp oneshot_section do
    source = File.read!(Path.join(@root, "lib/platform/agent_host.ex"))
    [_, rest] = String.split(source, "# ── One-shot, tool-less question", parts: 2)
    [section, _] = String.split(rest, "@doc \"True when the connected host advertised", parts: 2)
    section
  end

  test "the scan reads the secretary's modules, the gate among them" do
    files = secretary_files()
    assert files != []
    assert Enum.any?(files, &String.ends_with?(&1, "lib/platform/secretary/model/host.ex"))
    assert oneshot_section() =~ "def oneshot("
  end

  test "no secretary module references another model path" do
    hits =
      for file <- secretary_files(),
          {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@forbidden, line),
          do: "#{Path.relative_to(file, @root)}:#{n}: #{String.trim(line)}"

    assert hits == []
  end

  test "AgentHost.oneshot/3 references no other model path" do
    hits = oneshot_section() |> String.split("\n") |> Enum.filter(&Regex.match?(@forbidden, &1))
    assert hits == []
  end

  test "the pattern catches each forbidden reference (control)" do
    for ref <- [
          "alias Platform.Agents.ToollessChat",
          "Platform.Agents.Providers.Anthropic.chat(x)",
          "Req.post(url)",
          "Platform.ExternalAgents.dispatch(a)",
          "Platform.Responsibilities.Router.fire(k)",
          "Platform.Agents.AgentResponder.respond(m)"
        ] do
      assert Regex.match?(@forbidden, ref), ref
    end

    refute Regex.match?(@forbidden, "{:error, :api_key}")
  end
end
