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
    # The first-run goal box (task 01a19554-fd07 stage 2) hands off into a
    # chat DM, so a member without chat could not use it either.
    PlatformWeb.FirstRunLive => {:chat, nil},
    PlatformWeb.ChangelogLive => {:activity, nil},
    PlatformWeb.InboxLive => {:inbox, nil},
    PlatformWeb.TasksLive => {:tasks, nil},
    PlatformWeb.FilesLive => {:files, nil},
    PlatformWeb.MeetingLive => {:meetings, nil},
    PlatformWeb.CalendarLive => {:calendar, nil},
    PlatformWeb.BookingSettingsLive => {:calendar, nil},
    PlatformWeb.VoiceLive => {:voice, nil},
    PlatformWeb.EmailLive => {:email, nil},
    PlatformWeb.SkillsLive => {:skills, nil},
    PlatformWeb.ControlCenterLive => {:agents, "agents.manage_own"},
    # The remote terminal (task 01a17b17): the owner's own agent, so the same
    # module and permission as the agent page that links to it.
    PlatformWeb.TerminalLive => {:agents, "agents.manage_own"},
    # The configuration screen (task 01a17b1c stage 5): same module and
    # permission as the agent page; `ConfigFiles.Access` is the real gate.
    PlatformWeb.AgentConfigLive => {:agents, "agents.manage_own"},
    PlatformWeb.ExtensionPageLive => {:extension, nil},
    PlatformWeb.UsageLive => {:admin, "agents.manage_own"},
    PlatformWeb.ExperimentsLive => {:experiments, nil},
    PlatformWeb.OrgMemoryLive => {:context, nil},
    PlatformWeb.CanvasLive => {:chat, "canvas.read"},
    PlatformWeb.AdminLive => {:admin, nil},
    PlatformWeb.RecoveryLive => {:admin, nil},
    PlatformWeb.ExternalRecoveryLive => {:admin, nil},
    PlatformWeb.UserAccessLive => {:admin, nil},
    PlatformWeb.AccessLive => {:admin, "access.manage"},
    PlatformWeb.AccessViewAsLive => {:admin, "access.manage"},
    PlatformWeb.AdminOrgsLive => {:admin, nil},
    PlatformWeb.AdminBrandingLive => {:admin, nil},
    PlatformWeb.AdminThemesLive => {:admin, nil},
    PlatformWeb.AdminPrototypesLive => {:admin, nil},
    PlatformWeb.AdminInsightsLive => {:admin, nil},
    PlatformWeb.AdminVaultLive => {:admin, nil},
    PlatformWeb.ConnectAiLive => {:admin, nil},
    PlatformWeb.AdminPromptsLive => {:prompts, "prompts.manage"},
    PlatformWeb.AdminFederationLive => {:admin, nil},
    PlatformWeb.PipelineLive => {:tasks, "tasks.manage"},
    PlatformWeb.AdminSignInUsersLive => {:admin, nil}
  }

  # Every current gated-session view has a module. Keep an explicit list so
  # any future exception must be deliberate and documented here.
  # View-as keeps its existing target-scoped authorization on the chat host.
  # The mapping above inventories its module; this narrow compatibility
  # exemption admits guest project managers whose ViewAs.compute authorizes
  # the target. The new AccessLive panel has no exemption.
  #
  # Settings (task 01a1557a-807f stage 1) is the viewer's own account: every
  # signed-in user has one, so no module permission can sensibly gate it.
  # Each row on the page checks its own destination through `mounts?/2`
  # instead, so the page reveals nothing its viewer could not already open.
  @ungated [PlatformWeb.AccessViewAsLive, PlatformWeb.SettingsLive]

  @doc "The explicit module mapping used by the mount gate and its route sweep."
  def view_modules, do: @view_modules

  @doc "Views intentionally available without a module permission."
  def ungated_views, do: @ungated

  @doc """
  Would `view` pass this gate's module check for `scope`?

  The one answer to "may this actor open that page", read from the same
  `view_modules/0` mapping and `Platform.Access.module_access?/3` call the
  mount gate uses (the mount gate calls this). A listed view needs its
  module; an unlisted view passes only when it is deliberately ungated.
  Fails closed for an unknown view or a nil scope. Pages that link to other
  pages (Settings' rows) ask this rather than restating the rules.
  """
  @spec mounts?(Platform.Access.Scope.t() | nil, module()) :: boolean()
  def mounts?(scope, view) do
    case Map.fetch(@view_modules, view) do
      {:ok, {key, permission}} -> Access.module_access?(scope, key, permission)
      :error -> Enum.member?(@ungated, view)
    end
  end

  def on_mount(:default, _params, _session, %{view: PlatformWeb.AccessViewAsLive} = socket),
    do: {:cont, socket}

  # Build-time modules declare the core module key and permission for each
  # page. The generic host must not become an exception to authorization.
  def on_mount(
        :default,
        %{"prefix" => prefix},
        _session,
        %{view: PlatformWeb.ExtensionPageLive} = socket
      ) do
    case Platform.Extensions.live_page_for(prefix) do
      %{module: key, permission: permission} when is_atom(key) and is_binary(permission) ->
        if Access.module_access?(socket.assigns[:access_scope], key, permission),
          do: {:cont, socket},
          else: {:halt, redirect(socket, to: "/access-denied?module=#{key}")}

      nil ->
        # The host supplies its existing 404 for an unclaimed prefix.
        {:cont, socket}

      _ ->
        {:halt, redirect(socket, to: "/access-denied")}
    end
  end

  def on_mount(:default, _params, _session, socket) do
    if mounts?(socket.assigns[:access_scope], socket.view) do
      {:cont, socket}
    else
      case Map.fetch(@view_modules, socket.view) do
        {:ok, {key, _permission}} ->
          {:halt, redirect(socket, to: "/access-denied?module=#{key}")}

        :error ->
          {:halt, redirect(socket, to: "/access-denied")}
      end
    end
  end
end
