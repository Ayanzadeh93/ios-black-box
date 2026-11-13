# Developing and installing these skills

The capture platform is iOS. The user task can be indoor or outdoor and can use
ordinary UI, camera/ML, AR, app audio, commerce, fitness, or an app-specific event
adapter. New adapters should declare their clock, units, permissions and replay
limits rather than imply that the core records every device signal.

## Install

From your app's project directory:

```bash
npx skills add Ayanzadeh93/ios-black-box --skill ios-field-testing ios-black-box ios-sensor-tape --agent codex --yes
```

For developing a checkout locally:

```bash
npx skills add . --skill ios-field-testing ios-black-box ios-sensor-tape --agent codex --yes
```

The Vercel CLI installs to `.agents/skills/` for Codex in the current project.
Add `--global` only when you want a user-wide installation. Do not commit field
recordings or private app traces. Review Debug template integration in your app.

## Development helper skills

This extension used Vercel's official `find-skills` and Anthropic's official
`skill-creator`, installed locally for Codex. Their source and content hashes are
recorded in `skills-lock.json`; installed copies in `.agents/` are ignored.

```bash
npx skills add vercel-labs/skills --skill find-skills --agent codex --yes
npx skills add anthropics/skills --skill skill-creator --agent codex --yes
npx skills list
```

Discovery checked the skills.sh leaderboard, which listed
[`anthropics/skills/skill-creator`](https://skills.sh/anthropics/skills/skill-creator)
at approximately 431K installs. Its official repository had approximately 194K
stars when inspected. CLI searches for `skill-creator --owner anthropics` and
`swift testing` returned no matches in this environment, so the known official
source was checked directly. Popularity is discovery context, not a guarantee of
correctness. No unrelated skills were installed.

## Portable verification

Python 3.9+ is sufficient for analysis and scenario tooling. Device capture needs
macOS, Xcode 16.3+ with Swift 6.1+, a signed Debug app, and an unlocked paired physical iPhone.

```bash
python3 -m unittest discover -s tests -v
bash -n skills/ios-black-box/scripts/session.sh skills/ios-sensor-tape/scripts/tape.sh
python3 skills/ios-field-testing/scripts/scenario.py validate skills/ios-field-testing/evals/fixtures/commerce.json
python3 skills/ios-field-testing/scripts/scenario.py evaluate skills/ios-field-testing/evals/fixtures/commerce.json skills/ios-field-testing/evals/fixtures/commerce-pass.jsonl
```

The fail fixture intentionally exits 1; the truncated fixture exits 2. Portable
tests use synthetic artifacts and mock device commands. They do not establish
ReplayKit behavior, Swift framework type correctness, signing, depth accuracy,
app background execution, or physical-device reliability. Compile and exercise
the Debug templates in a representative app before relying on a field run.

`skills/ios-field-testing/evals/evals.json` contains three realistic prompts for
checking the agent workflow: commerce retry, outdoor fitness interruption, and
camera rotation. Evaluate the produced plans and evidence separately from the
portable code tests. Do not label prompt examples as completed hardware tests.
