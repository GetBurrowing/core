defmodule Platform.SignInAdmin.AccountsBoundaryTest do
  @moduledoc """
  Task 01a113ea stage 2, syntactic half of the Accounts boundary:
  `Platform.SignInAdmin` and everything under `lib/platform/sign_in_admin/`
  never write a Suite user themselves. Every user write goes through
  `Platform.Accounts`.

  This guard is keyed on spelling, so a refactor can walk past it (an alias,
  a helper module outside the scanned paths). The behavioural half, the
  identical-rows test in `Platform.SignInAdminTest`, is the one that has to
  hold; this one is the cheap early warning.

  The scanner is shown able to fire (a positive control on an inline string)
  and able to find the files (a file-count floor), so a pass is not silence
  from a scanner that reads nothing.
  """
  use ExUnit.Case, async: true

  @lib Path.expand("../../../lib", __DIR__)

  # Qualified spellings are matched too: `Platform.Repo.insert` contains
  # `Repo.insert`, and `%Accounts.User{` / `%Platform.Accounts.User{` are
  # matched with or without the `Platform.` prefix.
  @forbidden [
    {"Repo.insert", ~r/\bRepo\.insert/},
    {"Repo.update", ~r/\bRepo\.update/},
    {"Repo.insert_all", ~r/\bRepo\.insert_all/},
    {"Repo.update_all", ~r/\bRepo\.update_all/},
    {"Repo.delete", ~r/\bRepo\.delete/},
    {"Multi.insert", ~r/\bMulti\.insert/},
    {"Multi.update", ~r/\bMulti\.update/},
    {"User.changeset", ~r/\bUser\.changeset/},
    {"%Accounts.User{", ~r/%(?:Platform\.)?Accounts\.User\{/}
  ]

  # A bare `%User{` is the Suite user only where the file aliases it.
  # `pocket_id.ex` builds its own nested `%User{}` (the pocket-id user, a
  # plain struct that is never persisted), so a context-free `%User{` match
  # would flag a file that writes nothing. Shown both ways in the controls.
  @accounts_user_alias ~r/alias\s+Platform\.Accounts\.(?:User\b|\{[^}]*\bUser\b)/
  @bare_user_struct ~r/%User\{/

  defp scanned_files do
    [Path.join(@lib, "platform/sign_in_admin.ex")] ++
      Path.wildcard(Path.join(@lib, "platform/sign_in_admin/**/*.ex"))
  end

  defp hits(source) do
    direct = for {label, regex} <- @forbidden, Regex.match?(regex, source), do: label

    if Regex.match?(@accounts_user_alias, source) and Regex.match?(@bare_user_struct, source),
      do: direct ++ ["%User{"],
      else: direct
  end

  test "the scanner fires on a direct user write (positive control)" do
    write = "alias Platform.Accounts.User\nRepo.insert(User.changeset(%User{}, attrs))"
    assert "Repo.insert" in hits(write)
    assert "User.changeset" in hits(write)
    assert "%User{" in hits(write)
    assert "%User{" in hits("alias Platform.Accounts.{Role, User}\n%User{email: e}")
    assert "%Accounts.User{" in hits("%Platform.Accounts.User{email: e}")
    assert "%Accounts.User{" in hits("%Accounts.User{email: e}")
    assert "Repo.update" in hits("Platform.Repo.update(changeset)")
    assert "Repo.delete" in hits("Repo.delete_all(q)")
    assert "Multi.insert" in hits("Ecto.Multi.insert(multi, :user, cs)")
  end

  test "the scanner stays quiet on the sanctioned calls and on a non-Suite User struct" do
    assert hits("Accounts.find_or_create_from_oidc(attrs)") == []
    assert hits("Accounts.relink_oidc_identity(user, sub)") == []
    # The pocket-id user struct, with no Accounts alias in the file.
    assert hits("defp decode(b), do: %User{id: b[\"id\"]}") == []
  end

  test "the scanner finds the context's files" do
    files = scanned_files()
    assert Enum.all?(files, &File.regular?/1)
    assert length(files) >= 3, "found only #{inspect(files)}"
  end

  test "no file in the SignInAdmin context writes a Suite user directly" do
    offenders =
      for file <- scanned_files(),
          label <- hits(File.read!(file)),
          do: "#{Path.relative_to(file, @lib)}: #{label}"

    assert offenders == [],
           "SignInAdmin must write users only through Platform.Accounts; found:\n" <>
             Enum.join(offenders, "\n")
  end
end
