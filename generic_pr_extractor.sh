#!/bin/bash
# Azure DevOps PR Comment Extractor
# Script to download ALL completed PR reviews and comments from Azure DevOps
# Handles pagination, includes error handling, and aggregates reviewers/votes/comments
# Outputs comprehensive CSV files with PR details, reviews, and comments

# Configuration - EDIT THESE VALUES FOR YOUR REPOSITORY
ORG_NAME="YourOrgName"              # Your Azure DevOps organization name
PROJECT_NAME="YourProjectName"      # Your project name
REPOSITORY_NAME="YourRepoName"      # Repository name to extract PRs from
REPOSITORY_ID=""                    # Repository ID (leave blank to auto-detect)
OUTPUT_DIR="pr_data"                # Directory where results will be saved
PAGE_SIZE=100                       # Number of PRs to fetch per API call
MAX_PAGES=200                       # Safety limit to prevent infinite loops
COMPLETED_ONLY=true                 # Set to true to only include completed PRs

# Create output directory
mkdir -p "$OUTPUT_DIR"
LOG_FILE="$OUTPUT_DIR/extraction.log"
echo "Starting PR comment extraction at $(date)" > "$LOG_FILE"

# Check for PAT token
if [ -z "$AZURE_DEVOPS_PAT" ]; then
  echo "Error: AZURE_DEVOPS_PAT environment variable not set" | tee -a "$LOG_FILE"
  echo "Please set it with: export AZURE_DEVOPS_PAT=your_personal_access_token" | tee -a "$LOG_FILE"
  exit 1
fi

# Check for required tools
if ! command -v curl &> /dev/null; then
  echo "Error: curl is required but not installed" | tee -a "$LOG_FILE"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but not installed" | tee -a "$LOG_FILE"
  exit 1
fi

# Create auth header
AUTH_HEADER="Basic $(echo -n ":$AZURE_DEVOPS_PAT" | base64 -w 0)"

# Get repository ID if not provided
if [ -z "$REPOSITORY_ID" ]; then
  echo "No repository ID provided. Attempting to fetch it..." | tee -a "$LOG_FILE"
  REPO_URL="https://dev.azure.com/$ORG_NAME/$PROJECT_NAME/_apis/git/repositories/$REPOSITORY_NAME?api-version=6.0"
  REPO_RESPONSE=$(curl -s -H "Authorization: $AUTH_HEADER" "$REPO_URL")
  
  if echo "$REPO_RESPONSE" | jq -e '.id' &>/dev/null; then
    REPOSITORY_ID=$(echo "$REPO_RESPONSE" | jq -r '.id')
    echo "Found repository ID: $REPOSITORY_ID" | tee -a "$LOG_FILE"
  else
    echo "Error: Could not fetch repository ID. Please check your organization, project, and repository names." | tee -a "$LOG_FILE"
    echo "Response: $(echo "$REPO_RESPONSE" | head -c 200)" | tee -a "$LOG_FILE"
    exit 1
  fi
fi

echo "Fetching all pull requests for $REPOSITORY_NAME (with pagination)..." | tee -a "$LOG_FILE"

# Create a temporary file to store all PR data
ALL_PRS_FILE=$(mktemp)
echo "[]" > "$ALL_PRS_FILE"

# Pagination variables
SKIP=0
PAGE_COUNT=0
CONTINUE=true

