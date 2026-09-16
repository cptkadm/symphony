defmodule SymphonyElixir.WorkspaceLockTest do
  use SymphonyElixir.TestSupport

  test "a competing workspace creator cannot enter an active creation hook" do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces")
    ready = Path.join(Path.dirname(root), "ready")
    gate = Path.join(Path.dirname(root), "gate")
    {_, 0} = System.cmd("mkfifo", [gate])

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_create: "touch '#{ready}'; cat '#{gate}'",
      hook_timeout_ms: 5_000
    )

    first = Task.async(fn -> Workspace.create_for_issue("LOCK-1") end)
    wait_until(fn -> File.exists?(ready) end)
    second = Workspace.create_for_issue("LOCK-1")
    File.write!(gate, "release\n")
    assert {:ok, _} = Task.await(first)
    assert {:error, {:workspace_locked, _owner}} = second
  end

  alias SymphonyElixir.WorkspaceLock

  test "OS owners contend, independent paths coexist, and release preserves stale metadata safely" do
    workspace = lock_path("OS-1")
    {first, owner} = start_holder(workspace)
    assert owner["owner_pid"] == System.pid()
    assert owner["issue_identifier"] == "OS-1"
    assert is_binary(owner["host"])
    assert is_binary(owner["acquired_at"])
    assert owner["orchestrator_instance_id"] == "external-test"

    assert {:error, {:workspace_locked, ^owner}} = WorkspaceLock.with_lock(workspace, "OS-1", nil, fn -> flunk("entered") end)
    assert :independent = WorkspaceLock.with_lock(lock_path("OS-2"), "OS-2", nil, fn -> :independent end)
    release_holder(first)
    assert :reacquired = WorkspaceLock.with_lock(workspace, "OS-1", nil, fn -> :reacquired end)
  end

  test "a losing worker starts neither Codex nor any lifecycle hook or deletion" do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces")
    marker = Path.join(root, "unexpected")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      codex_command: "touch '#{marker}'",
      hook_after_create: "touch '#{marker}'",
      hook_before_run: "touch '#{marker}'",
      hook_after_run: "touch '#{marker}'",
      hook_before_remove: "touch '#{marker}'"
    )

    issue = %Issue{id: "locked-issue", identifier: "OS-1", title: "Lock test", state: "Todo"}
    workspace = Path.join(root, Workspace.workspace_key(issue))
    {holder, owner} = start_holder(workspace)

    try do
      assert_raise RuntimeError, ~r/workspace_locked/, fn -> AgentRunner.run(issue) end
      refute File.exists?(workspace)
      File.mkdir_p!(workspace)
      sentinel = Path.join(workspace, "preserve")
      File.write!(sentinel, "original")
      assert {:error, {:workspace_locked, ^owner}, ""} = Workspace.remove(workspace)
      assert File.read!(sentinel) == "original"
      refute File.exists?(marker)
    after
      release_holder(holder)
    end
  end

  test "SIGKILL releases OS ownership and corrupt metadata never grants or prevents ownership" do
    workspace = lock_path("OS-1")
    {holder, owner} = start_holder(workspace)
    System.cmd("kill", ["-KILL", to_string(owner["lock_holder_pid"])])
    assert_receive {^holder, {:exit_status, _}}, 5_000

    for path <- Path.wildcard(Path.join(Path.dirname(workspace), ".symphony-locks/*.lock")) do
      File.write!(path, "invalid stale metadata")
    end

    assert :ok = WorkspaceLock.with_lock(workspace, "OS-1", nil, fn -> :ok end)
  end

  test "worker death releases its guardian and canonical aliases share ownership" do
    workspace = lock_path("OS-1")
    File.mkdir_p!(workspace)
    alias_path = lock_path("alias")
    File.ln_s!(workspace, alias_path)
    parent = self()

    worker =
      spawn(fn ->
        WorkspaceLock.with_lock(workspace, "OS-1", nil, fn ->
          send(parent, :owned)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :owned, 5_000
    assert {:error, {:workspace_locked, _}} = WorkspaceLock.with_lock(alias_path, "OS-1", nil, fn -> flunk("entered") end)
    Process.exit(worker, :kill)
    wait_until(fn -> WorkspaceLock.with_lock(workspace, "OS-1", nil, fn -> :ok end) == :ok end)
  end

  test "a delayed command cannot mutate after its ownership was released" do
    workspace = lock_path("OS-1")

    command =
      WorkspaceLock.with_lock(workspace, "OS-1", nil, fn ->
        WorkspaceLock.command(workspace, nil, "printf unexpected")
      end)

    {output, status} = System.cmd("bash", ["-lc", command], stderr_to_stdout: true)
    assert status != 0
    refute output == "unexpected"
  end

  test "exceptions release ownership and a workflow reload keeps the prepared workspace owned" do
    workspace = lock_path("OS-1")

    assert_raise RuntimeError, "operation failed", fn ->
      WorkspaceLock.with_lock(workspace, "OS-1", nil, fn -> raise "operation failed" end)
    end

    assert :ok = WorkspaceLock.with_lock(workspace, "OS-1", nil, fn -> :ok end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))

    assert :ok =
             Workspace.with_workspace("OS-1", nil, fn prepared ->
               write_workflow_file!(Workflow.workflow_file_path(), workspace_root: lock_path("new-root"))
               assert {:ok, ^prepared} = SymphonyElixir.PathSafety.canonicalize(workspace)
               contender = Task.async(fn -> WorkspaceLock.with_lock(prepared, "OS-1", nil, fn -> flunk("entered") end) end)
               assert {:error, {:workspace_locked, _}} = Task.await(contender)
               :ok
             end)
  end

  test "unexpected holder death kills the worker before it can continue" do
    parent = self()
    workspace = lock_path("OS-1")

    worker =
      spawn(fn ->
        WorkspaceLock.with_lock(workspace, "OS-1", nil, fn ->
          send(parent, :owned)

          receive do
            :continue -> send(parent, :mutated)
          end
        end)
      end)

    ref = Process.monitor(worker)
    assert_receive :owned, 5_000
    assert {:error, {:workspace_locked, owner}} = WorkspaceLock.with_lock(workspace, "OS-1", nil, fn -> :ok end)
    System.cmd("kill", ["-KILL", to_string(owner["lock_holder_pid"])])
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 5_000
    send(worker, :continue)
    refute_received :mutated
    assert :ok = WorkspaceLock.with_lock(workspace, "OS-1", nil, fn -> :ok end)
  end

  test "an invalid lock directory fails closed before invoking the operation" do
    workspace = lock_path("OS-1")
    File.mkdir_p!(Path.dirname(workspace))
    File.write!(Path.join(Path.dirname(workspace), ".symphony-locks"), "not a directory")
    assert {:error, _} = WorkspaceLock.with_lock(workspace, "OS-1", nil, fn -> flunk("entered") end)
  end

  test "missing, malformed, truncated, exiting, and stalled helpers fail closed" do
    root = Path.dirname(Workflow.workflow_file_path())
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    previous_path = System.get_env("PATH")

    try do
      System.put_env("PATH", bin)
      result = WorkspaceLock.with_lock(lock_path("OS-1"), nil, nil, fn -> flunk("entered") end)
      assert {:error, :workspace_lock_python3_not_found} = result

      for {script, expected} <- [
            {"printf 'invalid\\n'", {:workspace_lock_failed, "invalid"}},
            {"exit 7", {:workspace_lock_exit, 7}},
            {"/usr/bin/head -c 70000 /dev/zero", :workspace_lock_invalid_response},
            {"/bin/sleep 11", :workspace_lock_timeout}
          ] do
        helper = Path.join(bin, "python3")
        File.write!(helper, "#!/bin/sh\n" <> script <> "\n")
        File.chmod!(helper, 0o755)
        assert {:error, ^expected} = WorkspaceLock.with_lock(lock_path("OS-1"), nil, nil, fn -> flunk("entered") end)
      end
    after
      restore_env("PATH", previous_path)
    end
  end

  test "closing the guardian port stops the worker even on a normal port exit" do
    parent = self()

    worker =
      spawn(fn ->
        WorkspaceLock.with_lock(lock_path("OS-1"), "OS-1", nil, fn ->
          {:links, [guardian]} = Process.info(self(), :links)
          send(guardian, :unrelated_message)
          %{port: port} = :sys.get_state(guardian)
          send(parent, {:holder_port, port})

          receive do
            :continue -> send(parent, :mutated)
          end
        end)
      end)

    ref = Process.monitor(worker)
    assert_receive {:holder_port, port}, 5_000
    Port.close(port)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 5_000
    refute_received :mutated
  end

  test "the lock namespace cannot be created or removed as an issue workspace" do
    root = Path.dirname(lock_path("OS-1"))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    reserved = Path.join(root, ".symphony-locks")
    assert {:error, {:workspace_reserved_path, _}} = Workspace.create_for_issue(".symphony-locks")
    assert {:ok, []} = Workspace.remove(reserved)
    refute File.exists?(reserved)
    assert {:error, _} = WorkspaceLock.with_lock(reserved, ".symphony-locks", nil, fn -> flunk("entered") end)
    refute File.exists?(reserved)
  end

  test "SSH command transport uses the same OS ownership as a local worker" do
    root = Path.dirname(Workflow.workflow_file_path())
    fake_ssh = Path.join(root, "ssh")
    File.write!(fake_ssh, "#!/bin/sh\nfor argument do command=$argument; done\nexec /bin/bash -c \"$command\"\n")
    File.chmod!(fake_ssh, 0o755)
    previous_path = System.get_env("PATH")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.dirname(lock_path("OS-1")),
      hook_after_create: "echo created > created",
      hook_before_remove: "echo removed > removed"
    )

    try do
      System.put_env("PATH", root <> ":" <> previous_path)

      assert :ok =
               Workspace.with_workspace("OS-1", "loopback-test", fn workspace ->
                 assert File.read!(Path.join(workspace, "created")) == "created\n"
                 result = WorkspaceLock.with_lock(workspace, "OS-1", nil, fn -> flunk("entered") end)
                 assert {:error, {:workspace_locked, _}} = result
                 :ok
               end)

      assert {:ok, []} = Workspace.remove(lock_path("OS-1"), "loopback-test")
      refute File.exists?(lock_path("OS-1"))
    after
      restore_env("PATH", previous_path)
    end
  end

  @tag timeout: 30_000
  test "two OS orchestrators polling the same issue have exactly one mutating worker" do
    root = Path.dirname(Workflow.workflow_file_path())
    ready = Path.join(root, "orchestrator-hook")
    gate = Path.join(root, "orchestrator-gate")
    {_, 0} = System.cmd("mkfifo", [gate])

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      poll_interval_ms: 60_000,
      hook_before_run: "echo writer >> '#{ready}'; cat '#{gate}'; exit 1",
      hook_timeout_ms: 20_000
    )

    first = start_orchestrator()

    try do
      wait_until(fn -> File.exists?(ready) end, 1_000)
      second = start_orchestrator()

      try do
        output = await_port_output(second, "workspace_locked")
        assert output =~ "owner_pid"
        assert output =~ "orchestrator_instance_id"
        assert File.read!(ready) == "writer\n"
        # A dead VM's still-running hook retains activity ownership until exit.
        {:os_pid, pid} = Port.info(first, :os_pid)
        System.cmd("kill", ["-KILL", to_string(pid)])
        assert_receive {^first, {:exit_status, _}}, 5_000
        assert {:error, {:workspace_locked, _}} = WorkspaceLock.with_lock(lock_path("OS-1"), "OS-1", nil, fn -> :ok end)
        File.write!(gate, "release\n")
        wait_until(fn -> WorkspaceLock.with_lock(lock_path("OS-1"), "OS-1", nil, fn -> :ok end) == :ok end)
      after
        if Port.info(second), do: Port.command(second, "stop\n")
      end
    after
      if Port.info(first), do: Port.command(first, "stop\n")
    end
  end

  defp start_orchestrator do
    code = """
    Application.ensure_all_started(:logger)
    SymphonyElixir.Workflow.set_workflow_file_path(#{inspect(Workflow.workflow_file_path())})
    issue = %SymphonyElixir.Tracker.Issue{id: "os-issue", identifier: "OS-1", title: "OS race", state: "In Progress", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    {:ok, _} = SymphonyElixir.AgentRuntimeSupervisor.start_link([])
    IO.gets("")
    System.halt(0)
    """

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

    Port.open(
      {:spawn_executable, System.find_executable("elixir")},
      [:binary, :exit_status, :stderr_to_stdout, args: paths ++ ["--eval", code]]
    )
  end

  defp await_port_output(port, expected, output \\ "") do
    if String.contains?(output, expected) do
      output
    else
      receive do
        {^port, {:data, data}} -> await_port_output(port, expected, output <> data)
        {^port, {:exit_status, status}} -> flunk("orchestrator exited #{status}: #{output}")
      after
        10_000 -> flunk("orchestrator did not report #{expected}: #{output}")
      end
    end
  end

  defp lock_path(name), do: Path.join([Path.dirname(Workflow.workflow_file_path()), "workspaces", name])

  defp start_holder(workspace) do
    metadata =
      Jason.encode!(%{
        workspace_path: workspace,
        issue_identifier: "OS-1",
        owner_pid: System.pid(),
        orchestrator_instance_id: "external-test",
        attempt_id: "external-attempt"
      })

    script = Path.expand("../../priv/workspace_lock.py", __DIR__)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("python3")},
        [:binary, :exit_status, line: 65_536, args: ["-I", "-u", script, metadata]]
      )

    assert_receive {^port, {:data, {:eol, line}}}, 5_000
    assert %{"status" => "acquired", "owner" => owner} = Jason.decode!(line)
    {port, owner}
  end

  defp release_holder(port) do
    Port.command(port, "release\n")
    assert_receive {^port, {:exit_status, 0}}, 5_000
  end

  defp wait_until(condition, attempts \\ 200)
  defp wait_until(condition, 0), do: assert(condition.())

  defp wait_until(condition, attempts) do
    unless condition.() do
      Process.sleep(10)
      wait_until(condition, attempts - 1)
    end
  end
end
