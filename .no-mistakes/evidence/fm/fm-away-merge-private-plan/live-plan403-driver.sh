#!/usr/bin/env bash
# Live-augmented probe for the away merge grant / plan-gated 403 exemption.
#
# It drives the real bin/fm-pr-merge.sh end to end. The only live network read
# is GitHub's branch-rules endpoint, which is delegated to the real gh against a
# real private free-plan repository (ZipBomb/vibra) that genuinely answers with
# the plan-upgrade 403. Every other forge read is answered from local fixtures so
# no real pull request is opened or merged. This proves the product resolves the
# live plan-403 as queue-free while away and proceeds to the forge, and that a
# general rules-read failure (a 404) still refuses.
set -u

WORKTREE=${WORKTREE:-/home/zipbomb/.no-mistakes/worktrees/9000821919f5/01M2Q2E8THEYYXH83XWYXMKNTF}
# shellcheck source=tests/lib.sh
. "$WORKTREE/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$WORKTREE/bin/fm-pr-merge.sh"
REAL_GH=$(command -v gh) || fail "real gh not found"
REAL_GH_TOKEN=$("$REAL_GH" auth token) || fail "real gh is not authenticated"
JQ_BIN=$(command -v jq) || fail "jq not found"
TMP_ROOT=$(fm_test_tmproot fm-live-plan403)

make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$case_dir/wt" "$fakebin"
  cp "$WORKTREE/.tasks.toml" "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/home/data/backlog.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/gh.log"
  printf '%s\n' "$case_dir"
}

# Build fake gh/gh-axi that answer every pre-merge and outcome read locally but
# delegate the branch-rules read to the real gh verbatim.
add_live_gh_mocks() {
  local case_dir=$1 head=$2
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *statusCheckRollup*) cat "\$FM_TEST_GH_VIEW_JSON"; exit 0 ;;
      *headRefOid*) cat "\$FM_TEST_GH_HEAD"; exit 0 ;;
    esac
    ;;
  "pr merge")
    printf 'merged:\n  number: %s\n  status: ok\n' "\${3:-}"
    exit 0
    ;;
  "api graphql")
    cat "\$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    # Live delegation: the real gh reads the real GitHub branch rules with the
    # host's own credential, since HOME is redirected into the fixture.
    GH_TOKEN="$REAL_GH_TOKEN" "$REAL_GH" "\$@" >"\$FM_TEST_LIVE_RULES_STDOUT" 2> >(tee "\$FM_TEST_LIVE_RULES_STDERR" >&2)
    exit \$?
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

write_away_record() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$WORKTREE/bin/fm-afk-contract.sh" propose "$@" >/dev/null
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$WORKTREE/bin/fm-afk-contract.sh" confirm >/dev/null
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$WORKTREE" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_GH_VIEW_JSON="$case_dir/github-view.json" \
  FM_TEST_GH_HEAD="$case_dir/github-head" \
  FM_TEST_GH_MERGE_RC_FILE="$case_dir/github-merge-rc" \
  FM_TEST_GH_MERGE_OUTPUT="" \
  FM_TEST_GH_GRAPHQL_FAIL="$case_dir/github-graphql-fail" \
  FM_TEST_GH_RULES_FAIL="$case_dir/github-rules-fail" \
  FM_TEST_GH_RULES_FAIL_BODY="$case_dir/github-rules-fail-body" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_AWAY_RECORD_AFTER_VIEW="$case_dir/away-record-after-view" \
  FM_TEST_ROOT="$WORKTREE" \
  FM_TEST_AWAY_MUTATE_AT_MERGE="" \
  FM_TEST_AWAY_MUTATE_OUT="$case_dir/away-mutate-output" \
  FM_TEST_AWAY_MUTATE_RC="$case_dir/away-mutate-rc" \
  FM_TEST_AWAY_GRANTS_AT_MERGE="$case_dir/away-grants-at-merge" \
  FM_TEST_REAL_MV="$(command -v mv)" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  FM_TEST_LIVE_RULES_STDOUT="$case_dir/live-rules-stdout" \
  FM_TEST_LIVE_RULES_STDERR="$case_dir/live-rules-stderr" \
  HOME="$case_dir/user-home" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  return "$rc"
}

head=abcdabcdabcdabcdabcdabcdabcdabcdabcdabcd

echo "== scenario A: away grant + live plan-gated 403 =="
case_dir=$(make_case live-away-grant-plan403)
add_live_gh_mocks "$case_dir" "$head"
write_away_record "$case_dir" --grant task-x1
run_pr_merge "$case_dir" task-x1 https://github.com/ZipBomb/vibra/pull/1001 \
  > "$case_dir/stdout" 2> "$case_dir/stderr"
rc=$?
echo "exit=$rc"
echo "--- product stderr ---"; cat "$case_dir/stderr"
echo "--- live gh rules stdout ---"; cat "$case_dir/live-rules-stdout" 2>/dev/null
echo "--- live gh rules stderr ---"; cat "$case_dir/live-rules-stderr" 2>/dev/null
echo "--- forge log ---"; cat "$case_dir/gh.log"
echo "--- wake queue ---"; cat "$case_dir/state/.wake-queue" 2>/dev/null
if [ "$rc" -ne 0 ]; then fail "scenario A: away grant merge blocked by a live plan-403"; fi
grep -q 'pr merge 1001 --repo ZipBomb/vibra --match-head-commit '"$head"' --squash' "$case_dir/gh.log" \
  || fail "scenario A: the forge merge was not reached"
grep -q "merge landed: task-x1 https://github.com/ZipBomb/vibra/pull/1001 away-grant" "$case_dir/state/.wake-queue" \
  || fail "scenario A: the landed merge was not recorded under the grant"
grep -q "Upgrade to GitHub Pro or make this repository public" "$case_dir/live-rules-stderr" \
  || fail "scenario A: the live rules read did not answer with the plan-gated 403"
pass "away grant proceeds on a live plan-gated 403 from a real private free-plan repo"

echo
echo "== scenario B: away grant + live general rules failure (404) still refuses =="
case_dir=$(make_case live-away-grant-general-failure)
add_live_gh_mocks "$case_dir" "$head"
write_away_record "$case_dir" --grant task-x1
run_pr_merge "$case_dir" task-x1 https://github.com/ZipBomb/definitely-not-a-repo-xyz123/pull/1002 \
  > "$case_dir/stdout" 2> "$case_dir/stderr"
rc=$?
echo "exit=$rc"
echo "--- product stderr ---"; cat "$case_dir/stderr"
echo "--- live gh rules stderr ---"; cat "$case_dir/live-rules-stderr" 2>/dev/null
echo "--- forge log ---"; cat "$case_dir/gh.log"
if [ "$rc" -ne 2 ]; then fail "scenario B: a live general rules failure must still refuse (got $rc)"; fi
grep -q 'merge-queue state does not prove an immediate merge' "$case_dir/stderr" \
  || fail "scenario B: the refusal did not name the unproven queue state"
grep -q 'pr merge' "$case_dir/gh.log" && fail "scenario B: the forge merge ran despite an unreadable rules response"
pass "an away grant still refuses on a live general branch-rules failure"

echo
echo "ALL LIVE SCENARIOS PASSED"
