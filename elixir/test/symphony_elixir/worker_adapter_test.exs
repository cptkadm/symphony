defmodule SymphonyElixir.WorkerAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Worker.Codex

  test "Codex overload is provider capacity, not an implementation failure" do
    result = Codex.classify({:turn_failed, %{"error" => %{"codexErrorInfo" => "serverOverloaded"}}})
    assert result.class == :provider_capacity
  end

  alias SymphonyElixir.Worker
  alias SymphonyElixir.Worker.Result

  defmodule Fake do
    @behaviour Worker
    def identity, do: %{provider: "fake", model: "test", harness: "one-shot"}
    def capabilities, do: %{conversation: false, resume: false, usage: false, quota: false}

    def start(context) do
      send(Process.get(:observer, self()), {:started, context})

      case Process.get(:start_result, :ok) do
        :ok -> {:ok, :opaque}
        result -> result
      end
    end

    def run(:opaque, context, on_update) do
      send(Process.get(:observer, self()), {:ran, context})
      on_update.(%{event: :progress, timestamp: DateTime.utc_now()})
      File.write!(Path.join(context.workspace, "valid-work"), "preserve this implementation")

      case Process.get(:result, %Result{class: :success}) do
        :wait ->
          observer = Process.get(:observer)

          child =
            spawn_link(fn ->
              receive do
                :stop -> :ok
              end
            end)

          send(observer, {:mutating_child, child})

          receive do
            :finish -> %Result{class: :success}
          end

        :raise ->
          raise "malformed provider behavior"

        result ->
          result
      end
    end

    def stop(:opaque) do
      send(Process.get(:observer, self()), :stopped)
      :ok
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "worker-contract-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    on_exit(fn -> File.rm_rf!(root) end)
    issue = %Issue{id: "adapter-issue", identifier: "GH-11", title: "Worker contract", state: "In Progress", dispatchable: true}
    %{issue: issue}
  end

  test "one-shot adapter uses the common runner and gets fresh bounded context", %{issue: issue} do
    assert :ok = AgentRunner.run(issue, self(), worker_adapter: Fake, max_turns: 2, branch: "issue-branch", issue_state_fetcher: fn _ -> {:ok, [issue]} end)
    assert_receive {:started, %{branch: "issue-branch", max_turns: 2} = context}
    assert Map.keys(context) |> Enum.sort() == [:branch, :issue, :max_turns, :prompt, :turn, :worker_host, :workspace]
    assert_receive {:ran, %{turn: 1, prompt: first}}
    assert_receive {:ran, %{turn: 2, prompt: second}}
    assert first == second
    assert_receive {:worker_identity, "adapter-issue", _, %{provider: "fake"}, %{conversation: false, resume: false}}
    assert_receive {:worker_result, "adapter-issue", _, %Result{class: :success, session_id: nil}}
    assert_receive :stopped
  end

  for class <- [:provider_capacity, :rate_limited, :transport_failure, :cancelled, :authentication_failure, :input_required, :implementation_failure, :unknown_failure] do
    test "#{class} preserves valid local work and stops the handle", %{issue: issue} do
      Process.put(:result, %Result{class: unquote(class)})
      assert_raise RuntimeError, fn -> AgentRunner.run(issue, self(), worker_adapter: Fake) end
      assert_receive {:started, context}
      assert File.read!(Path.join(context.workspace, "valid-work")) == "preserve this implementation"
      assert_receive :stopped
      assert_receive {:worker_result, "adapter-issue", _, %Result{class: unquote(class)}}
    end
  end

  test "malformed results fail closed and cleanup still runs", %{issue: issue} do
    for result <- [:ok, %{class: :success}, %Result{class: :invented}, %Result{class: :success, retry_at_ms: -1}] do
      Process.put(:result, result)
      assert_raise RuntimeError, ~r/unknown_failure/, fn -> AgentRunner.run(issue, self(), worker_adapter: Fake) end
      assert_receive :stopped
      assert_receive {:worker_result, "adapter-issue", _, %Result{class: :unknown_failure}}
    end
  end

  test "malformed startup cannot report success", %{issue: issue} do
    Process.put(:start_result, :ok_but_no_handle)
    assert_raise RuntimeError, ~r/unknown_failure/, fn -> AgentRunner.run(issue, self(), worker_adapter: Fake) end
    refute_receive {:ran, _}
    refute_receive :stopped
  end

  test "cancellation kills owned resources and permits safe workspace reuse", %{issue: issue} do
    observer = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:observer, observer)
        Process.put(:result, :wait)
        AgentRunner.run(issue, observer, worker_adapter: Fake)
      end)

    assert_receive {:mutating_child, child}, 5_000
    child_ref = Process.monitor(child)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert_receive {:DOWN, ^child_ref, :process, ^child, :killed}
    assert_receive {:started, context}
    assert File.read!(Path.join(context.workspace, "valid-work")) == "preserve this implementation"
    assert :ok = AgentRunner.run(issue, nil, worker_adapter: Fake, issue_state_fetcher: fn _ -> {:ok, []} end)
  end

  test "scheduler ignores stale terminal reports and handles overload independently of Codex events", %{issue: issue} do
    entry = %{pid: self(), identifier: issue.identifier, issue: issue, retry_attempt: 4, workspace_path: "/test/workspace", last_codex_event: :turn_failed}
    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    stale = spawn(fn -> :ok end)
    assert {:noreply, ^state} = Orchestrator.handle_info({:worker_result, issue.id, stale, %Result{class: :success}}, state)
    {:noreply, updated} = Orchestrator.handle_info({:worker_result, issue.id, self(), %Result{class: :provider_capacity}}, state)
    retried = Orchestrator.handle_agent_down_for_test(:normal, updated, issue.id, updated.running[issue.id], nil)
    assert retried.blocked == %{}
    assert retried.retry_attempts[issue.id].workspace_path == "/test/workspace"
    assert retried.retry_attempts[issue.id].error == "worker: provider_capacity"
    Process.cancel_timer(retried.retry_attempts[issue.id].timer_ref)
  end

  test "quota suspension honors retry time and never claims completion", %{issue: issue} do
    state = %Orchestrator.State{claimed: MapSet.new([issue.id])}
    result = %Result{class: :rate_limited, retry_at_ms: System.system_time(:millisecond) + 60_000}
    entry = %{identifier: issue.identifier, issue: issue, worker_result: result, retry_attempt: 0}
    before = System.monotonic_time(:millisecond)
    updated = Orchestrator.handle_agent_down_for_test(:normal, state, issue.id, entry, nil)
    assert updated.retry_attempts[issue.id].due_at_ms >= before + 59_000
    refute MapSet.member?(updated.completed, issue.id)
    Process.cancel_timer(updated.retry_attempts[issue.id].timer_ref)
    blocked = Orchestrator.handle_agent_down_for_test(:normal, state, issue.id, %{entry | worker_result: %Result{class: :rate_limited}}, nil)
    assert blocked.retry_attempts == %{}
    assert blocked.blocked[issue.id].error =~ "rate_limited"
  end

  test "structured Codex classes include startup overload, quota, auth and transport" do
    assert Codex.classify({:response_error, %{"code" => -32001}}).class == :provider_capacity

    for {info, class} <- [
          {"usageLimitExceeded", :rate_limited},
          {"unauthorized", :authentication_failure},
          {%{"responseStreamDisconnected" => %{"httpStatusCode" => 502}}, :transport_failure},
          {"futureError", :unknown_failure}
        ] do
      assert Codex.classify({:turn_failed, %{"turn" => %{"error" => %{"codexErrorInfo" => info}}}}).class == class
    end

    assert Codex.classify({:turn_failed, %{"error" => %{"message" => "serverOverloaded"}}}).class == :implementation_failure
  end
end
