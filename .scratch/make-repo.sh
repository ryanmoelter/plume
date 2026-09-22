#!/bin/zsh
# Build a scratch repo for driving Plume's worktree UI. /tmp only.
set -e
R=/tmp/plume42-repo
rm -rf "$R"
mkdir -p "$R"
cd "$R"
git init -b main
git config user.email t@e.com
git config user.name T
git config commit.gpgsign false
echo hello > README.md
git add .
git commit -qm init
echo "REPO=$R"
git worktree list
