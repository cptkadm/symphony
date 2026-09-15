defmodule SymphonyElixir.Codex.WorkspaceGitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.{DynamicTool, WorkspaceGit}
  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.Tracker.Issue

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-git-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(root, "workspaces")
    workspace = Path.join(workspace_root, "GH-15")
    remote = Path.join(root, "remote.git")
    File.mkdir_p!(workspace)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    git!(root, ["init", "--bare", remote])
    git!(workspace, ["init", "-b", "main"])
    git!(workspace, ["config", "user.name", "Symphony Test"])
    git!(workspace, ["config", "user.email", "symphony@example.test"])
    File.write!(Path.join(workspace, "README.md"), "baseline\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "-m", "baseline"])
    git!(workspace, ["remote", "add", "origin", remote])
    git!(workspace, ["push", "-u", "origin", "main"])

    issue = %Issue{
      id: "15",
      identifier: "GH-15",
      title: "Workspace Git bridge",
      description: "test",
      state: "open",
      url: "https://example.test/issues/15",
      labels: []
    }

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, workspace: workspace, remote: remote, issue: issue}
  end

  test "advertises only allowlisted workspace Git operations" do
    assert [spec] = WorkspaceGit.tool_specs()
    assert spec["name"] == "workspace_git"

    assert spec["inputSchema"]["properties"]["operation"]["enum"] == [
             "ensure_branch",
             "commit",
             "push"
           ]
  end

  test "creates a branch, commits explicit paths, and pushes the current non-default branch", %{
    workspace: workspace,
    remote: remote,
    issue: issue
  } do
    binding = %{adapter: GitHubAdapter, tracker_settings: %{}, tool_specs: []}

    branch_response =
      DynamicTool.execute(
        "workspace_git",
        %{"operation" => "ensure_branch", "branch" => "feat/gh-15-evidence-capture"},
        binding,
        issue: issue
      )

    assert branch_response["success"]
    assert git!(workspace, ["branch", "--show-current"]) == "feat/gh-15-evidence-capture"

    File.write!(Path.join(workspace, "README.md"), "changed\n")
    File.write!(Path.join(workspace, "capture.txt"), "new\n")

    commit_response =
      DynamicTool.execute(
        "workspace_git",
        %{
          "operation" => "commit",
          "message" => "feat: capture evidence",
          "paths" => ["README.md", "capture.txt"]
        },
        binding,
        issue: issue
      )

    assert commit_response["success"]
    assert git!(workspace, ["log", "-1", "--pretty=%s"]) == "feat: capture evidence"
    assert git!(workspace, ["status", "--short"]) == ""

    push_response =
      DynamicTool.execute(
        "workspace_git",
        %{"operation" => "push"},
        binding,
        issue: issue
      )

    assert push_response["success"]

    assert git!(workspace, ["rev-parse", "HEAD"]) ==
             git_bare!(remote, ["rev-parse", "refs/heads/feat/gh-15-evidence-capture"])
  end

  test "refuses traversal staging and direct pushes of the default branch", %{
    workspace: _workspace,
    issue: issue
  } do
    invalid_paths =
      WorkspaceGit.execute(
        %{
          "operation" => "commit",
          "message" => "bad",
          "paths" => ["../outside"]
        },
        issue: issue
      )

    refute invalid_paths["success"]
    assert Jason.decode!(invalid_paths["output"])["error"]["message"] =~ "repository-relative"

    default_push = WorkspaceGit.execute(%{"operation" => "push"}, issue: issue)
    refute default_push["success"]
    assert Jason.decode!(default_push["output"])["error"]["message"] =~ "default branch"
  end

  defp git!(workspace, args) do
    {output, status} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end

  defp git_bare!(git_dir, args) do
    {output, status} = System.cmd("git", ["--git-dir", git_dir | args], stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
