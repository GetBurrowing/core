defmodule Platform.Federation.AdminTools do
  @moduledoc """
  Definitions for the `admin` bundle (task 01a17b10 stage 3): the install's
  infra-desk tools. Behaviour and the audit wrapper live in
  `Platform.Admin.Tools`.

  No tool takes a confirm or approve argument, and none is behind an
  allow-list. The one capability boundary is `[agents] full_root`: with it off,
  `admin_restart`, `admin_deploy` and `admin_rollback` return a structured
  `requires_full_root` result naming the manifest key.
  """

  @names ~w(admin_health admin_logs admin_env_names admin_migrations admin_rpc admin_restart admin_deploy admin_rollback)

  @doc "Every tool name in the bundle."
  def names, do: @names

  def definitions do
    [
      definition(
        "admin_health",
        "Health of core, its database, the memory service and the agent host.",
        %{},
        "core, repo, memory, agent_host (configured, connected, full_root)",
        "First stop when something looks wrong on this install."
      ),
      definition(
        "admin_logs",
        "Recent log lines, scrubbed of credentials. source `core` is core's own recent log; source `agent` is an agent's journal, asked of the agent host.",
        %{
          source: opt("string", "`core` (default) or `agent`."),
          agent_id: opt("string", "Agent UUID for source `agent`; defaults to you."),
          lines: opt("integer", "How many lines, at most 500. Default 100.")
        },
        "source, lines",
        "To see what core or an agent has been logging."
      ),
      definition(
        "admin_env_names",
        "The NAMES of core's environment variables and of each native agent's env file. Values are never returned.",
        %{},
        "core (names), agents (agent_id, name, names or status)",
        "To check whether a variable is set without reading it."
      ),
      definition(
        "admin_migrations",
        "Database migration status, or run the pending migrations.",
        %{action: opt("string", "`status` (default) or `run`.")},
        "status: up, pending (versions and names). run: ran (versions)",
        "Before or after a deploy, or when a boot reports a pending migration."
      ),
      definition(
        "admin_rpc",
        "Evaluate an Elixir expression in the running core release. The variable `args` is the map you pass as `args`. The result is inspected, scrubbed and truncated. This is a shell inside core: it is not gated by full_root.",
        %{
          expression: req("string", "Elixir expression."),
          args: opt("object", "Bound as the variable `args`, with string keys.")
        },
        "result (string)",
        "When no other admin tool answers the question."
      ),
      definition(
        "admin_restart",
        "Restart a compose service through the agent host. Needs full_root; otherwise returns requires_full_root.",
        %{service: opt("string", "Compose service name. Default `core-platform`.")},
        "service, restarted, or requires_full_root with the manifest key",
        "To bounce a stuck service."
      ),
      definition(
        "admin_deploy",
        "Move a compose service to an image tag (pull, recreate) through the agent host. Needs full_root; otherwise returns requires_full_root.",
        %{
          service: opt("string", "Compose service name. Default `core-platform`."),
          tag: req("string", "Image tag to run.")
        },
        "service, image, previous, or requires_full_root with the manifest key",
        "To pin or advance an image tag."
      ),
      definition(
        "admin_rollback",
        "Move a compose service back to a tag, or to the image before the last admin_deploy. Needs full_root; otherwise returns requires_full_root.",
        %{
          service: opt("string", "Compose service name. Default `core-platform`."),
          tag: opt("string", "Tag to roll back to; defaults to the image before the last deploy.")
        },
        "service, image, previous, or requires_full_root with the manifest key",
        "After a bad deploy."
      )
    ]
  end

  defp req(type, description), do: %{type: type, required: true, description: description}
  defp opt(type, description), do: %{type: type, required: false, description: description}

  defp definition(name, description, parameters, returns, usage),
    do: %{
      name: name,
      description: description,
      parameters: parameters,
      returns: returns,
      limitations:
        "Requires install.admin (an install admin's agent; capped at its owner). Every call writes an audit row. Takes no confirmation argument.",
      when_to_use: usage
    }
end
