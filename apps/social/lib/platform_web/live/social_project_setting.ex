defmodule PlatformWeb.SocialProjectSetting do
  @moduledoc """
  The "Project for renders" row in the Social tab's Settings pane (task
  01a16532 stage 3; design direction canvas 01a16763-cfb1). It lives in
  its own file so `PlatformWeb.SocialLive` only renders it, assigns it and
  delegates its one event.

    * `load/2` builds the row's state. The option list (the org's
      non-archived projects, by name) is read ONLY for an approver, so a
      non-approver's page never carries another project's name.
    * `row/1` is the approver's row: a select that saves on choose (no
      Save button), the helper line, a warning when unset, "Saved" for
      about two seconds, and "Create a project first" when the org has
      none. `readonly/1` is the non-approver's plain-text value, one entry
      in the read-only `<dl>`.
    * `save/3` is the event's server side: the submitted id must be one of
      the options rebuilt NOW for this profile, and
      `Platform.Social.set_profile_project/4` re-checks the approver and
      the project's org. A forged event writes nothing.
  """

  use PlatformWeb, :html

  alias Platform.Social

  @saved_ms 2_000

  @doc "How long \"Saved\" shows, in ms."
  def saved_ms, do: @saved_ms

  @doc """
  The row's state for `profile`: the current project (nil when unset or
  not in the profile's org), the approver's options, and `saved?`.
  """
  def load(nil, _can_edit?), do: nil

  def load(profile, can_edit?) do
    current =
      case Social.render_project(profile) do
        {:ok, project} -> project
        {:error, _} -> nil
      end

    %{
      current: current,
      options: if(can_edit?, do: options(profile.org_id), else: []),
      saved?: false
    }
  end

  @doc "The org's non-archived projects, sorted by name."
  def options(org_id) do
    [org_id: org_id]
    |> Platform.Tasks.list_projects_unscoped()
    |> Enum.filter(&is_nil(&1.archived_at))
  end

  @doc """
  Sets `profile`'s project to `project_id` for `user_id`, only if the id
  is among the options rebuilt now for the profile's org.
  """
  def save(profile, user_id, project_id) do
    if is_binary(project_id) and Enum.any?(options(profile.org_id), &(&1.id == project_id)),
      do: Social.set_profile_project(profile.org_id, profile, user_id, project_id),
      else: {:error, :not_an_option}
  end

  # Where projects are created: the Tasks sidebar's "New project".
  @projects_path "/tasks"

  attr :setting, :map, required: true

  def row(assigns) do
    assigns = assign(assigns, :projects_path, @projects_path)

    ~H"""
    <div class="max-w-xl space-y-1 pt-2" data-role="social-project-setting">
      <form
        id="social-project-setting-form"
        phx-change="set_profile_project"
        class="space-y-1"
      >
        <div class="flex items-center gap-2">
          <span
            :if={is_nil(@setting.current)}
            class="inline-flex"
            data-role="social-project-unset-icon"
          >
            <.icon name="hero-exclamation-triangle" class="size-4 text-warning" />
          </span>
          <label for="social-project-select" class="text-[15px]" data-role="social-project-label">
            Project for renders
          </label>
          <span
            :if={@setting.saved?}
            class="text-[13px] text-base-content/70"
            data-role="social-project-saved"
          >
            Saved
          </span>
        </div>
        <select
          :if={@setting.options != []}
          id="social-project-select"
          name="project_id"
          class="select w-full"
          data-role="social-project-select"
        >
          <option :if={is_nil(@setting.current)} value="" selected>Choose a project</option>
          <option
            :for={project <- @setting.options}
            value={project.id}
            selected={@setting.current && @setting.current.id == project.id}
          >
            {project.name}
          </option>
        </select>
      </form>
      <p
        :if={@setting.options == []}
        class="text-[13px] text-base-content/70"
        data-role="social-project-none"
      >
        <.link navigate={@projects_path} class="link">Create a project first</.link>
      </p>
      <p
        :if={@setting.current}
        class="text-[13px] text-base-content/70"
        data-role="social-project-helper"
      >
        Clip renders and uploaded covers are stored as files in this project.
      </p>
      <p
        :if={is_nil(@setting.current)}
        class="text-[13px] text-base-content/70"
        data-role="social-project-unset"
      >
        Clips can't render until a project is chosen.
      </p>
    </div>
    """
  end

  attr :setting, :map, required: true

  def readonly(assigns) do
    ~H"""
    <div data-role="social-project-readonly">
      <dt class="inline">Project for renders:</dt>
      <dd class="inline">{if @setting.current, do: @setting.current.name, else: "Not set"}</dd>
    </div>
    """
  end
end
