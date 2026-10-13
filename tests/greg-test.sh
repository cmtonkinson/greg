#!/usr/bin/env bash
# Tests greg's non-LLM logic: templating, Slack URL validation, review dedupe.
set -euo pipefail

GREG_HOME=$(mktemp -d)
export GREG_HOME
trap 'rm -rf "$GREG_HOME"' EXIT
# shellcheck source=../bin/greg
source "$(dirname "$0")/../bin/greg"
ensure_home

failures=0
check() {
  local name=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name"$'\n'"  expected: $expected"$'\n'"  actual:   $actual"
    failures=$((failures + 1))
  fi
}

template=$GREG_HOME/t.txt
printf 'a={{A}} b={{B}} a={{A}}' >"$template"
check "render replaces every key literally" \
  'a=x & \1 b=</y> a=x & \1' "$(render "$template" A='x & \1' B='</y>')"

for f in prompts/review-system.txt prompts/review-user.txt; do
  check "$f names the configured skill, not the default" 'yes no' \
    "$(out=$(render "$GREG_ROOT/$f" SKILL=my-skill)
      grep -q my-skill <<<"$out" && echo -n yes || echo -n no
      grep -q code-review <<<"$out" && echo ' yes' || echo ' no')"
done

config=$GREG_HOME/config
skill_from() {
  REVIEW_SKILL=code-review
  load_config "$1" && echo "$REVIEW_SKILL"
}
check "config: no file keeps the default skill" code-review "$(skill_from "$GREG_HOME/missing")"
printf '# comment\n\nREVIEW_SKILL=review-pr\n' >"$config"
check "config: sets the skill, skipping comments and blank lines" review-pr "$(skill_from "$config")"
printf 'REVEIW_SKILL=review-pr\n' >"$config"
check "config: an unknown key is an error" fail "$(load_config "$config" 2>/dev/null && echo ok || echo fail)"
printf 'review skill\n' >"$config"
check "config: a malformed line is an error" fail "$(load_config "$config" 2>/dev/null && echo ok || echo fail)"

check "normalize keeps PR links in canonical form, newest ask per PR" \
  '[{"pr_url":"https://github.com/octo-org/hello-world/pull/12","ts":"2026-10-12T10:00:00Z"}]' \
  "$(normalize_slack_asks <<<'[
    {"pr_url":"https://github.com/octo-org/hello-world/pull/12/files#diff","ts":"2026-10-11T10:00:00Z"},
    {"pr_url":"https://www.github.com/octo-org/hello-world/pull/12","ts":"2026-10-12T10:00:00Z"},
    {"pr_url":"https://evil.example/github.com/x/y/pull/1","ts":"2026-10-12T10:00:00Z"},
    {"pr_url":"https://github.com/octo-org/hello-world/issues/3","ts":"2026-10-12T10:00:00Z"}]' | jq -c 'map({pr_url, ts})')"

pr='{"url":"https://github.com/o/r/pull/1","sha":"aaa"}'
check "needs_review: unseen PR" yes "$(needs_review "$pr" && echo yes || echo no)"

echo '{"issues":{},"prs":{"https://github.com/o/r/pull/1":{"sha":"aaa","status":"done","attempts":0}},"slack":{}}' >"$STATE"
check "needs_review: done at same SHA" no "$(needs_review "$pr" && echo yes || echo no)"
check "needs_review: new push" yes "$(needs_review '{"url":"https://github.com/o/r/pull/1","sha":"bbb"}' && echo yes || echo no)"

echo '{"issues":{},"prs":{"https://github.com/o/r/pull/1":{"sha":"aaa","status":"failed","attempts":2}},"slack":{}}' >"$STATE"
check "needs_review: failed with attempts left" yes "$(needs_review "$pr" && echo yes || echo no)"

echo '{"issues":{},"prs":{"https://github.com/o/r/pull/1":{"sha":"aaa","status":"failed","attempts":3}},"slack":{}}' >"$STATE"
check "needs_review: failed, attempts exhausted" no "$(needs_review "$pr" && echo yes || echo no)"

result='{"review_body":"Looks close.","questions":["Why X?"],"findings":[
  {"path":"a.py","line":12,"comment":"Inline me."},
  {"path":"a.py","line":40,"comment":"Outside the hunk."},
  {"path":"gone.py","line":3,"comment":"File not in diff."}]}'
