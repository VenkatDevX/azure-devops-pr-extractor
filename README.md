# Azure DevOps PR Comment Extractor

This tool extracts all completed Pull Requests with their comments and build information from an Azure DevOps repository. It produces comprehensive CSV files that include PR details, build information, and all associated comments.

## Features

- Retrieves **completed** PRs from any Azure DevOps repository
- Extracts build information linked to each PR
- Collects all comments from each PR, including thread information
- Creates separate CSV files for PRs and comments
- Sorts PRs chronologically (oldest first)
- Handles pagination to retrieve hundreds of PRs
- Processes all comment threads and their individual comments
- Properly formats CSV output for easy analysis

## Prerequisites

- Bash shell environment (Linux, macOS, WSL on Windows)
- `curl` command for API requests
- [jq](https://stedolan.github.io/jq/download/) command-line JSON processor
- Azure DevOps Personal Access Token (PAT) with Code (Read) and Build (Read) permissions

## Setup

1. Clone or download this repository
2. Make the script executable:
   ```bash
   chmod +x complete_pr_csv_extractor.sh
   ```
3. Set your Azure DevOps PAT as an environment variable:
   ```bash
   export AZURE_DEVOPS_PAT=your_personal_access_token
   ```

## Configuration

Edit the script to set your specific configuration:

```bash
# Configuration
ORG_NAME="YourOrgName"              # Your Azure DevOps organization name
PROJECT_NAME="YourProjectName"      # Your project name
REPOSITORY_NAME="YourRepoName"      # Repository name to extract PRs from
OUTPUT_DIR="pr_data"                # Directory where results will be saved
PAGE_SIZE=100                       # Number of PRs to fetch per API call
MAX_PAGES=200                       # Safety limit to prevent infinite loops
COMPLETED_ONLY=true                 # Set to true to only include completed PRs
```

You'll also need to update the repository ID in the script with your specific repository ID. You can find this by running the diagnostic script included in this repository.

## Usage

Run the script from the command line:

```bash
./complete_pr_csv_extractor.sh
```

The script will:
1. Fetch all completed PRs from the specified repository (with pagination)
2. Sort them chronologically (oldest first)
3. Retrieve build information for each PR
4. Process each PR to extract comments
5. Create CSV output files

## Output Files

The script generates two main CSV files in the specified output directory:

1. `all_prs.csv` - Contains information about all completed PRs:
   - PR ID
   - PR Title
   - PR Creator
   - PR Created Date
   - PR Status
   - PR URL
   - PR Merge Status
   - Build Information (build number and result)
   - Deployment Information (if available)

2. `pr_comments.csv` - Contains all comments across all completed PRs:
   - PR ID
   - PR Title
   - PR Creator
   - PR Created Date
   - PR Status
   - PR URL
   - Build Information
   - Deployment Information
   - Thread ID
   - Comment ID
   - Comment Author
   - Comment Date
   - Comment Content
   - File Path
   - Line Number

Additionally, the script creates a detailed log file (`extraction.log`) with information about the extraction process.

## Build Information

The script attempts to retrieve build information linked to each PR by:

1. Matching by commit ID from the PR's merge commit
2. Time-based matching with the PR creator
3. Looking for builds completed on the same day as the PR

Depending on your Azure DevOps configuration, deployment information may or may not be available through the standard API.

## Example Usage Scenarios

### Analyzing PR Review Process

Use the extracted data to analyze:
- Comment frequency by author
- Average comments per PR
- Most commented files
- Correlation between PR size and review thoroughness

### Code Quality Insights

- Track which areas of code receive the most review comments
- Identify patterns in review feedback
- Analyze review comment types (questions, suggestions, issues)

### Team Collaboration Metrics

- Measure team engagement in code reviews
- Identify most active reviewers
- Analyze comment resolution patterns

## Troubleshooting

If you encounter issues:

1. Check the log file in `pr_data/extraction.log` for detailed error information
2. Ensure your PAT token has the correct permissions (Code Read and Build Read)
3. Verify you're using the correct organization, project, and repository ID
4. For detailed API diagnostics, run the included `build_api_test.sh` script

## Limitations

- Build and deployment information may not be correctly linked to PRs if there's no clear matching pattern
- Some Azure DevOps configurations may not provide access to all information
- The script may need customization for specific repository setups

## License

This tool is provided under the MIT License. Feel free to modify and adapt it to your needs.

