defmodule PlatformWeb.SocialClipHeadline do
  @moduledoc "Headline drafts use the current immutable source render and the canonical job path."
  use PlatformWeb, :live_component
  alias Platform.Social
  alias Platform.Social.{ClipHeadlines, ClipJobs, ClipLook}

  def mount(socket),
    do: {:ok, assign(socket, base_id: nil, draft: draft(nil), error: nil, notice: nil)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    base = assigns.base

    socket =
      if socket.assigns.base_id != (base && base.id) do
        assign(socket, base_id: base && base.id, draft: draft(base), error: nil, notice: nil)
      else
        socket
      end

    jobs =
      case ClipJobs.list_jobs(assigns.profile.org_id, assigns.profile.id) do
        {:ok, jobs} -> Enum.filter(jobs, &(&1.clip_id == assigns.clip.id))
        _ -> []
      end

    attempt =
      Enum.find(
        Enum.reverse(jobs),
        &(&1.payload["headline"] || &1.payload["headline_template"] ||
            get_in(&1.payload, ["look", "title", "enabled"]) == false)
      )

    attempt =
      if attempt, do: %{id: attempt.id, status: attempt.status, code: safe_code(attempt.error)}

    {:ok,
     assign(socket,
       pending?: Enum.any?(jobs, &(&1.status in ~w(queued claimed running))),
       attempt: attempt
     )}
  end

  defp draft(nil), do: %{"headline" => "", "template" => "", "seconds" => "3.0", "emphasis" => ""}

  defp draft(base) do
    title = (base.look || %{})["title"] || %{}

    %{
      "headline" => base.headline || "",
      "template" => if(title["enabled"] == false, do: "disabled", else: title["template"] || ""),
      "seconds" => to_string(title["secs"] || 3.0),
      "emphasis" => Enum.map_join(title["emphasis"] || [], ", ", &to_string(&1 + 1))
    }
  end

  def handle_event("change", params, socket) do
    draft =
      Map.merge(socket.assigns.draft, Map.take(params, ~w(headline template seconds emphasis)))

    changed = draft["headline"] != socket.assigns.draft["headline"]
    cleared = changed and socket.assigns.draft["emphasis"] != ""
    draft = if changed, do: Map.put(draft, "emphasis", ""), else: draft

    {:noreply,
     assign(socket,
       draft: draft,
       error: nil,
       notice:
         if(cleared,
           do: "Emphasis cleared because the headline changed. Select its words again.",
           else: nil
         )
     )}
  end

  def handle_event("submit", params, socket) do
    with :ok <- authorize(socket),
         :ok <- original_source(socket.assigns.base),
         {:ok, title} <- title(params) do
      %{profile: p, clip: clip, user_id: user} = socket.assigns
      attrs = %{"base_render_id" => params["base_render_id"], "look" => %{"title" => title}}

      result =
        if params["template"] == "disabled" or
             (String.trim(params["headline"] || "") == "" and
                not is_nil(get_in(socket.assigns.base.provenance || %{}, ["headline", "content"]))) do
          ClipJobs.enqueue_appearance(p.org_id, clip.id, user, attrs)
        else
          ClipJobs.enqueue_fix(
            p.org_id,
            clip.id,
            user,
            Map.merge(attrs, %{"operation" => "edit_headline", "headline" => params["headline"]})
          )
        end

      case result do
        {:ok, _} ->
          send_update(PlatformWeb.SocialClipsReview,
            id: socket.assigns.review_id,
            job_event: true
          )

          {:noreply, assign(socket, pending?: true, error: nil, notice: nil)}

        {:error, reason} ->
          {:noreply, assign(socket, error: message(reason))}
      end
    else
      {:error, reason} -> {:noreply, assign(socket, error: message(reason))}
    end
  end

  def handle_event("default", %{"action" => "use"}, socket) do
    with :ok <- authorize(socket) do
      p = Social.get_profile(socket.assigns.profile.org_id, socket.assigns.profile.id)
      title = ClipLook.effective(p.show_look)["title"]

      draft =
        Map.merge(socket.assigns.draft, %{
          "template" =>
            if(title["enabled"] == false, do: "disabled", else: title["template"] || ""),
          "seconds" => to_string(title["secs"]),
          "emphasis" => ""
        })

      {:noreply,
       assign(socket,
         draft: draft,
         error: nil,
         notice: "Show default selected. Render a new version to apply it."
       )}
    else
      {:error, reason} -> {:noreply, assign(socket, error: message(reason))}
    end
  end

  def handle_event("default", %{"action" => action}, socket) when action in ~w(save reset) do
    with :ok <- authorize(socket),
         true <- action == "reset" or socket.assigns.draft["template"] != "disabled",
         {:ok, title} <-
           if(action == "reset",
             do: {:ok, %{}},
             else: title(Map.merge(socket.assigns.draft, %{"emphasis" => ""}))
           ) do
      p = Social.get_profile(socket.assigns.profile.org_id, socket.assigns.profile.id)
      look = p.show_look || %{}
      current = Map.drop(look["title"] || %{}, ~w(template enabled secs emphasis emphasis_text))

      title =
        if action == "reset",
          do: current,
          else: Map.merge(current, Map.drop(title, ~w(emphasis emphasis_text)))

      case ClipJobs.save_show_default(
             p.org_id,
             p.id,
             socket.assigns.user_id,
             Map.put(look, "title", title)
           ) do
        {:ok, _} ->
          {:noreply,
           assign(socket,
             error: nil,
             notice:
               "Headline default #{if action == "reset", do: "reset", else: "saved"}. Existing videos are unchanged."
           )}

        {:error, reason} ->
          {:noreply, assign(socket, error: message(reason))}
      end
    else
      false ->
        {:noreply,
         assign(socket,
           error:
             "No opening headline applies to this clip only. Choose a title treatment before saving a show default."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: message(reason))}
    end
  end

  defp authorize(socket) do
    a = socket.assigns
    p = Social.get_profile(a.profile.org_id, a.profile.id)

    cond do
      is_nil(p) or Social.approver_check(p.org_id, p, a.user_id) != :ok -> {:error, :unauthorized}
      a.pending? -> {:error, :job_in_flight}
      not a.current? or is_nil(a.base) -> {:error, :stale_version}
      true -> :ok
    end
  end

  defp title(params) do
    template = params["template"] || ""
    raw = params["emphasis"] || ""

    with true <- template in ["", "disabled" | ClipLook.headline_templates()],
         {seconds, ""} <- Float.parse(to_string(params["seconds"] || "3.0")),
         true <- seconds > 0.5 and seconds <= 6,
         {:ok, indices} <- positions(raw),
         true <- ClipHeadlines.valid_emphasis?(indices, params["headline"]) do
      title = %{
        "secs" => seconds,
        "enabled" => template != "disabled",
        "emphasis" => indices,
        "emphasis_text" => params["headline"] || ""
      }

      title =
        if template in ["", "disabled"], do: title, else: Map.put(title, "template", template)

      # An empty selection preserves legacy appearance; explicitly select legacy to undo a branded base.
      title = if template == "disabled", do: Map.put(title, "template", "legacy"), else: title
      {:ok, title}
    else
      _ -> {:error, :headline_input_invalid}
    end
  end

  defp positions(raw) do
    values = raw |> String.split(~r/[ ,]+/, trim: true) |> Enum.map(&Integer.parse/1)

    if Enum.all?(values, &match?({n, ""} when n > 0, &1)) do
      indices = Enum.map(values, fn {n, ""} -> n - 1 end)

      if length(Enum.uniq(indices)) == length(indices),
        do: {:ok, indices},
        else: {:error, :headline_input_invalid}
    else
      {:error, :headline_input_invalid}
    end
  end

  defp original_source(base) do
    source = base.source || %{}

    if is_binary(source["source_url"]) or is_binary(source["source_file_id"]),
      do: :ok,
      else: {:error, :source_unavailable}
  end

  defp message(:headline_input_invalid),
    do: "Choose a supported template, 0.6–6 seconds, and unique word numbers from this headline."

  defp message(:headline_emphasis_stale),
    do: "Emphasis no longer matches this headline. Select its words again."

  defp message(:stale_version),
    do: "A newer version is ready. Reload it before changing the headline."

  defp message(:job_in_flight), do: "A render is already running. Wait for it to finish."
  defp message(:invalid_headline), do: "Enter a headline of 1–200 characters on one line."

  defp message(:source_unavailable),
    do:
      "The original source mapping is unavailable. The delivered video cannot be used as a source."

  defp message(_), do: "This version cannot be changed. Reload and try again."

  defp safe_code(error) when is_binary(error) do
    code = error |> String.split(":", parts: 2) |> hd()

    if code in ~w(HEADLINE_UNBACKED HEADLINE_TEMPLATE_CLI_UNSUPPORTED HEADLINE_TEMPLATE_CONTRACT_INVALID HEADLINE_TEMPLATE_NOT_APPLIED HEADLINE_ASSETS_MISSING HEADLINE_ASSET_MISMATCH HEADLINE_EMPHASIS_STALE HEADLINE_TIMING_EXCEEDS_CLIP HEADLINE_FIT HEADLINE_LAYOUT_UNSAFE HEADLINE_TEXT_TOO_LONG HEADLINE_FACE_OVERLAP HEADLINE_SOURCE_MISSING HEADLINE_BASE_STALE HEADLINE_LAYOUT_SHORTEN_TEXT HEADLINE_FACE_REGION_UNSAFE HEADLINE_FACE_GEOMETRY_MISSING HEADLINE_FACE_GEOMETRY_INVALID HEADLINE_DECORATION_OUT_OF_BOUNDS APPEARANCE_PROJECT_MISSING PROJECT_NOT_FOUND SOURCE_MISSING SOURCE_UNAVAILABLE CLIP_FINALIZE),
      do: code,
      else: "RENDER_FAILED"
  end

  defp safe_code(_), do: "RENDER_FAILED"

  def failure_message(code)
      when code in ~w(HEADLINE_TEMPLATE_UNSUPPORTED HEADLINE_TEMPLATE_CAPABILITY_MISSING HEADLINE_TEMPLATE_INVALID HEADLINE_ASSET_MISSING HEADLINE_ASSET_MISMATCH HEADLINE_TEMPLATE_CLI_UNSUPPORTED HEADLINE_TEMPLATE_CONTRACT_INVALID HEADLINE_ASSETS_MISSING HEADLINE_TEMPLATE_NOT_APPLIED),
      do:
        "The runner does not support this template or its exact assets. Install the qualified renderer and retry."

  def failure_message(code)
      when code in ~w(HEADLINE_FIT HEADLINE_FIT_INVALID HEADLINE_FACE_OVERLAP HEADLINE_LAYOUT_UNSAFE HEADLINE_TEXT_TOO_LONG HEADLINE_LAYOUT_SHORTEN_TEXT HEADLINE_FACE_REGION_UNSAFE HEADLINE_FACE_GEOMETRY_MISSING HEADLINE_FACE_GEOMETRY_INVALID HEADLINE_DECORATION_OUT_OF_BOUNDS),
      do: "The headline cannot fit safely around the face. Shorten it and render again."

  def failure_message(code) when code in ~w(HEADLINE_EMPHASIS_STALE HEADLINE_EMPHASIS_INVALID),
    do: "Emphasis no longer matches the headline. Select its words again."

  def failure_message(code)
      when code in ~w(SOURCE_UNAVAILABLE SOURCE_PROJECT_MISSING HEADLINE_SOURCE_MISSING APPEARANCE_PROJECT_MISSING PROJECT_NOT_FOUND SOURCE_MISSING),
      do:
        "The runner needs the original project and source mapping. It cannot reprocess the delivered video."

  def failure_message("HEADLINE_TIMING_EXCEEDS_CLIP"),
    do: "The opening is longer than this clip. Shorten the opening duration and try again."

  def failure_message("HEADLINE_BASE_STALE"),
    do: "The original render has changed. Reload the current version and try again."

  def failure_message(_), do: "Check the clip runner, then enter a headline and try again."

  def render(assigns) do
    assigns =
      assign(assigns,
        disabled?:
          !assigns.can_edit? or assigns.pending? or !assigns.current? or is_nil(assigns.base)
      )

    ~H"""
    <section id={@id} aria-label="Clip headline" data-role="clip-headline-section" class="space-y-2">
      <form
        phx-submit="submit"
        phx-change="change"
        phx-target={@myself}
        data-role="clip-headline-form"
      >
        <input type="hidden" name="base_render_id" value={@base && @base.id} />
        <label for="clip-headline" class="text-xs font-semibold text-base-content">Headline</label>
        <.input
          id="clip-headline"
          name="headline"
          type="text"
          value={@draft["headline"]}
          maxlength="200"
          disabled={@disabled?}
          aria-describedby="clip-headline-help"
          class="input input-bordered mt-1 w-full bg-base-100 text-sm"
          data-role="clip-headline-input"
        />
        <p id="clip-headline-help" class="mt-1 text-xs text-subtle">
          Headlines are generated automatically. Enter new text to render another version. Local generated text stays on the clip runner. Captions are separate.
        </p>
        <.input
          id="headline-template"
          name="template"
          label="Opening treatment"
          type="select"
          value={@draft["template"]}
          options={[
            {"Existing title", ""},
            {"Chrome Hook", "chrome-hook"},
            {"Neon Broadcast", "neon-broadcast"},
            {"Arcade Punch", "arcade-punch"},
            {"Original title style", "legacy"},
            {"No opening headline", "disabled"}
          ]}
          disabled={@disabled?}
          data-role="headline-template"
        />
        <.input
          id="headline-seconds"
          name="seconds"
          type="number"
          label="Opening duration (seconds)"
          value={@draft["seconds"]}
          min="0.6"
          max="6"
          step="0.1"
          disabled={@disabled?}
          data-role="headline-seconds"
        />
        <.input
          id="headline-emphasis"
          name="emphasis"
          type="text"
          label="Emphasis word numbers"
          value={@draft["emphasis"]}
          placeholder="For example: 2, 4"
          disabled={@disabled? or @draft["template"] in ["", "legacy", "disabled"]}
          aria-describedby="headline-words"
          data-role="headline-emphasis"
        />
        <p id="headline-words" class="break-words text-xs text-subtle" data-role="headline-words">
          {if @draft["headline"] == "",
            do: "Enter the headline to choose emphasis. Generated wording stays private."}<span
            :for={{word, i} <- Enum.with_index(String.split(@draft["headline"]))}
            class="mr-2"
          >{i + 1}: {word}</span>
        </p>
        <p class="mt-1 text-xs text-subtle">
          Brief entrance and exit; the title clears while captions continue. Fit is checked by the renderer.
        </p>
        <button
          type="submit"
          class="btn btn-primary btn-sm mt-2 min-h-11"
          disabled={@disabled?}
          phx-disable-with="Rendering…"
          data-role="clip-headline-render"
        >
          {if @pending?, do: "Rendering…", else: "Render headline"}
        </button>
      </form>
      <div class="flex flex-wrap gap-2" aria-label="Headline show default">
        <button
          :for={
            {label, action} <- [
              {"Use show default", "use"},
              {"Save as show default", "save"},
              {"Reset show default", "reset"}
            ]
          }
          type="button"
          phx-click="default"
          phx-value-action={action}
          phx-target={@myself}
          disabled={@disabled?}
          class="btn btn-ghost btn-xs min-h-11"
          data-role={"headline-default-#{action}"}
        >
          {label}
        </button>
      </div>
      <p :if={@notice} role="status" class="text-xs text-info" data-role="headline-notice">
        {@notice}
      </p>
      <p :if={@pending?} role="status" class="text-xs text-subtle" data-role="clip-headline-pending">
        Rendering a new version. You can keep playing this one.
      </p>
      <p :if={@error} role="alert" class="text-xs text-error" data-role="clip-headline-error">
        {@error}
      </p>
      <p
        :if={@attempt && @attempt.status == "failed"}
        role="alert"
        class="text-xs text-error"
        data-role="clip-headline-failure"
      >
        Headline render failed ({@attempt.code}). Your previous video is unchanged. {failure_message(
          @attempt.code
        )}
      </p>
      <details data-role="headline-render-details" class="text-xs text-subtle">
        <summary class="cursor-pointer">Headline render details</summary>
        <%= if @base && get_in(@base.provenance || %{}, ["headline", "template"]) do %>
          <p>
            Template: {get_in(@base.provenance, ["headline", "template"])} · revision {get_in(
              @base.provenance,
              ["headline", "revision"]
            )}
          </p>
          <p :for={key <- ~w(entrance_s hold_s exit_s total_s)}>
            {key}: {get_in(@base.provenance, ["headline", "timing", key])} s
          </p>
        <% else %>
          <p>
            {if @base && get_in(@base.look || %{}, ["title", "enabled"]) == false,
              do: "Opening headline disabled",
              else: "Existing render — template and timing not recorded"}
          </p>
        <% end %>
      </details>
    </section>
    """
  end
end
