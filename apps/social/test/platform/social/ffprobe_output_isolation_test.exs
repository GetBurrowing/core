defmodule Platform.Social.FfprobeOutputIsolationTest do
  use ExUnit.Case, async: false

  alias Platform.Social.Renderer.Ffmpeg

  setup do
    root =
      Path.join(System.tmp_dir!(), "probe-isolation-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old_probe = Application.get_env(:social, :ffprobe_path)
    old_tmp = Application.get_env(:social, :render_tmp_dir)

    on_exit(fn ->
      restore(:ffprobe_path, old_probe)
      restore(:render_tmp_dir, old_tmp)
      unless File.exists?(Path.join(root, "child-exit-unconfirmed")), do: File.rm_rf!(root)
    end)

    Application.put_env(:social, :render_tmp_dir, root)

    script = Path.join(root, "fake-ffprobe")
    log = Path.join(root, "calls")
    pid_file = Path.join(root, "child-pid")

    File.write!(script, """
    #!/bin/sh
    if [ "$1" = "-h" ]; then
      echo help >> '#{log}'
      echo '-o <output_file> write to specified output'
      exit 0
    fi
    output=''
    input=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = '-o' ]; then shift; output="$1"; else input="$1"; fi
      shift
    done
    echo media >> '#{log}'
    case "$input" in
      *unconfirmed*) echo $$ > '#{pid_file}'; /bin/sleep 4; echo done > '#{root}/finished'; exit 0 ;;
      *timeout*) echo $$ > '#{pid_file}'; exec /bin/sleep 5 ;;
      *missing*) exit 0 ;;
      *unreadable*) mkdir "$output"; exit 0 ;;
      *cleanupfail*) printf '{}' > "$output"; chmod 500 "$(dirname "$output")"; exit 0 ;;
      *invalid*) printf 'not-json' > "$output"; exit 0 ;;
      *notobject*) printf '[]' > "$output"; exit 0 ;;
      *nonzero*) printf '{"streams":[{"codec_type":"video","width":100,"height":180}],"format":{"duration":"1.0"}}' > "$output"; echo 'genuine-probe-error' >&2; exit 7 ;;
      *first*) width=320 ;;
      *second*) width=640 ;;
      *) width=100 ;;
    esac
    echo 'warning emitted on stderr' >&2
    printf '{"streams":[{"codec_type":"video","width":%s,"height":180}],"format":{"duration":"1.0"}}' "$width" > "$output"
    """)

    File.chmod!(script, 0o700)
    Application.put_env(:social, :ffprobe_path, script)
    %{root: root, script: script, log: log, pid_file: pid_file}
  end

  defp restore(key, nil), do: Application.delete_env(:social, key)
  defp restore(key, value), do: Application.put_env(:social, key, value)

  defp input(root, name) do
    path = Path.join(root, name <> ".mp4")
    File.write!(path, "fixture")
    path
  end

  defp assert_clean(root), do: assert(Path.wildcard(Path.join(root, "ffprobe-*")) == [])

  test "warning does not contaminate valid output and concurrent probes remain isolated", %{
    root: root
  } do
    results =
      ["first", "second"]
      |> Enum.map(fn name ->
        Task.async(fn -> Ffmpeg.probe_owned(input(root, name), 2_000) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert [{:ok, %{width: 320}}, {:ok, %{width: 640}}] = results
    assert_clean(root)
  end

  test "successful probe preserves warnings in the log", %{root: root} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{width: 100}} = Ffmpeg.probe_owned(input(root, "ordinary"), 2_000)
      end)

    assert log =~ "ffprobe emitted diagnostics"
    refute log =~ "warning emitted on stderr"
    assert_clean(root)
  end

  test "failed private directory allocation refuses without running the media probe", %{
    root: root,
    log: log
  } do
    not_directory = Path.join(root, "not-a-directory")
    File.write!(not_directory, "fixture")
    Application.put_env(:social, :render_tmp_dir, not_directory)
    assert {:error, reason} = Ffmpeg.probe_owned(input(root, "ordinary"), 2_000)
    assert reason =~ "temporary directory unavailable"
    assert File.read!(log) |> String.split("\n", trim: true) == ["help"]
    assert_clean(root)
  end

  test "missing or invalid output is refused and cleaned", %{root: root} do
    for name <- ["missing", "unreadable", "invalid", "notobject"] do
      assert {:error, _} = Ffmpeg.probe_owned(input(root, name), 2_000)
      assert_clean(root)
    end
  end

  test "confirmed exit with output cleanup failure reports a private obligation", %{root: root} do
    owned = input(root, "cleanupfail")
    assert {:error, {:probe_lifecycle, details}} = unprivileged_cleanup_probe(root, owned)
    assert %{child_exit: :confirmed, input_used?: true, output_dir: dir} = details
    assert File.regular?(owned)
    assert File.dir?(dir)
    File.chmod!(dir, 0o700)
    File.rm_rf!(dir)
  end

  # Root can remove a 0500 directory. Run the real probe/cleanup in a
  # short-lived unprivileged VM, with only this fixture's files writable.
  # No probe result or filesystem operation is mocked.
  defp unprivileged_cleanup_probe(root, owned) do
    code_dir = Path.join(root, "child-code")
    File.mkdir!(code_dir)

    for module <- [Ffmpeg, Platform.Social.Toolchain | Application.spec(:jason, :modules)] do
      {^module, beam, _} = :code.get_object_code(module)
      File.write!(Path.join(code_dir, Atom.to_string(module) <> ".beam"), beam)
    end

    marker = Path.join(root, "child-exit-unconfirmed")
    File.write!(marker, "Retain fixture input unless the child confirms probe exit.")
    python = System.find_executable("python3")
    elixir = System.find_executable("elixir")
    assert is_binary(python) and is_binary(elixir)

    launcher = """
    import os, pwd, sys
    root, executable, *args = sys.argv[1:]
    if os.geteuid() == 0:
        user = pwd.getpwnam('nobody')
        for directory, dirs, files in os.walk(root):
            os.chown(directory, user.pw_uid, user.pw_gid)
            for name in files:
                os.chown(os.path.join(directory, name), user.pw_uid, user.pw_gid)
        os.setgroups([])
        os.setgid(user.pw_gid)
        os.setuid(user.pw_uid)
    if os.geteuid() == 0:
        raise RuntimeError('cleanup fixture must not run as root')
    os.execv(executable, [executable, *args])
    """

    child = """
    [root, owned] = System.argv()
    Application.put_env(:social, :render_tmp_dir, root)
    Application.put_env(:social, :ffprobe_path, Path.join(root, "fake-ffprobe"))
    result = Platform.Social.Renderer.Ffmpeg.probe_owned(owned, 2_000)
    IO.puts("OWNED_PROBE_RESULT:" <> Base.encode64(:erlang.term_to_binary(result)))
    """

    supervisor = start_supervised!({Task.Supervisor, []})

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        System.cmd(
          python,
          [
            "-c",
            launcher,
            root,
            elixir,
            "--erl",
            "+S 2:2",
            "-pa",
            code_dir,
            "-e",
            child,
            "--",
            root,
            owned
          ],
          stderr_to_stdout: true
        )
      end)

    try do
      assert {:ok, {output, 0}} = Task.yield(task, 15_000)
      assert [_, encoded] = Regex.run(~r/^OWNED_PROBE_RESULT:(.+)$/m, output)
      result = encoded |> String.trim() |> Base.decode64!() |> :erlang.binary_to_term([:safe])
      assert {:error, {:probe_lifecycle, %{child_exit: :confirmed}}} = result
      File.rm!(marker)
      result
    after
      # A killed launcher cannot attest to its OS child's exit. In that case
      # leave the marker, so the fixture's on_exit retains its input too.
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "nonzero remains refusal with diagnostic even if output is valid", %{root: root, log: log} do
    assert {:error, reason} = Ffmpeg.probe_owned(input(root, "nonzero"), 2_000)
    assert reason =~ "exit 7"
    assert reason =~ "genuine-probe-error"
    assert File.read!(log) |> String.split("\n", trim: true) == ["help", "media"]
    assert_clean(root)
  end

  test "unsupported capability uses the original stdout path", %{root: root, script: script} do
    File.write!(
      script,
      "#!/bin/sh\nif [ \"$1\" = \"-h\" ]; then echo '-output <output_file>'; exit 0; fi\necho legacy-invoked >&2; exit 8\n"
    )

    assert {:error, reason} = Ffmpeg.probe_owned(input(root, "legacy"), 2_000)
    assert reason =~ "exit 8"
    assert reason =~ "legacy-invoked"
    assert_clean(root)
  end

  test "unsupported capability accepts clean legacy JSON", %{root: root, script: script} do
    fake_bin = Path.join(root, "clean-bin")
    File.mkdir!(fake_bin)
    fake_nice = Path.join(fake_bin, "nice")
    nice_log = Path.join(root, "nice-calls")
    File.write!(fake_nice, "#!/bin/sh\necho nice >> '#{nice_log}'\nshift 2\nexec \"$@\"\n")
    File.chmod!(fake_nice, 0o700)
    prior_path = System.fetch_env!("PATH")
    System.put_env("PATH", fake_bin <> ":" <> prior_path)
    on_exit(fn -> System.put_env("PATH", prior_path) end)

    File.write!(script, """
    #!/bin/sh
    if [ "$1" = "-h" ]; then echo 'no output option'; exit 0; fi
    printf '{"streams":[{"codec_type":"video","width":222,"height":180}],"format":{"duration":"1.0"}}'
    """)

    assert {:ok, %{width: 222}} = Ffmpeg.probe_owned(input(root, "legacy-clean"), 2_000)
    assert File.read!(nice_log) |> String.split("\n", trim: true) == ["nice", "nice"]
    assert_clean(root)
  end

  test "nonzero capability help falls back to clean legacy success", %{
    root: root,
    script: script,
    log: log
  } do
    fake_bin = Path.join(root, "clean-bin")
    File.mkdir!(fake_bin)
    fake_nice = Path.join(fake_bin, "nice")
    File.write!(fake_nice, "#!/bin/sh\nshift 2\nexec \"$@\"\n")
    File.chmod!(fake_nice, 0o700)
    prior_path = System.fetch_env!("PATH")
    System.put_env("PATH", fake_bin <> ":" <> prior_path)
    on_exit(fn -> System.put_env("PATH", prior_path) end)

    File.write!(script, """
    #!/bin/sh
    if [ "$1" = "-h" ]; then echo help >> '#{log}'; exit 4; fi
    echo media >> '#{log}'
    printf '{"streams":[{"codec_type":"video","width":333,"height":180}],"format":{"duration":"1.0"}}'
    """)

    assert {:ok, %{width: 333}} = Ffmpeg.probe_owned(input(root, "help-nonzero"), 2_000)
    assert File.read!(log) |> String.split("\n", trim: true) == ["help", "media"]
    assert_clean(root)
  end

  test "unsupported capability retains merged-output warning limitation", %{
    root: root,
    script: script
  } do
    File.write!(script, """
    #!/bin/sh
    if [ "$1" = "-h" ]; then echo 'no output file option'; exit 0; fi
    echo 'fixture warning' >&2
    printf '{"streams":[{"codec_type":"video","width":222,"height":180}],"format":{"duration":"1.0"}}'
    """)

    assert {:error, "ffprobe returned unreadable output"} =
             Ffmpeg.probe_owned(input(root, "legacy-valid"), 2_000)

    assert_clean(root)
  end

  test "legacy transport confirms termination on media timeout", %{
    root: root,
    script: script,
    pid_file: pid_file
  } do
    File.write!(script, """
    #!/bin/sh
    if [ "$1" = "-h" ]; then echo 'no output option'; exit 0; fi
    echo $$ > '#{pid_file}'
    exec /bin/sleep 5
    """)

    owned = input(root, "legacy-timeout")
    assert {:error, reason} = Ffmpeg.probe_owned(owned, 500)
    assert is_binary(reason) and reason =~ "timed out"
    assert File.regular?(owned)
    pid = File.read!(pid_file) |> String.trim()

    {output, status} =
      System.cmd("kill", ["-0", pid], stderr_to_stdout: true, env: [{"LC_ALL", "C"}])

    assert status != 0
    assert output =~ "No such process"
    assert_clean(root)
  end

  test "legacy transport retains input when termination is unconfirmed", %{
    root: root,
    script: script
  } do
    fake_bin = Path.join(root, "fake-bin")
    File.mkdir!(fake_bin)
    fake_kill = Path.join(fake_bin, "kill")
    File.write!(fake_kill, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake_kill, 0o700)
    prior_path = System.fetch_env!("PATH")
    System.put_env("PATH", fake_bin <> ":" <> prior_path)

    on_exit(fn ->
      System.put_env("PATH", prior_path)
      System.cmd("/bin/sleep", ["4"])
    end)

    File.write!(script, """
    #!/bin/sh
    if [ "$1" = "-h" ]; then echo 'no output option'; exit 0; fi
    /bin/sleep 4
    echo done > '#{root}/finished'
    """)

    owned = input(root, "legacy-unconfirmed")
    assert {:error, {:probe_lifecycle, details}} = Ffmpeg.probe_owned(owned, 200)
    assert %{child_exit: :unconfirmed, input_used?: true, output_dir: nil} = details
    assert File.regular?(owned)
    refute File.exists?(Path.join(root, "finished"))
    assert_clean(root)
  end

  test "unconfirmed termination retains the owned input and output directory", %{root: root} do
    fake_bin = Path.join(root, "fake-bin")
    File.mkdir!(fake_bin)
    fake_kill = Path.join(fake_bin, "kill")
    File.write!(fake_kill, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake_kill, 0o700)
    prior_path = System.fetch_env!("PATH")
    System.put_env("PATH", fake_bin <> ":" <> prior_path)

    on_exit(fn ->
      System.put_env("PATH", prior_path)
      # The fixture exits naturally; never delete its input while it can run.
      System.cmd("/bin/sleep", ["4"])
    end)

    owned = input(root, "unconfirmed")
    assert {:error, {:probe_lifecycle, details}} = Ffmpeg.probe_owned(owned, 200)
    assert %{child_exit: :unconfirmed, input_used?: true, output_dir: dir} = details
    assert File.regular?(owned)
    assert File.dir?(dir)
    refute File.exists?(Path.join(root, "finished"))
  end

  test "unconfirmed capability process refuses before media execution", %{
    root: root,
    script: script,
    log: log
  } do
    fake_bin = Path.join(root, "fake-bin")
    File.mkdir!(fake_bin)
    fake_kill = Path.join(fake_bin, "kill")
    File.write!(fake_kill, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake_kill, 0o700)
    prior_path = System.fetch_env!("PATH")
    System.put_env("PATH", fake_bin <> ":" <> prior_path)

    on_exit(fn ->
      System.put_env("PATH", prior_path)
      System.cmd("/bin/sleep", ["3"])
    end)

    File.write!(script, """
    #!/bin/sh
    if [ "$1" = "-h" ]; then /bin/sleep 8; exit 0; fi
    echo media >> '#{log}'
    exit 0
    """)

    owned = input(root, "help-unconfirmed")
    assert {:error, {:probe_lifecycle, details}} = Ffmpeg.probe_owned(owned, 2_000)
    assert %{child_exit: :unconfirmed, input_used?: false, output_dir: nil} = details
    assert File.regular?(owned)
    refute File.exists?(log)
    assert_clean(root)
  end

  test "an oversized help response is not treated as established capability", %{
    root: root,
    script: script
  } do
    File.write!(script, """
    #!/bin/sh
    if [ "$1" = "-h" ]; then
      echo '-o <output_file>'
      head -c 300000 /dev/zero
      exit 0
    fi
    echo oversized-help-legacy >&2
    exit 8
    """)

    assert {:error, reason} = Ffmpeg.probe_owned(input(root, "legacy"), 2_000)
    assert reason =~ "exit 8"
    assert reason =~ "oversized-help-legacy"
    assert_clean(root)
  end

  test "timeout reaps the running child before cleaning its output directory", %{
    root: root,
    pid_file: pid_file
  } do
    assert {:error, reason} = Ffmpeg.probe_owned(input(root, "timeout"), 500)
    assert reason =~ "timed out"
    pid = File.read!(pid_file) |> String.trim()

    {output, status} =
      System.cmd("kill", ["-0", pid], stderr_to_stdout: true, env: [{"LC_ALL", "C"}])

    assert status != 0
    assert output =~ "No such process"
    assert_clean(root)
  end
end
