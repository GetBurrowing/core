defmodule Platform.Social.Composer do
  @moduledoc """
  The composer's domain (task 01a14aca's engine, carried onto main and
  extended by Social authoring 6/11, task 01a16c50): one idea adapted per
  account in the brand's voice, the reasoning beside each version, and the
  send into the EXISTING approval path. The screen is
  `PlatformWeb.SocialComposer`.

  ## adapt_one/3: one independent model call per account

  Each picked account is its own column: its own experiment resolution
  (`Platform.Social.Composer.AdaptationSurface`, target = platform), its own
  prompt template row, its own `Platform.Agents.ToollessChat.call/4`, its own
  closed-shape parse (`Platform.Social.Composer.Output`). Every failure (no
  prompt, provider error, invalid JSON, a raise) is that column's
  `{:error, reason}`; it never fails another column. `adapt/3` runs several
  concurrently.

  ## The brand voice

  The prompt carries `profile.voice_notes` and the 4/11 voice
  (`Platform.Social.Voice`): samples, banned phrases and accepted learnings.
  A version that still contains a banned phrase is regenerated ONCE with a
  note naming the phrase; if the second version has one too, it is kept and
  returned with `banned_phrase` set, so the screen flags it. A phrase is
  never silently stripped.

  ## Model seam

  The model is the profile's drafting agent's (`profile.drafting_agent_id`,
  4/11), else `Platform.Roles.assignee_for/1` of the configured
  responsibility key. The agent is NOT dispatched: this is one tool-less
  completion with its credentials and model. The provider module,
  temperature and max_tokens are data in `config :social, :composer`
  (`config/1`). No agent: every column is `{:error, :no_drafting_agent}`.

  ## rationale/3: facts, not a second model call

  `why_format` is the model's own one-sentence reason; `why_time` is the
  account's next free posting slot (`Platform.Social.next_free_slot/2`) or
  says there is none; `voice_check` names a banned phrase, and a run of
  words the brand already used in one of its last 30 posts.

  ## send/4: through the approval gate, never around it

  Re-reads the profile and the user, then writes nothing unless every check
  passes: a live human who may read the profile's org, every draft on a
  live account of this profile with a non-blank body and a future or nil
  time, and an approval channel. Then it creates the idea (`source_kind`
  `"human"`, or joins the idea it was opened from) and one `needs_approval`
  post per draft through `Platform.Social.create_post/4`, which posts the
  approval card. With `approve: true` ("Send and approve") each post the
  user may approve right now (`Platform.Social.post_approver_check/4`) then
  goes through `Platform.Social.Approvals.decide_approve/2` AS that user, so
  the log records a human approval and `Publishing` stays the only
  publisher. An owned account's post waits for its owner; a draft-only
  account's waits for the human to post it by hand. Nothing here writes
  `approved` or `scheduled` itself.

  ## Metric data

  Each post's `composer_provenance` holds POST-SIDE facts only: platform,
  prompt slug, composition id, edited?, edit count before send, and the
  YouTube title. The arm a composition saw is on its
  `Platform.Experiments.Assignment` row.
  """

  import Ecto.Query

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Agents.ToollessChat
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Surfaces
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Security.ExternalContent
  alias Platform.Social
  alias Platform.Social.{Account, Approvals, Idea, Ideas, Post, PostEvents, Profile, Voice}
  alias Platform.Social.Composer.{AdaptationSurface, Output, Prompts}
  alias Platform.Types.UUIDv7

  @defaults [
    provider: Platform.Agents.Providers.Anthropic,
    responsibility_key: "social.composer",
    temperature: 0.7,
    max_tokens: 1500,
    model: nil
  ]

  @subject_type "social_composition"
  @log_tag "[Social.Composer]"
  @recent_posts 30
  @repeat_words 5

  @type column_result :: {:ok, map()} | {:error, term()}

  @doc "A `config :social, :composer` value, falling back to the built-in default."
  @spec config(atom()) :: term()
  def config(key) do
    :social
    |> Application.get_env(:composer, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc "The experiment subject type a composition is assigned under."
  @spec subject_type() :: String.t()
  def subject_type, do: @subject_type

  @doc "Platforms the composer writes for."
  @spec platforms() :: [String.t()]
  def platforms, do: Prompts.platforms()

  @doc "A fresh composition id (the experiment subject id)."
  @spec new_composition_id() :: String.t()
  def new_composition_id, do: UUIDv7.generate()

  @doc """
  Adapts one idea for each of `platforms`, concurrently. `input` as for
  `adapt_one/3`. Returns `%{composition_id, columns: [{platform, result}]}`
  in the order given. Never raises.
  """
  @spec adapt(Profile.t(), [String.t()], map()) :: %{
          composition_id: String.t(),
          columns: [{String.t(), column_result()}]
        }
  def adapt(%Profile{} = profile, platforms, input) when is_list(platforms) and is_map(input) do
    composition_id = composition_id(input)
    input = Map.put(input, :composition_id, composition_id)
    platforms = Enum.uniq(platforms)

    columns =
      platforms
      |> Task.async_stream(&adapt_one(profile, &1, input), timeout: :infinity, ordered: true)
      |> Enum.zip(platforms)
      |> Enum.map(fn
        {{:ok, result}, platform} -> {platform, result}
        {{:exit, reason}, platform} -> {platform, {:error, {:crashed, reason}}}
      end)

    %{composition_id: composition_id, columns: columns}
  end

  @doc """
  One column: the idea adapted for `platform`.

  `input`: `:idea` (required), `:source` and `:tone` (optional),
  `:composition_id` (optional; generated when absent, and it is the
  experiment subject id, so a re-adapt of the same composition keeps its
  arm).

  Returns `{:ok, %{text, title, posts, why_shape, prompt_slug, model,
  banned_phrase, regenerated?}}` (`posts` is the X thread, `title` the
  YouTube title, `banned_phrase` nil unless the version kept one after its
  one regeneration) or `{:error, reason}`. Never raises.
  """
  @spec adapt_one(Profile.t(), String.t(), map()) :: column_result()
  def adapt_one(%Profile{} = profile, platform, input) when is_map(input) do
    column(profile, platform, input, composition_id(input))
  rescue
    exception ->
      Logger.warning("#{@log_tag} column #{platform} raised: #{Exception.message(exception)}")
      {:error, :column_crashed}
  catch
    kind, reason ->
      Logger.warning("#{@log_tag} column #{platform} #{kind}: #{inspect(reason)}")
      {:error, :column_crashed}
  end

  defp composition_id(input) do
    case Map.get(input, :composition_id) do
      id when is_binary(id) -> if Platform.UUID.valid?(id), do: id, else: UUIDv7.generate()
      _ -> UUIDv7.generate()
    end
  end

  defp column(profile, platform, input, composition_id) do
    with :ok <- supported(platform),
         {:ok, idea} <- idea(input),
         {:ok, agent} <- agent_or_error(drafting_agent(profile)),
         arm = arm(profile, platform, composition_id),
         {:ok, prompt} <- render(arm["prompt_slug"], assigns(profile, input)),
         block = input_block(idea, input),
         {:ok, draft} <- draft(agent, arm, prompt, block, platform) do
      draft = check_banned(draft, profile, agent, arm, prompt, block, platform)
      {:ok, Map.merge(draft, %{prompt_slug: arm["prompt_slug"], model: arm["model"]})}
    end
  end

  defp draft(agent, arm, prompt, block, platform) do
    with {:ok, content} <- call_model(agent, arm, prompt, block, platform) do
      Output.parse_adaptation(platform, content)
    end
  end

  # A banned phrase: ONE regeneration naming it, then the version is kept
  # and flagged. Never stripped.
  defp check_banned(draft, profile, agent, arm, prompt, block, platform) do
    case banned_in(draft, profile) do
      nil ->
        Map.merge(draft, %{banned_phrase: nil, regenerated?: false})

      phrase ->
        note =
          "\n\nYour previous version used the phrase \"#{phrase}\", which this brand never " <>
            "uses. Write it again without that phrase or any form of it."

        case draft(agent, arm, prompt, block <> note, platform) do
          {:ok, second} ->
            Map.merge(second, %{banned_phrase: banned_in(second, profile), regenerated?: true})

          {:error, _} ->
            Map.merge(draft, %{banned_phrase: phrase, regenerated?: true})
        end
    end
  end

  defp banned_in(%{text: text, title: title}, profile),
    do: Voice.banned_phrase(Enum.join([title || "", text], "\n"), profile)

  defp supported(platform) do
    if platform in Prompts.platforms(), do: :ok, else: {:error, :unsupported_platform}
  end

  defp idea(input) do
    case Map.get(input, :idea) do
      idea when is_binary(idea) ->
        if String.trim(idea) == "", do: {:error, :idea_required}, else: {:ok, String.trim(idea)}

      _ ->
        {:error, :idea_required}
    end
  end

  defp agent_or_error(%Agent{} = agent), do: {:ok, agent}
  defp agent_or_error(_), do: {:error, :no_drafting_agent}

  # The arm for this column: an experiment's variant, a promoted default,
  # or the control (config). Resolution never raises (`Surfaces.resolve/4`).
  defp arm(profile, platform, composition_id) do
    subject = Subject.new(@subject_type, composition_id, %{org_id: profile.org_id})

    case Surfaces.resolve(AdaptationSurface.key(), platform, subject, org_id: profile.org_id) do
      {:variant, _experiment, _slug, payload} -> payload
      {:default, payload} -> payload
      :none -> control(platform)
    end
  end

  defp control(platform) do
    {:ok, payload} = AdaptationSurface.control_payload(platform)
    payload
  end

  defp render(slug, assigns) do
    case Prompts.render(slug, assigns) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, _} -> {:error, :prompt_not_found}
    end
  end

  @doc false
  # The prompt variables for `profile` (public for the tests).
  def assigns(%Profile{} = profile, input) do
    voice = Voice.of(profile)

    %{
      "profile_name" => profile.name,
      "voice_notes" => blank_default(profile.voice_notes, "none given"),
      "voice_samples" => listed(voice.samples, "none given"),
      "banned" => if(voice.banned == [], do: "none", else: Enum.join(voice.banned, "; ")),
      "learnings" => listed(Enum.map(voice.learnings || [], & &1.text), "none yet"),
      "hashtags" => Enum.join(profile.default_hashtags || [], " "),
      "tone" => blank_default(Map.get(input, :tone), "the brand's usual tone")
    }
  end

  defp listed([], default), do: default
  defp listed(items, _default), do: Enum.map_join(items, "\n", &("- " <> String.trim(&1)))

  defp blank_default(value, default) when is_binary(value) do
    if String.trim(value) == "", do: default, else: String.trim(value)
  end

  defp blank_default(_value, default), do: default

  defp input_block(idea, input) do
    source =
      case Map.get(input, :source) do
        text when is_binary(text) and text != "" ->
          ["", "Source:", ExternalContent.wrap(text, source: :unknown)]

        _ ->
          []
      end

    Enum.join(["Idea: " <> idea | source], "\n")
  end

  defp call_model(agent, arm, prompt, block, context) do
    agent = if is_binary(arm["model"]), do: %{agent | model: arm["model"]}, else: agent

    case ToollessChat.call(
           config(:provider),
           agent,
           [%{role: "user", content: prompt <> "\n\n" <> block}],
           temperature: config(:temperature),
           max_tokens: config(:max_tokens),
           log_tag: @log_tag,
           log_context: "column=#{context}"
         ) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, :provider_failed}
    end
  end

  @doc "The agent whose model drafts for `profile`, or nil."
  @spec drafting_agent(Profile.t()) :: Agent.t() | nil
  def drafting_agent(%Profile{drafting_agent_id: id}) when is_binary(id) do
    case Repo.get(Agent, id) do
      %Agent{} = agent -> agent
      nil -> fallback_agent()
    end
  end

  def drafting_agent(_profile), do: fallback_agent()

  defp fallback_agent do
    Roles.assignee_for(config(:responsibility_key))
  rescue
    _ -> nil
  end

  @doc "Plain words for a column's `{:error, reason}`."
  @spec error_text(term()) :: String.t()
  def error_text(:no_drafting_agent),
    do: "No drafting agent is set for this brand. Pick one in Settings, then try again."

  def error_text(:provider_failed), do: "The model didn't answer. Try this one again."
  def error_text(:invalid_output), do: "The model's reply wasn't a usable draft. Try again."
  def error_text(:prompt_not_found), do: "This platform's prompt is missing."
  def error_text(:unsupported_platform), do: "The composer doesn't write for this platform yet."
  def error_text(:idea_required), do: "Write the idea first."
  def error_text(_), do: "Something went wrong drafting this one. Try again."

  # ── Rationale ────────────────────────────────────────────────────────

  @doc """
  The reasoning panel for one version on `account`: `%{why_format,
  why_time, slot, voice_check, repeat, banned}`. `slot` is the account's
  next free posting slot after `now` (nil without slots); `repeat` a run of
  #{@repeat_words} words the brand already used in one of its last
  #{@recent_posts} posts; `banned` a banned phrase still in the text.

  `opts`: `:now`, and `:slot` / `:recent` to reuse an earlier read (the
  screen re-checks the voice on every edit without re-reading).
  """
  @spec rationale(Profile.t(), Account.t(), map(), keyword()) :: map()
  def rationale(%Profile{} = profile, %Account{} = account, draft, opts \\ []) do
    text = Map.get(draft, :text) || ""
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    slot = Keyword.get_lazy(opts, :slot, fn -> Social.next_free_slot(account, now) end)
    recent = Keyword.get_lazy(opts, :recent, fn -> recent_bodies(profile) end)
    repeat = repeated_phrase(text, recent)
    banned = Voice.banned_phrase(Enum.join([Map.get(draft, :title) || "", text], "\n"), profile)

    %{
      why_format: Map.get(draft, :why_shape),
      slot: slot,
      why_time: time_reason(slot, profile),
      repeat: repeat,
      banned: banned,
      voice_check: voice_text(banned, repeat)
    }
  end

  defp time_reason(nil, _profile),
    do: "No posting slots are set for this account, so it goes out when it's approved."

  defp time_reason(%DateTime{} = slot, profile) do
    tz = profile.timezone || "Etc/UTC"

    local =
      case DateTime.shift_zone(slot, tz) do
        {:ok, local} -> local
        _ -> slot
      end

    "Next open posting slot: " <> Calendar.strftime(local, "%a %-d %b, %H:%M") <> " (#{tz})."
  end

  defp voice_text(banned, _repeat) when is_binary(banned),
    do: "Uses \"#{banned}\", which this brand never says. Edit it out before sending."

  defp voice_text(nil, repeat) when is_binary(repeat),
    do: "\"#{repeat}\" already appears in one of the brand's last #{@recent_posts} posts."

  defp voice_text(nil, nil),
    do: "No banned phrases, and nothing repeats the brand's last #{@recent_posts} posts."

  @doc "The bodies of the profile's last #{@recent_posts} posts, newest first."
  @spec recent_bodies(Profile.t()) :: [String.t()]
  def recent_bodies(%Profile{id: profile_id}) do
    from(p in Post,
      join: a in Account,
      on: a.id == p.account_id,
      where: a.profile_id == ^profile_id and not is_nil(p.body),
      order_by: [desc: p.inserted_at],
      limit: @recent_posts,
      select: p.body
    )
    |> Repo.all()
  end

  @doc false
  # The first run of @repeat_words words in `text` that appears in one of
  # `bodies` (case and punctuation ignored), as written in `text`.
  def repeated_phrase(text, bodies) do
    words = words(text)
    seen = bodies |> Enum.flat_map(&(&1 |> words() |> grams())) |> MapSet.new()

    words
    |> Enum.chunk_every(@repeat_words, 1, :discard)
    |> Enum.find(&MapSet.member?(seen, Enum.map(&1, fn {norm, _} -> norm end)))
    |> case do
      nil -> nil
      gram -> Enum.map_join(gram, " ", fn {_, raw} -> raw end)
    end
  end

  defp words(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(fn raw ->
      {raw |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]/u, ""), raw}
    end)
    |> Enum.reject(fn {norm, _} -> norm == "" end)
  end

  defp grams(words) do
    words
    |> Enum.chunk_every(@repeat_words, 1, :discard)
    |> Enum.map(fn gram -> Enum.map(gram, fn {norm, _} -> norm end) end)
  end

  # ── Send ─────────────────────────────────────────────────────────────

  @doc "Whether `user` may compose on `profile` (a live human who can read its org)."
  @spec can_compose?(Profile.t(), term()) :: boolean()
  def can_compose?(%Profile{} = profile, %Platform.Accounts.User{archived_at: nil} = user),
    do: Social.approver_access?(user, profile)

  def can_compose?(_profile, _user), do: false

  @doc """
  The live accounts of `profile` that `user_id` may approve RIGHT NOW,
  through the one approve rule (`Platform.Social.post_approver_check/4`),
  minus draft-only accounts (a human posts those by hand). What "Send and
  approve" is offered for.
  """
  @spec approvable_account_ids(Profile.t(), [Account.t()], term()) :: [Ecto.UUID.t()]
  def approvable_account_ids(%Profile{} = profile, accounts, user_id) do
    for %Account{approval_mode: mode, archived_at: nil} = account <- accounts,
        mode != "draft_only",
        Social.post_approver_check(profile.org_id, profile, account, user_id) == :ok,
        do: account.id
  end

  @doc """
  Sends a composition into the approval path.

  `compose`: `%{idea: attrs | %Idea{}, drafts: [draft]}`. `attrs` are
  `Platform.Social.Ideas.create/4`'s (`title` required, `brief`,
  `source_url`, `clip_id`); an `%Idea{}` is the idea the composer was
  opened from (it must be this profile's). Each draft is `%{account_id,
  text}` plus optional `title` (YouTube), `scheduled_at`, `schedule_reason`,
  `prompt_slug`, `composition_id`, `original_text`, `edit_count`.

  `opts`: `approve: true` is "Send and approve".

  Returns `{:ok, %{idea, posts, approved, waiting_owner, by_hand,
  not_approved}}` (each a list of posts but `idea`; `waiting_owner` is
  `[{post, owner}]`). With nothing written: `{:error, reason}` for
  `:not_a_human`, `:approver_no_access`, `:not_found`, `:no_drafts`,
  `{:invalid_draft, account_id}`, `{:no_account, account_id}`,
  `:schedule_in_past`, `:profile_has_no_channel`, `:not_an_approver` (with
  `approve: true` and no account this user may approve), or an idea
  changeset. A write failing after earlier writes is
  `{:error, {:partial, reason, written_posts}}`.
  """
  @spec send(Profile.t(), term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send(%Profile{} = profile, user_id, %{drafts: drafts} = compose, opts \\ [])
      when is_list(drafts) do
    approve? = Keyword.get(opts, :approve, false)

    with {:ok, profile} <- reread(profile),
         {:ok, user} <- live_user(user_id),
         :ok <- may_compose(profile, user),
         {:ok, plan} <- plan_writes(profile, drafts),
         :ok <- require_channels(profile, plan),
         {:ok, approvable} <- approvable(profile, plan, user, approve?),
         {:ok, idea} <- idea_for(profile, user, Map.get(compose, :idea)) do
      with {:ok, posts} <- write(profile.org_id, idea, plan, user) do
        {:ok, Map.put(after_send(posts, plan, approvable, user, approve?), :idea, idea)}
      end
    end
  end

  @doc """
  "Save as idea": the idea alone, at stage Inbox, with no posts. Same user
  checks as `send/4`.
  """
  @spec save_idea(Profile.t(), term(), map()) :: {:ok, Idea.t()} | {:error, term()}
  def save_idea(%Profile{} = profile, user_id, attrs) when is_map(attrs) do
    with {:ok, profile} <- reread(profile),
         {:ok, user} <- live_user(user_id),
         :ok <- may_compose(profile, user) do
      idea_for(profile, user, attrs)
    end
  end

  defp reread(%Profile{org_id: org_id, id: id}) do
    case Social.get_profile(org_id, id) do
      %Profile{} = profile -> {:ok, profile}
      nil -> {:error, :not_found}
    end
  end

  defp live_user(user_id) do
    case user_id && Platform.Accounts.get_user(user_id) do
      %Platform.Accounts.User{archived_at: nil} = user -> {:ok, user}
      %Platform.Accounts.User{} -> {:error, :approver_archived}
      _ -> {:error, :not_a_human}
    end
  rescue
    _ -> {:error, :not_a_human}
  end

  defp may_compose(profile, user),
    do: if(can_compose?(profile, user), do: :ok, else: {:error, :approver_no_access})

  defp plan_writes(_profile, []), do: {:error, :no_drafts}

  defp plan_writes(profile, drafts) do
    accounts = Map.new(Social.list_accounts(profile.org_id, profile_id: profile.id), &{&1.id, &1})
    now = DateTime.utc_now()

    Enum.reduce_while(drafts, {:ok, []}, fn draft, {:ok, acc} ->
      id = Map.get(draft, :account_id)

      case Map.get(accounts, id) do
        %Account{archived_at: nil} = account ->
          case valid_draft(draft, account, now) do
            :ok -> {:cont, {:ok, acc ++ [{account, draft}]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _ ->
          {:halt, {:error, {:no_account, id}}}
      end
    end)
  end

  defp valid_draft(draft, account, now) do
    text = Map.get(draft, :text)

    cond do
      not (is_binary(text) and String.trim(text) != "") ->
        {:error, {:invalid_draft, account.id}}

      match?(%DateTime{}, draft[:scheduled_at]) and
          DateTime.compare(draft.scheduled_at, now) != :gt ->
        {:error, :schedule_in_past}

      true ->
        :ok
    end
  end

  defp require_channels(profile, plan) do
    Enum.reduce_while(plan, :ok, fn {account, _draft}, :ok ->
      case Social.require_channel("needs_approval", profile, account) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp approvable(_profile, _plan, _user, false), do: {:ok, []}

  defp approvable(profile, plan, user, true) do
    case approvable_account_ids(profile, Enum.map(plan, &elem(&1, 0)), user.id) do
      [] -> {:error, :not_an_approver}
      ids -> {:ok, ids}
    end
  end

  defp idea_for(%Profile{id: profile_id}, _user, %Idea{profile_id: profile_id} = idea),
    do: {:ok, idea}

  defp idea_for(_profile, _user, %Idea{}), do: {:error, :idea_profile_mismatch}

  defp idea_for(profile, user, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("source_kind", "human")
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    Ideas.create(profile.org_id, profile.id, attrs, {:user, user.id})
  end

  defp idea_for(_profile, _user, _), do: {:error, :idea_required}

  defp write(org_id, idea, plan, user) do
    plan
    |> Enum.reduce_while({:ok, []}, fn {%Account{} = account, draft}, {:ok, written} ->
      attrs = %{
        body: String.trim(draft.text),
        status: "needs_approval",
        scheduled_at: Map.get(draft, :scheduled_at),
        schedule_reason: schedule_reason(draft),
        composer_provenance: provenance(Map.put(draft, :platform, account.platform))
      }

      case Social.create_post(org_id, account, attrs, idea_id: idea.id) do
        {:ok, post} ->
          PostEvents.record!(post, "created", {:human, user.id})
          PostEvents.record!(post, "submitted", {:human, user.id})
          {:cont, {:ok, [post | written]}}

        {:error, reason} ->
          {:halt, {:error, reason, written}}
      end
    end)
    |> case do
      {:ok, posts} -> {:ok, Enum.reverse(posts)}
      {:error, reason, []} -> {:error, reason}
      {:error, reason, written} -> {:error, {:partial, reason, Enum.reverse(written)}}
    end
  end

  defp schedule_reason(draft) do
    case Map.get(draft, :schedule_reason) do
      reason when is_binary(reason) and reason != "" ->
        String.slice(reason, 0, Post.max_schedule_reason())

      _ ->
        nil
    end
  end

  # Send and approve: each post this user may approve goes through the ONE
  # decision path as that user. Everything else stays needs_approval.
  defp after_send(posts, plan, approvable, user, approve?) do
    accounts = Map.new(plan, fn {account, _} -> {account.id, account} end)
    empty = %{posts: posts, approved: [], waiting_owner: [], by_hand: [], not_approved: []}

    if approve? do
      Enum.reduce(posts, empty, fn post, acc ->
        account = Map.fetch!(accounts, post.account_id)

        cond do
          account.approval_mode == "draft_only" ->
            Map.update!(acc, :by_hand, &(&1 ++ [post]))

          post.account_id in approvable ->
            case approve_as(post, user) do
              {:ok, approved} -> Map.update!(acc, :approved, &(&1 ++ [approved]))
              {:error, _} -> Map.update!(acc, :not_approved, &(&1 ++ [post]))
            end

          is_binary(account.owner_user_id) ->
            owner = Platform.Accounts.get_user(account.owner_user_id)
            Map.update!(acc, :waiting_owner, &(&1 ++ [{post, owner}]))

          true ->
            Map.update!(acc, :not_approved, &(&1 ++ [post]))
        end
      end)
    else
      empty
    end
  end

  defp approve_as(post, user) do
    case Approvals.live_card(post.id) do
      %{canvas_id: canvas_id} ->
        case Approvals.decide_approve(canvas_id, user) do
          {:ok, %{post: approved}} -> {:ok, approved}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :no_card}
    end
  end

  @doc """
  The post-side facts stored on each composed post. No experiment or
  variant key: the arm lives on the `Experiments.Assignment` row.
  """
  @spec provenance(map()) :: map()
  def provenance(draft) do
    count = edit_count(draft)

    %{
      "source" => "composer",
      "platform" => Map.get(draft, :platform),
      "prompt_slug" => Map.get(draft, :prompt_slug),
      "composition_id" => Map.get(draft, :composition_id),
      "edited" => count > 0,
      "edit_count" => count
    }
    |> then(fn p ->
      case Map.get(draft, :title) do
        title when is_binary(title) and title != "" -> Map.put(p, "title", String.trim(title))
        _ -> p
      end
    end)
  end

  defp edit_count(draft) do
    given =
      case Map.get(draft, :edit_count) do
        n when is_integer(n) and n > 0 -> n
        _ -> 0
      end

    changed? =
      case Map.get(draft, :original_text) do
        original when is_binary(original) -> String.trim(original) != String.trim(draft.text)
        _ -> false
      end

    if given == 0 and changed?, do: 1, else: given
  end
end
