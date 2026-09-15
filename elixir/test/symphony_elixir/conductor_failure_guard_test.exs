defmodule SymphonyElixir.ConductorFailureGuardTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Tracker.Issue

  test "turn/completed with failed status is a hard turn failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-completed-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FAILED")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) ;;
          3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-failed"}}}' ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-failed"}}}'
            printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"turn-failed","status":"failed"},"error":{"message":"model turn failed"}}}'
            ;;
          *) exit 0 ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-failed",
        identifier: "MT-FAILED",
        title: "Failed terminal turn",
        description: "Regression coverage",
        state: "In Progress",
        url: "https://example.org/issues/MT-FAILED",
        labels: ["backend"]
      }

      owner = self()

      assert {:error, {:turn_failed, params}} =
               AppServer.run(workspace, "trigger failure", issue, on_message: fn message -> send(owner, {:codex_event, message}) end)

      assert get_in(params, ["turn", "status"]) == "failed"
      assert_receive {:codex_event, %{event: :turn_failed}}
      refute_receive {:codex_event, %{event: :turn_ended_with_error}}
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal turn failure blocks instead of retrying" do
    issue_id = "issue-terminal-failure"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-TERM",
      title: "Terminal failure",
      description: "Do not retry terminal task failure",
      state: "In Progress",
      url: "https://example.org/issues/MT-TERM",
      labels: ["backend"]
    }

    running_entry = %{
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: "/tmp/MT-TERM",
      session_id: "thread-turn",
      last_codex_event: :turn_failed,
      last_codex_message: nil,
      last_codex_timestamp: DateTime.utc_now(),
      retry_attempt: 0
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      blocked: %{},
      retry_attempts: %{}
    }

    updated =
      Orchestrator.handle_agent_down_for_test(
        {:shutdown, :turn_failed},
        state,
        issue_id,
        running_entry,
        running_entry.session_id
      )

    assert updated.retry_attempts == %{}
    assert updated.blocked[issue_id].error == "codex turn failed"
  end

  test "transient failures get one automatic retry and then block" do
    issue_id = "issue-transient-failure"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-TRANSIENT",
      title: "Transient failure",
      description: "Retry once",
      state: "In Progress",
      url: "https://example.org/issues/MT-TRANSIENT",
      labels: ["backend"]
    }

    base_entry = %{
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: "/tmp/MT-TRANSIENT",
      session_id: "thread-turn",
      last_codex_event: :turn_ended_with_error,
      last_codex_message: nil,
      last_codex_timestamp: DateTime.utc_now()
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new([issue_id]),
      blocked: %{},
      retry_attempts: %{}
    }

    retried =
      Orchestrator.handle_agent_down_for_test(
        {:shutdown, :turn_timeout},
        state,
        issue_id,
        Map.put(base_entry, :retry_attempt, 0),
        base_entry.session_id
      )

    assert retried.retry_attempts[issue_id].attempt == 1
    refute Map.has_key?(retried.blocked, issue_id)
    Process.cancel_timer(retried.retry_attempts[issue_id].timer_ref)

    exhausted =
      Orchestrator.handle_agent_down_for_test(
        {:shutdown, :turn_timeout},
        %{state | retry_attempts: %{}},
        issue_id,
        Map.put(base_entry, :retry_attempt, 1),
        base_entry.session_id
      )

    assert exhausted.retry_attempts == %{}
    assert exhausted.blocked[issue_id].error =~ "failed after 1 automatic retry"
  end
end
