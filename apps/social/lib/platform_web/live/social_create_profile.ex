defmodule PlatformWeb.SocialCreateProfile do
  @moduledoc """
  Creating a profile (task 01a14668), extracted from `PlatformWeb.SocialLive`
  by Social authoring 1/11 with no behaviour change.

  A human creator ({:user, id}: `@user` non-nil) gets the create form as the
  empty state and a "+ New profile" entry next to the switcher. The target
  org is resolved server-side by `creatable_orgs/1` from a FRESH read of the
  user, never from a client org id; the only write is
  `Platform.Social.create_profile/2`, with the creator as first approver.
  Agent viewers (and anyone without a creatable org) get no control.
  """

  use PlatformWeb, :html

  import PlatformWeb.SocialHelpers, only: [fresh_user: 1, blank_to_nil: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Social
  alias PlatformWeb.SocialScope

  def events, do: ~w(create_profile open_create close_create)

  # Create a profile. The user and their creatable orgs are re-read NOW; a
  # viewer who cannot create (an agent, an archived user, no creatable org)
  # is refused with no write. Only `name` and `home_url` come from params,
  # plus an `org_id` that must be in the fresh creatable set.
  def handle_event("create_profile", %{"profile" => params}, socket) when is_map(params) do
    user = fresh_user(socket)
    orgs = creatable_orgs(user)
    socket = assign_creatable(socket, orgs)

    case target_org(orgs, params) do
      nil ->
        {:noreply, assign(socket, :create_open?, false)}

      org_id ->
        attrs = %{
          name: params["name"],
          home_url: blank_to_nil(params["home_url"]),
          approver_user_ids: [user.id]
        }

        case Social.create_profile(org_id, attrs) do
          {:ok, profile} ->
            profiles = SocialScope.visible_profiles(socket)

            {:noreply,
             socket
             |> SocialScope.assign_profiles(profiles)
             |> SocialScope.load_profile(profile)
             |> assign(:tab, "queue")
             |> assign(:create_open?, false)
             |> assign(:create_form, blank_form())}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :create_form, error_form(changeset))}

          {:error, _} ->
            {:noreply,
             assign(
               socket,
               :create_form,
               error_form(params, "That profile could not be created. Try again.")
             )}
        end
    end
  end

  def handle_event("create_profile", _params, socket), do: {:noreply, socket}

  def handle_event("open_create", _params, socket) do
    socket = assign_creatable(socket, creatable_orgs(fresh_user(socket)))

    {:noreply,
     socket
     |> assign(:create_open?, socket.assigns.can_create?)
     |> assign(:create_form, blank_form())}
  end

  def handle_event("close_create", _params, socket),
    do: {:noreply, assign(socket, :create_open?, false)}

  @doc """
  The ONE place that decides where `user` may create a profile (keep it
  single: when RBAC gates this, this body is the edit). The orgs of the
  user's NON-external memberships in live orgs, intersected with what the
  swap points allow (`Platform.Tenancy.visibility/1` through
  `Platform.Social.visible_orgs/1`). nil, an archived user or an agent id
  (which `get_user/1` answers nil for) creates nowhere.
  """
  def creatable_orgs(%Platform.Accounts.User{archived_at: nil} = user) do
    allowed =
      case Platform.Tenancy.visibility(user) do
        :root_all -> Social.visible_orgs(:root)
        {:orgs, ids} -> Enum.flat_map(ids, &Social.visible_orgs/1)
        _ -> []
      end

    user
    |> Platform.Tenancy.list_user_memberships()
    |> Enum.filter(&match?(%{external: false, org: %{archived_at: nil}}, &1))
    |> Enum.filter(&(allowed == :all or &1.org_id in allowed))
    |> Enum.map(&%{id: &1.org_id, name: &1.org.name})
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&String.downcase(&1.name || ""))
  end

  def creatable_orgs(_user), do: []

  @doc "`can_create?` is for rendering only; the handler re-resolves."
  def assign_creatable(socket, orgs) do
    socket
    |> assign(:creatable_orgs, orgs)
    |> assign(:can_create?, orgs != [])
    |> assign_new(:create_form, &blank_form/0)
  end

  # A client org id is honoured only if it is in the fresh creatable set.
  # Without one, a user with exactly one creatable org creates there; with
  # several, the form carries the Org select and a missing id is refused.
  defp target_org(orgs, %{"org_id" => org_id}) when is_binary(org_id) do
    if Enum.any?(orgs, &(&1.id == org_id)), do: org_id
  end

  defp target_org([%{id: org_id}], params) when not is_map_key(params, "org_id"), do: org_id
  defp target_org(_orgs, _params), do: nil

  defp blank_form, do: to_form(%{"name" => "", "home_url" => ""}, as: :profile)

  # The unique constraint on [:org_id, :name] lands on :org_id (the first
  # field); a form that only shows :name errors would swallow it, so it is
  # moved onto Name with the canvas copy.
  defp error_form(%Ecto.Changeset{} = changeset) do
    name = Ecto.Changeset.get_field(changeset, :name)

    {unique, rest} =
      Enum.split_with(changeset.errors, fn
        {:org_id, {_msg, opts}} -> opts[:constraint] == :unique
        _ -> false
      end)

    errors =
      if unique == [],
        do: rest,
        else: [{:name, {"A profile called #{name} already exists.", []}} | rest]

    to_form(%{changeset | errors: errors}, as: :profile, action: :insert)
  end

  defp error_form(params, message) do
    to_form(
      %{"name" => params["name"] || "", "home_url" => params["home_url"] || ""},
      as: :profile,
      errors: [name: {message, []}],
      action: :insert
    )
  end

  attr :can_create?, :boolean, required: true
  attr :form, :any, required: true
  attr :orgs, :list, required: true

  @doc "The zero-profile empty state: the create form, or the ask-someone line."
  def empty_state(assigns) do
    ~H"""
    <%= if @can_create? do %>
      <div class="px-4 py-8 sm:px-6 sm:py-12">
        <section
          class="mx-auto max-w-xl rounded-xl border border-base-300 bg-base-100 p-4 sm:p-6"
          data-role="social-create"
        >
          <h2 class="text-lg font-semibold" data-role="social-create-heading">
            Set up your first social profile
          </h2>
          <p class="mt-1 mb-4 text-base-content/70" data-role="social-create-explanation">
            A profile is a brand or person you post for. You'll be its first approver.
          </p>
          <.create_form form={@form} orgs={@orgs} focus?={true} />
        </section>
      </div>
    <% else %>
      <div class="px-4 py-12 text-center sm:px-6">
        <p class="text-base-content/70" data-role="social-no-profiles">
          No social profiles yet. Ask an org member to set one up.
        </p>
      </div>
    <% end %>
    """
  end

  attr :form, :any, required: true
  attr :orgs, :list, required: true

  @doc "+ New profile: inline under the header from sm up, a bottom sheet below sm."
  def panel(assigns) do
    ~H"""
    <div phx-window-keydown="close_create" phx-key="escape">
      <button
        type="button"
        class="fixed inset-0 z-30 bg-base-content/40 sm:hidden"
        phx-click="close_create"
        aria-label="Close"
      >
      </button>
      <div
        id="social-create-panel"
        class="fixed inset-x-0 bottom-0 z-40 max-h-[85vh] overflow-y-auto rounded-t-2xl border border-base-300 bg-base-100 p-4 sm:static sm:z-auto sm:mt-3 sm:max-w-xl sm:rounded-xl"
        data-role="social-create-panel"
      >
        <div class="mb-3 flex items-center justify-between gap-2">
          <h2 class="text-lg font-semibold">New profile</h2>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="close_create"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <.create_form form={@form} orgs={@orgs} focus?={true} />
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :orgs, :list, required: true
  attr :focus?, :boolean, default: false

  # The two create fields (plus Org only when the user has several creatable
  # orgs). Errors render inline under their field.
  defp create_form(assigns) do
    assigns =
      assigns
      |> assign(:name_errors, field_errors(assigns.form[:name]))
      |> assign(:home_errors, field_errors(assigns.form[:home_url]))

    ~H"""
    <.form
      for={@form}
      id="social-create-form"
      phx-submit="create_profile"
      class="space-y-3"
      data-role="social-create-form"
    >
      <div :if={length(@orgs) > 1} class="fieldset py-0">
        <label for="social-create-org" class="label mb-1 font-medium">Org</label>
        <select
          id="social-create-org"
          name={@form[:org_id].name}
          class="select w-full"
          data-role="social-create-org"
        >
          <option
            :for={org <- @orgs}
            value={org.id}
            selected={org.id == @form[:org_id].value}
          >
            {org.name}
          </option>
        </select>
      </div>
      <div class="fieldset py-0">
        <label for="social-create-name" class="label mb-1 font-medium">Name</label>
        <input
          type="text"
          id="social-create-name"
          name={@form[:name].name}
          value={@form[:name].value}
          required
          maxlength="255"
          autocomplete="off"
          phx-mounted={@focus? && JS.focus()}
          class={["input w-full", @name_errors != [] && "input-error"]}
          aria-invalid={to_string(@name_errors != [])}
          aria-describedby={@name_errors != [] && "social-create-error"}
          data-role="social-create-name"
        />
        <p
          :for={msg <- @name_errors}
          id="social-create-error"
          role="alert"
          class="mt-1.5 flex items-center gap-1.5 text-sm text-base-content"
          data-role="social-create-error"
        >
          <.icon name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
          {msg}
        </p>
      </div>
      <div class="fieldset py-0">
        <label for="social-create-home-url" class="label mb-1 font-medium text-base-content/70">
          Home page (optional)
        </label>
        <input
          type="url"
          id="social-create-home-url"
          name={@form[:home_url].name}
          value={@form[:home_url].value}
          placeholder="https://youtube.com/@htc"
          autocomplete="off"
          class={["input w-full", @home_errors != [] && "input-error"]}
          aria-describedby="social-create-home-hint"
          data-role="social-create-home-url"
        />
        <p id="social-create-home-hint" class="mt-1 text-sm text-base-content/70">
          Where clips link back to. Add it later in Settings if you like.
        </p>
        <p
          :for={msg <- @home_errors}
          role="alert"
          class="mt-1.5 flex items-center gap-1.5 text-sm text-base-content"
        >
          <.icon name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
          {msg}
        </p>
      </div>
      <div class="flex justify-end pt-1">
        <button
          type="submit"
          class="btn btn-primary"
          phx-disable-with="Creating..."
          data-role="social-create-submit"
        >
          Create profile
        </button>
      </div>
    </.form>
    """
  end

  defp field_errors(%Phoenix.HTML.FormField{errors: errors}),
    do: Enum.map(errors, &PlatformWeb.CoreComponents.translate_error/1)
end
