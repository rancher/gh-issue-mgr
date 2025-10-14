#!/bin/sh

set -e

UPSTREAM_REPO=$1
BRANCH_MAPPING=$2

if [[ -z "$UPSTREAM_REPO" ]]; then
  echo "Missing \$UPSTREAM_REPO"
  exit 1
fi

if [[ -z "$BRANCH_MAPPING" ]]; then
  echo "Missing \$SOURCE_BRANCH:\$DESTINATION_BRANCH"
  exit 1
fi

SOURCE_BRANCH=${BRANCH_MAPPING%%:*}
DEST_BRANCH=${BRANCH_MAPPING#*:}

if ! echo $UPSTREAM_REPO | grep -Eq ':|@|\.git\/?$'
then
  echo "UPSTREAM_REPO does not seem to be a valid git URI, assuming it's a GitHub repo"
  echo "Originally: $UPSTREAM_REPO"
  UPSTREAM_REPO="https://github.com/${UPSTREAM_REPO}.git"
  echo "Now: $UPSTREAM_REPO"
fi

echo "UPSTREAM_REPO=$UPSTREAM_REPO"
echo "SOURCE_BRANCH=$SOURCE_BRANCH"
echo "DEST_BRANCH=$DEST_BRANCH"

git config --unset-all http."https://github.com/".extraheader || :

echo "Resetting origin to: https://$GITHUB_ACTOR:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY"
git remote set-url origin "https://$GITHUB_ACTOR:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY"

echo "Adding tmp_upstream $UPSTREAM_REPO"
git remote add tmp_upstream "$UPSTREAM_REPO"

echo "Fetching branches"
git fetch tmp_upstream --quiet
git fetch origin --quiet

# Ensure destination branch exists  
if ! git show-ref --verify --quiet "refs/heads/$DEST_BRANCH"; then
  echo "Destination branch does not exist locally, creating it from origin"
  git checkout -b "$DEST_BRANCH" "origin/$DEST_BRANCH" || git checkout -b "$DEST_BRANCH"
else
  git checkout "$DEST_BRANCH"
  git pull origin "$DEST_BRANCH" --rebase
fi

# Compare upstream source branch with local destination branch
UPSTREAM_HASH=$(git rev-parse "tmp_upstream/$SOURCE_BRANCH")
LOCAL_HASH=$(git rev-parse "HEAD")

if [ "$UPSTREAM_HASH" != "$LOCAL_HASH" ]; then
  echo "Branches differ, rebasing $DEST_BRANCH on tmp_upstream/$SOURCE_BRANCH"
  git rebase "tmp_upstream/$SOURCE_BRANCH"
else
  echo "Branches are already in sync."
fi

echo "Pushing to origin/$DEST_BRANCH"
git push origin "$DEST_BRANCH"

# Optional: Sync tags
if [[ "$SYNC_TAGS" = true ]]; then
  echo "Syncing all tags (without deleting local tags)"
  # Fetch all tags from the upstream repository, without deleting local tags
  git fetch tmp_upstream --tags --quiet
  # Push all local tags to the origin repository (without --force)
  git push origin --tags
elif [[ -n "$SYNC_TAGS" ]]; then
  echo "Syncing tags matching pattern: $SYNC_TAGS (without deleting local tags)"
  # Fetch all tags from the upstream repository, without deleting local tags
  git fetch tmp_upstream --tags --quiet
  # Filter tags matching the pattern and push them to the origin repository
  git tag | grep "$SYNC_TAGS" | xargs --no-run-if-empty git push origin
fi

echo "Removing tmp_upstream"
git remote rm tmp_upstream
git remote --verbose
