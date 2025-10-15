#!/bin/sh
set -e

# Fix Git safe directory issue
git config --global --add safe.directory /github/workspace

UPSTREAM_REPO=$1
BRANCH_PATTERN=$2

if [[ -z "$UPSTREAM_REPO" ]]; then
  echo "Missing \$UPSTREAM_REPO"
  exit 1
fi

if [[ -z "$BRANCH_PATTERN" ]]; then
  echo "Missing \$BRANCH_PATTERN"
  exit 1
fi

# ----------------------------
# Normalize upstream URL
# ----------------------------
if ! echo "$UPSTREAM_REPO" | grep -Eq ':|@|\.git\/?$'; then
  echo "Assuming GitHub repo shorthand"
  UPSTREAM_REPO="https://github.com/${UPSTREAM_REPO}.git"
fi

echo "UPSTREAM_REPO=$UPSTREAM_REPO"
echo "BRANCH_PATTERN=$BRANCH_PATTERN"

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
# Check if pattern contains wildcard
# ----------------------------
if [[ "$BRANCH_PATTERN" == *"*"* ]]; then
  echo "Detected wildcard pattern, syncing multiple branches"
  
  # Extract source and destination patterns
  SOURCE_PATTERN=${BRANCH_PATTERN%%:*}
  DEST_PATTERN=${BRANCH_PATTERN#*:}
  
  # Get list of remote branches matching the pattern
  # Convert shell wildcard to regex (e.g., v* -> v.*)
  MATCHING_BRANCHES=$(git ls-remote --heads tmp_upstream | awk '{print $2}' | sed 's|refs/heads/||' | grep "^${SOURCE_PATTERN//\*/.*}$" || true)
  
  if [[ -z "$MATCHING_BRANCHES" ]]; then
    echo "No branches matching pattern: $SOURCE_PATTERN"
    git remote rm tmp_upstream
    exit 0
  fi
  
  echo "Found branches: $MATCHING_BRANCHES"
  
  # Sync each branch individually
  while IFS= read -r SOURCE_BRANCH; do
    # Calculate destination branch name based on pattern
    if [[ "$SOURCE_PATTERN" == "$DEST_PATTERN" ]]; then
      DEST_BRANCH="$SOURCE_BRANCH"
    else
      # Simple replacement (extend this logic for more complex mappings)
      DEST_BRANCH="${SOURCE_BRANCH/$SOURCE_PATTERN/$DEST_PATTERN}"
    fi
    
    echo "Syncing $SOURCE_BRANCH -> $DEST_BRANCH"
    
    # Direct push (simplified version, no rebase for batch operations)
    git push origin "refs/remotes/tmp_upstream/$SOURCE_BRANCH:refs/heads/$DEST_BRANCH" --force
    
  done <<< "$MATCHING_BRANCHES"
  
else
  # Original single-branch logic
  SOURCE_BRANCH=${BRANCH_PATTERN%%:*}
  DEST_BRANCH=${BRANCH_PATTERN#*:}
  
  echo "Syncing single branch: $SOURCE_BRANCH -> $DEST_BRANCH"
  
  # Check if destination branch exists locally or remotely
  if git show-ref --verify --quiet "refs/heads/$DEST_BRANCH" || git ls-remote --heads origin "$DEST_BRANCH" | grep -q "$DEST_BRANCH"; then
    echo "Branch $DEST_BRANCH exists, using checkout and rebase"

    # Checkout branch (create locally if only exists on origin)
    if git show-ref --verify --quiet "refs/heads/$DEST_BRANCH"; then
      git checkout "$DEST_BRANCH"
    else
      git checkout -b "$DEST_BRANCH" "origin/$DEST_BRANCH"
    fi

    # Pull latest from origin
    git pull --rebase origin "$DEST_BRANCH" || echo "No upstream changes"
    
    # Fetch source branch from upstream
    git fetch tmp_upstream "$SOURCE_BRANCH:$SOURCE_BRANCH" --quiet
    
    # Rebase on tmp_upstream/SOURCE_BRANCH with error handling
    if ! git rebase "$SOURCE_BRANCH"; then
      echo "Rebase failed, aborting..."
      git rebase --abort
      exit 1
    fi

    # Push changes to origin
    git push origin "$DEST_BRANCH"
  else
    # Branch does not exist -> use direct push method
    echo "Branch $DEST_BRANCH does not exist, pushing directly from tmp_upstream"
    git push origin "refs/remotes/tmp_upstream/$SOURCE_BRANCH:refs/heads/$DEST_BRANCH" --force
  fi
fi

# ----------------------------
# Optional tag sync
# ----------------------------
git fetch tmp_upstream --tags --quiet

if [[ "$SYNC_TAGS" = true ]]; then
  echo "Force syncing all tags"
  # Only delete tags if they exist
  if [[ -n "$(git tag -l)" ]]; then
    git tag -d $(git tag -l) > /dev/null 2>&1 || true
  fi
  git push origin --tags --force
elif [[ -n "$SYNC_TAGS" ]]; then
  echo "Force syncing tags matching pattern: $SYNC_TAGS"
  # Only delete tags if they exist
  if [[ -n "$(git tag -l)" ]]; then
    git tag -d $(git tag -l) > /dev/null 2>&1 || true
  fi
  # Filter and push matching tags
  MATCHING_TAGS=$(git tag | grep "$SYNC_TAGS" || true)
  if [[ -n "$MATCHING_TAGS" ]]; then
    echo "$MATCHING_TAGS" | xargs -r git push origin --force
  else
    echo "No tags matching pattern: $SYNC_TAGS"
  fi
fi

# ----------------------------
# Cleanup
# ----------------------------
echo "Removing tmp_upstream"
git remote rm tmp_upstream
git remote --verbose