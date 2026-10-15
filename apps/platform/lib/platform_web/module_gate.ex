defmodule PlatformWeb.ModuleGate do
  @moduledoc """
  Checks a LiveView's module on every mount, including live navigation within
  one `live_session`. An unlisted view is denied so new routes need an explicit
  module decision before they become reachable.
  """

  import Phoenix.LiveView, only: [redirect: 2]

  alias Platform.Access

  @view_modules %{
    PlatformWeb.ChatLive => {:chat, nil},
    PlatformWeb.ActivityLive => {:activity, nil},
    PlatformWeb.ChangelogLive => {:activity, nil},
    PlatformWeb.InboxLive => {:inbox, nil},
    PlatformWeb.TasksLive => {:tasks, nil},
    PlatformWeb.FilesLive => {:files, nil},
    PlatformWeb.MeetingLive => {:meetings, nil},
    PlatformWeb.EmailLive => {:email, nil},
    PlatformWeb.SkillsLive => {:skills, nil},
    PlatformWeb.ControlCenterLive => {:admin, "agents.manage_own"},
    PlatformWeb.UsageLive => {:admin, "agents.manage_own"},
    PlatformWeb.ExperimentsLive => {:experiments, nil},
    PlatformWeb.OrgMemoryLive => {:context, nil},
    PlatformWeb.CanvasLive => {:chat, "canvas.read"},
    PlatformWeb.AdminLive => {:admin, nil},
    PlatformWeb.RecoveryLive => {:admin, nil},
    PlatformWeb.ExternalRecoveryLive => {:admin, nil},
    PlatformWeb.UserAccessLive => {:admin, nil},
    PlatformWeb.AdminOrgsLive => {:admin, nil},
    PlatformWeb.AdminBrandingLive => {:admin, nil},
    PlatformWeb.AdminPrototypesLive => {:admin, nil},
    PlatformWeb.AdminVaultLive => {:admin, nil},
    PlatformWeb.AdminPromptsLive => {:admin, nil},
    PlatformWeb.AdminFederationLive => {:admin, nil},
    PlatformWeb.PipelineLive => {:admin, nil},
    PlatformWeb.AdminSignInUsersLive => {:admin, nil}
  }

  # Every current gated-session view has a module. Keep an explicit list so
  # any future exception must be deliberate and documented here.
  @ungated []

  @doc "The explicit module mapping used by the mount gate and its route sweep."
  def view_modules, do: @view_modules

  @doc "Views intentionally available without a module permission."
  def ungated_views, do: @ungated

  def on_mount(:default, _params, _session, socket) do
    case Map.fetch(@view_modules, socket.view) do
      {:ok, {key, permission}} ->
        if Access.module_access?(socket.assigns[:access_scope], key, permission) do
          {:cont, socket}
        else
          {:halt, redirect(socket, to: "/access-denied?module=#{key}")}
        end

      :error ->
        if Enum.member?(@ungated, socket.view) do
          {:cont, socket}
        else
          {:halt, redirect(socket, to: "/access-denied")}
        end
    end
  end
end
