#!/bin/sh
set -e

git config --global --add safe.directory /github/workspace

UPSTREAM_REPO=$1
BRANCH_MAPPING=$2

if [[ -z "$UPSTREAM_REPO" ]]; then
  echo "Missing \$UPSTREAM_REPO"
  exit 1
fi

if [[ -z "$BRANCH_MAPPING" ]]; then
  echo "Missing \$SOURCE_BRANCH:\$DEST_BRANCH"
  exit 1
fi

SOURCE_BRANCH=${BRANCH_MAPPING%%:*}
DEST_BRANCH=${BRANCH_MAPPING#*:}

# ----------------------------
# Normalize upstream URL
# ----------------------------
if ! echo "$UPSTREAM_REPO" | grep -Eq ':|@|\.git\/?$'; then
  echo "Assuming GitHub repo shorthand"
  UPSTREAM_REPO="https://github.com/${UPSTREAM_REPO}.git"
fi

echo "UPSTREAM_REPO=$UPSTREAM_REPO"
echo "BRANCHES=$BRANCH_MAPPING"

git config --unset-all http."https://github.com/".extraheader || :

# ----------------------------
# Reset origin
# ----------------------------
echo "Resetting origin to: https://$GITHUB_ACTOR:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY"
git remote set-url origin "https://$GITHUB_ACTOR:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY"

# ----------------------------
# Add temporary upstream
# ----------------------------
echo "Adding tmp_upstream $UPSTREAM_REPO"
git remote add tmp_upstream "$UPSTREAM_REPO"
git fetch tmp_upstream --quiet
git remote --verbose

# ----------------------------
# Determine if DEST_BRANCH exists
# ----------------------------
if git show-ref --verify --quiet "refs/heads/$DEST_BRANCH" || git ls-remote --heads origin "$DEST_BRANCH" | grep -q "$DEST_BRANCH"; then
  # Branch exists locally or on origin -> use rebase
  echo "Branch $DEST_BRANCH exists, using checkout and rebase"

  # Checkout branch (create locally if only exists on origin)
  if git show-ref --verify --quiet "refs/heads/$DEST_BRANCH"; then
    git checkout "$DEST_BRANCH"
  else
    git checkout -b "$DEST_BRANCH" "origin/$DEST_BRANCH"
  fi

  # Pull latest from origin
  git pull --rebase origin "$DEST_BRANCH" || echo "No upstream changes"

  # Rebase on tmp_upstream/SOURCE_BRANCH
  git fetch tmp_upstream "$SOURCE_BRANCH:$SOURCE_BRANCH" --quiet
  git rebase "$SOURCE_BRANCH"

  # Push changes
  git push origin "$DEST_BRANCH"
else
  # Branch does not exist -> use original push refs method
  echo "Branch $DEST_BRANCH does not exist, pushing directly from tmp_upstream"
  git push origin "refs/remotes/tmp_upstream/$SOURCE_BRANCH:refs/heads/$DEST_BRANCH" --force
fi

# ----------------------------
# Optional tag sync
# ----------------------------
git fetch tmp_upstream --tags --quiet

if [[ "$SYNC_TAGS" = true ]]; then
  echo "Force syncing all tags"
  git tag -d $(git tag -l) > /dev/null
  git push origin --tags --force
elif [[ -n "$SYNC_TAGS" ]]; then
  echo "Force syncing tags matching pattern: $SYNC_TAGS"
  git tag -d $(git tag -l) > /dev/null
  git tag | grep "$SYNC_TAGS" | xargs --no-run-if-empty git push origin --force
fi

# ----------------------------
# Cleanup
# ----------------------------
echo "Removing tmp_upstream"
git remote rm tmp_upstream
git remote --verbose