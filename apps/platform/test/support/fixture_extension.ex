defmodule Platform.FixtureExtension do
  @moduledoc """
  A `Platform.Extension` that exists only in tests (ADR 0055, task 01a0ee08
  stage 2): the positive control for every seam `Platform.Extensions` feeds.
  Each callback contributes one recognisable entry, so a seam that stops
  reading the registry loses that entry and `test/platform/extensions_test.exs`
  goes red.

  `register/0` puts it in `:platform, :extensions` (replacing Play for the
  test) and restores the previous list on exit; `async: false` only.

  Runtime events are answered by sending `{:fixture_event, event, runtime_id,
  payload}` to the pid registered as `:fixture_extension_test_pid`, so a test
  can see the dispatch arrive.
  """

  @behaviour Platform.Extension

  import ExUnit.Callbacks, only: [on_exit: 1]

  @registry Platform.FixtureExtension.Registry
  @migrations Path.expand("fixtures/fixture_extension_migrations", __DIR__)

  @doc "Registers this extension (alone) until the calling test exits."
  def register(extensions \\ [__MODULE__]) do
    previous = Application.fetch_env(:platform, :extensions)
    Application.put_env(:platform, :extensions, extensions)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :extensions, value)
        :error -> Application.delete_env(:platform, :extensions)
      end
    end)

    :ok
  end

  @doc false
  def registry, do: @registry

  @doc false
  def migrations, do: @migrations

  @impl true
  def canvas_kinds, do: [__MODULE__.Kinds.FixtureWidget]

  @impl true
  def mcp_tool_bundles do
    [
      %{
        name: "fixture",
        definitions: [
          %{
            name: "fixture_echo",
            description: "Echoes its args (test fixture).",
            parameters: %{},
            returns: "the args",
            limitations: "test only",
            when_to_use: "never"
          }
        ],
        # `fixture_hidden` is owned but not listed, like a switched-off tool.
        tool_names: ["fixture_echo", "fixture_hidden"],
        execute: &execute/3,
        deny_message: fn
          "fixture_hidden" -> "fixture_hidden is switched off on this install"
          _ -> nil
        end
      }
    ]
  end

  defp execute(tool, args, _context), do: {:ok, %{tool: tool, args: args}}

  @impl true
  def runtime_channel_events, do: ["fixture_ping", "fixture_inert"]

  @impl true
  def handle_runtime_event("fixture_inert", _runtime_id, _payload),
    do: {:inert, "fixture is switched off; further fixture frames are dropped"}

  def handle_runtime_event(event, runtime_id, payload) do
    case Application.get_env(:platform, :fixture_extension_test_pid) do
      pid when is_pid(pid) -> send(pid, {:fixture_event, event, runtime_id, payload})
      _ -> :ok
    end

    :ok
  end

  # Deliberately NOT tolerant of an absent Registry: `Registry.lookup/2` on a
  # registry that is not running raises, which is what proves
  # `Platform.Extensions.runtime_disconnected/1` contains a module's failure.
  @impl true
  def runtime_disconnected(runtime_id) do
    _ = Registry.lookup(@registry, runtime_id)
    :ok
  end

  @impl true
  def live_hooks, do: [{__MODULE__.Hooks, :attach}]

  @impl true
  def experiment_surfaces, do: [__MODULE__.Surface]

  @impl true
  def experiment_metrics do
    %{
      "fixture_metric" => %{
        module: __MODULE__.Metric,
        label: "Fixture metric",
        description: "Test fixture metric.",
        direction: :neutral
      }
    }
  end

  @impl true
  def migrations_path, do: @migrations

  # Paths only: nothing builds these; the registry and the renderer are what
  # the extensions test exercises. `:css` is omitted on purpose, so the
  # registry's default fill is exercised too.
  @impl true
  def assets do
    %{
      js_hooks: Path.expand("fixtures/fixture_extension_assets/hooks.js", __DIR__),
      tailwind_sources: [Path.expand("fixtures/fixture_extension_assets", __DIR__)]
    }
  end

  @impl true
  def rail_items do
    [
      %{
        key: :fixture,
        label: "Fixture",
        path: "/fixture",
        hero_icon: "hero-puzzle-piece",
        cluster: :working,
        root_only?: false
      }
    ]
  end

  # Task 01a1386d-cb5c: the positive control for `Platform.Access.Registry`'s
  # extension seam. `Twin` below omits `permissions/0`, the negative control.
  @impl true
  def permissions do
    [
      %{
        module: "fixture",
        permissions: ["fixture.use"],
        rail: [%{key: :fixture, permission: "fixture.use"}],
        bundles: %{"fixture" => "fixture.use"}
      }
    ]
  end

  defmodule Twin do
    @moduledoc "Claims exactly what `Platform.FixtureExtension` claims: the two-extension clash control."
    @behaviour Platform.Extension
    alias Platform.FixtureExtension, as: F
    @impl true
    def canvas_kinds, do: F.canvas_kinds()
    @impl true
    def mcp_tool_bundles, do: F.mcp_tool_bundles()
    @impl true
    def runtime_channel_events, do: F.runtime_channel_events()
    @impl true
    def handle_runtime_event(event, runtime_id, payload),
      do: F.handle_runtime_event(event, runtime_id, payload)

    @impl true
    def runtime_disconnected(runtime_id), do: F.runtime_disconnected(runtime_id)
    @impl true
    def live_hooks, do: F.live_hooks()
    @impl true
    def experiment_surfaces, do: F.experiment_surfaces()
    @impl true
    def experiment_metrics, do: F.experiment_metrics()
    @impl true
    def migrations_path, do: nil
  end

  defmodule Kinds.FixtureWidget do
    @moduledoc "A canvas kind contributed by the fixture extension."
    use Platform.Chat.Canvas.Kind

    @impl true
    def describe, do: "Fixture widget, described by its own module."

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    attr :node, :map, required: true

    @impl true
    def render(assigns) do
      ~H"""
      <span data-role="fixture-widget"></span>
      """
    end
  end

  defmodule Hooks do
    @moduledoc "The fixture extension's LiveView hook."
    @doc false
    def attach(socket), do: Phoenix.Component.assign(socket, :fixture_hook_attached, true)
  end

  defmodule Surface do
    @moduledoc "An experiment surface contributed by the fixture extension."
    @behaviour Platform.Experiments.Surface

    @impl true
    def key, do: "fixture.surface"
    @impl true
    def subject_type, do: "task"
    @impl true
    def path, do: :dispatch
    @impl true
    def payload_schema, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def validate_payload(payload), do: {:ok, payload}
    @impl true
    def control_payload(_target, _opts), do: {:ok, %{}}
  end

  defmodule Metric do
    @moduledoc "An experiment metric contributed by the fixture extension."
    @doc false
    def compute(_experiment_id, _variant_slug), do: :no_data
  end
end
