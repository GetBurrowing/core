defmodule Platform.Role.EffectsTest do
  @moduledoc """
  Side effects under the web role (task 01a155a6 stage 4).

  One VM plays both nodes. The web node is the role (`:web`) the write runs
  under; the full node is every background child running in this VM, here
  `TaskRouterWatcher` (the `tasks:board` consumer) started for the test, plus
  whatever `Platform.Supervisor` already runs. After the write, every one of
  them is synchronised (`:sys.get_state/2` returns only after its mailbox up
  to that point is handled), so a background consumer that pushed again on
  the broadcast would have done so before the count is read.

  Push is observed through a Recorder injected as `:notifications_module`
  (the real `fan_out_to_user/3` short-circuits in :test env).

  NOT async: it sets the node role and app env.
  """

  use Platform.DataCase, async: false

  alias Platform.Inbox
  alias Platform.Orchestration.TaskRouterWatcher
  alias Platform.Repo
  alias Platform.Role
  alias Platform.Tasks

  defmodule Recorder do
    @moduledoc "Records `fan_out_to_user/3` and `fan_out_to_humans/3` to the installed owner."
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_user(user_id, payload, _opts \\ []) do
      notify({:notif, user_id, payload})
    end

    def fan_out_to_humans(participant_ids, payload, _opts \\ []) do
      for id <- participant_ids, do: notify({:notif, id, payload})
      :ok
    end

    defp notify(message) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, message)
      end

      :ok
    end
  end

  setup do
    keys = [:notifications_module, :role]
    previous = Map.new(keys, &{&1, Application.fetch_env(:platform, &1)})

    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    start_supervised!(TaskRouterWatcher)

    Application.put_env(:platform, :notifications_module, Recorder)
    Recorder.install(self())

    on_exit(fn ->
      :persistent_term.erase({Recorder, :owner})

      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    {:ok, project} =
      Tasks.create_project(%{name: "Effects #{System.unique_integer([:positive])}"})

    %{project: project}
  end

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Effects #{n}",
      email: "effects-#{n}@example.com",
      oidc_sub: "sub-effects-#{n}"
    })
  end

  # Every background child running in this VM has handled its mailbox up to
  # now. Children that are not OTP processes, or exit mid-call, are skipped.
  defp settle_background do
    :ok = TaskRouterWatcher.sync()

    background = MapSet.new(Role.background_ids())

    for {id, pid, _type, _mods} <- Supervisor.which_children(Platform.Supervisor),
        is_pid(pid),
        MapSet.member?(background, id) do
      try do
        :sys.get_state(pid, 2_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp pushes_to(user_id) do
    Stream.repeatedly(fn ->
      receive do
        {:notif, ^user_id, _payload} -> :one
      after
        300 -> :none
      end
    end)
    |> Enum.take_while(&(&1 == :one))
    |> length()
  end

  describe "an inbox item originating on a web node" do
    test "a sponsor assignment there pushes exactly once; no full-node consumer pushes it again",
         %{project: project} do
      sponsor = insert_user()

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Sponsored on exp"},
          actor: {:agent, Ecto.UUID.generate()}
        )

      settle_background()
      assert pushes_to(sponsor.id) == 0

      Application.put_env(:platform, :role, :web)

      {:ok, _} =
        Tasks.update_task(task, %{sponsor_user_id: sponsor.id},
          actor: {:agent, Ecto.UUID.generate()}
        )

      settle_background()

      assert [_row] = Inbox.list_unread_for_user(sponsor.id, kind: "task_sponsor_assigned")
      assert pushes_to(sponsor.id) == 1
    end

    test "a push-kind inbox row emitted there pushes exactly once" do
      user = insert_user()
      Application.put_env(:platform, :role, :web)

      {:ok, item} =
        Inbox.emit(%{
          user_id: user.id,
          kind: "review_request_pending",
          source_type: "task_review",
          source_id: Ecto.UUID.generate(),
          title: "Review requested on exp",
          body: "body",
          url: "/tasks/x"
        })

      settle_background()

      assert item.kind in Inbox.push_kinds()
      assert pushes_to(user.id) == 1
    end
  end

  # ── the table in Platform.Role is complete ──────────────────────────────

  @patterns %{
    push: ~r/\.fan_out_to_(user|humans)\(|\bPush\.(send_notification|send_to_user)\(/,
    mail: ~r/\b(Deliverer|Mailer)\.deliver\(/,
    http:
      ~r/\bReq\.(get|post|put|patch|delete|head|request|run)!?\(|\bFinch\.(request|stream)!?\(/,
    agent_dispatch: ~r/\b(ExternalDispatcher|ExternalAgents\.Dispatcher)\.dispatch\(/
  }

  # The files whose CODE (not a comment) calls the effect. `lib/` relative to
  # apps/platform, which is the test's working directory.
  defp files_calling(regex) do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      path
      |> File.stream!()
      |> Enum.any?(fn line ->
        trimmed = String.trim_leading(line)
        not String.starts_with?(trimmed, "#") and Regex.match?(regex, line)
      end)
    end)
    |> MapSet.new()
  end

  test "Role.effects/0 classifies exactly the files that call a side effect, per kind" do
    assert File.dir?("lib/platform"), "run from apps/platform"

    for {kind, regex} <- @patterns do
      found = files_calling(regex)

      tabled =
        Role.effects()
        |> Enum.filter(&(&1.kind == kind))
        |> MapSet.new(& &1.file)

      refute MapSet.size(found) == 0, "the #{kind} grep found nothing: the guard cannot fire"

      assert MapSet.difference(found, tabled) == MapSet.new(),
             "#{kind} call sites missing from Platform.Role.effects/0: " <>
               inspect(MapSet.difference(found, tabled) |> Enum.sort())

      assert MapSet.difference(tabled, found) == MapSet.new(),
             "Platform.Role.effects/0 lists #{kind} files that no longer call one: " <>
               inspect(MapSet.difference(tabled, found) |> Enum.sort())
    end
  end

  test "every effects row and node-local row carries a known class and a note" do
    for row <- Role.effects() do
      assert row.class in [:request, :background, :both, :follows_caller, :wire, :none]
      assert is_binary(row.note) and row.note != ""
    end

    for row <- Role.node_local() do
      assert row.handling in [:peer, :tolerates, :full_only, :pure]
      assert is_binary(row.note) and row.note != ""
    end
  end
end
