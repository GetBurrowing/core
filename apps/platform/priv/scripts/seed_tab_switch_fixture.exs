# Tab-switch measurement fixture (task 01a17b00 stage 1).
#
# Fills a PER-TASK dev database with the shape of a busy account so the
# tab-switch harness (`e2e/scripts/measure-tab-switch.sh`) measures mounts
# against realistic data rather than an empty install:
#
#   * a busy channel `tab-switch-busy` with >= 2,000 messages, including
#     attachments, reactions, threads (replies) and pins;
#   * >= 20 other channels the test user sits in, so the chat list is full;
#   * a task board of >= 300 tasks across every board status, in several
#     projects with epics, plus a stored project filter pref for the user;
#   * inbox items (chat mentions) for the user;
#   * >= 20 meetings.
#
# The test user is the `/dev/login?as=tabswitch` user (oidc sub
# `dev-tabswitch`), created through the same admission path the dev login
# uses, so the harness can sign in as it without touching any other session.
#
# Idempotent: every section counts what is already there and only tops up.
#
# REFUSES to run unless MIX_ENV is dev AND the configured database name
# carries the task suffix (default `01a17b00`, override with
# TAB_SWITCH_DB_SUFFIX). It never runs against `platform_dev` or any shared
# database.
#
# Usage (from apps/platform):
#   PLATFORM_DEV_DATABASE=platform_dev_01a17b00 MIX_ENV=dev \
#     mix run --no-start priv/scripts/seed_tab_switch_fixture.exs [--no-project-pref]
#
# `--no-start` matters: the guard must run BEFORE the application boots,
# because boot itself touches the configured database. The script starts
# `:platform` only after the guard passes, and refuses outright if the app
# was already started (a plain `mix run` booted it before the guard ran).
#
# `--no-project-pref` clears the stored tasks project pref instead of setting
# it (scenario S2 of the tasks-tab rows).

defmodule TabSwitchFixture.Guard do
  @moduledoc false

  @default_suffix "01a17b00"
  @shared ~w(platform_dev platform_test platform_prod platform)

  @doc """
  `:ok` when the seed may write to `database` under `mix_env`, else
  `{:error, reason}`. Pure, so the refusal is testable without a database.
  """
  def check(mix_env, database, suffix \\ @default_suffix)

  def check(mix_env, _database, _suffix) when mix_env != :dev,
    do: {:error, "MIX_ENV must be dev, got #{inspect(mix_env)}"}

  def check(_mix_env, database, _suffix) when not is_binary(database) or database == "",
    do: {:error, "no database configured"}

  def check(_mix_env, database, suffix) do
    cond do
      not is_binary(suffix) or byte_size(suffix) < 6 ->
        {:error, "task suffix #{inspect(suffix)} is too short to fence a database"}

      database in @shared ->
        {:error, "refusing shared database #{database}"}

      Regex.match?(~r/prod/i, database) ->
        {:error, "refusing database #{database}: looks like a production database"}

      not String.contains?(database, suffix) ->
        {:error, "database #{database} lacks the task suffix #{suffix}"}

      true ->
        :ok
    end
  end

  def default_suffix, do: @default_suffix
end

