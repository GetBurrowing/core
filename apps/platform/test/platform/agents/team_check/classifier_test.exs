defmodule Platform.Agents.TeamCheck.ClassifierTest do
  @moduledoc """
  `Platform.Agents.TeamCheck.Classifier.classify/1`, task 01a1b6de stage 3:
  a table of evidence -> class, offline beating every text class, who fixes
  it, and that nothing on the classify path can reach a model.
  """
  use ExUnit.Case, async: true

  alias Platform.Agents.TeamCheck.Classifier

  @now ~U[2026-11-07 12:00:00Z]
  @threshold 7_200
  @owner %{id: "owner-id", name: "Owner Person"}
  @sponsor %{id: "sponsor-id", name: "Sponsor Person"}

  defp online, do: %{online: true, last_seen_at: @now}
  defp gone(seconds_ago), do: %{online: false, last_seen_at: DateTime.add(@now, -seconds_ago)}

  defp failure(text, minutes_ago \\ 5, type \\ "execution.blocked") do
    %{event_type: type, text: text, occurred_at: DateTime.add(@now, -minutes_ago * 60)}
  end

  defp evidence(presence, failures, extra \\ %{}) do
    Map.merge(
      %{
        presence: presence,
        failures: failures,
        now: @now,
        offline_after_seconds: @threshold,
        owner: @owner
      },
      extra
    )
  end

  defp class(presence, failures), do: Classifier.classify(evidence(presence, failures)).class

  @table [
    {"remote: Permission to org/repo.git denied to agent-bot.", :access},
    {"git push failed: The requested URL returned error: 403", :access},
    {"repository is read-only for this token", :access},
    {"user is not a collaborator on the repository", :access},
    {"HTTP 401 from the forge", :credentials},
    {"the access token has expired", :credentials},
    {"fatal: Authentication failed for the remote", :credentials},
    {"invalid token supplied", :credentials},
    {"sh: mix: command not found", :toolchain},
    {"node is not installed on this host", :toolchain},
    {"missing elixir toolchain", :toolchain},
    {"out of credits for this month", :spend_consent},
    {"quota exceeded on the model account", :spend_consent},
    {"this run needs approval to spend more", :spend_consent}
  ]

  describe "the evidence table" do
    for {text, expected} <- @table do
      test "#{inspect(text)} -> #{expected}" do
        assert class(online(), [failure(unquote(text))]) == unquote(expected)
      end
    end

    test "every class is one of the six" do
      assert Classifier.classes() == [
               :offline,
               :access,
               :credentials,
               :toolchain,
               :spend_consent,
               :ok
             ]
    end
  end

  describe "offline wins" do
    test "offline with a 403 on record is offline, never access" do
      result = Classifier.classify(evidence(gone(86_400), [failure("HTTP 403 Forbidden")]))
      assert result.class == :offline
      assert result.evidence =~ "last seen"
    end

    test "offline beats every text class" do
      for {text, _} <- @table do
        assert class(gone(@threshold + 60), [failure(text)]) == :offline, text
      end
    end

    test "never seen is offline, and says why" do
      result =
        Classifier.classify(
          evidence(%{online: false, last_seen_at: nil, source: :no_runtime}, [])
        )

      assert result.class == :offline
      assert result.evidence =~ "no runtime"
    end

    test "disconnected inside the threshold is not offline" do
      assert class(gone(@threshold - 60), [failure("HTTP 403")]) == :access
      assert class(gone(@threshold - 60), []) == :ok
    end
  end

  describe "ok and ordering" do
    test "present with no failures is ok, with no fixer" do
      result = Classifier.classify(evidence(online(), []))

      assert result == %{
               class: :ok,
               evidence: "present; no open failures",
               basis: "ok",
               fixer: nil,
               action: nil
             }
    end

    test "a failure no pattern matches stays ok and is named, not dropped" do
      result =
        Classifier.classify(
          evidence(online(), [failure("Executor never acked", 5, "execution.no_ack_timeout")])
        )

      assert result.class == :ok
      assert result.evidence =~ "execution.no_ack_timeout"
    end

    test "the newest matching failure decides" do
      older = failure("HTTP 401", 60)
      newer = failure("HTTP 403", 5)
      assert class(online(), [older, newer]) == :access
      assert class(online(), [failure("HTTP 401", 5), failure("HTTP 403", 60)]) == :credentials
    end

    test "evidence is one line and bounded" do
      long = "HTTP 403\n" <> String.duplicate("word ", 200)
      result = Classifier.classify(evidence(online(), [failure(long)]))
      refute result.evidence =~ "\n"
      assert String.length(result.evidence) <= 200
    end
  end

  describe "who fixes it" do
    test "the owner by default" do
      result = Classifier.classify(evidence(online(), [failure("HTTP 403")]))
      assert result.fixer == @owner
      assert result.action =~ "access"
    end

    test "the sponsoring human when the agent is bound to one" do
      result = Classifier.classify(evidence(gone(86_400), [], %{sponsor: @sponsor}))
      assert result.fixer == @sponsor
      assert result.action =~ "online"
    end

    test "every stuck class names an action" do
      for {text, _} <- @table do
        assert is_binary(Classifier.classify(evidence(online(), [failure(text)])).action)
      end
    end
  end

  describe "no model on the classify path" do
    test "the classifier calls nothing outside the standard library" do
      {:ok, {_, [imports: imports]}} =
        :beam_lib.chunks(:code.which(Classifier), [:imports])

      modules = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      offenders =
        Enum.filter(modules, fn mod ->
          name = Atom.to_string(mod)
          String.starts_with?(name, "Elixir.Platform") or String.starts_with?(name, "Elixir.Req")
        end)

      assert offenders == [], "classify/1 must stay pure; it calls #{inspect(offenders)}"
    end
  end
end
