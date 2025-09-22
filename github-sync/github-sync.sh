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

if ! echo $UPSTREAM_REPO | grep -Eq ':|@|\.git\/?$'
then
  echo "UPSTREAM_REPO does not seem to be a valid git URI, assuming it's a GitHub repo"
  echo "Originally: $UPSTREAM_REPO"
  UPSTREAM_REPO="https://github.com/${UPSTREAM_REPO}.git"
  echo "Now: $UPSTREAM_REPO"
fi

echo "UPSTREAM_REPO=$UPSTREAM_REPO"
echo "BRANCHES=$BRANCH_MAPPING"

git config --unset-all http."https://github.com/".extraheader || :

echo "Resetting origin to: https://$GITHUB_ACTOR:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY"
git remote set-url origin "https://$GITHUB_ACTOR:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY"

echo "Adding tmp_upstream $UPSTREAM_REPO"
git remote add tmp_upstream "$UPSTREAM_REPO"

echo "Fetching tmp_upstream"
git fetch tmp_upstream --quiet
git remote --verbose

echo "Pushing changings from tmp_upstream to origin"
git push origin "refs/remotes/tmp_upstream/${BRANCH_MAPPING%%:*}:refs/heads/${BRANCH_MAPPING#*:}" --force

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
