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

  test "one-shot adapter uses common runner and gets fresh bounded context",
       %{issue: issue} do
    assert :ok =
             AgentRunner.run(issue, self(),
               worker_adapter: Fake,
               max_turns: 2,
               branch: "issue-branch",
               issue_state_fetcher: fn _ -> {:ok, [issue]} end
             )

    assert_receive {:started, %{branch: "issue-branch", max_turns: 2} = context}
    assert Map.keys(context) |> Enum.sort() == [:branch, :issue, :max_turns, :prompt, :turn, :worker_host, :workspace]
    assert_receive {:ran, %{turn: 1, prompt: first}}
    assert_receive {:ran, %{turn: 2, prompt: second}}
    assert first == second
    assert_receive {:worker_identity, "adapter-issue", _, %{provider: "fake"}, %{conversation: false, resume: false}}
    assert_receive {:worker_result, "adapter-issue", _, %Result{class: :success, session_id: nil}}
    assert_receive :stopped
  end

  @worker_classes [
    :provider_capacity,
    :rate_limited,
    :transport_failure,
    :cancelled,
    :authentication_failure,
    :input_required,
    :implementation_failure,
    :unknown_failure
  ]

  for class <- @worker_classes do
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
    malformed_results = [
      :ok,
      %{class: :success},
      %Result{class: :invented},
      %Result{class: :success, retry_at_ms: -1}
    ]

    for result <- malformed_results do
      Process.put(:result, result)

      assert_raise RuntimeError, ~r/unknown_failure/, fn ->
        AgentRunner.run(issue, self(), worker_adapter: Fake)
      end

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

  test "scheduler ignores stale terminal reports and handles overload independently of Codex events",
       %{issue: issue} do
    entry = %{
      pid: self(),
      identifier: issue.identifier,
      issue: issue,
      retry_attempt: 4,
      workspace_path: "/test/workspace",
      last_codex_event: :turn_failed
    }

    state = %Orchestrator.State{running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    stale = spawn(fn -> :ok end)

    assert {:noreply, ^state} =
             Orchestrator.handle_info({:worker_result, issue.id, stale, %Result{class: :success}}, state)

    {:noreply, updated} =
      Orchestrator.handle_info(
        {:worker_result, issue.id, self(), %Result{class: :provider_capacity}},
        state
      )

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

    blocked =
      Orchestrator.handle_agent_down_for_test(
        :normal,
        state,
        issue.id,
        %{entry | worker_result: %Result{class: :rate_limited}},
        nil
      )

    assert blocked.retry_attempts == %{}
    assert blocked.blocked[issue.id].error =~ "rate_limited"
  end

  test "structured Codex classes include startup overload, quota, auth and transport" do
    assert Codex.classify({:response_error, %{"code" => -32_001}}).class == :provider_capacity

    for {info, class} <- [
          {"usageLimitExceeded", :rate_limited},
          {"unauthorized", :authentication_failure},
          {%{"responseStreamDisconnected" => %{"httpStatusCode" => 502}}, :transport_failure},
          {"futureError", :unknown_failure}
        ] do
      turn_error = {:turn_failed, %{"turn" => %{"error" => %{"codexErrorInfo" => info}}}}
      assert Codex.classify(turn_error).class == class
    end

    overloaded_error = {:turn_failed, %{"error" => %{"message" => "serverOverloaded"}}}
    assert Codex.classify(overloaded_error).class == :implementation_failure
  end

  alias SymphonyElixir.Worker.CodexTelemetry

  test "normalizes valid results with metadata" do
    result = %Result{class: :success, session_id: "s1", usage: %{input_tokens: 10}, quota: %{limit: 100}}
    assert Result.normalize(result) == result
  end

  test "normalizes invalid metadata fields to fallback" do
    assert Result.normalize(%Result{class: :success, session_id: 123}) == %Result{}
    assert Result.normalize(%Result{class: :success, usage: "invalid"}) == %Result{}
    assert Result.normalize(%Result{class: :success, quota: 456}) == %Result{}
  end

  test "Worker boundary start and run exception handling" do
    defmodule FailingAdapter do
      @behaviour Worker
      def identity, do: %{provider: "fail", model: nil, harness: "fail"}
      def capabilities, do: %{conversation: false, resume: false, usage: false, quota: false}
      def start(_), do: raise("start error")
      def run(_, _, _), do: raise("run error")
      def stop(_), do: :ok
    end

    defmodule ErrorResultAdapter do
      @behaviour Worker
      def identity, do: %{provider: "err", model: nil, harness: "err"}
      def capabilities, do: %{conversation: false, resume: false, usage: false, quota: false}
      def start(_), do: {:error, %Result{class: :provider_capacity}}
      def run(_, _, _), do: %Result{class: :rate_limited}
      def stop(_), do: :ok
    end

    assert {:error, %Result{class: :unknown_failure}} = Worker.start(FailingAdapter, %{})
    assert %Result{class: :unknown_failure} = Worker.run(FailingAdapter, :handle, %{}, fn _ -> :ok end)
    assert {:error, %Result{class: :provider_capacity}} = Worker.start(ErrorResultAdapter, %{})
  end

  test "Codex adapter start, stop, and error classification" do
    invalid_context = %{
      workspace: "/nonexistent/symphony/path",
      worker_host: nil,
      prompt: "p",
      issue: %Issue{id: "1", identifier: "GH-1"}
    }

    assert {:error, %Result{}} = Codex.start(invalid_context)
    port = Port.open({:spawn, "true"}, [])
    assert :ok = Codex.stop(%{port: port})
  end

  test "Codex adapter identity, capabilities, and full error classification" do
    assert Codex.identity() == %{provider: "openai", model: nil, harness: "codex-app-server"}
    assert Codex.capabilities() == %{conversation: true, resume: false, usage: true, quota: true}

    assert Codex.classify({:turn_input_required, %{}}).class == :input_required
    assert Codex.classify({:approval_required, %{}}).class == :input_required
    assert Codex.classify({:turn_cancelled, %{}}).class == :cancelled
    assert Codex.classify({:port_exit, 1}).class == :transport_failure
    assert Codex.classify(:turn_timeout).class == :transport_failure
    assert Codex.classify(:response_timeout).class == :transport_failure
    assert Codex.classify({:response_error, %{"other" => "err"}}).class == :unknown_failure
    assert Codex.classify({:turn_failed, %{"other" => "err"}}).class == :implementation_failure
    assert Codex.classify(:other_reason).class == :unknown_failure

    for info <- [
          "sessionBudgetExceeded",
          "httpConnectionFailed",
          "responseStreamConnectionFailed",
          "responseTooManyFailedAttempts",
          "contextWindowExceeded",
          "sandboxError",
          "badRequest"
        ] do
      assert Codex.classify({:turn_failed, %{"codexErrorInfo" => info}}).class in [
               :rate_limited,
               :transport_failure,
               :implementation_failure
             ]
    end

    assert Codex.classify({:turn_failed, %{"codexErrorInfo" => %{"nested" => "err"}}}).class ==
             :unknown_failure
  end

  test "CodexTelemetry normalizes telemetry updates with usage and quota" do
    update = %{
      event: :turn_completed,
      payload: %{
        "method" => "turn/completed",
        "usage" => %{"input_tokens" => "100", "output_tokens" => 50, "total_tokens" => 150},
        "rate_limits" => %{"limit_id" => "daily", "primary" => %{}}
      }
    }

    normalized = CodexTelemetry.normalize(update)
    assert normalized.worker_usage == %{input: 100, output: 50, total: 150}
    assert normalized.worker_quota == %{"limit_id" => "daily", "primary" => %{}}
  end

  test "CodexTelemetry extracts token usage from turn completed payloads" do
    update1 = %{
      "method" => "turn/completed",
      "usage" => %{"input_tokens" => 100, "output_tokens" => 50, "total_tokens" => 150}
    }

    assert CodexTelemetry.extract_token_usage(update1) == %{
             "input_tokens" => 100,
             "output_tokens" => 50,
             "total_tokens" => 150
           }

    update2 = %{
      payload: %{
        "method" => "turn/completed",
        "params" => %{
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
        }
      }
    }

    assert CodexTelemetry.extract_token_usage(update2) == %{
             "prompt_tokens" => 10,
             "completion_tokens" => 20,
             "total_tokens" => 30
           }

    update3 = %{
      "tokenUsage" => %{
        "total" => %{"inputTokens" => 5, "outputTokens" => 5, "totalTokens" => 10}
      }
    }

    assert CodexTelemetry.extract_token_usage(update3) == %{
             "inputTokens" => 5,
             "outputTokens" => 5,
             "totalTokens" => 10
           }

    update4 = %{
      "method" => "turn/completed",
      "usage" => %{"input_tokens" => "invalid_num", "output_tokens" => -5, "total_tokens" => 10.5}
    }

    assert CodexTelemetry.extract_token_usage(update4) == %{}
    assert CodexTelemetry.extract_token_usage(%{}) == %{}
    assert CodexTelemetry.extract_rate_limits(%{}) == nil
  end
end
