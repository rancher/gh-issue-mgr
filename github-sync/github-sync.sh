#!/bin/bash
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
# Function to sync a single branch with rebase support
# ----------------------------
sync_branch() {
  local SOURCE_BRANCH=$1
  local DEST_BRANCH=$2
  
  echo "----------------------------------------"
  echo "Syncing: $SOURCE_BRANCH -> $DEST_BRANCH"
  echo "----------------------------------------"
  
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
    git fetch tmp_upstream "$SOURCE_BRANCH:tmp_sync_$SOURCE_BRANCH" --quiet
    
    # Rebase on tmp_sync_SOURCE_BRANCH with error handling
    if ! git rebase "tmp_sync_$SOURCE_BRANCH"; then
      echo "❌ Rebase failed for $DEST_BRANCH, aborting..."
      git rebase --abort
      # Clean up temp branch
      git branch -D "tmp_sync_$SOURCE_BRANCH" 2>/dev/null || true
      return 1
    fi

    # Clean up temp branch
    git branch -D "tmp_sync_$SOURCE_BRANCH" 2>/dev/null || true

    # Push changes to origin
    git push origin "$DEST_BRANCH"
    echo "✓ Successfully synced $DEST_BRANCH with rebase"
  else
    # Branch does not exist -> use direct push method
    echo "Branch $DEST_BRANCH does not exist, pushing directly from tmp_upstream"
    git push origin "refs/remotes/tmp_upstream/$SOURCE_BRANCH:refs/heads/$DEST_BRANCH" --force
    echo "✓ Successfully created $DEST_BRANCH"
  fi
  
  return 0
}

# ----------------------------
# Check if pattern contains wildcard
# ----------------------------
if [[ "$BRANCH_PATTERN" == *"*"* ]]; then
  echo "Detected wildcard pattern, syncing multiple branches with rebase support"
  
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
  
  # Track failures
  FAILED_BRANCHES=()
  SUCCESS_COUNT=0
  
  # Sync each branch individually
  while IFS= read -r SOURCE_BRANCH; do
    # Calculate destination branch name based on pattern
    if [[ "$SOURCE_PATTERN" == "$DEST_PATTERN" ]]; then
      DEST_BRANCH="$SOURCE_BRANCH"
    else
      # Simple replacement for pattern mapping
      # For v* -> v*, keep the same name
      # For feature-* -> prod-*, replace prefix
      if [[ "$SOURCE_PATTERN" == *"*" && "$DEST_PATTERN" == *"*" ]]; then
        PREFIX_SOURCE=${SOURCE_PATTERN%\**}
        PREFIX_DEST=${DEST_PATTERN%\**}
        SUFFIX_SOURCE=${SOURCE_PATTERN#*\*}
        SUFFIX_DEST=${DEST_PATTERN#*\*}
        
        # Extract the wildcard part
        WILDCARD_PART=${SOURCE_BRANCH#$PREFIX_SOURCE}
        WILDCARD_PART=${WILDCARD_PART%$SUFFIX_SOURCE}
        
        DEST_BRANCH="${PREFIX_DEST}${WILDCARD_PART}${SUFFIX_DEST}"
      else
        DEST_BRANCH="${SOURCE_BRANCH/$SOURCE_PATTERN/$DEST_PATTERN}"
      fi
    fi
    
    if sync_branch "$SOURCE_BRANCH" "$DEST_BRANCH"; then
      ((SUCCESS_COUNT++))
    else
      FAILED_BRANCHES+=("$SOURCE_BRANCH -> $DEST_BRANCH")
    fi
    
  done <<< "$MATCHING_BRANCHES"
  
  # Summary
  echo ""
  echo "========================================"
  echo "Wildcard Sync Summary"
  echo "========================================"
  echo "✓ Successfully synced: $SUCCESS_COUNT branches"
  
  if [[ ${#FAILED_BRANCHES[@]} -gt 0 ]]; then
    echo "❌ Failed to sync: ${#FAILED_BRANCHES[@]} branches"
    for branch in "${FAILED_BRANCHES[@]}"; do
      echo "  - $branch"
    done
    exit 1
  fi
  
else
  # Original single-branch logic
  SOURCE_BRANCH=${BRANCH_PATTERN%%:*}
  DEST_BRANCH=${BRANCH_PATTERN#*:}
  
  echo "Syncing single branch: $SOURCE_BRANCH -> $DEST_BRANCH"
  
  if ! sync_branch "$SOURCE_BRANCH" "$DEST_BRANCH"; then
    exit 1
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

echo ""
echo "✓ Sync completed successfully!"