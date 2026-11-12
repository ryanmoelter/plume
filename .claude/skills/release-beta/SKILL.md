---
name: release-beta
description: Cut a beta of the release in progress — merge the release branch into main, bump to <version>-beta.<n>, draft the beta's changelog, tag, package with --beta and publish to the beta channel, then keep working on the same release branch. Use on "/release-beta", "make a beta", "cut a beta of this release", or mid-way through a `release-cycle` run when the user wants what is merged so far in beta users' hands.
---

# Release a beta

A beta ships what a `release-cycle` run has merged so far. The cycle keeps going on the same release branch afterwards, and the stable release follows later. `docs/releasing.md` is the reference, especially "Beta releases" and "Sharing a build". Read it before starting; don't duplicate it here.

You are the coordinator, as in `release-cycle`. Delegate builds and tests to a Sonnet agent. Ask before each outward-facing step: pushing, publishing the GitHub release, publishing the feed.

## 1. Settle what ships

- Every package in the beta is merged into `<prefix>/release-<version>`, built, and verified by the `release-cycle` verifier. The user has reviewed the review page and asked for the beta.
- Collect everything the verifier couldn't check in a running app: the review page's warn and fail items and its "not checked" notes. Put them in one issue through the `roadmap` skill, titled `Test the <version> items the verifier couldn't reach`. Make it a sub-issue of the `Release <version>` issue, in project Admin, state To do, in the current cycle. Give it one checkbox per item, saying what to do and what to expect. That issue carries the open testing, so the shipped issues can close.
- Work the user has asked for but that isn't merged stays on the release branch for the next beta or the stable release. Don't wait for it.

## 2. Version and changelog

Read the last beta tag for this version: `git tag --list 'v<version>-beta.*' --sort=-v:refname | head -1`. `<n>` is one past it, or 1. The build number is one past the highest `CURRENT_PROJECT_VERSION` ever released, beta or stable. `package-release.sh` refuses a build that doesn't outrun the published appcast.

On the release branch:

1. Set `MARKETING_VERSION` to `<version>-beta.<n>` and bump `CURRENT_PROJECT_VERSION`, in the **app target's** Debug and Release blocks only. Xcode quotes a beta version; leave the quotes. Commit the bump alone.
2. Draft `## Draft: <version>-beta.<n> (<build>)` at the top of `CHANGELOG.md`. Use the voice and the sources from `release-cycle` step 5. For beta 2 and later, cover only what changed since the previous beta. End with the `### Recently` list.
3. Leave the draft **uncommitted**, and tell the user it's ready. They edit it and remove `Draft: ` to approve it. Then confirm the heading is exactly `## <version>-beta.<n> (<build>)`, and commit `CHANGELOG.md` on its own.

## 3. Merge to main

- Merge the release branch into `main` with `--no-ff`, from the primary checkout. The user's request for the beta is the confirmation that it may reach `main`.
- Move every issue that shipped to **Done** through the `roadmap` skill, except the `Release <version>` issue and the testing issue from step 1. Issues still in progress on the release branch stay In Progress.
- Delegate a Release build and `PlumeTests` to Sonnet. Tell it **not** to install. It verifies the bundle in `BUILT_PRODUCTS_DIR`, as in `release-cycle`.
- If commits sign here, `git log --format='%G? %h %s' <last-tag>..main | grep -v '^G'` must print nothing. `<last-tag>` is the newest `v*` tag of any kind.
- Tag `v<version>-beta.<n>` on `main`'s HEAD. Ask, then push `main` and the tag.

## 4. Package and publish

- Run `OP_ACCOUNT=my.1password.com scripts/package-release.sh --beta` from the primary checkout on `main`. **Never pass `--allow-branch`** without the maintainer's explicit approval.
- The script makes a draft prerelease. Ask the user to publish it, or publish it once they say so. Then run the feed command the script prints (`scripts/publish-feed.sh`), with `CO_AUTHOR` set to the model's trailer identity.
- Betas never reach Homebrew. Don't run `update-tap.sh`.
- Add the GitHub prerelease link to the `Release <version>` issue's description, under the stable release's placeholder line. Leave the issue In Progress.

## 5. Continue the cycle

Fast-forward the release branch to `main` (`git merge --ff-only main` on the release branch), so it holds the version bump and the changelog. Keep merging packages onto it as before. The next beta or the stable release repeats from step 2. The stable release follows `release-cycle` step 5. Its `## <version> (<build>)` section covers the whole release, betas included, and its build number is above the last beta's.

## Gotchas

- A hotfix shipped during the beta reaches beta users as a downgrade in marketing version. Cut a new beta right after it. `docs/releasing.md` explains why.
- `package-release.sh` refuses a `Draft:` heading, a version without a `-beta.<n>` suffix under `--beta`, and a tag that doesn't point at `HEAD`. Each refusal names the fix.