# Fetch PRs in batches using pagination
while $CONTINUE && [ $PAGE_COUNT -lt $MAX_PAGES ]; do
  PAGE_COUNT=$((PAGE_COUNT + 1))
  echo "Fetching PRs batch $PAGE_COUNT (skip=$SKIP)..." | tee -a "$LOG_FILE"
  
  # Basic API query with skip parameter for pagination
  PR_URL="https://dev.azure.com/$ORG_NAME/$PROJECT_NAME/_apis/git/repositories/$REPOSITORY_NAME/pullRequests?api-version=6.0&searchCriteria.status=all&\$top=$PAGE_SIZE&\$skip=$SKIP"
  
  PR_RESPONSE=$(curl -s -H "Authorization: $AUTH_HEADER" "$PR_URL")
  
  # Check if response is valid
  if ! echo "$PR_RESPONSE" | jq empty &>/dev/null; then
    echo "Error: Invalid JSON response for batch $PAGE_COUNT" | tee -a "$LOG_FILE"
    echo "First 200 chars: $(echo "$PR_RESPONSE" | head -c 200)" | tee -a "$LOG_FILE"
    break
  fi
  
  # Count PRs in this batch
  PR_COUNT=$(echo "$PR_RESPONSE" | jq '.value | length')
  if [ -z "$PR_COUNT" ] || ! [[ "$PR_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Warning: Could not determine PR count in batch $PAGE_COUNT. Assuming 0." | tee -a "$LOG_FILE"
    PR_COUNT=0
  fi
  
  echo "Found $PR_COUNT PRs in batch $PAGE_COUNT." | tee -a "$LOG_FILE"
  
  if [ "$PR_COUNT" -eq 0 ]; then
    echo "No more PRs found. Finished fetching." | tee -a "$LOG_FILE"
    break
  fi
  
  # Append these PRs to our collection
  TEMP=$(mktemp)
  jq -s '.[0] + .[1].value' "$ALL_PRS_FILE" <(echo "$PR_RESPONSE") > "$TEMP"
  mv "$TEMP" "$ALL_PRS_FILE"
  
  # Move to next page
  SKIP=$((SKIP + PAGE_SIZE))
  
  # Check if we need to continue pagination
  if [ "$PR_COUNT" -lt "$PAGE_SIZE" ]; then
    echo "Received fewer PRs than page size. No more pages." | tee -a "$LOG_FILE"
    CONTINUE=false
  fi
  
  # Sleep to avoid API rate limiting
  sleep 1
done

if [ $PAGE_COUNT -ge $MAX_PAGES ]; then
  echo "Warning: Reached maximum page limit ($MAX_PAGES). Some PRs may not have been processed." | tee -a "$LOG_FILE"
fi

# Sort PRs by creation date (oldest first)
echo "Sorting PRs by creation date (oldest first)..." | tee -a "$LOG_FILE"
SORTED_PRS_FILE=$(mktemp)
jq 'sort_by(.creationDate)' "$ALL_PRS_FILE" > "$SORTED_PRS_FILE"

# Count total PRs
TOTAL_PRS=$(jq length "$SORTED_PRS_FILE")
echo "Found $TOTAL_PRS total PRs after pagination." | tee -a "$LOG_FILE"

# Create a file for PRs only (without comments)
PR_LIST_FILE="$OUTPUT_DIR/all_prs.csv"
echo "PR ID,PR Title,PR Creator,PR Created Date,PR Status,PR URL,PR Merge Status,Build Info,Deployment Info" > "$PR_LIST_FILE"

# Create CSV header for comments
echo "PR ID,PR Title,PR Creator,PR Created Date,PR Status,PR URL,Build Info,Deployment Info,Thread ID,Comment ID,Comment Author,Comment Date,Comment Content,File Path,Line Number" > "$OUTPUT_FILE"

# Process each PR in chronological order (oldest first)
PROCESSED=0
TOTAL_COMMENTS=0

# Create a debug directory
mkdir -p "$OUTPUT_DIR/debug"

jq -c '.[]' "$SORTED_PRS_FILE" | while read -r PR; do
  # Extract PR info
  PR_ID=$(echo "$PR" | jq -r '.pullRequestId')
  PR_TITLE=$(echo "$PR" | jq -r '.title // "Unknown"' | sed 's/,/;/g' | sed 's/"/""/g')
  PR_CREATOR=$(echo "$PR" | jq -r '.createdBy.displayName // "Unknown"' | sed 's/,/;/g' | sed 's/"/""/g')
  PR_CREATED_DATE=$(echo "$PR" | jq -r '.creationDate // "Unknown"')
  PR_STATUS=$(echo "$PR" | jq -r '.status // "Unknown"')
  PR_MERGE_STATUS=$(echo "$PR" | jq -r '.mergeStatus // "Unknown"')
  PR_URL="https://dev.azure.com/$ORG_NAME/$PROJECT_NAME/_git/$REPOSITORY_NAME/pullrequest/$PR_ID"
  
  # Skip non-completed PRs if COMPLETED_ONLY is true
  if [ "$COMPLETED_ONLY" = true ] && [ "$PR_STATUS" != "completed" ]; then
    echo "Skipping PR #$PR_ID: Status is $PR_STATUS (not completed)" | tee -a "$LOG_FILE"
    continue
  fi
  
  PROCESSED=$((PROCESSED + 1))
  echo "Processing PR #$PR_ID ($PROCESSED of $TOTAL_PRS): $PR_TITLE" | tee -a "$LOG_FILE"
  
  # Get build information associated with this PR
  BUILD_INFO="Unknown"
  BUILD_NUMBER="Unknown"
  BUILD_RESULT="Unknown"
  DEPLOYMENT_INFO="Not Available"
  
  # Extract commit ID from the PR if available
  COMMIT_ID=$(echo "$PR" | jq -r '.lastMergeCommit.commitId // .lastMergeSourceCommit.commitId // "Unknown"')
  
  # Get the PR completion date and creator for matching
  PR_COMPLETED_DATE=$(echo "$PR" | jq -r '.closedDate // .completionDate // "Unknown"')
  PR_CREATOR_ID=$(echo "$PR" | jq -r '.createdBy.id // "Unknown"')
  
  # Try to find builds associated with this PR - use repository ID filter
  BUILD_URL="https://dev.azure.com/$ORG_NAME/$PROJECT_NAME/_apis/build/builds?api-version=6.0&repositoryId=$REPOSITORY_ID&repositoryType=TfsGit&queryOrder=finishTimeDescending&top=50"
  BUILD_RESPONSE=$(curl -s -H "Authorization: $AUTH_HEADER" "$BUILD_URL")
  
  # Save the build response for debugging
  if [ "$PROCESSED" -le 3 ]; then
    mkdir -p "$OUTPUT_DIR/debug"
    echo "$BUILD_RESPONSE" > "$OUTPUT_DIR/debug/repo_builds_pr_${PR_ID}.json"
  fi
  
  # Check if the response is valid and has a value array
  if echo "$BUILD_RESPONSE" | jq -e '.value' &>/dev/null; then
    PR_BUILD=""
    
    # First, try to match by commit ID if we have one
    if [ "$COMMIT_ID" != "Unknown" ]; then
      PR_BUILD=$(echo "$BUILD_RESPONSE" | jq -c '.value[] | select(.sourceVersion != null and .sourceVersion == "'$COMMIT_ID'") | {id: .id, number: .buildNumber, result: .result, status: .status}' | head -1)
    fi
    
    # If no match by commit ID, try time-based matching
    if [ -z "$PR_BUILD" ] && [ "$PR_COMPLETED_DATE" != "Unknown" ]; then
      # Extract just the date part for fuzzy matching
      PR_COMPLETED_DATE_ONLY=$(echo "$PR_COMPLETED_DATE" | cut -d'T' -f1)
      PR_COMPLETED_TIME=$(echo "$PR_COMPLETED_DATE" | cut -d'T' -f2 | cut -d'.' -f1)
      
      # Look for builds completed around the same time as the PR (within 1 hour)
      echo "$BUILD_RESPONSE" | jq -c '.value[]' | while read -r BUILD; do
        # Check if build has finish time
        BUILD_FINISH_TIME=$(echo "$BUILD" | jq -r '.finishTime // "Unknown"')
        if [ "$BUILD_FINISH_TIME" != "Unknown" ]; then
          # Extract date and time for comparison
          BUILD_DATE=$(echo "$BUILD_FINISH_TIME" | cut -d'T' -f1)
          BUILD_TIME=$(echo "$BUILD_FINISH_TIME" | cut -d'T' -f2 | cut -d'.' -f1)
          
          # If date matches and requested by same person, likely match
          if [ "$BUILD_DATE" = "$PR_COMPLETED_DATE_ONLY" ]; then
            # Check if this build was requested by the same person who created the PR
            BUILD_REQUESTOR=$(echo "$BUILD" | jq -r '.requestedFor.id // "Unknown"')
            if [ "$BUILD_REQUESTOR" = "$PR_CREATOR_ID" ]; then
              # Very likely the right build
              PR_BUILD=$(echo "$BUILD" | jq -c '{id: .id, number: .buildNumber, result: .result, status: .status}')
              break
            elif [ -z "$PR_BUILD" ]; then
              # Possible match, save it but continue looking for a better one
              PR_BUILD=$(echo "$BUILD" | jq -c '{id: .id, number: .buildNumber, result: .result, status: .status}')
            fi
          fi
        fi
      done
    fi
    
    # If we found a build, extract the information
    if [ -n "$PR_BUILD" ]; then
      BUILD_NUMBER=$(echo "$PR_BUILD" | jq -r '.number // "Unknown"')
      BUILD_RESULT=$(echo "$PR_BUILD" | jq -r '.result // "Unknown"')
      BUILD_INFO="Build #$BUILD_NUMBER ($BUILD_RESULT)"
    fi
  else
    echo "  - Warning: Invalid or empty build response" | tee -a "$LOG_FILE"
  fi
  
  # ALWAYS add PR to the PR list file
  echo "$PR_ID,\"$PR_TITLE\",\"$PR_CREATOR\",\"$PR_CREATED_DATE\",\"$PR_STATUS\",\"$PR_URL\",\"$PR_MERGE_STATUS\",\"$BUILD_INFO\",\"$DEPLOYMENT_INFO\"" >> "$PR_LIST_FILE"
  
  # Get PR threads (comments)
  THREADS_URL="https://dev.azure.com/$ORG_NAME/$PROJECT_NAME/_apis/git/repositories/$REPOSITORY_NAME/pullRequests/$PR_ID/threads?api-version=6.0"
  THREADS_RESPONSE=$(curl -s -H "Authorization: $AUTH_HEADER" "$THREADS_URL")
  
  # Check if threads response is valid
  if ! echo "$THREADS_RESPONSE" | jq empty &>/dev/null; then
    echo "  - Warning: Invalid JSON response for threads" | tee -a "$LOG_FILE"
    echo "$PR_ID,\"$PR_TITLE\",\"$PR_CREATOR\",\"$PR_CREATED_DATE\",\"$PR_STATUS\",\"$PR_URL\",\"$BUILD_INFO\",\"$DEPLOYMENT_INFO\",\"\",\"\",\"Error fetching comments\",\"\",\"\",\"\",\"\"" >> "$OUTPUT_FILE"
    continue
  fi
  
  # If we got a valid response but there are no threads or comments,
  # still add an entry for this PR in the comments CSV
  THREAD_COUNT=0
  if echo "$THREADS_RESPONSE" | jq -e '.value' &>/dev/null; then
    THREAD_COUNT=$(echo "$THREADS_RESPONSE" | jq '.value | length')
    if [ -z "$THREAD_COUNT" ] || ! [[ "$THREAD_COUNT" =~ ^[0-9]+$ ]]; then
      echo "  - Warning: Could not determine thread count. Assuming 0." | tee -a "$LOG_FILE"
      THREAD_COUNT=0
    fi
    
    echo "  - Found $THREAD_COUNT comment threads" | tee -a "$LOG_FILE"
    
    # If no threads found, still add this PR to the comments CSV
    if [ "$THREAD_COUNT" -eq 0 ]; then
      echo "$PR_ID,\"$PR_TITLE\",\"$PR_CREATOR\",\"$PR_CREATED_DATE\",\"$PR_STATUS\",\"$PR_URL\",\"$BUILD_INFO\",\"$DEPLOYMENT_INFO\",\"\",\"\",\"No comments\",\"\",\"\",\"\",\"\"" >> "$OUTPUT_FILE"
      continue
    fi
    
    # Process each thread - DIRECT APPROACH
    PR_COMMENTS=0
    
    # Direct approach using temporary files for thread and comment data
    THREADS_TEMP=$(mktemp)
    echo "$THREADS_RESPONSE" | jq '.value' > "$THREADS_TEMP"
    
    for i in $(seq 0 $((THREAD_COUNT - 1))); do
      THREAD_TEMP=$(mktemp)
      jq ".[$i]" "$THREADS_TEMP" > "$THREAD_TEMP"
      
      # Extract thread info
      THREAD_ID=$(jq -r '.id' "$THREAD_TEMP")
      
      # Basic file path and line info
      FILE_PATH=$(jq -r '.threadContext.filePath // ""' "$THREAD_TEMP" | sed 's/,/;/g' | sed 's/"/""/g')
      LINE_NUMBER=$(jq -r '.threadContext.rightFileStart.line // ""' "$THREAD_TEMP")
      
      # Check if thread has comments
      if jq -e '.comments' "$THREAD_TEMP" > /dev/null; then
        COMMENTS_TEMP=$(mktemp)
        jq '.comments' "$THREAD_TEMP" > "$COMMENTS_TEMP"
        COMMENTS_COUNT=$(jq 'length' "$COMMENTS_TEMP")
        
        # If no comments in thread, add an entry for this thread
        if [ "$COMMENTS_COUNT" -eq 0 ]; then
          echo "$PR_ID,\"$PR_TITLE\",\"$PR_CREATOR\",\"$PR_CREATED_DATE\",\"$PR_STATUS\",\"$PR_URL\",\"$BUILD_INFO\",\"$DEPLOYMENT_INFO\",\"$THREAD_ID\",\"\",\"No comments in thread\",\"\",\"\",\"$FILE_PATH\",\"$LINE_NUMBER\"" >> "$OUTPUT_FILE"
          continue
        fi
        
        for j in $(seq 0 $((COMMENTS_COUNT - 1))); do
          COMMENT_TEMP=$(mktemp)
          jq ".[$j]" "$COMMENTS_TEMP" > "$COMMENT_TEMP"
          
          # Extract comment info
          COMMENT_ID=$(jq -r '.id' "$COMMENT_TEMP")
          
          # Make sure author object exists before trying to extract displayName
          if jq -e '.author' "$COMMENT_TEMP" > /dev/null; then
            COMMENT_AUTHOR=$(jq -r '.author.displayName // "Unknown"' "$COMMENT_TEMP" | sed 's/,/;/g' | sed 's/"/""/g')
          else
            COMMENT_AUTHOR="Unknown"
          fi
          
          COMMENT_DATE=$(jq -r '.publishedDate // .lastUpdatedDate // "Unknown"' "$COMMENT_TEMP")
          
          # Check if content exists and extract it
          if jq -e '.content' "$COMMENT_TEMP" > /dev/null; then
            # Extract content and clean it up
            COMMENT_CONTENT=$(jq -r '.content // ""' "$COMMENT_TEMP")
            
            # Skip empty content
            if [ -z "$COMMENT_CONTENT" ]; then
              echo "  - Warning: Empty content in comment $COMMENT_ID of thread $THREAD_ID" | tee -a "$LOG_FILE"
              continue
            fi
            
            # Clean up the content for CSV
            COMMENT_CONTENT=$(echo "$COMMENT_CONTENT" | sed 's/,/;/g' | sed 's/"/""/g' | tr '\n\r' ' ')
            
            # Write to CSV
            echo "$PR_ID,\"$PR_TITLE\",\"$PR_CREATOR\",\"$PR_CREATED_DATE\",\"$PR_STATUS\",\"$PR_URL\",\"$BUILD_INFO\",\"$DEPLOYMENT_INFO\",\"$THREAD_ID\",\"$COMMENT_ID\",\"$COMMENT_AUTHOR\",\"$COMMENT_DATE\",\"$COMMENT_CONTENT\",\"$FILE_PATH\",\"$LINE_NUMBER\"" >> "$OUTPUT_FILE"
            
            PR_COMMENTS=$((PR_COMMENTS + 1))
            TOTAL_COMMENTS=$((TOTAL_COMMENTS + 1))
          else
            # No content found
            echo "  - Warning: No content in comment $COMMENT_ID of thread $THREAD_ID" | tee -a "$LOG_FILE"
            # Add entry for comments with no content
            echo "$PR_ID,\"$PR_TITLE\",\"$PR_CREATOR\",\"$PR_CREATED_DATE\",\"$PR_STATUS\",\"$PR_URL\",\"$BUILD_INFO\",\"$DEPLOYMENT_INFO\",\"$THREAD_ID\",\"$COMMENT_ID\",\"$COMMENT_AUTHOR\",\"$COMMENT_DATE\",\"No content\",\"$FILE_PATH\",\"$LINE_NUMBER\"" >> "$OUTPUT_FILE"
          fi
          
          rm "$COMMENT_TEMP"
        done
        
        rm "$COMMENTS_TEMP"
      else
        echo "  - Warning: No comments in thread $THREAD_ID" | tee -a "$LOG_FILE"
        # Add an entry for threads with no comments
        echo "$PR_ID,\"$PR_TITLE\",\"$PR_CREATOR\",\"$PR_CREATED_DATE\",\"$PR_STATUS\",\"$PR_URL\",\"$BUILD_INFO\",\"$DEPLOYMENT_INFO\",\"$THREAD_ID\",\"\",\"No comments in thread\",\"\",\"\",\"$FILE_PATH\",\"$LINE_NUMBER\"" >> "$OUTPUT_FILE"
      fi
      
      rm "$THREAD_TEMP"
    done
    
    rm "$THREADS_TEMP"
    
    echo "  - Extracted $PR_COMMENTS comments" | tee -a "$LOG_FILE"
    
    # If no comments were found at all despite having threads
    if [ "$PR_COMMENTS" -eq 0 ]; then
      echo "$PR_ID,\"$PR_TITLE\",\"$PR_CREATOR\",\"$PR_CREATED_DATE\",\"$PR_STATUS\",\"$PR_URL\",\"$BUILD_INFO\",\"$DEPLOYMENT_INFO\",\"\",\"\",\"No comments found\",\"\",\"\",\"\",\"\"" >> "$OUTPUT_FILE"
    fi
    
  else
    echo "  - No threads found" | tee -a "$LOG_FILE"
    echo "$PR_ID,\"$PR_TITLE\",\"$PR_CREATOR\",\"$PR_CREATED_DATE\",\"$PR_STATUS\",\"$PR_URL\",\"$BUILD_INFO\",\"$DEPLOYMENT_INFO\",\"\",\"\",\"No comments\",\"\",\"\",\"\",\"\"" >> "$OUTPUT_FILE"
  fi
  
  # Sleep to avoid API rate limiting
  sleep 0.5
done

# Clean up temp files
rm -f "$ALL_PRS_FILE" "$SORTED_PRS_FILE"

# Count total entries in each CSV
PR_COUNT=$(grep -c "^" "$PR_LIST_FILE")
PR_COUNT=$((PR_COUNT - 1)) # Subtract header

COMMENT_COUNT=$(grep -c "^" "$OUTPUT_FILE")
COMMENT_COUNT=$((COMMENT_COUNT - 1)) # Subtract header

echo "Extraction complete!" | tee -a "$LOG_FILE"
echo "Total PRs processed: $PROCESSED" | tee -a "$LOG_FILE"
echo "Total PRs in PR list CSV: $PR_COUNT" | tee -a "$LOG_FILE"
echo "Total comments extracted: $TOTAL_COMMENTS" | tee -a "$LOG_FILE"
echo "Total entries in comments CSV: $COMMENT_COUNT" | tee -a "$LOG_FILE"
echo "Results saved to:" | tee -a "$LOG_FILE"
echo "- All PRs: $PR_LIST_FILE" | tee -a "$LOG_FILE"
echo "- Comments: $OUTPUT_FILE" | tee -a "$LOG_FILE"
echo "Completed at $(date)" | tee -a "$LOG_FILE"
