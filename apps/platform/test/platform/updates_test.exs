defmodule Platform.UpdatesTest do
  @moduledoc """
  `Platform.Updates` (task 01a1b7b6 stage 3): core's half of the host
  updater's file contract. Core writes exactly two shapes through
  staging -> inbox, and reads status.json defensively.
  """

  # async: false: mutates the Platform.Updates application env.
  use Platform.DataCase, async: false

  import Platform.UpdaterFixtures

  alias Platform.Updates

  setup :setup_updater_dirs

  defp inbox(%{core_dir: core}), do: core |> Path.join("inbox") |> File.ls!() |> Enum.sort()
  defp staging(%{core_dir: core}), do: core |> Path.join("staging") |> File.ls!()

  defp read_inbox(%{core_dir: core}, name),
    do: core |> Path.join("inbox") |> Path.join(name) |> File.read!() |> Jason.decode!()

  # Returns an idempotent restore function.
  defp make_staging_unwritable(staging_dir) do
    if root?() do
      File.rm_rf!(staging_dir)
      File.write!(staging_dir, "")

      fn ->
        File.rm(staging_dir)
        File.mkdir_p!(staging_dir)
      end
    else
      File.chmod!(staging_dir, 0o500)
      fn -> File.chmod!(staging_dir, 0o700) end
    end
  end

  defp root? do
    {uid, 0} = System.cmd("id", ["-u"])
    String.trim(uid) == "0"
  end

  describe "request/2" do
    test "writes exactly {action, request_id, requested_at} as inbox/request.json", ctx do
      for action <- [:check, :update, :rollback] do
        assert {:ok, request_id} = Updates.request(action, nil)
        body = read_inbox(ctx, "request.json")

        assert Map.keys(body) |> Enum.sort() == ["action", "request_id", "requested_at"]
        assert body["action"] == Atom.to_string(action)
        assert body["request_id"] == request_id
        assert {:ok, _, 0} = DateTime.from_iso8601(body["requested_at"])
        assert {:ok, _} = Ecto.UUID.cast(request_id)
        # UUIDv7: version nibble 7.
        assert String.at(request_id, 14) == "7"
        assert inbox(ctx) == ["request.json"]
        assert staging(ctx) == []
      end
    end

    test "an unknown action writes nothing", ctx do
      for action <- [:pull, :migrate, "update", "check", nil] do
        assert_raise FunctionClauseError, fn -> Updates.request(action, nil) end
      end

      assert inbox(ctx) == []
      assert staging(ctx) == []
    end

    test "a caller map cannot reach request.json (no image, channel or extra key)", ctx do
      for params <- [
            %{"action" => "update", "image" => "docker.io/evil/x:1"},
            %{action: :update, image: "docker.io/evil/x:1"},
            [action: :update, channel: "edge"]
          ] do
        assert_raise FunctionClauseError, fn -> Updates.request(params, nil) end
      end

      # Control: the same call with a bare action does write.
      assert {:ok, _} = Updates.request(:update, nil)
      refute File.read!(Path.join([ctx.core_dir, "inbox", "request.json"])) =~ "evil"

      assert Map.keys(read_inbox(ctx, "request.json")) |> Enum.sort() ==
               ["action", "request_id", "requested_at"]
    end

    test "the file reaches the inbox only by a rename out of staging", ctx do
      staging_dir = Path.join(ctx.core_dir, "staging")
      # A staging dir core cannot write into: the request must fail and the
      # inbox stay empty. A direct write to the inbox would succeed here.
      # Mode bits do not bind root (CI runs the suite as root in a container),
      # so as root the staging dir is replaced by a plain file instead.
      restore = make_staging_unwritable(staging_dir)
      on_exit(restore)

      assert {:error, _} = Updates.request(:update, nil)
      assert {:error, _} = Updates.set_auto_update(false, nil)
      assert inbox(ctx) == []

      # Control: writable staging, the same calls land in the inbox.
      restore.()
      assert {:ok, _} = Updates.request(:update, nil)
      assert :ok = Updates.set_auto_update(false, nil)
      assert inbox(ctx) == ["request.json", "settings.json"]
      assert staging(ctx) == []
    end

    test "with no inbox dir (no updater) nothing is written anywhere", ctx do
      File.rm_rf!(Path.join(ctx.core_dir, "inbox"))
      assert {:error, :no_inbox_dir} = Updates.request(:update, nil)
      assert staging(ctx) == []
    end

    test "records an audit event with the actor and the action" do
      actor = Platform.TenancyFixtures.root_admin!()
      assert {:ok, request_id} = Updates.request(:update, actor)

      event =
        Platform.Repo.one!(
          from(e in Platform.Audit.Event,
            where: e.event_type == "platform.updates.update_requested" and e.actor_id == ^actor.id
          )
        )

      assert event.metadata["action"] == "update"
      assert event.metadata["request_id"] == request_id
    end
  end

  describe "set_auto_update/2" do
    test "writes exactly {auto_update} as inbox/settings.json", ctx do
      assert :ok = Updates.set_auto_update(false, nil)
      assert read_inbox(ctx, "settings.json") == %{"auto_update" => false}
      assert :ok = Updates.set_auto_update(true, nil)
      assert read_inbox(ctx, "settings.json") == %{"auto_update" => true}
      assert staging(ctx) == []
    end

    test "a non-boolean writes nothing", ctx do
      for value <- ["false", "true", 0, nil, %{"auto_update" => false, "image" => "x"}] do
        assert_raise FunctionClauseError, fn -> Updates.set_auto_update(value, nil) end
      end

      assert inbox(ctx) == []
    end
  end

  describe "status/0" do
    test "missing is :not_installed", ctx do
      refute File.exists?(ctx.status_path)
      assert Updates.status() == :not_installed
    end

    test "keeps known keys only, at every level", ctx do
      write_status!(ctx.status_path, %{
        "secret" => "x",
        "current" => %{"digest" => "d", "commit" => "c", "extra" => 1},
        "last_rollback" => %{"at" => "t", "from" => "f", "to" => "o", "why" => "w"},
        "dump" => "/var/lib/burrow-updater/state/pre-update.dump"
      })

      status = Updates.status()

      assert status |> Map.keys() |> Enum.sort() ==
               Enum.sort([
                 :channel,
                 :auto_update,
                 :last_result,
                 :last_checked_at,
                 :deferred_since,
                 :current,
                 :available,
                 :last_rollback,
                 :pending_irreversible,
                 :last_request,
                 :error
               ])

      assert status.current == %{digest: "d", commit: "c"}
      assert status.last_rollback == %{at: "t", from: "f", to: "o"}
      assert status.channel == "stable"
      assert status.last_result == "ok"
    end

    test "every stage 1 last_result is kept; anything else reads as nil", ctx do
      for result <- Updates.last_results() do
        write_status!(ctx.status_path, %{"last_result" => result})
        assert Updates.status().last_result == result
      end

      write_status!(ctx.status_path, %{"last_result" => "pwned", "channel" => "nightly"})
      status = Updates.status()
      assert status.last_result == nil
      assert status.channel == nil
    end

    test "malformed JSON, a non-object and oversize are errors, never a crash", ctx do
      File.write!(ctx.status_path, "{not json")
      assert {:error, _} = Updates.status()

      File.write!(ctx.status_path, "[1, 2]")
      assert {:error, _} = Updates.status()

      padding = String.duplicate(" ", 65_536)
      File.write!(ctx.status_path, Jason.encode!(status_json()) <> padding)
      assert {:error, :oversize} = Updates.status()

      # A directory where the file should be.
      File.rm!(ctx.status_path)
      File.mkdir_p!(ctx.status_path)
      assert {:error, _} = Updates.status()
    end
  end

  describe "health_summary/0" do
    test "nil when not installed or unreadable", ctx do
      assert Updates.health_summary() == nil
      File.write!(ctx.status_path, "{")
      assert Updates.health_summary() == nil
    end

    test "carries the five fields and no digest", ctx do
      write_status!(ctx.status_path, %{
        "last_result" => "rolled_back",
        "available" => %{"digest" => "ghcr.io/example/core@sha256:" <> String.duplicate("b", 64)},
        "last_rollback" => %{
          "at" => "2026-11-07T03:10:00Z",
          "from" => "913287c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6",
          # The updater falls back to the ref when it cannot read a commit.
          "to" => "ghcr.io/example/core@sha256:" <> String.duplicate("c", 64)
        }
      })

      summary = Updates.health_summary()

      assert summary |> Map.keys() |> Enum.sort() ==
               [:auto_update, :channel, :last_checked_at, :last_result, :last_rollback]

      assert summary.last_rollback == %{
               at: "2026-11-07T03:10:00Z",
               from: "913287c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6",
               to: nil
             }

      refute Jason.encode!(summary) =~ "sha256:"
    end
  end
end
