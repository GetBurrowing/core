defmodule Platform.Access.PermissionLabels do
  @moduledoc """
  Plain-language labels for permission keys (task `01a1a2e4-9265` stage 1).

  The agent page and the Custom roles page show a person what a permission
  lets someone do ("Publish prototypes"), with the key (`prototypes.publish`)
  beside it in mono. The explicit map covers the permissions those pages name
  most often; every other registered permission falls back to
  `"<Action> <module>"`, humanized from the key, so no registered permission
  ever renders an empty label (pinned by `permission_labels_test.exs`
  against `Platform.Access.Registry.permission_names/0`).
  """

  @labels %{
    "prototypes.publish" => "Publish prototypes",
    "prototypes.read" => "View prototypes",
    "tasks.read" => "View tasks",
    "tasks.write" => "Create and update tasks",
    "tasks.manage" => "Approve and reject plans",
    "tasks.promote" => "Promote tasks",
    "canvas.read" => "View canvases",
    "canvas.write" => "Create and edit canvases",
    "chat.read" => "Read chat",
    "chat.write" => "Post in chat",
    "chat.manage" => "Manage chat",
    "files.read" => "View files",
    "files.write" => "Add and delete files",
    "mail.use" => "Use mail",
    "mail.manage" => "Manage mail"
  }

  @doc "The label for `permission`. Never empty for a binary key."
  @spec label(String.t()) :: String.t()
  def label(permission) when is_binary(permission) do
    case Map.fetch(@labels, permission) do
      {:ok, label} -> label
      :error -> fallback(permission)
    end
  end

  @doc "The explicit labels, for callers that list them."
  @spec labels() :: %{String.t() => String.t()}
  def labels, do: @labels

  defp fallback("mcp." <> bundle), do: "Use the #{humanize(bundle)} tools"

  defp fallback(permission) do
    case String.split(permission, ".", parts: 2) do
      [module, action] when module != "" and action != "" ->
        String.capitalize(humanize(action)) <> " " <> humanize(module)

      _ ->
        permission
    end
  end

  defp humanize(part), do: part |> String.replace(["_", "-"], " ") |> String.trim()
end
