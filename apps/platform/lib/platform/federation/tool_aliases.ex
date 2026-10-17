defmodule Platform.Federation.ToolAliases do
  @moduledoc """
  Hidden, execute-only aliases for the 17 tool names that used to be dotted
  (task 01a14a7f stage 3).

  Core listed `skill.list`, `canvas.create`, `attachment.upload_start` and 14
  more with a dot while every other tool used an underscore. They are now
  listed by their underscore name only. The old name still CALLS: it is
  resolved here, at `Platform.Federation.ToolCall.invoke/4`, before
  authorization, so `/mcp` `tools/call`, the runtime socket's `tool_call` and
  `suite_run` inner calls all accept it, and it needs exactly the grant its
  underscore name needs, never more.

  An alias is never LISTED: `tools/list`, `ToolAuthorization.deny_reason/1`'s
  catalogue and `suite_run_describe` read tool definitions, and no definition
  carries an alias name. Code mode binds the alias name too
  (`Platform.CodeMode.Bindings.tool_names/1`), so a script written against
  `suite.canvas.create(...)` keeps working.

  ## Removing the aliases

  A dotted call is countable two ways. The `dispatch_tool_calls` ledger row
  records the name the caller SENT in `tool`, and every resolved alias emits
  `[:platform, :federation, :legacy_tool_name]` with
  `%{legacy: name, canonical: canonical, runtime_id: id}` metadata. Removal is
  a separate task, gated on this reading zero across every install:

      SELECT tool, runtime_id, count(*) FROM dispatch_tool_calls
      WHERE tool LIKE '%.%' AND inserted_at > $since GROUP BY 1, 2;
  """

  @aliases %{
    "attachment.get_inline" => "attachment_get_inline",
    "attachment.upload_inline" => "attachment_upload_inline",
    "attachment.upload_start" => "attachment_upload_start",
    "canvas.create" => "canvas_create",
    "canvas.describe" => "canvas_describe",
    "canvas.list_kinds" => "canvas_list_kinds",
    "canvas.patch" => "canvas_patch",
    "canvas.restore" => "canvas_restore",
    "canvas.template" => "canvas_template",
    "canvas.versions" => "canvas_versions",
    "feedback.submit" => "feedback_submit",
    "prototype.publish" => "prototype_publish",
    "prototype.rollback" => "prototype_rollback",
    "prototype.versions" => "prototype_versions",
    "skill.get" => "skill_get",
    "skill.list" => "skill_list",
    "skill.upsert" => "skill_upsert"
  }

  @legacy_event [:platform, :federation, :legacy_tool_name]

  @doc "Legacy (dotted) name => canonical (underscore) name."
  @spec aliases() :: %{String.t() => String.t()}
  def aliases, do: @aliases

  @doc "Every legacy name, sorted."
  @spec legacy_names() :: [String.t()]
  def legacy_names, do: @aliases |> Map.keys() |> Enum.sort()

  @doc """
  `{:alias, canonical}` for a legacy name, `:canonical` for anything else.

  Anything else includes names that are not tools at all: resolving never
  invents a name, so an unknown name stays unknown and is refused by
  authorization under the name the caller sent.
  """
  @spec resolve(String.t()) :: {:alias, String.t()} | :canonical
  def resolve(name) when is_binary(name) do
    case Map.fetch(@aliases, name) do
      {:ok, canonical} -> {:alias, canonical}
      :error -> :canonical
    end
  end

  @doc "The telemetry event a resolved legacy name emits."
  @spec legacy_event() :: [atom()]
  def legacy_event, do: @legacy_event

  @doc """
  Emit the legacy-name telemetry counter. `runtime_id` is nil for a caller
  that has no runtime (a persisted canvas script).
  """
  @spec emit_legacy(String.t(), String.t(), String.t() | nil) :: :ok
  def emit_legacy(legacy, canonical, runtime_id) do
    :telemetry.execute(@legacy_event, %{count: 1}, %{
      legacy: legacy,
      canonical: canonical,
      runtime_id: runtime_id
    })
  end
end
