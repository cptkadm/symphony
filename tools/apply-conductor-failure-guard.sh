#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

python3 <<'PY'
from pathlib import Path

root = Path.cwd()
app = root / "elixir/lib/symphony_elixir/codex/app_server.ex"
orch = root / "elixir/lib/symphony_elixir/orchestrator.ex"
test = root / "elixir/test/symphony_elixir/conductor_failure_guard_test.exs"

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)

app_text = app.read_text()
app_text = replace_once(
    app_text,
    '''          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")
            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
''',
    '''          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")
            maybe_emit_turn_ended_with_error(on_message, session_id, reason, metadata)

            {:error, reason}
''',
    "app_server error emission",
)

app_text = replace_once(
    app_text,
    '''  @spec stop_session(session()) :: :ok
''',
    '''  defp maybe_emit_turn_ended_with_error(on_message, session_id, reason, metadata) do
    unless explicit_terminal_turn_error?(reason) do
      emit_message(
        on_message,
        :turn_ended_with_error,
        %{
          session_id: session_id,
          reason: reason
        },
        metadata
      )
    end
  end

  defp explicit_terminal_turn_error?({kind, _details})
       when kind in [:turn_failed, :turn_cancelled, :turn_input_required, :approval_required],
       do: true

  defp explicit_terminal_turn_error?(_reason), do: false

  @spec stop_session(session()) :: :ok
''',
    "app_server terminal error helper insertion",
)

app_text = replace_once(
    app_text,
    '''      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}
''',
    '''      {:ok, %{"method" => "turn/completed"} = payload} ->
        case turn_completion_status(payload) do
          "failed" ->
            emit_turn_event(
              on_message,
              :turn_failed,
              payload,
              payload_string,
              port,
              Map.get(payload, "params")
            )

            {:error, {:turn_failed, Map.get(payload, "params")}}

          "interrupted" ->
            emit_turn_event(
              on_message,
              :turn_cancelled,
              payload,
              payload_string,
              port,
              Map.get(payload, "params")
            )

            {:error, {:turn_cancelled, Map.get(payload, "params")}}

          _ ->
            emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
            {:ok, :turn_completed}
        end
''',
    "app_server completed status handling",
)

app_text = replace_once(
    app_text,
    '''  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
''',
    '''  defp turn_completion_status(payload) when is_map(payload) do
    case get_in(payload, ["params", "turn", "status"]) do
      status when is_binary(status) -> String.downcase(status)
      _ -> nil
    end
  end

  defp turn_completion_status(_payload), do: nil

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
''',
    "app_server completion status helper insertion",
)
app.write_text(app_text)

orch_text = orch.read_text()
orch_text = replace_once(
    orch_text,
    '''  @failure_retry_base_ms 10_000
''',
    '''  @failure_retry_base_ms 10_000
  @max_failure_retry_attempts 1
''',
    "orchestrator retry cap constant",
)

orch_text = replace_once(
    orch_text,
    '''  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        delay_type: :continuation,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end
''',
    '''  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    cond do
      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)

      terminal_turn_failure_blocker?(running_entry) ->
        block_terminal_turn_failure_agent_down(state, issue_id, running_entry, session_id, :normal)

      true ->
        Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

        state
        |> complete_issue(issue_id)
        |> schedule_issue_retry(issue_id, 1, %{
          identifier: running_entry.identifier,
          issue_url: running_entry.issue.url,
          delay_type: :continuation,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        })
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    cond do
      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)

      terminal_turn_failure_blocker?(running_entry) ->
        block_terminal_turn_failure_agent_down(state, issue_id, running_entry, session_id, reason)

      true ->
        retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end
''',
    "orchestrator agent-down classification",
)

orch_text = replace_once(
    orch_text,
    '''  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      error: "agent exited: #{inspect(reason)}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path)
    })
  end
''',
    '''  defp block_terminal_turn_failure_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "codex turn failed: #{inspect(reason)}")

    Logger.warning("Agent task blocked after terminal Codex turn failure for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    if failure_retry_limit_reached?(running_entry) do
      error = "agent failed after #{@max_failure_retry_attempts} automatic retry: #{inspect(reason)}"

      Logger.warning("Agent task blocked after exhausting transient retry budget for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

      block_issue_from_entry(state, issue_id, running_entry, error)
    else
      Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

      next_attempt = next_retry_attempt_from_running(running_entry)

      schedule_issue_retry(state, issue_id, next_attempt, %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        error: "agent exited: #{inspect(reason)}",
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path)
      })
    end
  end
''',
    "orchestrator bounded retry handling",
)

