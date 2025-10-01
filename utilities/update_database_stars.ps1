# Database Star Count Updater (PowerShell Wrapper)
# This script updates the SQLite database with GitHub star counts

param(
    [int]$BatchSize = 100,
    [double]$RateLimit = 1.0,
    [switch]$Force
)

$DB_FILE = "force_push_commits.sqlite3"

Write-Host "Database Star Count Updater" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host "Database: $DB_FILE"
Write-Host "Batch Size: $BatchSize"
Write-Host "Rate Limit: $RateLimit seconds between requests"
Write-Host ""

# Check if database exists
if (-not (Test-Path $DB_FILE)) {
    Write-Host "❌ Database file '$DB_FILE' not found!" -ForegroundColor Red
    Write-Host "Make sure you're in the correct directory." -ForegroundColor Red
    exit 1
}

# Check if Python script exists
if (-not (Test-Path "update_database_stars.py")) {
    Write-Host "❌ update_database_stars.py not found!" -ForegroundColor Red
    exit 1
}

# Check for GitHub token
if (-not $env:GITHUB_TOKEN) {
    Write-Host "⚠️  Warning: GITHUB_TOKEN is not set!" -ForegroundColor Yellow
    Write-Host "   Without a token, you'll be limited to 60 requests/hour." -ForegroundColor Yellow
    Write-Host "   With a token, you get 5000 requests/hour." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   To set your token:" -ForegroundColor Yellow
    Write-Host "   `$env:GITHUB_TOKEN='your_personal_access_token'" -ForegroundColor Yellow
    Write-Host ""
    
    if (-not $Force) {
        $response = Read-Host "Continue without token? (y/N)"
        if ($response.ToLower() -ne 'y') {
            Write-Host "Aborted." -ForegroundColor Red
            exit 0
        }
    }
}

# Set environment variables for the Python script
$env:BATCH_SIZE = $BatchSize
$env:RATE_LIMIT_DELAY = $RateLimit

# Run the Python script
Write-Host "🚀 Starting database star count update..." -ForegroundColor Green
Write-Host ""

try {
    C:/Users/amede/AppData/Local/Programs/Python/Python311/python.exe update_database_stars.py
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "✅ Database update completed successfully!" -ForegroundColor Green
        Write-Host ""
        Write-Host "You can now use the fast query script:" -ForegroundColor Cyan
        Write-Host "  python query_orgs_by_stars.py 100    # Organizations with 100+ stars" -ForegroundColor Gray
        Write-Host "  python query_orgs_by_stars.py 500    # Organizations with 500+ stars" -ForegroundColor Gray
        Write-Host "  python query_orgs_by_stars.py 0      # All organizations" -ForegroundColor Gray
    } else {
        Write-Host ""
        Write-Host "❌ Database update failed!" -ForegroundColor Red
        exit $LASTEXITCODE
    }
} catch {
    Write-Host ""
    Write-Host "❌ Error running update script: $_" -ForegroundColor Red
    exit 1
}