files='[{"filename":"a.py","patch":"@@ -10,3 +10,5 @@ def f():\n ctx\n+new\n@@ -30 +33 @@\n-x\n+y"},{"filename":"bin.dat"}]'
payload=$(build_review_payload "$result" "$files" abc https://github.com/o/r)
check "payload: finding inside a hunk becomes an inline RIGHT comment" \
  '[{"path":"a.py","line":12,"side":"RIGHT","body":"Inline me."}]' "$(jq -c .comments <<<"$payload")"
# shellcheck disable=SC2016 # literal Markdown backticks
check "payload: findings outside the diff go to the body with links, then questions" \
  'Looks close.

- [`a.py:40`](https://github.com/o/r/blob/abc/a.py#L40): Outside the hunk.
- [`gone.py:3`](https://github.com/o/r/blob/abc/gone.py#L3): File not in diff.

Questions:
- Why X?' "$(jq -r .body <<<"$payload")"
check "payload: single-line hunk header counts as one line" \
  '[{"path":"a.py","line":33,"side":"RIGHT","body":"c"}]' \
  "$(build_review_payload '{"review_body":"","questions":[],"findings":[{"path":"a.py","line":33,"comment":"c"}]}' "$files" abc u | jq -c .comments)"
check "payload: no event, so GitHub creates it pending" null "$(jq -c .event <<<"$payload")"

check "notification: GitHub request names the author" \
  '{"title":"o/r#7 — REJECT","subtitle":"Ada via GitHub","message":"4000 lines changed"}' \
  "$(pr_notification '{"owner":"o","repo":"r","number":7,"author":"Ada","churn":4000,"slack":null}' REJECT)"
check "notification: Slack ask names the sender" \
  '{"title":"o/r#7 — APPROVE","subtitle":"Bo via Slack","message":"12 lines changed"}' \
  "$(pr_notification '{"owner":"o","repo":"r","number":7,"author":"Ada","churn":12,"slack":{"sender":"Bo"}}' APPROVE)"

SLACK_ROOT_STATE=$GREG_HOME/root-state.json
echo '{"workspaces":{"T0AB":{"id":"T0AB","domain":"acme","url":"https://acme.slack.com/"}}}' >"$SLACK_ROOT_STATE"
check "slack_app_url: thread permalink opens the message in the app" \
  'slack://channel?team=T0AB&id=C0XY&message=1791817138.942119' \
  "$(slack_app_url 'https://acme.slack.com/archives/C0XY/p1791817138942119?thread_ts=1791817138.942119&cid=C0XY')"
check "slack_app_url: unknown workspace prints nothing" '' \
  "$(slack_app_url 'https://other.slack.com/archives/C0XY/p1791817138942119')"
check "slack_app_url: non-permalink prints nothing" '' "$(slack_app_url 'https://acme.slack.com/team/U1')"

check "iso_shift subtracts seconds" 2026-10-12T09:00:00Z "$(iso_shift 2026-10-12T10:00:00Z -3600)"

# The stub claude plays the Slack connector state in $STUB_MCP and a scan
# result of status $STUB_SCAN, and records each call.
stub_dir=$GREG_HOME/stub calls=$GREG_HOME/claude-calls
mkdir -p "$stub_dir"
cat >"$stub_dir/claude" <<'EOF'
#!/usr/bin/env bash
echo "$1 $2" >>"$CLAUDE_CALLS"
if [[ $1 == mcp ]]; then
  case $STUB_MCP in
  connected) printf 'claude.ai Slack:\n  Status: ✔ Connected\n' ;;
  missing) echo 'No MCP server named "claude.ai Slack".' && exit 1 ;;
  auth) printf 'claude.ai Slack:\n  Status: ! Needs authentication\n' ;;
  failed) printf 'claude.ai Slack:\n  Status: ✘ Failed to connect\n  Issue: HTTP 502\n' ;;
  esac
else
  printf '{"structured_output":{"status":"%s","asks":[]}}\n' "$STUB_SCAN"
fi
EOF
chmod +x "$stub_dir/claude"
notify() { :; }
slack_case() {
  echo '{"issues":{},"prs":{},"slack":{}}' >"$STATE"
  : >"$calls"
  PATH=$stub_dir:$PATH CLAUDE_CALLS=$calls STUB_MCP=$1 STUB_SCAN=${2:-ok} slack_scan >/dev/null
  jq -c '{paused: (.slack.recheck_at != null), error: (.slack.error != null)}' "$STATE"
}
check "slack: connected runs the scan" '{"paused":false,"error":false}' "$(slack_case connected)"
check "slack: connected makes one check and one scan" 'mcp get|-p ' "$(paste -sd '|' "$calls" | cut -c 1-11)"
check "slack: missing connector pauses without a scan" '{"paused":true,"error":true} mcp get' \
  "$(slack_case missing) $(cat "$calls")"
check "slack: unauthenticated connector pauses" '{"paused":true,"error":true}' "$(slack_case auth)"
check "slack: failed connection skips this tick only" '{"paused":false,"error":true} mcp get' \
  "$(slack_case failed) $(cat "$calls")"
check "slack: scan reporting unavailable pauses" '{"paused":true,"error":true}' "$(slack_case connected unavailable)"
check "slack: pause lasts a day" true \
  "$(jq --arg t "$(iso_shift "$(now_iso)" 86000)" '.slack.recheck_at > $t' "$STATE")"
