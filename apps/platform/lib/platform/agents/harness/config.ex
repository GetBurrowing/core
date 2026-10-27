defmodule Platform.Agents.Harness.Config do
  @moduledoc """
  The harness-neutral shape of an agent's configuration.

  Secret VALUES are never a field of this struct. An MCP server carries the
  `env_names` and `header_names` it needs, not what they are set to; the values
  stay in the file on the agent's machine and are redacted on the way out.

    * `instructions`: markdown or `nil`
    * `skills`, `subagents`, `commands`: `[%{name, description, body}]`
    * `settings`: `%{known: map, raw: map}`, the keys the adapter understands
      and everything else it found (secret-bearing keys are dropped on parse)
    * `mcp_servers`: `[%{name, transport, command, args, url, env_names,
      header_names, managed_by_burrow?}]`
  """

  @concepts [:instructions, :skills, :subagents, :commands, :settings, :mcp_servers]

  defstruct instructions: nil,
            skills: [],
            subagents: [],
            commands: [],
            settings: %{known: %{}, raw: %{}},
            mcp_servers: []

  @type entry :: %{name: String.t(), description: String.t(), body: String.t()}
  @type mcp_server :: %{
          name: String.t(),
          transport: :stdio | :http,
          command: String.t() | nil,
          args: [String.t()],
          url: String.t() | nil,
          env_names: [String.t()],
          header_names: [String.t()],
          managed_by_burrow?: boolean()
        }
  @type t :: %__MODULE__{}

  @doc "Every concept a harness may support."
  def concepts, do: @concepts

  @doc "Burrow's own MCP servers; they carry the runtime token and are never written."
  def burrow_server_names, do: ~w(burrow burrow-channel)

  @doc "Concepts for which this config holds something."
  @spec populated_concepts(t()) :: [atom()]
  def populated_concepts(%__MODULE__{} = c) do
    Enum.filter(@concepts, fn
      :instructions -> c.instructions not in [nil, ""]
      :settings -> c.settings.known != %{} or c.settings.raw != %{}
      other -> Map.fetch!(c, other) != []
    end)
  end

  @doc "A normalised MCP server map; unknown keys are dropped, so a value cannot ride along."
  @spec mcp_server(map()) :: mcp_server()
  def mcp_server(attrs) do
    name = Map.fetch!(attrs, :name)

    %{
      name: name,
      transport: Map.get(attrs, :transport, if(Map.get(attrs, :url), do: :http, else: :stdio)),
      command: Map.get(attrs, :command),
      args: Map.get(attrs, :args, []),
      url: Map.get(attrs, :url),
      env_names: attrs |> Map.get(:env_names, []) |> Enum.sort(),
      header_names: attrs |> Map.get(:header_names, []) |> Enum.sort(),
      managed_by_burrow?: Map.get(attrs, :managed_by_burrow?, name in burrow_server_names())
    }
  end

  @doc "MCP servers this app may write (everything but Burrow's own)."
  def writable_servers(%__MODULE__{mcp_servers: servers}),
    do: servers |> Enum.reject(& &1.managed_by_burrow?) |> Enum.sort_by(& &1.name)
end
