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

# Fetch origin to ensure local refs are up-to-date (once)
echo "Fetching origin branches"
git fetch origin --prune --quiet

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
  
  # Clean up any leftover rebase state
  if [[ -d ".git/rebase-merge" ]] || [[ -d ".git/rebase-apply" ]]; then
    echo "Cleaning up leftover rebase state..."
    git rebase --abort 2>/dev/null || true
    rm -fr .git/rebase-merge .git/rebase-apply 2>/dev/null || true
  fi
  
  # Check if destination branch exists on origin (remote)
  if git ls-remote --heads origin "$DEST_BRANCH" | grep -q "$DEST_BRANCH"; then
    echo "Branch $DEST_BRANCH exists on origin, using checkout and rebase"

    # Specific fetch for this branch to ensure ref exists
    git fetch origin "$DEST_BRANCH" --quiet
    
    # Ensure we're not on the target branch
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$CURRENT_BRANCH" == "$DEST_BRANCH" ]]; then
      git checkout --detach HEAD
    fi
    
    # Delete local branch if it exists (to ensure clean state)
    if git show-ref --verify --quiet "refs/heads/$DEST_BRANCH"; then
      git branch -D "$DEST_BRANCH" 2>/dev/null || true
    fi
    
    # Create fresh local branch from origin
    git checkout -b "$DEST_BRANCH" "origin/$DEST_BRANCH"
    
    # Fetch source branch from upstream
    git fetch tmp_upstream "$SOURCE_BRANCH:tmp_sync_$SOURCE_BRANCH" --quiet
    
    # Rebase on tmp_sync_SOURCE_BRANCH with error handling
    if ! git rebase "tmp_sync_$SOURCE_BRANCH"; then
      echo "❌ Rebase failed for $DEST_BRANCH with conflicts"
      echo "Conflict details:"
      git status --short || echo "No status available"
      echo ""
      echo "Aborting rebase and cleaning up..."
      git rebase --abort 2>/dev/null || true
      rm -fr .git/rebase-merge .git/rebase-apply 2>/dev/null || true
      
      # Clean up temp branch
      git branch -D "tmp_sync_$SOURCE_BRANCH" 2>/dev/null || true
      
      # Return to detached state to avoid leaving repo in bad state
      git checkout --detach HEAD 2>/dev/null || true
      
      return 1
    fi

    # Clean up temp branch
    git branch -D "tmp_sync_$SOURCE_BRANCH" 2>/dev/null || true

    # Push changes to origin with force-with-lease for safety
    if git push origin "$DEST_BRANCH" --force-with-lease; then
      echo "✓ Push successful for $DEST_BRANCH"
    else
      echo "❌ Push failed for $DEST_BRANCH - check branch protections or token permissions"
      return 1
    fi
    echo "✓ Successfully synced $DEST_BRANCH with rebase"
  else
    # Branch does not exist -> use direct push method
    echo "Branch $DEST_BRANCH does not exist, pushing directly from tmp_upstream"
    if git push origin "refs/remotes/tmp_upstream/$SOURCE_BRANCH:refs/heads/$DEST_BRANCH" --force; then
      echo "✓ Push successful for new $DEST_BRANCH"
    else
      echo "❌ Push failed for new $DEST_BRANCH"
      return 1
    fi
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
  
  echo "Found branches:"
  echo "$MATCHING_BRANCHES"
  
  # Track failures
  FAILED_BRANCHES=()
  SUCCESS_COUNT=0
  
  # Sync each branch individually
  while IFS= read -r SOURCE_BRANCH; do
    # Calculate destination branch name based on pattern
    if [[ "$SOURCE_PATTERN" == "$DEST_PATTERN" ]]; then
      DEST_BRANCH="$SOURCE_BRANCH"
    else
      # Pattern replacement logic
      if [[ "$SOURCE_PATTERN" == *"*" && "$DEST_PATTERN" == *"*" ]]; then
        # Both patterns have wildcards - extract and reconstruct
        PREFIX_SOURCE=${SOURCE_PATTERN%\**}
        PREFIX_DEST=${DEST_PATTERN%\**}
        SUFFIX_SOURCE=${SOURCE_PATTERN#*\*}
        SUFFIX_DEST=${DEST_PATTERN#*\*}
        
        # Extract the wildcard part
        WILDCARD_PART=${SOURCE_BRANCH#$PREFIX_SOURCE}
        WILDCARD_PART=${WILDCARD_PART%$SUFFIX_SOURCE}
        
        DEST_BRANCH="${PREFIX_DEST}${WILDCARD_PART}${SUFFIX_DEST}"
      else
        # Simple string replacement (fallback for non-wildcard patterns)
        DEST_BRANCH="${SOURCE_BRANCH/$SOURCE_PATTERN/$DEST_PATTERN}"
      fi
    fi
    
    if sync_branch "$SOURCE_BRANCH" "$DEST_BRANCH"; then
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      FAILED_BRANCHES+=("$SOURCE_BRANCH -> $DEST_BRANCH")
    fi
    
  done <<< "$MATCHING_BRANCHES"
  
  # Summary
  echo ""
  echo "========================================"
  echo "Wildcard Sync Summary"
  echo "========================================"
  echo "✓ Successfully synced $SUCCESS_COUNT branches"

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
echo "Syncing tags if specified: SYNC_TAGS=$SYNC_TAGS"

git fetch tmp_upstream --tags --quiet
if [[ $? -ne 0 ]]; then
  echo "❌ Failed to fetch tags from tmp_upstream"
  exit 1
fi

if [[ "$SYNC_TAGS" == "true" ]]; then
  echo "Force syncing all tags"
  if git push origin --tags --force; then
    echo "✓ Tags push successful"
  else
    echo "❌ Tags push failed"
    exit 1
  fi
elif [[ -n "$SYNC_TAGS" ]]; then
  echo "Force syncing tags matching pattern: $SYNC_TAGS"
  MATCHING_TAGS=$(git tag | grep "$SYNC_TAGS" || true)
  if [[ -n "$MATCHING_TAGS" ]]; then
    echo "$MATCHING_TAGS" | xargs -r git push origin --force
    echo "✓ Matching tags pushed"
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