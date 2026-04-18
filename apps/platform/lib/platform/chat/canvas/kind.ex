defmodule Platform.Chat.Canvas.Kind do
  @moduledoc """
  Behaviour for canvas node kinds (ADR 0036).

  A "kind" is a single Elixir module under `Platform.Chat.Canvas.Kinds.*` that
  owns everything about a node type: its props schema, renderer, default props,
  emitted events, and presence metadata shape. The registry of kinds
  (`Platform.Chat.Canvas.Kinds`) is the single source of truth from which
  agent tool schemas, patch validation, and renderer dispatch are all derived.

  Each kind module must `use Platform.Chat.Canvas.Kind` and implement the
  callbacks below. `use` injects a `name/0` derived from the module name
  (e.g. `Kinds.Stack` → `"stack"`), which callers use to look up a kind.
  """

  @type child_rule :: :none | :any | [String.t()]

  @type event_descriptor :: %{
          required(:name) => String.t(),
          required(:payload_schema) => map(),
          optional(:description) => String.t()
        }

  @doc "Structural props JSON schema (JSON Schema Draft 7 map)."
  @callback schema() :: map()

  @doc "Styling props JSON schema (variant/tone/density/etc)."
  @callback styling() :: map()

  @doc """
  Child kind whitelist.

    * `:none` — this kind is a leaf, no children allowed
    * `:any`  — children may be any kind
    * `[name, ...]` — only listed kind names allowed (e.g. `[\"checklist_item\"]`)
  """
  @callback children() :: child_rule()

  @doc "Default props for a freshly-inserted node of this kind."
  @callback defaults() :: map()

  @doc "Structured events this kind can emit."
  @callback events() :: [event_descriptor()]

  @doc """
  Kind-specific presence metadata shape.

    * `:none` — no per-node presence metadata beyond engagement level
    * `map`   — JSON Schema describing the kind's presence bag
  """
  @callback presence_shape() :: :none | map()

  @doc """
  Renders the node as a function component.

  Receives an assigns map containing at least `:node` (the node map with
  `"id"`, `"props"`, optionally `"children"`) and `:rendered_children` (a list
  of already-rendered child components; the renderer pre-renders children
  before invoking the parent kind).
  """
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour Platform.Chat.Canvas.Kind

      use Phoenix.Component

      @doc """
      The name under which this kind is registered
      (derived from the module's last segment, snake_cased).
      """
      def name do
        __MODULE__
        |> Module.split()
        |> List.last()
        |> Macro.underscore()
      end

      def styling, do: %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
      def events, do: []
      def presence_shape, do: :none
      def defaults, do: %{}
      def children, do: :none

      defoverridable styling: 0, events: 0, presence_shape: 0, defaults: 0, children: 0
    end
  end
end