orch_text = replace_once(
    orch_text,
    '''      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(issue_id, false)
        |> schedule_issue_retry(issue_id, next_attempt, %{
          identifier: identifier,
          issue_url: running_entry.issue.url,
          error: "stalled for #{elapsed_ms}ms without codex activity"
        })
      end
''',
    '''      cond do
        input_required_blocker?(running_entry) ->
          error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

          Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

          state
          |> record_session_completion_totals(running_entry)
          |> stop_and_block_issue(issue_id, running_entry, error)

        terminal_turn_failure_blocker?(running_entry) ->
          error = blocker_error(running_entry, "stalled after terminal Codex turn failure")

          state
          |> record_session_completion_totals(running_entry)
          |> stop_and_block_issue(issue_id, running_entry, error)

        failure_retry_limit_reached?(running_entry) ->
          error = "codex worker stalled after #{@max_failure_retry_attempts} automatic retry"

          Logger.warning("Issue blocked after exhausting stall retry budget: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}")

          state
          |> record_session_completion_totals(running_entry)
          |> stop_and_block_issue(issue_id, running_entry, error)

        true ->
          Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

          next_attempt = next_retry_attempt_from_running(running_entry)

          state
          |> terminate_running_issue(issue_id, false)
          |> schedule_issue_retry(issue_id, next_attempt, %{
            identifier: identifier,
            issue_url: running_entry.issue.url,
            error: "stalled for #{elapsed_ms}ms without codex activity"
          })
      end
''',
    "orchestrator stalled retry cap",
)

orch_text = replace_once(
    orch_text,
    '''  defp input_required_blocker?(_running_entry), do: false
''',
    '''  defp input_required_blocker?(_running_entry), do: false

  defp terminal_turn_failure_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_failed, :turn_cancelled]
  end

  defp terminal_turn_failure_blocker?(_running_entry), do: false

  defp failure_retry_limit_reached?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :retry_attempt, 0) >= @max_failure_retry_attempts
  end

  defp failure_retry_limit_reached?(_running_entry), do: false
''',
    "orchestrator failure classification helpers",
)

orch_text = replace_once(
    orch_text,
    '''  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
''',
    '''  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(:turn_failed), do: "codex turn failed"
  defp codex_event_blocker_error(:turn_cancelled), do: "codex turn interrupted or cancelled"
''',
    "orchestrator blocker messages",
)

orch_text = replace_once(
    orch_text,
    '''  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
''',
    '''  @doc false
  @spec handle_agent_down_for_test(term(), State.t() | map(), String.t(), map(), String.t()) :: term()
  def handle_agent_down_for_test(reason, state, issue_id, running_entry, session_id) do
    handle_agent_down(reason, state, issue_id, running_entry, session_id)
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
''',
    "orchestrator test helper",
)
orch.write_text(orch_text)

test.write_text(r'''defmodule SymphonyElixir.ConductorFailureGuardTest do
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
               AppServer.run(workspace, "trigger failure", issue,
                 on_message: fn message -> send(owner, {:codex_event, message}) end
               )

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
''')
PY

cd "$ROOT/elixir"
mise exec -- mix format \
  lib/symphony_elixir/codex/app_server.ex \
  lib/symphony_elixir/orchestrator.ex \
  test/symphony_elixir/conductor_failure_guard_test.exs
mise exec -- mix test test/symphony_elixir/conductor_failure_guard_test.exs

cd "$ROOT"
rm -- "$0"
git add elixir/lib/symphony_elixir/codex/app_server.ex \
        elixir/lib/symphony_elixir/orchestrator.ex \
        elixir/test/symphony_elixir/conductor_failure_guard_test.exs \
        tools/apply-conductor-failure-guard.sh

git commit -m "fix: stop retry loops after terminal Codex failures"

echo
echo "Patch applied, focused tests passed, and commit created."
echo "Now push with: git push fork HEAD"
