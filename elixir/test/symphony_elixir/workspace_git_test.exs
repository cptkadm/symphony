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

  test "ensure_branch when already on branch returns changed false", %{
    issue: issue
  } do
    binding = %{adapter: GitHubAdapter, tracker_settings: %{}, tool_specs: []}

    res =
      DynamicTool.execute(
        "workspace_git",
        %{"operation" => "ensure_branch", "branch" => "main"},
        binding,
        issue: issue
      )

    assert res["success"]
    assert Jason.decode!(res["output"])["changed"] == false
  end

  test "ensure_branch switches to existing local branch", %{
    workspace: workspace,
    issue: issue
  } do
    git!(workspace, ["branch", "local-feature"])

    binding = %{adapter: GitHubAdapter, tracker_settings: %{}, tool_specs: []}

    res =
      DynamicTool.execute(
        "workspace_git",
        %{"operation" => "ensure_branch", "branch" => "local-feature"},
        binding,
        issue: issue
      )

    assert res["success"]
    assert Jason.decode!(res["output"])["changed"] == true
    assert git!(workspace, ["branch", "--show-current"]) == "local-feature"
  end

  test "ensure_branch switches to existing remote branch", %{
    workspace: workspace,
    issue: issue
  } do
    git!(workspace, ["checkout", "-b", "remote-feature"])
    File.write!(Path.join(workspace, "remote.txt"), "remote")
    git!(workspace, ["add", "remote.txt"])
    git!(workspace, ["commit", "-m", "remote feat"])
    git!(workspace, ["push", "-u", "origin", "remote-feature"])
    git!(workspace, ["checkout", "main"])
    git!(workspace, ["branch", "-D", "remote-feature"])

    binding = %{adapter: GitHubAdapter, tracker_settings: %{}, tool_specs: []}

    res =
      DynamicTool.execute(
        "workspace_git",
        %{"operation" => "ensure_branch", "branch" => "remote-feature"},
        binding,
        issue: issue
      )

    assert res["success"]
    assert Jason.decode!(res["output"])["changed"] == true
    assert git!(workspace, ["branch", "--show-current"]) == "remote-feature"
  end

  test "error responses for invalid operation, missing arguments, and empty commit", %{
    issue: issue
  } do
    res = WorkspaceGit.execute(%{"operation" => "unknown"}, issue: issue)
    refute res["success"]

    res2 = WorkspaceGit.execute(%{"operation" => "ensure_branch", "branch" => ""}, issue: issue)
    refute res2["success"]

    res3 =
      WorkspaceGit.execute(
        %{"operation" => "commit", "message" => "", "paths" => ["README.md"]},
        issue: issue
      )

    refute res3["success"]
  end

  test "error payload handling for missing issue, invalid workspace, and invalid arguments" do
    res_no_issue = WorkspaceGit.execute(%{})
    refute res_no_issue["success"]
    assert res_no_issue["output"] =~ "requires the current issue context"

    res_not_map = WorkspaceGit.execute("not_a_map", issue: %Issue{id: "15", identifier: "GH-15"})
    refute res_not_map["success"]
    assert res_not_map["output"] =~ "expects a JSON object"

    fake_issue = %Issue{id: "999", identifier: "GH-999"}
    res_no_ws = WorkspaceGit.execute(%{"operation" => "push"}, issue: fake_issue)
    refute res_no_ws["success"]
    assert res_no_ws["output"] =~ "workspace is missing or invalid"

    bad_ws_issue = %Issue{id: "bad", identifier: "../outside"}
    res_bad_ws = WorkspaceGit.execute(%{"operation" => "push"}, issue: bad_ws_issue)
    refute res_bad_ws["success"]
    assert res_bad_ws["output"] =~ "workspace is missing or invalid"
  end

  test "commit message too large, invalid branch, nothing to commit, detached head, and failed git cmd", %{
    workspace: workspace,
    issue: issue
  } do
    large_msg = String.duplicate("a", 25_000)

    res1 =
      WorkspaceGit.execute(
        %{"operation" => "commit", "message" => large_msg, "paths" => ["README.md"]},
        issue: issue
      )

    refute res1["success"]
    assert res1["output"] =~ "safety limit"

    res2 =
      WorkspaceGit.execute(
        %{"operation" => "ensure_branch", "branch" => "invalid..branch"},
        issue: issue
      )

    refute res2["success"]
    assert res2["output"] =~ "not a valid Git branch"

    res3 =
      WorkspaceGit.execute(
        %{"operation" => "commit", "message" => "nothing", "paths" => ["README.md"]},
        issue: issue
      )

    refute res3["success"]
    assert res3["output"] =~ "No staged changes remain"

    res_bad_path =
      WorkspaceGit.execute(
        %{"operation" => "commit", "message" => "m", "paths" => [":magic_path"]},
        issue: issue
      )

    refute res_bad_path["success"]
    assert res_bad_path["output"] =~ "forbidden"

    res_git_failed =
      WorkspaceGit.execute(
        %{"operation" => "commit", "message" => "fail", "paths" => ["nonexistent.txt"]},
        issue: issue
      )

    refute res_git_failed["success"]
    assert res_git_failed["output"] =~ "Git command failed"

    git!(workspace, ["checkout", "HEAD~0"])

    res4 = WorkspaceGit.execute(%{"operation" => "push"}, issue: issue)

    refute res4["success"]
    assert res4["output"] =~ "detached HEAD"
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
