// The PR path filters see the entire PR. Here we check just the update.
module.exports = async function skipMarkdownBuild({ github, context, core }, workflow) {
  const { before, pull_request: pr } = context.payload;
  const { owner, repo } = context.repo;
  if (!before || !pr?.head.repo?.id || context.payload.action !== "synchronize") return false;

  try {
    const { data: diff } = await github.rest.repos.compareCommitsWithBasehead({
      owner, repo, basehead: `${before}...${pr.head.sha}`, per_page: 1,
    });
    // GitHub returns at most 300 changed files. An incomplete list cannot justify a skip.
    if (diff.status !== "ahead" || !diff.files?.length || diff.files.length >= 300) return false;

    function isDocumentation(path) {
      if (!path.endsWith(".md")) return false;
      if (path.startsWith("assets/licenses/") || path.startsWith("assets/font_assets/")) return false;
      if (path === "deploy/rust/README.md" && workflow === "rust.yml") return false;
      if (workflow !== "flutter.yml" && /^crates\/[^/]+\/licenses\//.test(path)) return false;
      return true;
    }

    if (!diff.files.every(file => isDocumentation(file.filename) &&
        (file.status !== "renamed" || (file.previous_filename && isDocumentation(file.previous_filename))))) {
      return false;
    }

    // pull_requests[].base.sha in the runs API can reflect the current PR base.
    // The workflow's run-name records the base actually used when that run started.
    const { data } = await github.rest.actions.listWorkflowRuns({
      owner, repo, workflow_id: workflow, event: "pull_request", head_sha: before, per_page: 100,
    });
    const previous = data.workflow_runs.find(run =>
      run.display_title === `PR #${pr.number} · base ${pr.base.sha}` &&
      run.head_repository?.id === pr.head.repo?.id && run.head_branch === pr.head.ref);
    if (previous?.status !== "completed" || previous.conclusion !== "success") return false;
    core.notice(`Only Markdown documentation changed. Reusing ${previous.html_url}`);
    return true;
  } catch (error) {
    core.warning(`Could not verify this update; running the build: ${error.message}`);
    return false;
  }
};
