#!/bin/sh
set -e

# ----------------------------
# Config Git safe directory for CI
# ----------------------------
git config --global --add safe.directory /github/workspace

# ----------------------------
# Input arguments
# ----------------------------
UPSTREAM_REPO=$1
BRANCH_MAPPING=$2

if [ -z "$UPSTREAM_REPO" ]; then
  echo "Missing \$UPSTREAM_REPO"
  exit 1
fi

if [ -z "$BRANCH_MAPPING" ]; then
  echo "Missing \$SOURCE_BRANCH:\$DEST_BRANCH"
  exit 1
fi

SOURCE_BRANCH=${BRANCH_MAPPING%%:*}
DEST_BRANCH=${BRANCH_MAPPING#*:}

# ----------------------------
# Normalize upstream URL
# ----------------------------
if ! echo "$UPSTREAM_REPO" | grep -Eq ':|@|\.git\/?$'; then
  echo "Assuming GitHub repo"
  UPSTREAM_REPO="https://github.com/${UPSTREAM_REPO}.git"
fi

echo "UPSTREAM_REPO=$UPSTREAM_REPO"
echo "SOURCE_BRANCH=$SOURCE_BRANCH"
echo "DEST_BRANCH=$DEST_BRANCH"

# ----------------------------
# Reset origin
# ----------------------------
git config --unset-all http."https://github.com/".extraheader || :
git remote set-url origin "https://$GITHUB_ACTOR:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY"

# ----------------------------
# Add temporary upstream
# ----------------------------
git remote add tmp_upstream "$UPSTREAM_REPO"
git fetch tmp_upstream --quiet
git fetch origin --quiet

# ----------------------------
# Checkout or create DEST_BRANCH
# ----------------------------
if git show-ref --verify --quiet "refs/heads/$DEST_BRANCH"; then
  git checkout "$DEST_BRANCH"
else
  if git ls-remote --heads origin "$DEST_BRANCH" | grep -q "$DEST_BRANCH"; then
    git checkout -b "$DEST_BRANCH" "origin/$DEST_BRANCH"
  else
    git checkout -b "$DEST_BRANCH"
  fi
fi

git pull --rebase origin "$DEST_BRANCH" || echo "No upstream changes"

# ----------------------------
# Rebase if needed
# ----------------------------
UPSTREAM_HASH=$(git rev-parse "tmp_upstream/$SOURCE_BRANCH")
LOCAL_HASH=$(git rev-parse "HEAD")

if [ "$UPSTREAM_HASH" != "$LOCAL_HASH" ]; then
  echo "Branches differ, rebasing $DEST_BRANCH on tmp_upstream/$SOURCE_BRANCH"
  git rebase "tmp_upstream/$SOURCE_BRANCH"
else
  echo "Branches are already in sync."
fi

# ----------------------------
# Push branch to origin
# ----------------------------
git push --set-upstream origin "$DEST_BRANCH"

# ----------------------------
# Optional: Sync tags
# ----------------------------
if [ "$SYNC_TAGS" = "true" ]; then
  echo "Syncing all tags (without deleting local tags)"
  git fetch tmp_upstream --tags --quiet
  git push origin --tags
elif [ -n "$SYNC_TAGS" ]; then
  echo "Syncing tags matching pattern: $SYNC_TAGS"
  git fetch tmp_upstream --tags --quiet
  git tag | grep -E "$SYNC_TAGS" | xargs -r git push origin
fi

# ----------------------------
# Cleanup
# ----------------------------
git remote rm tmp_upstream
git remote --verbose
