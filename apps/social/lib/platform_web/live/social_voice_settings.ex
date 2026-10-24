defmodule PlatformWeb.SocialVoiceSettings do
  @moduledoc """
  Brand voice, timezone and posting slots in Settings (Social authoring
  4/11, task 01a16c4f-9041). Rendered and driven by
  `PlatformWeb.SocialSettingsTab`, which owns the events and routes them
  here.

  Two parts, both per brand:

    * **Voice and timing** (`social-voice-form`): timezone, sample posts
      (add/remove rows), banned phrases (chips), learnings (read only, with
      remove, which writes at once), who is notified (a subset of the
      approvers) and the drafting agent (active agents of the org). Edits
      live in a draft in assigns (`:voice_draft`) until Save.
    * **Posting slots**, one card per live account: weekday chips plus a
      time to add slots, each slot removable, and a weekly goal. Save per
      account (`Platform.Social.update_account_schedule/3`).

  Approvers only. A non-approver gets `readonly/1`: no form, no button.
  Every write re-checks the approver on the server (`SocialHelpers.authorize/1`)
  and takes ids only from the options rebuilt for this profile, so a forged
  event writes nothing.
  """

  use PlatformWeb, :html

  import PlatformWeb.SocialHelpers, only: [authorize: 1, notice: 2, profile_account: 2]

  alias Platform.Social
  alias Platform.Social.{PostingSlot, Profile, Voice}

  @empty_slots "No slots yet. Approve into next slot is off until you add one."

  @doc "The empty-slots sentence."
  def empty_slots_text, do: @empty_slots

  @events ~w(voice_change voice_save voice_add_sample voice_remove_sample voice_add_banned
             voice_remove_banned voice_remove_learning slot_change slot_toggle_day slot_add
             slot_remove slot_save)

  @doc "The events this module handles (routed by the Settings tab)."
  def events, do: @events

  # ── Load ────────────────────────────────────────────────────────────

  @doc "Assigns the voice and slot state for the socket's profile."
  def load(%{assigns: %{profile: %Profile{} = profile, can_edit?: can_edit?}} = socket) do
    options = options(profile, can_edit?)

    socket
    |> assign(:voice_options, options)
    |> assign(:voice_draft, voice_draft(profile))
    |> assign(:voice_errors, [])
    |> assign(:slot_cards, slot_cards(profile))
  end

  def load(socket) do
    socket
    |> assign(:voice_options, %{timezones: [], approvers: [], agents: []})
    |> assign(:voice_draft, nil)
    |> assign(:voice_errors, [])
    |> assign(:slot_cards, [])
  end

  defp options(_profile, false), do: %{timezones: [], approvers: [], agents: []}

  defp options(%Profile{} = profile, true) do
    approvers =
      (profile.approver_user_ids || [])
      |> Enum.map(&Platform.Accounts.get_user/1)
      |> Enum.reject(&is_nil/1)

    %{
      timezones: timezones(profile.timezone),
      approvers: approvers,
      agents: Social.drafting_agent_options(profile.org_id)
    }
  end

  # Every canonical IANA zone, plus the profile's own if it is not one.
  defp timezones(current) do
    zones = Tzdata.canonical_zone_list()
    if current in zones or current in [nil, ""], do: zones, else: [current | zones]
  end

  defp voice_draft(%Profile{} = profile) do
    voice = Voice.of(profile)

    %{
      "timezone" => profile.timezone || "Etc/UTC",
      "samples" => voice.samples,
      "banned" => voice.banned,
      "banned_new" => "",
      "notify_user_ids" => profile.notify_user_ids || [],
      "drafting_agent_id" => profile.drafting_agent_id || ""
    }
  end

  defp slot_cards(%Profile{} = profile) do
    profile.org_id
    |> Social.list_accounts(profile_id: profile.id)
    |> Enum.map(&slot_card(&1, profile))
  end

  defp slot_card(account, profile) do
    %{
      account: account,
      slots: Enum.map(account.posting_slots || [], &%{weekday: &1.weekday, time: &1.time}),
      goal: if(account.weekly_goal, do: Integer.to_string(account.weekly_goal), else: ""),
      days: [],
      time: "09:00",
      errors: [],
      next_free: next_free_label(account, profile)
    }
  end

  defp next_free_label(account, profile) do
    case Social.next_free_slot(account, DateTime.utc_now()) do
      nil ->
        nil

      at ->
        at
        |> DateTime.shift_zone!(profile.timezone || "Etc/UTC")
        |> Calendar.strftime("%a %-d %b, %H:%M")
    end
  end

  # ── Events ──────────────────────────────────────────────────────────

  @doc "Handles one of `events/0`."
  def handle_event(_event, _params, %{assigns: %{voice_draft: nil}} = socket),
    do: {:noreply, socket}

  def handle_event(_event, _params, %{assigns: %{can_edit?: false}} = socket),
    do: {:noreply, notice(socket, "Only an approver of this profile can change it.")}

  def handle_event("voice_change", %{"voice" => params}, socket),
    do: {:noreply, update(socket, :voice_draft, &merge_voice(&1, params))}

  def handle_event("voice_add_sample", _params, socket) do
    {:noreply,
     update(socket, :voice_draft, fn d ->
       if length(d["samples"]) < Voice.limits().samples,
         do: %{d | "samples" => d["samples"] ++ [""]},
         else: d
     end)}
  end

  def handle_event("voice_remove_sample", %{"index" => index}, socket),
    do: {:noreply, update(socket, :voice_draft, &drop_at(&1, "samples", index))}

  def handle_event("voice_add_banned", _params, socket),
    do: {:noreply, update(socket, :voice_draft, &fold_banned/1)}

  def handle_event("voice_remove_banned", %{"index" => index}, socket),
    do: {:noreply, update(socket, :voice_draft, &drop_at(&1, "banned", index))}

  def handle_event("voice_remove_learning", %{"id" => id}, socket) do
    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, profile} <- Social.remove_voice_learning(profile.org_id, profile, user_id, id) do
      {:noreply, socket |> put_profile(profile) |> notice("Learning removed.")}
    else
      {:error, :not_an_approver} -> {:noreply, refuse(socket)}
      _ -> {:noreply, notice(socket, "That learning could not be removed.")}
    end
  end

  def handle_event("voice_save", params, socket) do
    socket =
      case params do
        %{"voice" => p} -> update(socket, :voice_draft, &merge_voice(&1, p))
        _ -> socket
      end

    with {:ok, profile, _user_id} <- authorize(socket) do
      draft = fold_banned(socket.assigns.voice_draft)
      attrs = voice_attrs(draft, profile, socket.assigns.voice_options)

      case Social.update_profile(profile.org_id, profile, attrs) do
        {:ok, profile} ->
          {:noreply,
           socket
           |> put_profile(profile)
           |> assign(:voice_draft, voice_draft(profile))
           |> assign(:voice_errors, [])
           |> notice("Voice and timing saved.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> assign(:voice_draft, draft)
           |> assign(:voice_errors, changeset_errors(changeset))}

        {:error, _} ->
          {:noreply, notice(socket, "Those settings could not be saved.")}
      end
    else
      _ -> {:noreply, refuse(socket)}
    end
  end

  def handle_event("slot_change", %{"account_id" => id} = params, socket) do
    slot = Map.get(params, "slot", %{})

    {:noreply,
     update_card(socket, id, fn card ->
       %{
         card
         | time: Map.get(slot, "time", card.time),
           goal: Map.get(slot, "weekly_goal", card.goal)
       }
     end)}
  end

  def handle_event("slot_toggle_day", %{"account_id" => id, "day" => day}, socket) do
    case Integer.parse(to_string(day)) do
      {d, ""} when d in 1..7 ->
        {:noreply,
         update_card(socket, id, fn card ->
           days = if d in card.days, do: List.delete(card.days, d), else: [d | card.days]
           %{card | days: Enum.sort(days)}
         end)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("slot_add", %{"account_id" => id}, socket) do
    {:noreply,
     update_card(socket, id, fn card ->
       cond do
         card.days == [] ->
           %{card | errors: ["Pick at least one day."]}

         not valid_time?(card.time) ->
           %{card | errors: ["Time must be HH:MM."]}

         true ->
           added = Enum.map(card.days, &%{weekday: &1, time: card.time})

           slots =
             (card.slots ++ added)
             |> Enum.uniq()
             |> Enum.sort_by(&{&1.weekday, &1.time})

           %{card | slots: slots, days: [], errors: []}
       end
     end)}
  end

  def handle_event("slot_remove", %{"account_id" => id, "index" => index}, socket) do
    {:noreply,
     update_card(socket, id, fn card ->
       case Integer.parse(to_string(index)) do
         {i, ""} -> %{card | slots: List.delete_at(card.slots, i)}
         _ -> card
       end
     end)}
  end

  def handle_event("slot_save", %{"account_id" => id} = params, socket) do
    socket =
      if is_map(params["slot"]),
        do: elem(handle_event("slot_change", params, socket), 1),
        else: socket

    with {:ok, profile, _user_id} <- authorize(socket),
         %{} = account <- profile_account(profile, id),
         %{} = card <- Enum.find(socket.assigns.slot_cards, &(&1.account.id == account.id)) do
      attrs = %{posting_slots: card.slots, weekly_goal: blank_to_nil(card.goal)}

      case Social.update_account_schedule(profile.org_id, account, attrs) do
        {:ok, account} ->
          {:noreply,
           socket
           |> update_card(id, fn _ -> slot_card(account, profile) end)
           |> notice("Slots saved for #{account_label(account)}.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, update_card(socket, id, &%{&1 | errors: changeset_errors(changeset)})}

        {:error, _} ->
          {:noreply, notice(socket, "Those slots could not be saved.")}
      end
    else
      {:error, :not_an_approver} -> {:noreply, refuse(socket)}
      _ -> {:noreply, notice(socket, "That account is not part of this profile.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp refuse(socket), do: notice(socket, "Only an approver of this profile can change it.")

  defp put_profile(socket, profile) do
    socket
    |> assign(:profile, profile)
    |> assign(:scope, {:profile, profile})
  end

  defp merge_voice(draft, params) when is_map(params) do
    draft
    |> put_if(params, "timezone")
    |> put_if(params, "banned_new")
    |> put_if(params, "drafting_agent_id")
    |> then(fn d ->
      case params["samples"] do
        list when is_list(list) -> %{d | "samples" => Enum.filter(list, &is_binary/1)}
        %{} = map -> %{d | "samples" => indexed_values(map)}
        _ -> d
      end
    end)
    |> then(fn d ->
      case params["notify_user_ids"] do
        list when is_list(list) -> %{d | "notify_user_ids" => Enum.reject(list, &(&1 == ""))}
        _ -> d
      end
    end)
  end

  defp merge_voice(draft, _params), do: draft

  defp put_if(draft, params, key) do
    case params[key] do
      value when is_binary(value) -> Map.put(draft, key, value)
      _ -> draft
    end
  end

  defp indexed_values(map) do
    map
    |> Enum.flat_map(fn {k, v} ->
      case Integer.parse(k) do
        {i, ""} when is_binary(v) -> [{i, v}]
        _ -> []
      end
    end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp drop_at(draft, key, index) do
    case Integer.parse(to_string(index)) do
      {i, ""} -> Map.update!(draft, key, &List.delete_at(&1, i))
      _ -> draft
    end
  end

  # Adds the typed phrase(s) (comma-separated) as chips, case-insensitively
  # de-duplicated, and clears the input.
  defp fold_banned(draft) do
    new =
      (draft["banned_new"] || "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    banned = Enum.uniq_by(draft["banned"] ++ new, &String.downcase/1)
    %{draft | "banned" => banned, "banned_new" => ""}
  end

  # Only offered values are written: a timezone from the list, approvers
  # of THIS profile, an agent of this org. Anything else falls back to what
  # the profile has (or nil for the agent).
  defp voice_attrs(draft, profile, %{timezones: zones, approvers: approvers, agents: agents}) do
    approver_ids = MapSet.new(approvers, & &1.id)
    agent_ids = MapSet.new(agents, & &1.id)

    timezone = if draft["timezone"] in zones, do: draft["timezone"], else: profile.timezone

    agent_id =
      if MapSet.member?(agent_ids, draft["drafting_agent_id"]),
        do: draft["drafting_agent_id"],
        else: nil

    %{
      timezone: timezone,
      voice: %{samples: draft["samples"], banned: draft["banned"]},
      notify_user_ids:
        draft["notify_user_ids"] |> Enum.filter(&MapSet.member?(approver_ids, &1)) |> Enum.uniq(),
      drafting_agent_id: agent_id
    }
  end

  defp update_card(socket, id, fun) do
    update(socket, :slot_cards, fn cards ->
      Enum.map(cards, fn card -> if card.account.id == id, do: fun.(card), else: card end)
    end)
  end

  defp valid_time?(time) when is_binary(time),
    do: Regex.match?(~r/\A([01]\d|2[0-3]):[0-5]\d\z/, time)

  defp valid_time?(_), do: false

  defp blank_to_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: v)
  defp blank_to_nil(v), do: v

  defp changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> flatten_errors([])
  end

  defp flatten_errors(errors, path) when is_map(errors) do
    Enum.flat_map(errors, fn {k, v} -> flatten_errors(v, path ++ [k]) end)
  end

  defp flatten_errors(list, path) when is_list(list) do
    Enum.flat_map(list, fn
      msg when is_binary(msg) -> ["#{label_for(path)} #{msg}"]
      other -> flatten_errors(other, path)
    end)
  end

  defp label_for(path), do: path |> List.last() |> to_string() |> String.replace("_", " ")

  defp account_label(account), do: "@#{account.handle || account.platform}"

  # ── Render ──────────────────────────────────────────────────────────

  attr :profile, :map, required: true
  attr :draft, :map, required: true
  attr :options, :map, required: true
  attr :errors, :list, default: []
  attr :cards, :list, required: true

  @doc "The approver's editor."
  def editor(assigns) do
    assigns =
      assigns
      |> assign(:form, to_form(assigns.draft, as: :voice))
      |> assign(:learnings, Voice.of(assigns.profile).learnings)
      |> assign(:limits, Voice.limits())

    ~H"""
    <section
      class="mt-6 max-w-xl rounded-lg border border-base-300 bg-base-100 p-3 sm:p-4"
      aria-labelledby="social-voice-label"
      data-role="social-voice"
    >
      <h3 id="social-voice-label" class="text-sm font-semibold text-base-content">
        Voice and timing
      </h3>
      <p class="mt-0.5 text-sm text-base-content">
        Drafting agents copy the samples and never use a banned phrase.
      </p>

      <.form
        for={@form}
        id="social-voice-form"
        phx-change="voice_change"
        phx-submit="voice_save"
        class="mt-3 space-y-4"
        data-role="social-voice-form"
      >
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <.input
            field={@form[:timezone]}
            type="select"
            label="Timezone"
            options={@options.timezones}
            data-role="social-voice-timezone"
          />
          <.input
            field={@form[:drafting_agent_id]}
            type="select"
            label="Drafting agent"
            prompt="No agent"
            options={Enum.map(@options.agents, &{&1.name, &1.id})}
            data-role="social-voice-agent"
          />
        </div>

        <fieldset class="space-y-2" data-role="social-voice-samples">
          <legend class="text-sm font-medium text-base-content">
            Sample posts
            <span class="font-normal text-base-content">
              ({length(@draft["samples"])} of {@limits.samples})
            </span>
          </legend>
          <p :if={@draft["samples"] == []} class="text-sm text-base-content">
            No samples yet. Paste two or three posts that sound like this brand.
          </p>
          <div
            :for={{sample, i} <- Enum.with_index(@draft["samples"])}
            class="flex items-start gap-2"
            data-role="social-voice-sample"
          >
            <label for={"social-voice-sample-#{i}"} class="sr-only">Sample {i + 1}</label>
            <textarea
              id={"social-voice-sample-#{i}"}
              name="voice[samples][]"
              rows="3"
              maxlength={@limits.sample_length}
              class="textarea min-w-0 flex-1"
            >{sample}</textarea>
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-square"
              phx-click="voice_remove_sample"
              phx-value-index={i}
              aria-label={"Remove sample #{i + 1}"}
              data-role="social-voice-sample-remove"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <button
            :if={length(@draft["samples"]) < @limits.samples}
            type="button"
            class="btn btn-outline btn-sm"
            phx-click="voice_add_sample"
            data-role="social-voice-sample-add"
          >
            <.icon name="hero-plus" class="size-4" /> Add sample
          </button>
        </fieldset>

        <fieldset class="space-y-2" data-role="social-voice-banned">
          <legend class="text-sm font-medium text-base-content">Banned phrases</legend>
          <p class="text-sm text-base-content">
            Agents cannot use these. People see a warning.
          </p>
          <ul :if={@draft["banned"] != []} class="flex flex-wrap gap-1.5">
            <li
              :for={{phrase, i} <- Enum.with_index(@draft["banned"])}
              class="badge badge-outline gap-1 py-3"
              data-role="social-voice-banned-chip"
            >
              <span class="max-w-48 truncate">{phrase}</span>
              <button
                type="button"
                class="cursor-pointer text-base-content hover:text-base-content"
                phx-click="voice_remove_banned"
                phx-value-index={i}
                aria-label={"Remove #{phrase}"}
                data-role="social-voice-banned-remove"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </li>
          </ul>
          <div class="flex items-center gap-2">
            <label for="social-voice-banned-new" class="sr-only">Add a banned phrase</label>
            <input
              id="social-voice-banned-new"
              type="text"
              name={@form[:banned_new].name}
              value={@draft["banned_new"]}
              placeholder="e.g. game changer"
              maxlength={@limits.phrase_length}
              class="input min-w-0 flex-1"
              data-role="social-voice-banned-input"
            />
            <button
              type="button"
              class="btn btn-outline btn-sm"
              phx-click="voice_add_banned"
              data-role="social-voice-banned-add"
            >
              Add
            </button>
          </div>
        </fieldset>

        <input type="hidden" name="voice[notify_user_ids][]" value="" />
        <.input
          field={@form[:notify_user_ids]}
          type="select"
          multiple
          class="w-full select h-auto min-h-20 bg-none py-1"
          size="3"
          label="Notify (approvers only)"
          options={Enum.map(@options.approvers, &{&1.name || &1.email, &1.id})}
          data-role="social-voice-notify"
        />

        <ul :if={@errors != []} class="space-y-1 text-sm text-error" data-role="social-voice-errors">
          <li :for={msg <- @errors}>{msg}</li>
        </ul>

        <button type="submit" class="btn btn-neutral btn-sm" data-role="social-voice-save">
          Save voice and timing
        </button>
      </.form>

      <div class="mt-5 space-y-2" data-role="social-voice-learnings">
        <h4 class="text-sm font-medium text-base-content">Learnings</h4>
        <p :if={@learnings == []} class="text-sm text-base-content">
          None yet. Accepted notes from the weekly review land here.
        </p>
        <ul :if={@learnings != []} class="space-y-1.5">
          <li
            :for={learning <- @learnings}
            class="flex items-start justify-between gap-2 rounded-lg border border-base-300 px-3 py-2 text-sm"
            data-role="social-voice-learning"
          >
            <span class="min-w-0 break-words">{learning.text}</span>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="voice_remove_learning"
              phx-value-id={learning.id}
              data-role="social-voice-learning-remove"
            >
              Remove
            </button>
          </li>
        </ul>
      </div>
    </section>

    <section
      class="mt-6 max-w-xl space-y-3"
      aria-labelledby="social-slots-label"
      data-role="social-slots"
    >
      <h3 id="social-slots-label" class="text-sm font-semibold text-base-content">
        Posting slots <span class="font-normal text-base-content">({@draft["timezone"]})</span>
      </h3>
      <p :if={@cards == []} class="text-sm text-base-content" data-role="social-slots-no-accounts">
        Connect an account to add posting slots.
      </p>
      <.slot_card :for={card <- @cards} card={card} />
    </section>
    """
  end

  attr :card, :map, required: true

  defp slot_card(assigns) do
    assigns = assign(assigns, :id, assigns.card.account.id)

    ~H"""
    <div
      id={"social-slots-#{@id}"}
      class="rounded-lg border border-base-300 bg-base-100 p-3 sm:p-4"
      data-role="social-slot-card"
      data-account-id={@id}
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <p class="text-sm font-semibold text-base-content">
          {platform_label(@card.account.platform)}
          <span :if={@card.account.handle} class="font-normal text-base-content">
            @{@card.account.handle}
          </span>
        </p>
        <p :if={@card.next_free} class="text-sm text-base-content" data-role="social-slot-next">
          Next free: {@card.next_free}
        </p>
      </div>

      <p
        :if={@card.slots == []}
        class="mt-2 text-sm text-base-content"
        data-role="social-slots-empty"
      >
        {empty_slots_text()}
      </p>
      <ul :if={@card.slots != []} class="mt-2 flex flex-wrap gap-1.5" data-role="social-slot-list">
        <li
          :for={{slot, i} <- Enum.with_index(@card.slots)}
          class="badge badge-outline gap-1 py-3 font-mono"
          data-role="social-slot"
          data-slot={"#{slot.weekday}-#{slot.time}"}
        >
          {slot_label(slot)}
          <button
            type="button"
            class="cursor-pointer text-base-content hover:text-base-content"
            phx-click="slot_remove"
            phx-value-account_id={@id}
            phx-value-index={i}
            aria-label={"Remove #{slot_label(slot)}"}
            data-role="social-slot-remove"
          >
            <.icon name="hero-x-mark" class="size-3.5" />
          </button>
        </li>
      </ul>

      <form
        id={"social-slot-form-#{@id}"}
        phx-change="slot_change"
        phx-submit="slot_save"
        class="mt-3 space-y-3"
        data-role="social-slot-form"
      >
        <input type="hidden" name="account_id" value={@id} />
        <div class="flex flex-wrap gap-1" role="group" aria-label="Days">
          <button
            :for={{day, name} <- PostingSlot.weekday_names()}
            type="button"
            class={["btn btn-xs", if(day in @card.days, do: "btn-primary", else: "btn-outline")]}
            aria-pressed={to_string(day in @card.days)}
            phx-click="slot_toggle_day"
            phx-value-account_id={@id}
            phx-value-day={day}
            data-role="social-slot-day"
            data-day={day}
          >
            {name}
          </button>
        </div>
        <div class="flex flex-wrap items-end gap-2">
          <label class="flex flex-col gap-1 text-sm">
            <span class="font-medium">Time</span>
            <input
              type="time"
              name="slot[time]"
              value={@card.time}
              class="input w-32"
              data-role="social-slot-time"
            />
          </label>
          <button
            type="button"
            class="btn btn-outline btn-sm"
            phx-click="slot_add"
            phx-value-account_id={@id}
            data-role="social-slot-add"
          >
            Add slot
          </button>
          <label class="flex flex-col gap-1 text-sm sm:ml-auto">
            <span class="font-medium">Posts per week</span>
            <input
              type="number"
              name="slot[weekly_goal]"
              value={@card.goal}
              min="1"
              max="100"
              placeholder="No goal"
              class="input w-28"
              data-role="social-slot-goal"
            />
          </label>
        </div>
        <ul
          :if={@card.errors != []}
          class="space-y-1 text-sm text-error"
          data-role="social-slot-errors"
        >
          <li :for={msg <- @card.errors}>{msg}</li>
        </ul>
        <button type="submit" class="btn btn-neutral btn-sm" data-role="social-slot-save">
          Save slots
        </button>
      </form>
    </div>
    """
  end

  attr :profile, :map, required: true
  attr :cards, :list, required: true

  @doc "What a non-approver sees: the same facts, no controls."
  def readonly(assigns) do
    assigns = assign(assigns, :voice, Voice.of(assigns.profile))

    ~H"""
    <dl class="mt-6 max-w-xl space-y-3 text-sm" data-role="social-voice-readonly">
      <div>
        <dt class="text-base-content">Timezone</dt>
        <dd>{@profile.timezone}</dd>
      </div>
      <div>
        <dt class="text-base-content">Sample posts</dt>
        <dd :if={@voice.samples == []}>None</dd>
        <dd :for={sample <- @voice.samples} class="mt-1 whitespace-pre-wrap">{sample}</dd>
      </div>
      <div>
        <dt class="text-base-content">Banned phrases</dt>
        <dd>{if @voice.banned == [], do: "None", else: Enum.join(@voice.banned, ", ")}</dd>
      </div>
      <div :if={@voice.learnings != []}>
        <dt class="text-base-content">Learnings</dt>
        <dd :for={learning <- @voice.learnings} class="mt-1">{learning.text}</dd>
      </div>
      <div :for={card <- @cards} data-role="social-slot-card" data-account-id={card.account.id}>
        <dt class="text-base-content">
          Slots for {platform_label(card.account.platform)}
          <span :if={card.account.handle}>@{card.account.handle}</span>
        </dt>
        <dd :if={card.slots == []} data-role="social-slots-empty">{empty_slots_text()}</dd>
        <dd :if={card.slots != []} class="font-mono">
          {Enum.map_join(card.slots, ", ", &slot_label/1)}
        </dd>
        <dd :if={card.goal != ""}>{card.goal} posts per week</dd>
      </div>
    </dl>
    """
  end

  defp slot_label(%{weekday: d, time: t}),
    do: PostingSlot.label(%PostingSlot{weekday: d, time: t})

  defp platform_label(platform), do: Platform.Social.PlatformLimits.label(platform) || platform
end