echo "{\"issues\":{},\"prs\":{},\"slack\":{\"recheck_at\":\"$(iso_shift "$(now_iso)" 3600)\"}}" >"$STATE"
: >"$calls"
check "slack: while paused, nothing runs" '[] 0' \
  "$(PATH=$stub_dir:$PATH CLAUDE_CALLS=$calls STUB_MCP=connected slack_scan) $(wc -l <"$calls" | tr -d ' ')"
echo "{\"issues\":{},\"prs\":{},\"slack\":{\"recheck_at\":\"$(iso_shift "$(now_iso)" -60)\",\"error\":\"x\"}}" >"$STATE"
PATH=$stub_dir:$PATH CLAUDE_CALLS=$calls STUB_MCP=connected STUB_SCAN=ok slack_scan >/dev/null
check "slack: after the pause, a good scan clears it" '{"paused":false,"error":false}' \
  "$(jq -c '{paused: (.slack.recheck_at != null), error: (.slack.error != null)}' "$STATE")"

BLOCK_DIR=$GREG_HOME/blocks
check "blocks: no directory means no blocks" '[]' "$(load_blocks)"
check "blocks: no blocks leaves the core schema as is" \
  "$(jq -c . "$GREG_ROOT/schemas/review.json")" "$(review_schema '[]')"
check "blocks: no blocks adds nothing to the prompt" no \
  "$(review_system_prompt '[]' | grep -q brief-blocks && echo yes || echo no)"

mkdir -p "$BLOCK_DIR"
echo '{"title":"Risk","description":"How risky.","type":"string"}' >"$BLOCK_DIR/risk.json"
echo '<p>{{this}}</p>' >"$BLOCK_DIR/risk.html"
blocks=$(load_blocks)
check "blocks: a pair loads with its schema and template" \
  '[{"name":"risk","schema":{"title":"Risk","description":"How risky.","type":"string"},"template":"<p>{{this}}</p>\n"}]' \
  "$blocks"
check "blocks: schema requires each block under custom_blocks, keeping core blocks" \
  '{"core_requires":true,"requires":["risk"],"props":{"risk":{"title":"Risk","description":"How risky.","type":"string"}},"core_blocks":"array"}' \
  "$(review_schema "$blocks" | jq -c '{core_requires: (.required | index("custom_blocks") != null),
    requires: .properties.custom_blocks.required, props: .properties.custom_blocks.properties,
    core_blocks: .properties.blocks.type}')"
# shellcheck disable=SC2016 # literal Markdown backticks
check "blocks: prompt lists each block's description" '- `custom_blocks.risk`: How risky.' \
  "$(review_system_prompt "$blocks" | grep custom_blocks.risk)"

for bad in "orphan.html" "Upper.json" "notes.txt" "sub/"; do
  rm -rf "${BLOCK_DIR:?}"/{orphan.html,Upper.json,Upper.html,notes.txt,sub}
  case $bad in
  */) mkdir "$BLOCK_DIR/$bad" ;;
  Upper.json) echo '{"title":"U","description":"u"}' >"$BLOCK_DIR/Upper.json" && touch "$BLOCK_DIR/Upper.html" ;;
  *) touch "$BLOCK_DIR/$bad" ;;
  esac
  check "blocks: $bad is rejected" fail "$(load_blocks 2>/dev/null && echo ok || echo fail)"
done
rm -rf "${BLOCK_DIR:?}"/sub
echo '{"title":"Risk","type":"string"}' >"$BLOCK_DIR/risk.json"
check "blocks: schema without a description is rejected" fail "$(load_blocks 2>/dev/null && echo ok || echo fail)"

# The installer clones a scratch repo holding the working tree, so it tests
# uncommitted changes too.
upstream=$GREG_HOME/upstream install_home=$GREG_HOME/install-home
mkdir -p "$upstream" "$install_home"
git -C "$GREG_ROOT" ls-files -z --cached --others --exclude-standard |
  (cd "$GREG_ROOT" && xargs -0 tar -cf -) | tar -xf - -C "$upstream"
commit() { git -C "$upstream" -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m "$1"; }
git -C "$upstream" init --quiet && git -C "$upstream" add --all && commit one
installed() {
  HOME=$install_home GREG_REPO=$upstream "$@" >/dev/null 2>&1 && echo ok || echo fail
}
src=$install_home/.local/share/greg/src
check "install: first run clones and links greg" ok "$(installed sh "$upstream/install.sh")"
check "install: greg links to the clone" "$src/bin/greg" "$(readlink "$install_home/.local/bin/greg")"
check "install: a second run converges" ok "$(installed sh "$upstream/install.sh")"
commit two
check "install: greg update fast-forwards its own clone" "ok $(git -C "$upstream" rev-parse HEAD)" \
  "$(installed env -u GREG_HOME "$install_home/.local/bin/greg" update) $(git -C "$src" rev-parse HEAD)"
check "install: a non-clone in the way is refused" fail \
  "$(rm -rf "$src" && mkdir -p "$src" && installed sh "$GREG_ROOT/install.sh")"

(( failures == 0 ))
