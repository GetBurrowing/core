defmodule Platform.Accounts.MaskNamesTest do
  @moduledoc """
  Task 01a1557a-e538 stage 2: screen-share name masking as one person's
  preference with a 12-hour expiry, `Accounts.mask_names?/2` and
  `Accounts.put_mask_names/3`, stored under
  `users.preferences["mask_names_until"]` (ISO8601 UTC).
  """

  use Platform.DataCase, async: true

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Repo

  @now ~U[2026-10-21 18:00:00Z]

  defp insert_user(prefs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "mask_names_#{n}@example.com",
      name: "Mask Names #{n}",
      oidc_sub: "oidc-mask-names-#{n}",
      preferences: prefs
    })
  end

  defp reload(user), do: Repo.get!(User, user.id)

  test "on is masked at now and at now + 11h59m, and not at now + 12h01m" do
    user = insert_user()
    assert {:ok, %User{}} = Accounts.put_mask_names(user.id, true, @now)
    user = reload(user)

    assert user.preferences["mask_names_until"] == "2026-10-22T06:00:00Z"
    assert Accounts.mask_names?(user, @now)
    assert Accounts.mask_names?(user, DateTime.add(@now, 11 * 3600 + 59 * 60, :second))
    refute Accounts.mask_names?(user, DateTime.add(@now, 12 * 3600 + 60, :second))
  end

  test "the default arity reads the real clock" do
    user = insert_user()
    {:ok, _} = Accounts.put_mask_names(user, true)
    assert Accounts.mask_names?(reload(user))
  end

  test "off deletes the key" do
    user = insert_user()
    {:ok, _} = Accounts.put_mask_names(user.id, true, @now)
    assert Map.has_key?(reload(user).preferences, "mask_names_until")

    {:ok, _} = Accounts.put_mask_names(user.id, false, @now)
    refute Map.has_key?(reload(user).preferences, "mask_names_until")
    refute Accounts.mask_names?(reload(user), @now)
  end

  test "a missing, garbage or non-string value reads as unmasked" do
    refute Accounts.mask_names?(insert_user(), @now)
    refute Accounts.mask_names?(insert_user(%{"mask_names_until" => "tomorrow"}), @now)
    refute Accounts.mask_names?(insert_user(%{"mask_names_until" => 12}), @now)
    refute Accounts.mask_names?(insert_user(%{"mask_names_until" => true}), @now)
    refute Accounts.mask_names?(nil, @now)
    refute Accounts.mask_names?(nil)
  end

  test "a past instant reads as unmasked; a future one as masked" do
    past = @now |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
    future = @now |> DateTime.add(1, :second) |> DateTime.to_iso8601()
    refute Accounts.mask_names?(insert_user(%{"mask_names_until" => past}), @now)
    assert Accounts.mask_names?(insert_user(%{"mask_names_until" => future}), @now)
  end

  test "an unknown or generated id is refused and writes nothing" do
    assert {:error, :not_found} = Accounts.put_mask_names(Ecto.UUID.generate(), true, @now)
    assert {:error, :not_found} = Accounts.put_mask_names("not-a-uuid", true, @now)
    assert {:error, :not_found} = Accounts.put_mask_names(nil, true, @now)
  end

  test "the theme and notification_level keys survive both writes" do
    user = insert_user()

    {:ok, _} =
      Accounts.put_theme_preference(user.id, %{"preset" => "burrow-sand", "mode" => "light"})

    {:ok, _} = Accounts.put_notification_level(user.id, "direct")

    {:ok, _} = Accounts.put_mask_names(user.id, true, @now)
    prefs = reload(user).preferences
    assert prefs["theme"] == %{"preset" => "burrow-sand", "mode" => "light"}
    assert prefs["notification_level"] == "direct"

    {:ok, _} = Accounts.put_mask_names(user.id, false, @now)
    prefs = reload(user).preferences
    assert prefs["theme"] == %{"preset" => "burrow-sand", "mode" => "light"}
    assert prefs["notification_level"] == "direct"
    refute Map.has_key?(prefs, "mask_names_until")
  end

  describe "one write path" do
    # Code lines only: comments and @doc/@moduledoc heredocs may NAME the key
    # (chat_live.ex and sidebar_mask.ex explain the model); only accounts.ex
    # may spell the QUOTED key in code, so `put_mask_names/3` is the one writer
    # and `mask_names_until/1` the one reader. The function name itself is
    # not the key, so callers of `Accounts.mask_names_until/1` are fine.
    defp code_lines(path) do
      {kept, _} =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.reduce({[], false}, fn line, {kept, in_doc?} ->
          cond do
            in_doc? and String.trim(line) == ~s(""") -> {kept, false}
            in_doc? -> {kept, true}
            Regex.match?(~r/^\s*@(module)?doc\s+"""/, line) -> {kept, true}
            String.starts_with?(String.trim_leading(line), "#") -> {kept, false}
            true -> {[line | kept], false}
          end
        end)

      kept
    end

    test "only accounts.ex spells the quoted key in code" do
      files = Path.wildcard(Path.expand("../../../lib/**/*.{ex,heex}", __DIR__))
      assert length(files) > 100

      hits =
        for f <- files,
            Enum.any?(code_lines(f), &String.contains?(&1, ~s("mask_names_until"))),
            do: Path.relative_to(f, Path.expand("../../..", __DIR__))

      assert hits == ["lib/platform/accounts.ex"]
    end
  end
end
