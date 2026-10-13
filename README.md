# greg
Every 20 minutes, greg finds the PRs and issues aimed at you on GitHub and in
Slack. It briefs each PR with a review skill before it notifies you, so the
notification opens a finished review.

------------------------------------------------------------------------
## What it does
- Assigned issues get a macOS notification right away.
- PRs where your review is requested, or that someone asks you to review in
  Slack, get a headless Claude review first. You then get a notification
  (`repo#pr — APPROVE`) that opens an HTML brief from `~/pr-briefs/`.
- The *Stage draft review* button posts the brief's comments as a pending GitHub
  review that only you can see. Edit it, then submit it yourself.
- A new push to a briefed PR gets a fresh brief.

------------------------------------------------------------------------
## Warning
![Slop-O-Meter rating: EXTREME](assets/slop-o-meter.png)

> Works on my machine 🤷‍♂️

*(This was fully vibed and highly specific to my local system, tools, workflow,
and preferences. Your mileage ~may~ **will for sure** vary.)*

------------------------------------------------------------------------
## Requirements
- macOS, bash 5, `git`, `jq`, `perl`, [gh] (logged in), and
  [terminal-notifier] 3.1 or later with notifications allowed in System
  Settings.
- [Claude Code], logged in. The claude.ai Slack connector is optional: without
  it, greg skips the Slack scan and checks for the connector again once a day.
- A PR review skill: Claude Code's built-in `/code-review` unless `config`
  names another (see Install).

------------------------------------------------------------------------
## Install
1. Install greg. This clones it into `~/.local/share/greg/src/` and links
   `greg` into `~/.local/bin/`:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/cmtonkinson/greg/main/install.sh | sh
   ```
2. Choose the review skill. greg uses Claude Code's built-in `/code-review`
   unless `config` in the clone sets `REVIEW_SKILL` to another skill's name
   (without the `/`). For example, to use a `/review-pr` skill:
   ```sh
   echo REVIEW_SKILL=review-pr >~/.local/share/greg/src/config
   ```
   Every run reads this file, scheduled or not. It is git-ignored, so updates
   leave it alone.
3. Start the schedule:
   ```sh
   greg install
   ```

To update, run `greg update` or the installer again. Either fast-forwards the
clone, and the schedule picks up the new version at its next tick.

------------------------------------------------------------------------
## Usage
Commands (`greg help` lists them all):
- `now`: run a tick in the foreground.
- `review URL`: brief one PR now.
- `stage URL`: create a pending GitHub review from a PR's brief.
- `inbox`: list briefed PRs and issues you have not actioned.
- `renotify [URL]`: post those notifications again.
- `rerender`: rebuild every brief after a template change.
- `update`: update greg.
- `status`, `pause`, `resume`, `uninstall`.

State, logs, and repo clones live in `~/.local/share/greg/`. Run the tests with
`tests/greg-test.sh`.

------------------------------------------------------------------------
## Brief blocks
Blocks add your own sections to every brief. Each block is a pair of files in
the clone's `blocks/` (git-ignored, so updates leave it alone; no
subdirectories), named with lowercase letters, digits, and hyphens:
- `<name>.json`: a JSON Schema for the block's data. Its `title` heads the
  section, and its `description` tells the reviewer what to put in it.
- `<name>.html`: a [Handlebars] template rendered with that data. `{{x}}`
  escapes the text; `{{md x}}` renders it as inline Markdown. The output sits
  in a `.block-<name>` element, so scope any `<style>` to it. The page's CSS
  variables and `.chip` classes are available.

Any other file in `blocks/` fails the review. Run `greg rerender` after
changing a template.

------------------------------------------------------------------------
## License
MIT. See [LICENSE](LICENSE.md).


------------------------------------------------------------------------
*Does anybody have Greg's number?*

[Claude Code]: https://claude.com/claude-code
[LGTM]: https://www.youtube.com/watch?v=3TNpOD6bov8
[gh]: https://cli.github.com/
[Handlebars]: https://handlebarsjs.com/
[terminal-notifier]: https://github.com/julienXX/terminal-notifier
