defmodule PlatformWeb.SocialComposer do
  @moduledoc """
  The composer (Social authoring 6/11, task 01a16c50): a human writes one
  idea and gets one version per account in the brand's voice, side by side
  with real previews, then sends them through approval. The domain is
  `Platform.Social.Composer`; this module is only the screen.

  ## Where it lives

  The header's "New idea" button (`button/1`, shown by
  `PlatformWeb.SocialTopBar` while `enabled?/0` is true) pushes
  `composer_open` to this LiveComponent by its DOM id. The component is
  hosted by `host/1`, which the Queue tab renders as its overlay (the shell
  renders overlays only from tabs), so it is in the DOM on every tab.
  Another tab opens it on an existing idea with `open_idea/1` (the Ideas
  tab's "Draft it", 7/11): sending then joins that idea instead of making a
  new one.

  ## The flow

    1. The idea: title, brief, an optional source (a link, or a clip from
       the brand's library) and the accounts. Every connected account is
       ticked; a draft-only account says "you post this yourself", an owned
       one names its owner. In All brands, a brand select comes first.
    2. The versions: one column per account. Each column drafts on its own
       (`start_async`, its own skeleton), so one failing says why and leaves
       the others usable, and "Regenerate this one" redrafts only it. Each
       shows `PlatformWeb.SocialPreview.preview/1` live while you edit, the
       flags (with the brand's banned phrases, which warn a human), and the
       reasoning (`Platform.Social.Composer.rationale/4`).
    3. The actions: "Send for approval" (into Needs you, each post at its
       suggested slot), "Save as idea" (the idea alone, stage Inbox) and,
       only for a user who may approve at least one picked account, "Send
       and approve". All three re-check everything server side in
       `Platform.Social.Composer`, so a forged event writes nothing.

  Nothing here publishes: posts leave only through the approval card's
  decision path and `Platform.Social.Publishing`.
  """

  use PlatformWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Platform.Social
  alias Platform.Social.{Composer, Ideas, PlatformLimits, Voice}
  alias PlatformWeb.{SocialHelpers, SocialPreview}

  @dom_id "social-composer"

  @doc ~s(Whether the header shows the "New idea" button.)
  def enabled?, do: true

  @doc "The composer's DOM id (also its component id)."
  def dom_id, do: @dom_id

  @doc ~s(The header's "New idea" button.)
  # The top bar calls this with a bare map, so it takes no assigns.
  def button(assigns) do
    ~H"""
    <button
      type="button"
      class="btn btn-primary btn-sm whitespace-nowrap"
      data-role="social-new-idea"
      phx-click={JS.push("composer_open", target: "#" <> dom_id())}
    >
      <.icon name="hero-plus-micro" class="size-4" /> New idea
    </button>
    """
  end

  @doc """
  Hosts the composer. Given the Social LiveView's assigns (`:user`,
  `:profiles`, `:scope`, `:profile`).
  """
  def host(assigns) do
    ~H"""
    <.live_component
      module={__MODULE__}
      id={dom_id()}
      user={@user}
      profiles={@profiles}
      scope={@scope}
      profile={@profile}
    />
    """
  end

  @doc ~s(Opens the composer on an existing idea (the Ideas tab's "Draft it"\).)
  def open_idea(idea_id),
    do: Phoenix.LiveView.send_update(__MODULE__, id: @dom_id, open_idea: idea_id)

  # ── Lifecycle ────────────────────────────────────────────────────────

  @impl true
  def mount(socket) do
    {:ok, reset(socket)}
  end

  @impl true
  def update(%{open_idea: idea_id}, socket) do
    {:ok, open_on_idea(socket, idea_id)}
  end

  def update(assigns, socket) do
    {:ok,
     assign(socket,
       user: assigns[:user],
       profiles: assigns[:profiles] || [],
       scope: assigns[:scope],
       shell_profile: assigns[:profile]
     )}
  end

  defp reset(socket) do
    assign(socket,
      open?: false,
      step: :idea,
      profile: nil,
      idea: nil,
      accounts: [],
      owners: %{},
      clips: [],
      picked: [],
      idea_form: idea_form(%{}),
      idea_error: nil,
      columns: %{},
      composition_id: nil,
      recent: [],
      can_approve?: false,
      sent: nil,
      send_error: nil,
      busy?: false
    )
  end

  # ── Events ───────────────────────────────────────────────────────────

  @impl true
  def handle_event("composer_open", _params, socket) do
    socket = reset(socket)
    profile = initial_profile(socket)
    {:noreply, socket |> assign(:open?, true) |> pick_profile(profile)}
  end

  def handle_event("composer_close", _params, socket), do: {:noreply, reset(socket)}

  def handle_event("idea_change", %{"idea" => params}, socket) do
    socket =
      case params["profile_id"] do
        id when is_binary(id) and id != "" ->
          if socket.assigns.profile && socket.assigns.profile.id == id,
            do: socket,
            else: pick_profile(socket, Enum.find(composable(socket), &(&1.id == id)))

        _ ->
          socket
      end

    picked = picked_ids(params, socket.assigns.accounts)

    {:noreply,
     assign(socket,
       idea_form: idea_form(Map.put(params, "profile_id", profile_id(socket))),
       picked: picked,
       idea_error: nil
     )}
  end

  def handle_event("draft", %{"idea" => params}, socket) do
    socket =
      assign(socket,
        idea_form: idea_form(Map.put(params, "profile_id", profile_id(socket))),
        picked: picked_ids(params, socket.assigns.accounts)
      )

    cond do
      is_nil(socket.assigns.profile) ->
        {:noreply, assign(socket, :idea_error, "Pick a brand first.")}

      blank?(params["title"]) ->
        {:noreply, assign(socket, :idea_error, "Give the idea a title.")}

      socket.assigns.picked == [] ->
        {:noreply, assign(socket, :idea_error, "Pick at least one account.")}

      true ->
        {:noreply, start_drafting(socket)}
    end
  end

  def handle_event("back", _params, socket),
    do: {:noreply, assign(socket, step: :idea, send_error: nil)}

  def handle_event("edit", %{"version" => %{"account_id" => id} = params}, socket) do
    case Map.get(socket.assigns.columns, id) do
      %{state: :ok} = column ->
        column = %{
          column
          | text: params["text"] || column.text,
            title: Map.get(params, "title", column.title)
        }

        column = refresh_rationale(column, socket)
        {:noreply, assign(socket, :columns, Map.put(socket.assigns.columns, id, column))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("regenerate", %{"account_id" => id}, socket) do
    case Enum.find(socket.assigns.accounts, &(&1.id == id)) do
      nil -> {:noreply, socket}
      account -> {:noreply, draft_column(socket, account)}
    end
  end

  def handle_event("send", %{"mode" => mode}, socket) when mode in ["approval", "approve"] do
    {:noreply, send_composition(socket, mode == "approve")}
  end

  def handle_event("save_idea", params, socket) do
    params = Map.get(params, "idea", socket.assigns.idea_form.params)
    {:noreply, save_idea(socket, params)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Async drafting ───────────────────────────────────────────────────

  @impl true
  def handle_async({:column, id}, {:ok, {ref, result}}, socket) do
    case Map.get(socket.assigns.columns, id) do
      %{ref: ^ref} = column ->
        column = column_result(column, result, socket)
        {:noreply, assign(socket, :columns, Map.put(socket.assigns.columns, id, column))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_async({:column, id}, {:exit, _reason}, socket) do
    case Map.get(socket.assigns.columns, id) do
      %{state: :loading} = column ->
        column = %{column | state: :error, error: Composer.error_text(:column_crashed)}
        {:noreply, assign(socket, :columns, Map.put(socket.assigns.columns, id, column))}

      _ ->
        {:noreply, socket}
    end
  end

  defp start_drafting(socket) do
    socket =
      assign(socket,
        step: :versions,
        idea_error: nil,
        send_error: nil,
        composition_id: socket.assigns.composition_id || Composer.new_composition_id(),
        recent: Composer.recent_bodies(socket.assigns.profile),
        can_approve?: can_approve?(socket)
      )

    picked = socket.assigns.picked
    keep = Map.take(socket.assigns.columns, picked)
    socket = assign(socket, :columns, keep)

    socket.assigns.accounts
    |> Enum.filter(&(&1.id in picked))
    |> Enum.reduce(socket, &draft_column(&2, &1))
  end

  defp draft_column(socket, account) do
    ref = make_ref()
    profile = socket.assigns.profile
    input = compose_input(socket)

    column = %{
      account: account,
      ref: ref,
      state: :loading,
      error: nil,
      text: "",
      title: nil,
      original_text: nil,
      draft: nil,
      rationale: nil
    }

    socket
    |> assign(:columns, Map.put(socket.assigns.columns, account.id, column))
    |> start_async({:column, account.id}, fn ->
      result = Composer.adapt_one(profile, account.platform, input)

      result =
        case result do
          {:ok, draft} -> {:ok, draft, Composer.rationale(profile, account, draft)}
          error -> error
        end

      {ref, result}
    end)
  end

  defp column_result(column, {:ok, draft, rationale}, _socket) do
    %{
      column
      | state: :ok,
        draft: draft,
        text: draft.text,
        title: draft.title,
        original_text: draft.text,
        rationale: rationale
    }
  end

  defp column_result(column, {:error, reason}, _socket),
    do: %{column | state: :error, error: Composer.error_text(reason)}

  defp refresh_rationale(%{rationale: nil} = column, _socket), do: column

  defp refresh_rationale(column, socket) do
    rationale =
      Composer.rationale(
        socket.assigns.profile,
        column.account,
        %{text: column.text, title: column.title, why_shape: column.draft.why_shape},
        slot: column.rationale.slot,
        recent: socket.assigns.recent
      )

    %{column | rationale: rationale}
  end

  defp compose_input(socket) do
    params = socket.assigns.idea_form.params

    idea =
      [params["title"], params["brief"]]
      |> Enum.reject(&blank?/1)
      |> Enum.map_join("\n\n", &String.trim/1)

    %{
      idea: idea,
      source: source_text(socket, params),
      composition_id: socket.assigns.composition_id
    }
  end

  defp source_text(socket, params) do
    clip = Enum.find(socket.assigns.clips, &(&1.id == params["clip_id"]))

    [
      !blank?(params["source_url"]) && "Link: " <> String.trim(params["source_url"]),
      clip &&
        Enum.join(
          Enum.reject(["Clip: " <> (clip.title || "untitled"), clip.caption], &blank?/1),
          "\n"
        )
    ]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  # ── Send / save ──────────────────────────────────────────────────────

  defp send_composition(socket, approve?) do
    %{profile: profile, columns: columns, accounts: accounts, user: user} = socket.assigns
    now = DateTime.utc_now()

    drafts =
      for account <- accounts,
          %{state: :ok} = column <- [Map.get(columns, account.id)],
          not blank?(column.text) do
        slot = Social.next_free_slot(account, now)

        %{
          account_id: account.id,
          text: column.text,
          title: column.title,
          scheduled_at: slot,
          schedule_reason: slot && column.rationale && column.rationale.why_time,
          prompt_slug: column.draft.prompt_slug,
          composition_id: socket.assigns.composition_id,
          original_text: column.original_text
        }
      end

    compose = %{
      idea: socket.assigns.idea || idea_attrs(socket.assigns.idea_form.params),
      drafts: drafts
    }

    case profile && Composer.send(profile, user && user.id, compose, approve: approve?) do
      {:ok, result} ->
        send(self(), {__MODULE__, :sent, result.idea.id})

        assign(socket,
          step: :sent,
          sent: summary(result, approve?, accounts, profile.timezone || "Etc/UTC"),
          send_error: nil
        )

      {:error, {:partial, _reason, posts}} ->
        send(self(), {__MODULE__, :sent, posts |> List.first() |> Map.get(:idea_id)})

        assign(socket,
          send_error: "Only #{length(posts)} of #{length(drafts)} went out. Check Needs you."
        )

      {:error, reason} ->
        assign(socket, :send_error, send_error_text(reason))

      nil ->
        assign(socket, :send_error, "Pick a brand first.")
    end
  end

  defp save_idea(socket, params) do
    case socket.assigns.profile &&
           Composer.save_idea(
             socket.assigns.profile,
             socket.assigns.user && socket.assigns.user.id,
             idea_attrs(params)
           ) do
      {:ok, idea} ->
        send(self(), {__MODULE__, :saved, idea.id})

        assign(socket,
          step: :sent,
          sent: %{
            kind: :saved,
            title: idea.title,
            lines: ["Saved to Ideas, in Inbox. Draft it whenever you're ready."]
          }
        )

      {:error, %Ecto.Changeset{}} ->
        assign(socket, idea_error: "Give the idea a title.", send_error: "Give the idea a title.")

      {:error, reason} ->
        assign(socket, idea_error: send_error_text(reason), send_error: send_error_text(reason))

      nil ->
        assign(socket, :idea_error, "Pick a brand first.")
    end
  end

  defp idea_attrs(params) do
    %{
      title: params["title"] |> to_string() |> String.trim(),
      brief: blank_nil(params["brief"]),
      source_url: blank_nil(params["source_url"]),
      clip_id: blank_nil(params["clip_id"])
    }
  end

  defp summary(result, approve?, accounts, tz) do
    label = fn post ->
      account = Enum.find(accounts, &(&1.id == post.account_id))
      account_label(account)
    end

    lines =
      if approve? do
        Enum.map(result.approved, &"Approved: #{label.(&1)}#{when_line(&1, tz)}") ++
          Enum.map(result.waiting_owner, fn {post, owner} ->
            "Sent to #{SocialHelpers.user_name(owner)}: #{label.(post)} (their account, they decide)"
          end) ++
          Enum.map(
            result.by_hand,
            &"In Needs you to copy: #{label.(&1)} (you post this yourself)"
          ) ++
          Enum.map(result.not_approved, &"Waiting in Needs you: #{label.(&1)}")
      else
        Enum.map(result.posts, &"In Needs you: #{label.(&1)}#{when_line(&1, tz)}")
      end

    %{kind: if(approve?, do: :approved, else: :sent), title: result.idea.title, lines: lines}
  end

  defp when_line(%{scheduled_at: %DateTime{} = at}, tz) do
    local =
      case DateTime.shift_zone(at, tz) do
        {:ok, local} -> local
        _ -> at
      end

    ", goes out " <> Calendar.strftime(local, "%a %-d %b, %H:%M") <> " (#{tz})"
  end

  defp when_line(_post, _tz), do: ""

  defp send_error_text(:not_an_approver),
    do: "You can't approve these accounts. Send it for approval instead."

  defp send_error_text(:profile_has_no_channel),
    do: "This brand has no approval channel yet. Set one in Settings."

  defp send_error_text(:no_drafts), do: "There's no version to send yet."
  defp send_error_text(:schedule_in_past), do: "A suggested time has passed. Try again."

  defp send_error_text({:no_account, _}),
    do: "One of these accounts is gone. Go back and pick again."

  defp send_error_text({:invalid_draft, _}),
    do: "One version is empty. Write something or regenerate it."

  defp send_error_text(:approver_no_access), do: "You can't post for this brand."
  defp send_error_text(:not_a_human), do: "Only a signed-in person can send."
  defp send_error_text(_), do: "That didn't go through. Try again."

  # ── State helpers ────────────────────────────────────────────────────

  defp composable(socket) do
    user = socket.assigns.user
    Enum.filter(socket.assigns.profiles, &Composer.can_compose?(&1, user))
  end

  defp initial_profile(socket) do
    profiles = composable(socket)

    case socket.assigns.scope do
      {:profile, %{id: id}} ->
        Enum.find(profiles, &(&1.id == id)) || List.first(profiles)

      _ ->
        (socket.assigns.shell_profile &&
           Enum.find(profiles, &(&1.id == socket.assigns.shell_profile.id))) ||
          List.first(profiles)
    end
  end

  defp pick_profile(socket, nil),
    do: assign(socket, profile: nil, accounts: [], picked: [], clips: [])

  defp pick_profile(socket, profile) do
    accounts =
      profile.org_id
      |> Social.list_accounts(profile_id: profile.id)
      |> Enum.filter(&(is_nil(&1.archived_at) and &1.platform in Composer.platforms()))

    owners =
      accounts
      |> Enum.map(& &1.owner_user_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Map.new(&{&1, Platform.Accounts.get_user(&1)})

    clips = Social.list_clips(profile.org_id, profile_id: profile.id, status: "rendered")

    assign(socket,
      profile: profile,
      accounts: accounts,
      owners: owners,
      clips: Enum.reverse(clips),
      picked: for(a <- accounts, ticked_by_default?(a), do: a.id),
      columns: %{},
      idea_form: idea_form(Map.put(socket.assigns.idea_form.params, "profile_id", profile.id))
    )
  end

  defp open_on_idea(socket, idea_id) do
    profiles = composable(socket)

    found =
      profiles
      |> Enum.map(& &1.org_id)
      |> Enum.uniq()
      |> Enum.find_value(&Ideas.get(&1, idea_id))

    case found && Enum.find(profiles, &(&1.id == found.profile_id)) do
      nil ->
        socket

      profile ->
        socket
        |> reset()
        |> assign(:open?, true)
        |> pick_profile(profile)
        |> assign(:idea, found)
        |> assign(
          :idea_form,
          idea_form(%{
            "profile_id" => profile.id,
            "title" => found.title,
            "brief" => found.brief,
            "source_url" => found.source_url,
            "clip_id" => found.clip_id
          })
        )
    end
  end

  # Connected accounts, and draft-only ones (a human posts those by hand,
  # so there is nothing to connect).
  defp ticked_by_default?(%{approval_mode: "draft_only"}), do: true
  defp ticked_by_default?(%{status: status}), do: status == "connected"

  defp picked_ids(params, accounts) do
    ids = List.wrap(params["account_ids"])
    for a <- accounts, a.id in ids, do: a.id
  end

  defp can_approve?(socket) do
    %{profile: profile, accounts: accounts, picked: picked, user: user} = socket.assigns
    picked_accounts = Enum.filter(accounts, &(&1.id in picked))
    user != nil and Composer.approvable_account_ids(profile, picked_accounts, user.id) != []
  end

  defp profile_id(socket), do: socket.assigns.profile && socket.assigns.profile.id

  defp idea_form(params), do: to_form(params, as: :idea, id: "composer-idea")

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
  defp blank_nil(value), do: if(blank?(value), do: nil, else: String.trim(value))

  defp account_label(nil), do: "an account"

  defp account_label(account),
    do: "#{SocialHelpers.platform_label(account.platform)} #{account.handle}"

  defp owner_name(owners, %{owner_user_id: id}) when is_binary(id),
    do: owners |> Map.get(id) |> SocialHelpers.user_name()

  defp owner_name(_owners, _account), do: nil

  # ── Render ───────────────────────────────────────────────────────────

  @impl true
  def render(%{open?: false} = assigns) do
    ~H"""
    <div id={dom_id()} data-role="social-composer" data-open="false" class="hidden"></div>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        composable: composable(assigns_socket(assigns)),
        ordered: ordered_columns(assigns),
        loading?: Enum.any?(Map.values(assigns.columns), &(&1.state == :loading)),
        ready:
          Enum.count(Map.values(assigns.columns), &(&1.state == :ok and not blank?(&1.text))),
        failed: Enum.count(Map.values(assigns.columns), &(&1.state == :error))
      )

    ~H"""
    <div
      id={dom_id()}
      data-role="social-composer"
      data-open="true"
      data-step={@step}
      class="fixed inset-0 z-50 flex items-stretch justify-center sm:items-center sm:p-4"
      phx-window-keydown="composer_close"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div
        class="absolute inset-0 hidden bg-base-content/40 sm:block"
        aria-hidden="true"
        phx-click="composer_close"
        phx-target={@myself}
      >
      </div>
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="composer-heading"
        class="relative flex h-full w-full flex-col overflow-hidden bg-base-100 text-base-content sm:h-[85vh] sm:max-w-[960px] sm:rounded-box sm:border sm:border-base-300 sm:shadow-xl"
      >
        <header class="flex items-center gap-3 border-b border-base-300 px-4 py-3 sm:px-6">
          <button
            :if={@step == :versions}
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="back"
            phx-target={@myself}
            aria-label="Back to the idea"
            data-role="composer-back"
          >
            <.icon name="hero-arrow-left" class="size-5" />
          </button>
          <div class="min-w-0 flex-1">
            <h2 id="composer-heading" class="truncate text-lg font-semibold">
              {heading(@step, @idea_form.params["title"])}
            </h2>
            <p :if={@profile} class="truncate text-sm text-base-content">
              {step_hint(@step, @profile)}
            </p>
          </div>
          <ol
            class="hidden items-center gap-2 text-xs font-medium text-base-content sm:flex"
            aria-label="Steps"
          >
            <li class={[@step == :idea && "text-base-content"]}>1 Idea</li>
            <li aria-hidden="true">·</li>
            <li class={[@step == :versions && "text-base-content"]}>2 Versions</li>
            <li aria-hidden="true">·</li>
            <li class={[@step == :sent && "text-base-content"]}>3 Sent</li>
          </ol>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="composer_close"
            phx-target={@myself}
            aria-label="Close"
            data-role="composer-close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>

        <.idea_step :if={@step == :idea} {assigns} />
        <.versions_step :if={@step == :versions} {assigns} />
        <.sent_step :if={@step == :sent} {assigns} />
      </section>
    </div>
    """
  end

  # The socket-less helpers above read `socket.assigns`; render has only assigns.
  defp assigns_socket(assigns), do: %{assigns: assigns}

  defp heading(:idea, _title), do: "New idea"
  defp heading(_step, title) when is_binary(title) and title != "", do: title
  defp heading(_step, _title), do: "New idea"

  defp step_hint(:idea, profile),
    do: "For #{profile.name}. One version per account, in the brand's voice."

  defp step_hint(:versions, profile),
    do: "#{profile.name} · edit any version, the preview follows."

  defp step_hint(:sent, profile), do: profile.name

  defp ordered_columns(assigns) do
    for account <- assigns.accounts,
        column = Map.get(assigns.columns, account.id),
        column != nil,
        do: {account, column}
  end

  # ── Step 1: the idea ──

  defp idea_step(assigns) do
    ~H"""
    <.form
      for={@idea_form}
      id="composer-idea-form"
      phx-change="idea_change"
      phx-submit="draft"
      phx-target={@myself}
      class="flex min-h-0 flex-1 flex-col"
    >
      <div class="min-h-0 flex-1 space-y-5 overflow-y-auto px-4 py-5 sm:px-6">
        <p :if={@composable == []} class="text-sm text-base-content" data-role="composer-no-brand">
          You can't post for any brand here yet.
        </p>

        <div :if={length(@composable) > 1 and is_nil(@idea)}>
          <.input
            field={@idea_form[:profile_id]}
            type="select"
            label="Brand"
            options={Enum.map(@composable, &{&1.name, &1.id})}
            data-role="composer-brand"
          />
        </div>

        <.input
          field={@idea_form[:title]}
          type="text"
          label="The idea"
          placeholder="What do you want to say?"
          maxlength="200"
          autocomplete="off"
          phx-mounted={JS.focus()}
          data-role="composer-title"
        />
        <.input
          field={@idea_form[:brief]}
          type="textarea"
          label="Brief (optional)"
          placeholder="The point, who it's for, anything the versions must include."
          rows="4"
          data-role="composer-brief"
        />

        <div class="grid gap-4 sm:grid-cols-2">
          <.input
            field={@idea_form[:source_url]}
            type="url"
            label="Source link (optional)"
            placeholder="https://"
            data-role="composer-source-url"
          />
          <.input
            :if={@clips != []}
            field={@idea_form[:clip_id]}
            type="select"
            label="Or a clip from the library"
            prompt="No clip"
            options={Enum.map(@clips, &{&1.title || "Untitled clip", &1.id})}
            data-role="composer-clip"
          />
        </div>

        <fieldset :if={@profile} class="space-y-2" data-role="composer-accounts">
          <legend class="mb-1 text-sm font-semibold">Accounts</legend>
          <p :if={@accounts == []} class="text-sm text-base-content">
            {@profile.name} has no accounts yet. Connect one in Connections.
          </p>
          <input type="hidden" name="idea[account_ids][]" value="" />
          <label
            :for={account <- @accounts}
            class="flex cursor-pointer items-center gap-3 rounded-box border border-base-300 px-3 py-2.5 hover:bg-base-200 has-[:checked]:border-primary"
            data-role="composer-account"
            data-account-id={account.id}
          >
            <input
              type="checkbox"
              name="idea[account_ids][]"
              value={account.id}
              checked={account.id in @picked}
              class="checkbox checkbox-primary checkbox-sm"
            />
            <SocialPreview.glyph platform={account.platform} class="size-4 shrink-0" />
            <span class="min-w-0 flex-1">
              <span class="block truncate text-sm font-medium">
                {SocialHelpers.platform_label(account.platform)}
                <span class="font-normal text-base-content">{account.handle}</span>
              </span>
              <span
                :if={account.approval_mode == "draft_only"}
                class="block text-xs text-base-content"
                data-role="composer-by-hand"
              >
                You post this yourself
              </span>
              <span
                :if={owner_name(@owners, account)}
                class="block text-xs text-base-content"
                data-role="composer-owner"
              >
                {owner_name(@owners, account)}'s account: they approve it
              </span>
              <span
                :if={account.status != "connected" and account.approval_mode != "draft_only"}
                class="block text-xs text-warning"
              >
                Not connected
              </span>
            </span>
          </label>
        </fieldset>

        <p :if={@idea_error} class="text-sm text-error" role="alert" data-role="composer-idea-error">
          {@idea_error}
        </p>
      </div>

      <footer class="flex flex-wrap items-center justify-end gap-2 border-t border-base-300 px-4 py-3 sm:px-6">
        <button
          type="button"
          class="btn btn-ghost btn-sm mr-auto"
          phx-click="composer_close"
          phx-target={@myself}
        >
          Cancel
        </button>
        <button
          :if={is_nil(@idea)}
          type="button"
          class="btn btn-sm"
          phx-click="save_idea"
          phx-target={@myself}
          data-role="composer-save-idea"
        >
          Save as idea
        </button>
        <button
          type="submit"
          class="btn btn-primary btn-sm"
          disabled={is_nil(@profile)}
          data-role="composer-draft"
        >
          Draft {length(@picked)} {if length(@picked) == 1, do: "version", else: "versions"}
          <.icon name="hero-arrow-right-micro" class="size-4" />
        </button>
      </footer>
    </.form>
    """
  end

  # ── Step 2: the versions ──

  defp versions_step(assigns) do
    ~H"""
    <div class="min-h-0 flex-1 overflow-y-auto px-4 py-4 sm:overflow-x-auto sm:px-6">
      <div
        class="grid gap-4 sm:min-h-full sm:grid-flow-col sm:auto-cols-[minmax(17.5rem,1fr)]"
        data-role="composer-columns"
      >
        <.column
          :for={{account, column} <- @ordered}
          account={account}
          column={column}
          profile={@profile}
          owners={@owners}
          myself={@myself}
        />
      </div>
    </div>

    <footer class="space-y-2 border-t border-base-300 px-4 py-3 sm:px-6">
      <p :if={@send_error} class="text-sm text-error" role="alert" data-role="composer-send-error">
        {@send_error}
      </p>
      <p
        :if={@failed > 0 and not @loading?}
        class="text-xs text-base-content"
        data-role="composer-left-out"
      >
        {@failed} {if @failed == 1, do: "version", else: "versions"} didn't draft and won't be sent. Try again on the column, or send the rest.
      </p>
      <div class="flex flex-wrap items-center justify-end gap-2">
        <button
          :if={is_nil(@idea)}
          type="button"
          class="btn btn-ghost btn-sm mr-auto"
          phx-click="save_idea"
          phx-target={@myself}
          data-role="composer-save-idea"
        >
          Save as idea
        </button>
        <button
          type="button"
          class={["btn btn-sm flex-1 sm:flex-none", if(@can_approve?, do: "", else: "btn-primary")]}
          disabled={@loading? or @ready == 0}
          phx-click="send"
          phx-value-mode="approval"
          phx-target={@myself}
          phx-disable-with="Sending…"
          data-role="composer-send"
        >
          Send {@ready} for approval
        </button>
        <button
          :if={@can_approve?}
          type="button"
          class="btn btn-primary btn-sm flex-1 sm:flex-none"
          disabled={@loading? or @ready == 0}
          phx-click="send"
          phx-value-mode="approve"
          phx-target={@myself}
          phx-disable-with="Approving…"
          data-role="composer-send-approve"
        >
          <.icon name="hero-check-micro" class="size-4" /> Send and approve
        </button>
      </div>
    </footer>
    """
  end

  attr :account, :map, required: true
  attr :column, :map, required: true
  attr :profile, :map, required: true
  attr :owners, :map, required: true
  attr :myself, :any, required: true

  defp column(assigns) do
    assigns =
      assign(assigns,
        form:
          to_form(
            %{
              "account_id" => assigns.account.id,
              "text" => assigns.column.text,
              "title" => assigns.column.title
            },
            as: :version,
            id: "composer-version-#{assigns.account.id}"
          ),
        flags:
          assigns.column.state == :ok &&
            PlatformLimits.flags(assigns.account.platform, %{
              body: assigns.column.text,
              title: assigns.column.title,
              account: assigns.account,
              banned: Voice.of(assigns.profile).banned
            })
      )

    ~H"""
    <article
      id={"composer-column-#{@account.id}"}
      class="flex min-w-0 flex-col gap-3 rounded-box border border-base-300 bg-base-100 p-3"
      data-role="composer-column"
      data-account-id={@account.id}
      data-platform={@account.platform}
      data-state={@column.state}
    >
      <header class="flex items-center gap-2">
        <SocialPreview.glyph platform={@account.platform} class="size-4 shrink-0" />
        <span class="min-w-0 flex-1 truncate text-sm font-semibold">
          {SocialHelpers.platform_label(@account.platform)}
          <span class="font-normal text-base-content">{@account.handle}</span>
        </span>
        <button
          type="button"
          class="btn btn-ghost btn-sm btn-square"
          disabled={@column.state == :loading}
          phx-click="regenerate"
          phx-value-account_id={@account.id}
          phx-target={@myself}
          aria-label="Regenerate this one"
          title="Regenerate this one"
          data-role="composer-regenerate"
        >
          <.icon name="hero-arrow-path" class="size-4" />
        </button>
      </header>

      <div
        :if={@column.state == :loading}
        class="space-y-3"
        data-role="composer-skeleton"
        aria-busy="true"
      >
        <span class="sr-only">
          Drafting the {SocialHelpers.platform_label(@account.platform)} version…
        </span>
        <div class="skeleton h-24 w-full"></div>
        <div class="skeleton h-4 w-11/12"></div>
        <div class="skeleton h-4 w-3/4"></div>
        <div class="skeleton h-40 w-full"></div>
      </div>

      <div
        :if={@column.state == :error}
        role="alert"
        class="rounded-box border border-error/40 bg-error/10 p-3 text-sm"
        data-role="composer-error"
      >
        <p class="font-medium">This version didn't draft.</p>
        <p class="text-base-content">{@column.error}</p>
      </div>

      <div :if={@column.state == :ok} class="flex min-w-0 flex-col gap-3">
        <p
          :if={@column.draft.banned_phrase}
          class="rounded-box border border-warning bg-warning/10 p-2 text-xs"
          data-role="composer-banned"
        >
          Redrafted once to drop "{@column.draft.banned_phrase}", and it's still there. Edit it out before sending.
        </p>
        <.form
          for={@form}
          id={"composer-edit-#{@account.id}"}
          phx-change="edit"
          phx-target={@myself}
          class="space-y-2"
        >
          <input type="hidden" name={@form[:account_id].name} value={@account.id} />
          <.input
            :if={@account.platform == "youtube"}
            field={@form[:title]}
            type="text"
            label="Title"
            phx-debounce="250"
            data-role="composer-edit-title"
          />
          <.input
            field={@form[:text]}
            type="textarea"
            label={if @account.platform == "youtube", do: "Description", else: "Text"}
            rows="6"
            phx-debounce="250"
            data-role="composer-edit"
          />
        </.form>

        <SocialPreview.preview
          id={"composer-preview-#{@account.id}"}
          platform={@account.platform}
          account={preview_account(@account, @owners, @profile)}
          body={@column.text}
          title={@column.title}
          flags={@flags}
        />

        <section class="space-y-2 rounded-box bg-base-200 p-3 text-sm" data-role="composer-rationale">
          <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content">
            Why this version
          </h3>
          <dl class="space-y-2">
            <div :if={@column.rationale.why_format}>
              <dt class="font-medium">Format</dt>
              <dd class="text-base-content" data-role="composer-why-format">
                {@column.rationale.why_format}
              </dd>
            </div>
            <div>
              <dt class="font-medium">Time</dt>
              <dd class="text-base-content" data-role="composer-why-time">
                {@column.rationale.why_time}
              </dd>
            </div>
            <div>
              <dt class="font-medium">Voice</dt>
              <dd
                class={[
                  (@column.rationale.banned || @column.rationale.repeat) && "text-warning",
                  !(@column.rationale.banned || @column.rationale.repeat) && "text-base-content"
                ]}
                data-role="composer-voice-check"
              >
                {@column.rationale.voice_check}
              </dd>
            </div>
          </dl>
        </section>
      </div>
    </article>
    """
  end

  defp preview_account(account, owners, profile) do
    %{
      name: profile.name,
      handle: account.handle,
      approval_mode: account.approval_mode,
      status: account.status,
      platform_account_type: account.platform_account_type,
      owner_name: owner_name(owners, account)
    }
  end

  # ── Step 3: sent ──

  defp sent_step(assigns) do
    ~H"""
    <div
      class="min-h-0 flex-1 overflow-y-auto px-4 py-8 sm:px-6"
      data-role="composer-sent"
      data-kind={@sent.kind}
    >
      <div class="mx-auto max-w-md space-y-4 text-center">
        <span class="mx-auto flex size-12 items-center justify-center rounded-full bg-success/15 text-success">
          <.icon name="hero-check" class="size-6" />
        </span>
        <h3 class="text-lg font-semibold">{sent_heading(@sent.kind)}</h3>
        <ul class="space-y-1.5 text-left text-sm" data-role="composer-sent-lines">
          <li :for={line <- @sent.lines} class="rounded-box bg-base-200 px-3 py-2">{line}</li>
        </ul>
      </div>
    </div>
    <footer class="flex flex-wrap items-center justify-end gap-2 border-t border-base-300 px-4 py-3 sm:px-6">
      <button
        type="button"
        class="btn btn-ghost btn-sm mr-auto"
        phx-click="composer_open"
        phx-target={@myself}
        data-role="composer-another"
      >
        Another idea
      </button>
      <button
        type="button"
        class="btn btn-primary btn-sm"
        phx-click={done_click(@sent.kind, @myself)}
        data-role="composer-done"
      >
        {if @sent.kind == :saved, do: "Done", else: "Open Needs you"}
      </button>
    </footer>
    """
  end

  defp done_click(:saved, myself), do: JS.push("composer_close", target: myself)

  defp done_click(_kind, myself),
    do:
      "composer_close" |> JS.push(target: myself) |> JS.push("select_tab", value: %{tab: "queue"})

  defp sent_heading(:sent), do: "Sent for approval"
  defp sent_heading(:approved), do: "Sent and approved"
  defp sent_heading(:saved), do: "Saved as an idea"
end
