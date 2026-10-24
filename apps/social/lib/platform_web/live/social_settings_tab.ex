defmodule PlatformWeb.SocialSettingsTab do
  @moduledoc """
  The Settings tab (extracted from `PlatformWeb.SocialLive` by Social
  authoring 1/11, no behaviour change): the profile's settings form (read
  only for a non-approver), "Project for renders" (`PlatformWeb.SocialProjectSetting`),
  voice, timezone and posting slots (`PlatformWeb.SocialVoiceSettings`, Social
  authoring 4/11, whose events this tab routes) and the install's Zernio API
  key. Per brand only (`all_brands?/0` false).

  ## The install's Zernio API key (task 01a14722)

  ONE write-only row for the install-level Zernio key, shown to any live
  human (`%User{archived_at: nil}`) who reaches the pane, approver or not.
  It writes only through `Platform.Social.Secrets.put_zernio_api_key/2`,
  after `save_zernio_key` re-reads the user. The value is never rendered
  (not masked, not a prefix, not its fingerprint) and never kept in assigns:
  the form is rebuilt empty after every submit and has no phx-change, so the
  value reaches the server only on submit. Status is metadata only: Set or
  Not set, who and when.
  """

  use PlatformWeb.SocialTab

  alias Platform.Accounts.User
  alias Platform.Social
  alias Platform.Social.{Publisher, Secrets}
  alias PlatformWeb.{SocialConnectionsTab, SocialProjectSetting, SocialScope, SocialVoiceSettings}

  @impl true
  def enabled?, do: true

  @impl true
  def events,
    do: ~w(validate_settings save_settings set_profile_project save_zernio_key
           replace_zernio_key retry_zernio_key cancel_zernio_key) ++ SocialVoiceSettings.events()

  @impl true
  def init(socket) do
    socket
    |> assign(:zernio_human?, human?(socket.assigns.user))
    |> assign(:zernio_mode, :idle)
    |> assign(:zernio_nonce, 0)
    |> assign_zernio()
  end

  @impl true
  def load(%{assigns: %{profile: nil}} = socket) do
    socket
    |> assign(:settings_options, %{approvers: [], spaces: []})
    |> assign(:project_setting, nil)
    |> assign(:settings_form, nil)
    |> SocialVoiceSettings.load()
  end

  def load(%{assigns: %{profile: profile, can_edit?: can_edit?}} = socket) do
    socket
    |> assign(:settings_options, settings_options(profile, can_edit?))
    |> assign(:project_setting, SocialProjectSetting.load(profile, can_edit?))
    |> assign(:settings_form, settings_form(profile, %{}))
    |> SocialVoiceSettings.load()
  end

  @impl true
  def handle_event("validate_settings", %{"profile" => params}, socket) do
    {:noreply,
     assign(socket, :settings_form, settings_form(socket.assigns.profile, params, :validate))}
  end

  def handle_event("save_settings", %{"profile" => params}, socket) do
    with {:ok, profile, _user} <- authorize(socket) do
      attrs = settings_attrs(params, profile, socket.assigns.settings_options)

      case Social.update_profile(profile.org_id, profile, attrs) do
        {:ok, profile} ->
          profiles = SocialScope.visible_profiles(socket)

          {:noreply,
           socket
           |> SocialScope.assign_profiles(profiles)
           |> assign(:profile, profile)
           |> assign(:scope, {:profile, profile})
           |> assign(:settings_form, settings_form(profile, %{}))
           |> SocialVoiceSettings.load()
           |> notice("Settings saved.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :settings_form, to_form(changeset, as: :profile))}

        {:error, _} ->
          {:noreply, notice(socket, "Those settings could not be saved.")}
      end
    else
      _ -> {:noreply, notice(socket, "Only an approver of this profile can change it.")}
    end
  end

  # Project for renders (task 01a16532): saves on choose. The approver is
  # re-checked here and in Social.set_profile_project/4; the id must be one
  # of the options rebuilt now (SocialProjectSetting.save/3).
  def handle_event("set_profile_project", params, socket) do
    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, profile} <- SocialProjectSetting.save(profile, user_id, params["project_id"]) do
      Process.send_after(self(), :project_saved_clear, SocialProjectSetting.saved_ms())

      {:noreply,
       socket
       |> assign(:profile, profile)
       |> assign(:scope, {:profile, profile})
       |> assign(:project_setting, %{SocialProjectSetting.load(profile, true) | saved?: true})}
    else
      {:error, :not_an_approver} ->
        {:noreply, notice(socket, "Only an approver of this profile can change it.")}

      _ ->
        {:noreply, notice(socket, "Those settings could not be saved.")}
    end
  end

  # The install's Zernio key. The user is re-read NOW and must be a live
  # human; anyone else (an agent session, nil, an archived user) is refused
  # with nothing written. The submitted value goes straight to Secrets and
  # is dropped: the form is rebuilt empty whatever the outcome.
  def handle_event("save_zernio_key", params, socket) do
    case fresh_user(socket) do
      %User{archived_at: nil} = user ->
        mode =
          case Secrets.put_zernio_api_key(zernio_value(params), user) do
            {:ok, _credential} -> :idle
            {:error, _reason} -> :error
          end

        blocked? = socket.assigns.zernio_blocks_connect?
        socket = socket |> assign(:zernio_mode, mode) |> assign_zernio()

        # Account rows are a stream: Connect/Reconnect re-render only when
        # the rows are re-streamed, so do that when the gate flipped.
        {:noreply,
         if(socket.assigns.zernio_blocks_connect? == blocked?,
           do: socket,
           else: SocialConnectionsTab.restream_accounts(socket)
         )}

      _not_a_live_human ->
        {:noreply, socket |> assign(:zernio_human?, false) |> assign_zernio()}
    end
  end

  # Replace (set), Try again (failed save) and Cancel only move the row
  # between its states; none of them reads or writes the key.
  def handle_event(event, _params, socket)
      when event in ~w(replace_zernio_key retry_zernio_key cancel_zernio_key) do
    mode = if event == "cancel_zernio_key", do: :idle, else: :edit

    {:noreply,
     if(socket.assigns.zernio_human?,
       do: socket |> assign(:zernio_mode, mode) |> assign_zernio(),
       else: socket
     )}
  end

  def handle_event(event, params, socket) when is_binary(event) do
    if event in SocialVoiceSettings.events(),
      do: SocialVoiceSettings.handle_event(event, params, socket),
      else: {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:project_saved_clear, %{assigns: %{project_setting: %{} = s}} = socket),
    do: {:noreply, assign(socket, :project_setting, %{s | saved?: false})}

  def handle_info(_message, _socket), do: :unhandled

  # Who the approver picker offers (HUMAN users who are internal members of
  # the profile's org; agents are not users, so never offered) and the org's
  # channels by name. Only built for someone who can edit.
  defp settings_options(_profile, false), do: %{approvers: [], spaces: []}

  defp settings_options(profile, true) do
    approvers =
      Platform.Accounts.list_users()
      |> Enum.filter(&Platform.Tenancy.internal_member?(&1, profile.org_id))

    spaces =
      [kind: "channel"]
      |> Platform.Chat.list_spaces()
      |> Enum.filter(&(&1.org_id == profile.org_id))
      |> Enum.sort_by(&String.downcase(&1.name || ""))

    %{approvers: approvers, spaces: spaces}
  end

  defp settings_form(profile, params, action \\ nil) do
    data = %{
      "home_url" => profile.home_url,
      "voice_notes" => profile.voice_notes,
      "default_hashtags" => Enum.join(profile.default_hashtags || [], ", "),
      "approver_user_ids" => profile.approver_user_ids || [],
      "space_id" => profile.space_id
    }

    to_form(Map.merge(data, params), as: :profile, action: action)
  end

  # Only the five settings fields are taken; approver ids and the space must
  # be among what the picker offered (server-side, not trusted from the client).
  defp settings_attrs(params, profile, %{approvers: approvers, spaces: spaces}) do
    offered_users = MapSet.new(approvers, & &1.id)
    offered_spaces = MapSet.new(spaces, & &1.id)

    approver_ids =
      params
      |> Map.get("approver_user_ids", [])
      |> List.wrap()
      |> Enum.filter(&MapSet.member?(offered_users, &1))
      |> Enum.uniq()

    space_id =
      case params["space_id"] do
        id when is_binary(id) ->
          if MapSet.member?(offered_spaces, id), do: id, else: profile.space_id

        _ ->
          profile.space_id
      end

    hashtags =
      (params["default_hashtags"] || "")
      |> String.split([",", " "], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{
      home_url: blank_to_nil(params["home_url"]),
      voice_notes: blank_to_nil(params["voice_notes"]),
      default_hashtags: hashtags,
      approver_user_ids: approver_ids,
      space_id: space_id
    }
  end

  # ── Zernio key ──────────────────────────────────────────────────────

  defp zernio_value(%{"zernio_key" => %{"api_key" => value}}) when is_binary(value), do: value
  defp zernio_value(_params), do: nil

  # Re-reads the key's status (Vault metadata only, nothing decrypted) and
  # rebuilds the form EMPTY under a fresh id, so no submitted value survives
  # in assigns or in the DOM. `zernio_blocks_connect?` is true only while the
  # Zernio publisher is selected and no key is set (the Fake needs no key).
  defp assign_zernio(socket) do
    status = zernio_status()

    socket
    |> assign(:zernio_status, status)
    |> assign(:zernio_form, to_form(%{"api_key" => ""}, as: :zernio_key))
    |> update(:zernio_nonce, &(&1 + 1))
    |> assign(
      :zernio_blocks_connect?,
      status == :not_set and Publisher.impl() == Platform.Social.Publisher.Zernio
    )
  end

  defp zernio_status do
    case Secrets.zernio_key_status() do
      :not_set ->
        :not_set

      {:set, %{changed_at: at, changed_by_user_id: user_id}} ->
        {:set, %{by: setter_name(user_id), on: Calendar.strftime(at, "%-d %b")}}
    end
  end

  defp setter_name(user_id) when is_binary(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %User{name: name} when is_binary(name) and name != "" -> name
      %User{email: email} when is_binary(email) -> email
      _ -> nil
    end
  end

  defp setter_name(_user_id), do: nil

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def pane(assigns) do
    ~H"""
    <.notice_line notice={@notice} tone={@notice_tone} />
    <.zernio_key
      :if={@zernio_human?}
      status={@zernio_status}
      mode={@zernio_mode}
      form={@zernio_form}
      nonce={@zernio_nonce}
    />
    <.settings
      profile={@profile}
      form={@settings_form}
      can_edit?={@can_edit?}
      options={@settings_options}
      project_setting={@project_setting}
    />
    <SocialVoiceSettings.editor
      :if={@profile && @can_edit? && @voice_draft}
      profile={@profile}
      draft={@voice_draft}
      options={@voice_options}
      errors={@voice_errors}
      cards={@slot_cards}
    />
    <SocialVoiceSettings.readonly
      :if={@profile && !@can_edit?}
      profile={@profile}
      cards={@slot_cards}
    />
    """
  end

  # The install's Zernio key: a status, never the value. The input is only
  # there while the key is not set, or after Replace / Try again; Save key
  # shows only while the input has text (CSS `peer`, no JS, no phx-change).
  attr :status, :any, required: true
  attr :mode, :atom, required: true
  attr :form, :any, required: true
  attr :nonce, :integer, required: true

  defp zernio_key(assigns) do
    assigns =
      assign(
        assigns,
        :input?,
        assigns.mode == :edit or (assigns.mode == :idle and assigns.status == :not_set)
      )

    ~H"""
    <section
      class="mb-6 max-w-xl rounded-lg border border-base-300 bg-base-100 p-3 sm:p-4"
      aria-labelledby="social-zernio-key-label"
      data-role="social-zernio-key"
      data-state={if @status == :not_set, do: "not_set", else: "set"}
      data-mode={@mode}
    >
      <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
        <h3 id="social-zernio-key-label" class="text-sm font-semibold text-base-content">
          Zernio API key
        </h3>
        <span
          :if={@status == :not_set}
          class="inline-flex items-center gap-1.5 text-sm font-medium text-warning"
          data-role="social-zernio-status"
        >
          <span class="size-2 rounded-full bg-warning" aria-hidden="true"></span> Not set
        </span>
        <span
          :if={@status != :not_set}
          class="inline-flex items-center gap-1.5 text-sm font-medium text-base-content"
          data-role="social-zernio-status"
        >
          <span class="size-2 rounded-full bg-success" aria-hidden="true"></span> Set
        </span>
      </div>
      <p class="mt-0.5 text-sm text-base-content/70" data-role="social-zernio-scope">
        One key for the whole org. Used by every profile.
      </p>

      <div
        :if={match?({:set, _}, @status) and @mode != :edit}
        class="mt-3 flex flex-wrap items-center justify-between gap-2"
      >
        <p class="text-sm text-base-content/70" data-role="social-zernio-changed">
          {last_changed(@status)}
        </p>
        <button
          :if={@mode == :idle}
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="replace_zernio_key"
          data-role="social-zernio-replace"
        >
          Replace
        </button>
      </div>

      <.form
        :if={@input?}
        for={@form}
        id={"social-zernio-key-form-#{@nonce}"}
        phx-submit="save_zernio_key"
        phx-auto-recover="ignore"
        class="mt-3"
        data-role="social-zernio-key-form"
      >
        <div class="flex flex-wrap items-center gap-2">
          <label for={"social-zernio-key-input-#{@nonce}"} class="sr-only">Zernio API key</label>
          <input
            id={"social-zernio-key-input-#{@nonce}"}
            type="password"
            name={@form[:api_key].name}
            value=""
            placeholder={if @status == :not_set, do: "paste key", else: "paste new key"}
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            class="peer input min-w-0 flex-1 border-edge bg-base-100 font-mono placeholder:text-base-content/70"
            data-role="social-zernio-key-input"
          />
          <button
            type="submit"
            class="btn btn-primary peer-placeholder-shown:hidden"
            data-role="social-zernio-save"
          >
            Save key
          </button>
        </div>
      </.form>
      <p
        :if={@input? and @status == :not_set}
        class="mt-2 text-sm text-base-content/70"
        data-role="social-zernio-helper"
      >
        Find it in Zernio > Settings > API.
      </p>
      <button
        :if={@mode == :edit and @status != :not_set}
        type="button"
        class="btn btn-ghost btn-sm mt-2"
        phx-click="cancel_zernio_key"
        data-role="social-zernio-cancel"
      >
        Cancel
      </button>

      <div
        :if={@mode == :error}
        role="alert"
        class="alert alert-error mt-3 flex flex-wrap items-center justify-between gap-2 text-sm"
        data-role="social-zernio-error"
      >
        <span>Couldn't save the key. Nothing was changed.</span>
        <button
          type="button"
          class="btn btn-sm"
          phx-click="retry_zernio_key"
          data-role="social-zernio-retry"
        >
          Try again
        </button>
      </div>
    </section>
    """
  end

  defp last_changed({:set, %{by: nil, on: on}}), do: "Last changed #{on}"
  defp last_changed({:set, %{by: by, on: on}}), do: "Last changed by #{by}, #{on}"

  attr :profile, :map, required: true
  attr :form, :any, required: true
  attr :can_edit?, :boolean, required: true
  attr :options, :map, required: true
  attr :project_setting, :map, default: nil

  defp settings(%{can_edit?: false} = assigns) do
    ~H"""
    <dl class="space-y-3 text-sm" data-role="social-settings-readonly">
      <div>
        <dt class="text-base-content/70">Home URL</dt>
        <dd>{@profile.home_url || "Not set"}</dd>
      </div>
      <div>
        <dt class="text-base-content/70">Voice notes</dt>
        <dd class="whitespace-pre-wrap">{@profile.voice_notes || "Not set"}</dd>
      </div>
      <div>
        <dt class="text-base-content/70">Hashtags</dt>
        <dd>{Enum.join(@profile.default_hashtags || [], " ")}</dd>
      </div>
      <SocialProjectSetting.readonly :if={@project_setting} setting={@project_setting} />
    </dl>
    """
  end

  defp settings(assigns) do
    ~H"""
    <.form
      for={@form}
      id="social-settings-form"
      phx-change="validate_settings"
      phx-submit="save_settings"
      class="max-w-xl space-y-1"
      data-role="social-settings-form"
    >
      <.input field={@form[:home_url]} type="url" label="Home URL" />
      <.input field={@form[:voice_notes]} type="textarea" label="Voice notes" />
      <.input
        field={@form[:default_hashtags]}
        type="text"
        label="Default hashtags (comma-separated)"
      />
      <.input
        field={@form[:approver_user_ids]}
        type="select"
        multiple
        class="w-full select h-auto min-h-24 bg-none py-1"
        size="4"
        label="Approvers (people only)"
        options={Enum.map(@options.approvers, &{&1.name || &1.email, &1.id})}
      />
      <.input
        field={@form[:space_id]}
        type="select"
        label="Approval channel"
        prompt="No channel"
        options={Enum.map(@options.spaces, &{&1.name, &1.id})}
      />
      <button type="submit" class="btn btn-neutral btn-sm mt-2" data-role="social-settings-save">
        Save settings
      </button>
    </.form>
    <SocialProjectSetting.row :if={@project_setting} setting={@project_setting} />
    """
  end
end
