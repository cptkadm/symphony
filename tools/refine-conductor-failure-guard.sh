#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

python3 <<'PY'
from pathlib import Path

p = Path("elixir/lib/symphony_elixir/orchestrator.ex")
s = p.read_text()

old = '''  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    if failure_retry_limit_reached?(running_entry) do
      error = "agent failed after #{@max_failure_retry_attempts} automatic retry: #{inspect(reason)}"
'''
new = '''  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    if codex_transient_retry_limit_reached?(running_entry) do
      error = "agent failed after #{@max_failure_retry_attempts} automatic Codex retry: #{inspect(reason)}"
'''
if old not in s:
    raise SystemExit("retry_agent_down pattern not found")
s = s.replace(old, new, 1)

old = '''  defp failure_retry_limit_reached?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :retry_attempt, 0) >= @max_failure_retry_attempts
  end

  defp failure_retry_limit_reached?(_running_entry), do: false
'''
new = '''  defp codex_transient_retry_limit_reached?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_ended_with_error, :startup_failed] and
      Map.get(running_entry, :retry_attempt, 0) >= @max_failure_retry_attempts
  end

  defp codex_transient_retry_limit_reached?(_running_entry), do: false

  defp failure_retry_limit_reached?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :retry_attempt, 0) >= @max_failure_retry_attempts
  end

  defp failure_retry_limit_reached?(_running_entry), do: false
'''
if old not in s:
    raise SystemExit("retry-limit helper pattern not found")
s = s.replace(old, new, 1)

p.write_text(s)
PY

cd "$ROOT/elixir"
mise exec -- mix format lib/symphony_elixir/orchestrator.ex
mise exec -- mix test test/symphony_elixir/conductor_failure_guard_test.exs test/symphony_elixir/core_test.exs
mise exec -- mix test

cd "$ROOT"
rm -- "$0"
git add elixir/lib/symphony_elixir/orchestrator.ex tools/refine-conductor-failure-guard.sh
git commit -m "fix: bound only Codex-attributed transient retries"

echo
echo "Refinement applied and full test suite passed."
echo "Now push with: git push fork HEAD"
