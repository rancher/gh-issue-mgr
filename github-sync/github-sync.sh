#!/bin/sh
set -e

# ----------------------------
# Configure Git safe directory for CI (GitHub Actions)
# ----------------------------
git config --global --add safe.directory /github/workspace

# ----------------------------
# Input arguments
# ----------------------------
UPSTREAM_REPO=$1        # The upstream repository URL or GitHub "owner/repo" shorthand
BRANCH_MAPPING=$2       # Format: SOURCE_BRANCH:DEST_BRANCH

if [ -z "$UPSTREAM_REPO" ]; then
  echo "Missing \$UPSTREAM_REPO"
  exit 1
fi

if [ -z "$BRANCH_MAPPING" ]; then
  echo "Missing \$SOURCE_BRANCH:\$DEST_BRANCH"
  exit 1
fi

SOURCE_BRANCH=${BRANCH_MAPPING%%:*}  # Extract source branch
DEST_BRANCH=${BRANCH_MAPPING#*:}     # Extract destination branch

# ----------------------------
# Normalize upstream URL
# ----------------------------
if ! echo "$UPSTREAM_REPO" | grep -Eq ':|@|\.git\/?$'; then
  echo "Assuming GitHub repo shorthand"
  UPSTREAM_REPO="https://github.com/${UPSTREAM_REPO}.git"
fi

echo "UPSTREAM_REPO=$UPSTREAM_REPO"
echo "SOURCE_BRANCH=$SOURCE_BRANCH"
echo "DEST_BRANCH=$DEST_BRANCH"

# ----------------------------
# Reset origin remote to use GitHub token
# ----------------------------
git config --unset-all http."https://github.com/".extraheader || :
git remote set-url origin "https://$GITHUB_ACTOR:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY"

# ----------------------------
# Add temporary upstream remote
# ----------------------------
git remote add tmp_upstream "$UPSTREAM_REPO"
git fetch tmp_upstream --quiet
git fetch origin --quiet
git remote --verbose

# ----------------------------
# Check if the source branch is a wildcard
# ----------------------------
if echo "$SOURCE_BRANCH" | grep -q "\*"; then
  echo "Wildcard branch detected: $SOURCE_BRANCH"
  
  # Find all branches in tmp_upstream matching the pattern
  matching_branches=$(git for-each-ref --format='%(refname:short)' refs/remotes/tmp_upstream/ | grep -E "$SOURCE_BRANCH")
  
  if [ -z "$matching_branches" ]; then
    echo "No upstream branches match pattern $SOURCE_BRANCH"
    exit 1
  fi

  # Push each matching branch to origin
  for upstream_branch in $matching_branches; do
    branch_name="${upstream_branch##*/}"  # Remove refs/remotes/tmp_upstream/ prefix
    
    if [ "$DEST_BRANCH" = "$SOURCE_BRANCH" ]; then
      target_branch="$branch_name"
    else
      target_branch="$DEST_BRANCH"
    fi

    echo "Pushing tmp_upstream/$upstream_branch -> origin/$target_branch"
    git push origin "refs/remotes/tmp_upstream/$upstream_branch:refs/heads/$target_branch" --force
  done

else
  # ----------------------------
  # Single branch sync
  # ----------------------------
  echo "Single branch sync: $SOURCE_BRANCH -> $DEST_BRANCH"

  # Checkout or create the destination branch locally
  if git show-ref --verify --quiet "refs/heads/$DEST_BRANCH"; then
    git checkout "$DEST_BRANCH"
  else
    if git ls-remote --heads origin "$DEST_BRANCH" | grep -q "$DEST_BRANCH"; then
      git checkout -b "$DEST_BRANCH" "origin/$DEST_BRANCH"
    else
      git checkout -b "$DEST_BRANCH"
    fi
  fi

  # Pull latest changes from origin (rebase)
  git pull --rebase origin "$DEST_BRANCH" || echo "No upstream changes"

  # Compare local branch with tmp_upstream branch
  UPSTREAM_HASH=$(git rev-parse "tmp_upstream/$SOURCE_BRANCH")
  LOCAL_HASH=$(git rev-parse "HEAD")

  if [ "$UPSTREAM_HASH" != "$LOCAL_HASH" ]; then
    echo "Branches differ, rebasing $DEST_BRANCH on tmp_upstream/$SOURCE_BRANCH"
    git rebase "tmp_upstream/$SOURCE_BRANCH"
  else
    echo "Branches are already in sync."
  fi

  # Push the local branch to origin
  git push --set-upstream origin "$DEST_BRANCH"
fi

# ----------------------------
# Optional: Sync tags
# ----------------------------
git fetch tmp_upstream --tags --quiet

if [ "$SYNC_TAGS" = "true" ]; then
  echo "Force syncing all tags"
  git push origin --tags --force
elif [ -n "$SYNC_TAGS" ]; then
  echo "Force syncing tags matching pattern: $SYNC_TAGS"
  git tag | grep -E "$SYNC_TAGS" | xargs -r git push origin --force
fi

# ----------------------------
# Cleanup temporary upstream remote
# ----------------------------
git remote rm tmp_upstream
git remote --verbose
