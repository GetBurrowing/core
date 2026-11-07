defmodule PlatformWeb.UxDevFixture do
  @moduledoc """
  A walkable UX role on an empty dev database (task 01a1af00 stage 4).
  Compiled in dev and test only; it is not in `lib/` and never ships in a
  release. Driven over HTTP by `PlatformWeb.DevUxFixtureController`
  (`POST /dev/ux_fixture/seed`, `POST /dev/ux_fixture/fire`,
  `GET /dev/ux_fixture/status`) so it runs INSIDE the dev server, where its
  PubSub broadcasts reach the open pages. A separate `mix run` would write
  the rows but no open Inbox would hear about them.

  `seed/1` builds, for one human (the dev-login user, the recipient):

    * a fixture agent holding the `designer` role (the holder is replaced:
      dev data only), so the agent is the `ux.friction_watch` assignee;
    * two internal channels the agent is in, with six "can't find my DMs"
      messages from three neutral-named teammates across both, and three
      "timestamps are too small" messages (the fyi);
    * a channel the agent is NOT in and a MIXED space (one external member)
      it IS in, each with strong DM friction: neither may reach a finding;
    * a digest space the agent and the recipient are in, set as the agent's
      `metadata["ux_digest_space_id"]`.

  `fire/2` runs the real Router path (`Router.fire("ux.friction_watch", meta)`)
  with the model swapped for `PlatformWeb.UxDevFixtureProvider` for the
  duration of the call, then gives the new decision a before | after mockup
  (two small generated PNG attachments in a channel the recipient can read)
  and links it to a fresh task with an execution log, so an answer can be
  seen landing in the task.
  The watch itself never draws mockups; the fixture adds them so the Inbox
  item can be walked in full. `kind: "cron"` is the weekly cron path (watch
  plus digest); anything else is an on-demand fire (watch only).
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.Message
  alias Platform.Inbox.Item
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.UxFrictionWatch
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Seeds
  alias Platform.Ux.Digest
  alias Platform.Ux.Finding
  alias PlatformWeb.UxDevFixtureProvider

  @agent_slug "ux-designer-fixture"
  @prefix "ux-fixture-"

  @dm_friction [
    {0, 0, "I can't find my direct messages anywhere"},
    {1, 0, "how do I get to direct messages from here?"},
    {2, 0, "where are my DMs? they were in the sidebar yesterday"},
    {0, 1, "still can't find my DMs on my phone"},
    {1, 1, "how do I get back to my direct messages after opening a channel?"},
    {2, 1, "where is the DM list? I keep losing it"}
  ]

  @fyi_friction [
    {0, 0, "the timestamps are too small to read on my laptop"},
    {1, 1, "timestamps are hard to read in the thread view"},
    {2, 0, "message timestamps are too small for me"}
  ]

  @doc "Seed the rig for `user_id`. Returns the ids it made."
  @spec seed(String.t()) :: {:ok, map()} | {:error, term()}
  def seed(user_id) when is_binary(user_id) do
    %User{} = recipient = Repo.get!(User, user_id)
    run = Integer.to_string(System.unique_integer([:positive]))

    reset!(recipient.id)
    :ok = Seeds.seed_defaults(only_keys: ["designer"])
    [spec] = UxFrictionWatch.register()
    {:ok, _} = Responsibilities.upsert_by_key(spec)

    agent = agent!()
    :ok = Roles.unassign_role("designer")
    {:ok, _} = Roles.assign_role("designer", agent.id)

    teammates = for n <- ~w(one two three), do: user!("Teammate #{String.capitalize(n)}", run)

    general = space!("ux-fixture-general", run, agent, [recipient | teammates])
    help = space!("ux-fixture-help", run, agent, [recipient | teammates])
    channels = [general, help]

    dm_messages = post_all!(@dm_friction, channels, teammates)
    fyi_messages = post_all!(@fyi_friction, channels, teammates)
    post!(general, Enum.at(teammates, 0), "lunch at noon works for me")

    # Not readable by the watch: a channel without the agent, and a mixed
    # space (one external member) with it.
    elsewhere = space!("ux-fixture-elsewhere", run, nil, [recipient | teammates])

    outside_messages =
      for t <- teammates,
          do: post!(elsewhere, t, "I really can't find my direct messages, where are they?")

    guest = user!("Partner Guest", run)
    {:ok, _} = Platform.Tenancy.mark_membership_external(%{user_id: guest.id, org_id: org_id!()})
    mixed = space!("ux-fixture-partner", run, agent, [Enum.at(teammates, 0), guest])

    mixed_messages =
      for _ <- 1..3,
          do:
            post!(mixed, Enum.at(teammates, 0), "how do I find direct messages? can't find them")

    digest = space!("ux-fixture-digest", run, agent, [recipient])

    agent =
      agent
      |> Ecto.Changeset.change(
        metadata: Map.put(agent.metadata || %{}, Digest.digest_space_key(), digest.id)
      )
      |> Repo.update!()

    UxDevFixtureProvider.reset()

    {:ok,
     %{
       recipient_user_id: recipient.id,
       agent_id: agent.id,
       readable_space_ids: Enum.map(channels, & &1.id),
       unreadable_space_ids: [elsewhere.id, mixed.id],
       digest_space_id: digest.id,
       digest_space_slug: digest.slug,
       dm_message_ids: Enum.map(dm_messages, & &1.id),
       fyi_message_ids: Enum.map(fyi_messages, & &1.id),
       unreadable_message_ids: Enum.map(outside_messages ++ mixed_messages, & &1.id)
     }}
  end

  @doc """
  Fire `ux.friction_watch` for `user_id` as recipient. `kind` "cron" is the
  weekly cron path; anything else is on demand. Returns the Router outcome.
  """
  @spec fire(String.t(), String.t() | nil) :: {:ok, map()}
  def fire(user_id, kind) when is_binary(user_id) do
    meta =
      %{recipient_user_id: user_id, org_id: org_id!()}
      |> then(&if(kind == "cron", do: Map.put(&1, :kind, :cron), else: &1))

    previous = Application.get_env(:platform, :ux_friction_watch_provider)
    Application.put_env(:platform, :ux_friction_watch_provider, UxDevFixtureProvider)

    outcome =
      try do
        Router.fire("ux.friction_watch", meta)
      after
        if previous,
          do: Application.put_env(:platform, :ux_friction_watch_provider, previous),
          else: Application.delete_env(:platform, :ux_friction_watch_provider)
      end

    attach_mockups!(user_id)
    {:ok, %{outcome: inspect(outcome)}}
  end

  @doc "What the rig holds now for `user_id`, as plain JSON-able maps."
  @spec status(String.t()) :: map()
  def status(user_id) do
    findings =
      Repo.all(
        from(f in Finding, where: f.recipient_user_id == ^user_id, order_by: f.inserted_at)
      )

    items =
      Repo.all(
        from(i in Item,
          where: i.user_id == ^user_id and i.kind == "ux_decision",
          order_by: i.inserted_at
        )
      )

    digest_messages =
      Repo.all(
        from(m in Message,
          where: fragment("?->>'source' = 'ux_digest'", m.metadata),
          order_by: m.inserted_at
        )
      )

    %{
      gathered_signals: UxDevFixtureProvider.last_seen(),
      findings:
        Enum.map(
          findings,
          &Map.take(&1, [
            :id,
            :kind,
            :status,
            :question,
            :evidence,
            :options,
            :mockup_refs,
            :group_key,
            :variant,
            :answer,
            :recipient_user_id
          ])
        ),
      inbox_items:
        Enum.map(
          items,
          &Map.take(&1, [:id, :user_id, :kind, :source_id, :title, :body, :url, :dismissed_at])
        ),
      digest_messages:
        Enum.map(digest_messages, &Map.take(&1, [:id, :space_id, :content, :metadata]))
    }
  end

  # ── internals ──────────────────────────────────────────────────────────

  # Dev data only: forget this recipient's earlier fixture findings and rows
  # so a re-seed starts from the empty state.
  defp reset!(user_id) do
    ids = Repo.all(from(f in Finding, where: f.recipient_user_id == ^user_id, select: f.id))
    Repo.delete_all(from(i in Item, where: i.source_type == "ux_finding" and i.source_id in ^ids))
    Repo.delete_all(from(f in Finding, where: f.id in ^ids))

    from(s in Platform.Chat.Space,
      where: like(s.slug, ^"#{@prefix}%") and is_nil(s.archived_at)
    )
    |> Repo.update_all(set: [archived_at: DateTime.utc_now()])
  end

  defp agent! do
    case Repo.get_by(Agent, slug: @agent_slug) do
      %Agent{} = agent ->
        agent

      nil ->
        %Agent{}
        |> Agent.changeset(%{
          slug: @agent_slug,
          name: "UX Designer",
          status: "active",
          kind: "native",
          workspace_id: nil
        })
        |> Repo.insert!()
    end
  end

  defp user!(name, run) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    %User{}
    |> User.changeset(%{
      email: "#{slug}-#{run}@example.com",
      name: name,
      oidc_sub: "ux-fixture-#{slug}-#{run}"
    })
    |> Repo.insert!()
  end

  defp space!(slug, run, agent, users) do
    name = String.replace_prefix(slug, @prefix, "")

    {:ok, space} =
      Chat.create_space(%{name: name, slug: "#{slug}-#{run}", kind: "channel"})

    if agent, do: join!(space, "agent", agent.id)
    for u <- users, do: join!(space, "user", u.id)
    space
  end

  defp join!(space, type, id) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: type,
        participant_id: id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp post_all!(lines, channels, teammates) do
    for {who, where, text} <- lines,
        do: post!(Enum.at(channels, where), Enum.at(teammates, who), text)
  end

  defp post!(space, %User{} = user, text) do
    participant =
      Repo.one!(
        from(p in Chat.Participant,
          where:
            p.space_id == ^space.id and p.participant_type == "user" and
              p.participant_id == ^user.id
        )
      )

    %Message{}
    |> Message.changeset(%{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: text,
      author_display_name: user.name,
      author_participant_type: "user",
      author_user_id: user.id
    })
    |> Repo.insert!()
  end

  defp org_id! do
    case Platform.Tenancy.get_root_org() do
      %{id: id} -> id
      _ -> raise "no root org"
    end
  end

  # The open decision gets a before | after pair, anchored in a readable
  # channel the recipient is in, so the Inbox's image viewer can open it.
  defp attach_mockups!(user_id) do
    with %Finding{} = finding <-
           Repo.one(
             from(f in Finding,
               where:
                 f.recipient_user_id == ^user_id and f.kind == "decision" and
                   f.status == "open" and f.mockup_refs == ^%{},
               limit: 1
             )
           ),
         [space_id | _] <- citation_space_ids(finding) do
      refs =
        for {side, png} <- [before: before_png(), after: after_png()], into: %{} do
          {:ok, meta} =
            AttachmentStorage.persist_binary_upload(png, "#{side}.png", "image/png")

          {:ok, attachment} =
            meta
            |> Map.merge(%{space_id: space_id, uploaded_by_user_id: user_id})
            |> Chat.create_attachment()

          {Atom.to_string(side), "/chat/attachments/" <> attachment.id}
        end

      finding
      |> Finding.changeset(%{mockup_refs: refs, task_id: linked_task_id!(finding)})
      |> Repo.update!()
    end

    :ok
  end

  # A task for the decision, with its execution log, so answering it shows
  # the outcome landing in the task (not chat).
  defp linked_task_id!(%Finding{question: question}) do
    project =
      case Repo.get_by(Platform.Tasks.Project, slug: "ux-fixture") do
        nil ->
          {:ok, project} = Platform.Tasks.create_project(%{name: "UX fixture"})
          project

        project ->
          project
      end

    {:ok, task} =
      Platform.Tasks.create_task(%{
        project_id: project.id,
        title: "UX: " <> String.trim_trailing(question, "?"),
        status: "backlog"
      })

    {:ok, _space} = Platform.Orchestration.ExecutionSpace.find_or_create(task.id)
    task.id
  end

  defp citation_space_ids(%Finding{evidence: evidence}) do
    for "chat:" <> rest <- evidence["citations"] || [],
        [space_id, _] <- [String.split(rest, ":")],
        uniq: true,
        do: space_id
  end

  # ── mockup PNGs: a sidebar before and after ───────────────────────────────

  @w 480
  @h 320
  @bg {245, 245, 244}
  @rail {231, 229, 228}
  @bar {168, 162, 158}
  @faint {214, 211, 209}
  @teal {13, 148, 136}
  @pane {255, 255, 255}

  defp before_png do
    rows = for i <- 0..6, do: {16, 40 + i * 30, 120, 12, @bar}

    png([
      {0, 0, 160, @h, @rail},
      {176, 16, 288, 288, @pane}
      | rows ++ [{16, 290, 70, 10, @faint}]
    ])
  end

  defp after_png do
    dms = [{10, 28, 140, 62, @teal}, {20, 40, 90, 10, @pane}, {20, 64, 110, 10, @pane}]
    rows = for i <- 0..5, do: {16, 110 + i * 30, 120, 12, @bar}
    png([{0, 0, 160, @h, @rail}, {176, 16, 288, 288, @pane} | dms ++ rows])
  end

  defp png(rects) do
    raw =
      for y <- 0..(@h - 1), into: <<>> do
        row =
          for x <- 0..(@w - 1), into: <<>> do
            {r, g, b} =
              Enum.reduce(rects, @bg, fn {rx, ry, rw, rh, c}, acc ->
                if x >= rx and x < rx + rw and y >= ry and y < ry + rh, do: c, else: acc
              end)

            <<r, g, b>>
          end

        <<0>> <> row
      end

    <<137, 80, 78, 71, 13, 10, 26, 10>> <>
      chunk("IHDR", <<@w::32, @h::32, 8, 2, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", <<>>)
  end

  defp chunk(type, data) do
    <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>>
  end
end
