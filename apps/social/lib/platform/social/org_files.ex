defmodule Platform.Social.OrgFiles do
  @moduledoc """
  The ONE rule for "this core Files row is in that org" (task 01a165ec,
  stage 2), shared by `Platform.Social.AgentDrafts` (media refs),
  `Platform.Social.Publishing` (media at publish) and
  `Platform.Social.Cover` (an uploaded cover). Read through core's public
  contexts (`Platform.Files`, `Platform.Tasks`), never a Repo query on a
  core table.

  A file's org is its own `org_id` when set, else its project's org; a file
  with neither, a missing id and a soft-deleted file have no org.
  """

  @doc "The org a file (or file id) belongs to, or nil."
  @spec org_of(map() | String.t() | nil) :: Ecto.UUID.t() | nil
  def org_of(id) when is_binary(id) do
    case Platform.Files.get_file(id) do
      nil -> nil
      file -> org_of(file)
    end
  end

  def org_of(%{org_id: org_id}) when is_binary(org_id), do: org_id

  def org_of(%{project_id: project_id}) when is_binary(project_id) do
    case Platform.Tasks.get_project(project_id) do
      %{org_id: org_id} -> org_id
      _ -> nil
    end
  end

  def org_of(_), do: nil

  @doc "Whether a file (or file id) is in `org_id`."
  @spec in_org?(map() | String.t() | nil, Ecto.UUID.t() | nil) :: boolean()
  def in_org?(_file, nil), do: false
  def in_org?(file, org_id), do: org_of(file) == org_id
end
