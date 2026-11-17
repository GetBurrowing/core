defmodule Platform.ShowrunnerSocialFixture do
  @moduledoc """
  A test-only `Platform.Extension` that contributes ONE tool bundle named
  `"social"` (task 01a1eaf6 stage 4). Core never names the real Social
  module, so the showrunner's bundle guard is exercised against this
  stand-in: same bundle name, two tools, one real permission
  (`skills.read`, which a plain org member holds and an owner cap can take
  away).

  `register/0` puts it in `:platform, :extensions` for the calling test and
  restores the previous list on exit; `async: false` only.
  """

  @behaviour Platform.Extension

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Registers this extension (alone) until the calling test exits."
  def register do
    previous = Application.fetch_env(:platform, :extensions)
    Application.put_env(:platform, :extensions, [__MODULE__])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :extensions, value)
        :error -> Application.delete_env(:platform, :extensions)
      end
    end)

    :ok
  end

  @impl true
  def canvas_kinds, do: []

  @impl true
  def mcp_tool_bundles do
    [
      %{
        name: "social",
        definitions:
          for name <- ["social_clip_propose", "social_draft_create"] do
            %{
              name: name,
              description: "Test stand-in for #{name}.",
              parameters: %{},
              returns: "an id",
              limitations: "test only",
              when_to_use: "never"
            }
          end,
        tool_names: ["social_clip_propose", "social_draft_create"],
        permissions: %{
          "social_clip_propose" => "skills.read",
          "social_draft_create" => "skills.read"
        },
        execute: fn tool, _args, _context -> {:ok, %{tool: tool, id: "stub"}} end,
        deny_message: fn _ -> nil end
      }
    ]
  end

  @impl true
  def runtime_channel_events, do: []

  @impl true
  def handle_runtime_event(_event, _runtime_id, _payload), do: :ok

  @impl true
  def runtime_disconnected(_runtime_id), do: :ok

  @impl true
  def live_hooks, do: []

  @impl true
  def experiment_surfaces, do: []

  @impl true
  def experiment_metrics, do: %{}

  @impl true
  def migrations_path, do: nil
end