defmodule TabSwitchFixture do
  @moduledoc false

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Accounts.ExternalAdmission
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant, Pin, Reaction, Space}
  alias Platform.Inbox
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks

  @busy_slug "tab-switch-busy"
  @busy_messages 2_000
  @other_spaces 22
  @tasks_target 320
  @meetings_target 24
  @inbox_target 40
  @peer_count 4
  @board_statuses ~w(backlog planning in_progress in_review deploying done blocked)

  def main(argv) do
    mix_env = Mix.env()
    database = Repo.config()[:database]
    suffix = System.get_env("TAB_SWITCH_DB_SUFFIX", TabSwitchFixture.Guard.default_suffix())

    case TabSwitchFixture.Guard.check(mix_env, database, suffix) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "seed_tab_switch_fixture: #{reason}")
        System.halt(2)
    end

    if List.keymember?(Application.started_applications(), :platform, 0) do
      IO.puts(
        :stderr,
        "seed_tab_switch_fixture: run with `mix run --no-start` so the guard runs before boot"
      )

      System.halt(2)
    end

    {:ok, _} = Application.ensure_all_started(:platform)

    Logger.configure(level: :warning)
    IO.puts("seed_tab_switch_fixture: writing to #{database}")

    user = admit!("tabswitch")
    peers = for n <- 1..@peer_count, do: admit!("tabswitch-peer#{n}")

    busy = busy_space!(user, peers)
    others = other_spaces!(user, peers)
    {projects, epics} = board!()
    pref = project_pref!(user, projects, "--no-project-pref" in argv)
    meetings = meetings!(projects)
    inbox = inbox!(user, busy)

    report(user, busy, others, projects, epics, pref, meetings, inbox)
  end

  # ── people ──────────────────────────────────────────────────────────────

  # The same admission call `/dev/login?as=<slug>` makes.
  defp admit!(slug) do
    result =
      ExternalAdmission.admit(
        %{sub: "dev-#{slug}", email: "#{slug}@localhost", name: "Dev #{String.capitalize(slug)}"},
        surface: :app
      )

    case result do
      %ExternalAdmission.Result{user: user} -> user
      other -> raise "admission failed for #{slug}: #{inspect(other)}"
    end
  end

  defp participant!(space, user) do
    case Repo.one(
           from(p in Participant,
             where:
               p.space_id == ^space.id and p.participant_type == "user" and
                 p.participant_id == ^user.id,
             limit: 1
           )
         ) do
      %Participant{} = p ->
        p

      nil ->
        {:ok, p} =
          Chat.add_participant(space.id, %{
            participant_type: "user",
            participant_id: user.id,
            display_name: user.name,
            joined_at: DateTime.utc_now()
          })

        p
    end
  end

  defp channel!(slug, name) do
    case Chat.get_space_by_slug(slug) do
      %Space{} = space ->
        space

      nil ->
        general = Chat.get_space_by_slug("general")

        {:ok, space} =
          Chat.create_space(%{
            name: name,
            slug: slug,
            kind: "channel",
            org_id: general && general.org_id
          })

        space
    end
  end

  # ── the busy space ──────────────────────────────────────────────────────

  defp message_count(space) do
    Repo.aggregate(
      from(m in Message, where: m.space_id == ^space.id and is_nil(m.deleted_at)),
      :count
    )
  end

  defp busy_space!(user, peers) do
    space = channel!(@busy_slug, "Tab switch busy")
    authors = Enum.map([user | peers], &participant!(space, &1))

    have = message_count(space)
    missing = max(@busy_messages - have, 0)

    # 90% top-level, every 40th of those carries an attachment; the last
    # 10% are thread replies, five per thread.
    top_level = div(missing * 9, 10)
    replies = missing - top_level

    tops =
      for i <- 1..top_level//1 do
        author = Enum.at(authors, rem(i, length(authors)))
        content = "busy message #{have + i}: " <> filler(i)

        if rem(i, 40) == 0 do
          {:ok, msg, _} =
            Chat.post_message_with_attachments(
              %{
                space_id: space.id,
                participant_id: author.id,
                content_type: "text",
                content: content
              },
              [attachment_attrs(i)]
            )

          msg
        else
          {:ok, msg} =
            Chat.post_message(%{
              space_id: space.id,
              participant_id: author.id,
              content_type: "text",
              content: content
            })

          msg
        end
      end

    parents = tops |> Enum.take_every(max(div(length(tops), max(div(replies, 5), 1)), 1))

    replies_left =
      Enum.reduce_while(parents, replies, fn parent, left ->
        if left <= 0 do
          {:halt, left}
        else
          {:ok, thread} = Chat.create_thread_for_message(space.id, parent.id)

          for r <- 1..min(5, left) do
            author = Enum.at(authors, rem(r, length(authors)))

            {:ok, _} =
              Chat.post_message(%{
                space_id: space.id,
                thread_id: thread.id,
                participant_id: author.id,
                content_type: "text",
                content: "reply #{r} on #{String.slice(parent.content, 0, 30)}"
              })
          end

          {:cont, left - min(5, left)}
        end
      end)

    # Any remainder (few parents) lands top-level so the count is met.
    for i <- 1..replies_left//1 do
      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: hd(authors).id,
          content_type: "text",
          content: "busy remainder #{i}"
        })
    end

    reactions!(space, authors)
    pins!(space, user)
    space
  end

  defp filler(i) do
    words = ~w(deploy review canvas thread meeting budget board render socket mount latency
               fixture payload compress frame inbox agent stage plan project epic)

    n = 6 + rem(i * 7, 30)
    Enum.map_join(1..n, " ", fn k -> Enum.at(words, rem(i * 31 + k * 17, length(words))) end)
  end

  defp attachment_attrs(i) do
    {name, type} =
      case rem(div(i, 40), 3) do
        0 -> {"screenshot-#{i}.png", "image/png"}
        1 -> {"notes-#{i}.pdf", "application/pdf"}
        2 -> {"log-#{i}.txt", "text/plain"}
      end

    %{
      filename: name,
      content_type: type,
      byte_size: 10_000 + i,
      storage_key: "tab-switch-fixture/#{i}/#{name}"
    }
  end

  defp reactions!(space, authors) do
    have =
      Repo.aggregate(
        from(r in Reaction,
          join: m in Message,
          on: m.id == r.message_id,
          where: m.space_id == ^space.id
        ),
        :count
      )

    if have < 300 do
      targets =
        Repo.all(
          from(m in Message,
            where: m.space_id == ^space.id and is_nil(m.thread_id) and is_nil(m.deleted_at),
            order_by: [desc: m.inserted_at],
            limit: 150,
            select: m.id
          )
        )

      emojis = ["👍", "🎉", "👀", "🚀"]

      for {mid, i} <- Enum.with_index(targets), k <- 0..1 do
        author = Enum.at(authors, rem(i + k, length(authors)))

        _ =
          Chat.add_reaction(%{
            message_id: mid,
            participant_id: author.id,
            emoji: Enum.at(emojis, rem(i + k, 4))
          })
      end
    end
  end

  defp pins!(space, user) do
    have = Repo.aggregate(from(p in Pin, where: p.space_id == ^space.id), :count)

    if have < 10 do
      Repo.all(
        from(m in Message,
          where: m.space_id == ^space.id and is_nil(m.thread_id) and is_nil(m.deleted_at),
          order_by: [desc: m.inserted_at],
          offset: 5,
          limit: 10,
          select: m.id
        )
      )
      |> Enum.each(fn mid ->
        _ = Chat.pin_message(user, %{space_id: space.id, message_id: mid})
      end)
    end
  end

  # ── the rest of the chat list ───────────────────────────────────────────

  defp other_spaces!(user, peers) do
    for n <- 1..@other_spaces do
      space = channel!("tab-switch-room-#{n}", "Tab switch room #{n}")
      me = participant!(space, user)
      peer = participant!(space, Enum.at(peers, rem(n, length(peers))))

      for i <- (message_count(space) + 1)..5//1 do
        {:ok, _} =
          Chat.post_message(%{
            space_id: space.id,
            participant_id: if(rem(i, 2) == 0, do: me.id, else: peer.id),
            content_type: "text",
            content: "room #{n} message #{i}: " <> filler(n * 10 + i)
          })
      end

      space
    end
  end

  # ── the task board ──────────────────────────────────────────────────────

  defp board! do
    projects =
      for name <- ["Tab Switch Alpha", "Tab Switch Beta", "Tab Switch Gamma", "Tab Switch Delta"] do
        case Repo.one(from(p in Tasks.Project, where: p.name == ^name, limit: 1)) do
          nil ->
            {:ok, p} = Tasks.create_project(%{name: name})
            p

          p ->
            p
        end
      end

    epics =
      for p <- projects, e <- 1..3 do
        name = "#{p.name} epic #{e}"

        case Repo.one(
               from(x in Tasks.Epic, where: x.project_id == ^p.id and x.name == ^name, limit: 1)
             ) do
          nil ->
            {:ok, epic} = Tasks.create_epic(%{project_id: p.id, name: name})
            epic

          epic ->
            epic
        end
      end

    project_ids = Enum.map(projects, & &1.id)

    have =
      Repo.aggregate(from(t in Tasks.Task, where: t.project_id in ^project_ids), :count)

    for i <- (have + 1)..@tasks_target//1 do
      project = Enum.at(projects, rem(i, length(projects)))
      project_epics = Enum.filter(epics, &(&1.project_id == project.id))

      epic =
        if rem(i, 4) == 0, do: nil, else: Enum.at(project_epics, rem(i, length(project_epics)))

      {:ok, _} =
        Tasks.create_task(%{
          project_id: project.id,
          epic_id: epic && epic.id,
          title: "Tab switch task #{i}: " <> String.slice(filler(i), 0, 60),
          description: filler(i * 3),
          status: Enum.at(@board_statuses, rem(i, length(@board_statuses))),
          priority: Enum.at(~w(low medium high critical), rem(i, 4))
        })
    end

    {projects, epics}
  end

  defp project_pref!(user, projects, clear?) do
    if clear? do
      {:ok, _} = Accounts.put_tasks_project_pref(user.id, nil, nil)
      :none
    else
      p = hd(projects)
      {:ok, _} = Accounts.put_tasks_project_pref(user.id, p.id, nil)
      {:project, p.name}
    end
  end

  # ── meetings ────────────────────────────────────────────────────────────

  defp meetings!(projects) do
    project = hd(projects)

    have =
      Repo.aggregate(
        from(m in Platform.Meetings.Meeting,
          where: m.project_id == ^project.id and like(m.name, "Tab switch meeting %")
        ),
        :count
      )

    now = DateTime.utc_now()

    for i <- (have + 1)..@meetings_target//1 do
      start = DateTime.add(now, (i - div(@meetings_target, 2)) * 86_400, :second)

      {:ok, _} =
        Meetings.create_meeting(%{
          project_id: project.id,
          name: "Tab switch meeting #{i}",
          scheduled_start_at: start,
          scheduled_end_at: DateTime.add(start, 1_800, :second)
        })
    end

    have |> max(@meetings_target)
  end

  # ── inbox ───────────────────────────────────────────────────────────────

  defp inbox!(user, busy) do
    have =
      Repo.aggregate(
        from(i in Platform.Inbox.Item, where: i.user_id == ^user.id and i.kind == "chat_mention"),
        :count
      )

    if have < @inbox_target do
      Repo.all(
        from(m in Message,
          where: m.space_id == ^busy.id and is_nil(m.thread_id) and is_nil(m.deleted_at),
          order_by: [desc: m.inserted_at],
          offset: 20,
          limit: ^(@inbox_target - have),
          select: m
        )
      )
      |> Enum.each(fn m ->
        _ =
          Inbox.emit(%{
            user_id: user.id,
            kind: "chat_mention",
            source_type: "chat_message",
            source_id: m.id,
            title: "Mentioned in Tab switch busy",
            body: String.slice(m.content || "", 0, 120),
            url: "/chat/#{busy.slug}"
          })
      end)
    end

    Repo.aggregate(
      from(i in Platform.Inbox.Item, where: i.user_id == ^user.id and i.kind == "chat_mention"),
      :count
    )
  end

  # ── report ──────────────────────────────────────────────────────────────

  defp report(user, busy, others, projects, epics, pref, meetings, inbox) do
    project_ids = Enum.map(projects, & &1.id)

    by_status =
      Repo.all(
        from(t in Tasks.Task,
          where: t.project_id in ^project_ids,
          group_by: t.status,
          select: {t.status, count(t.id)}
        )
      )

    IO.puts("""
    seed_tab_switch_fixture: done
      user:         dev-tabswitch (#{user.id})
      busy space:   /chat/#{busy.slug}, #{message_count(busy)} messages
      other spaces: #{length(others)}
      projects:     #{length(projects)}, epics: #{length(epics)}
      tasks:        #{inspect(by_status)}
      project pref: #{inspect(pref)}
      meetings:     #{meetings}
      inbox items:  #{inbox}
    """)
  end
end

unless Process.get(:tab_switch_fixture_load_only) do
  TabSwitchFixture.main(System.argv())
end
