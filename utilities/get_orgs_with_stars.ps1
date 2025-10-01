# GitHub Star Count Database Updater (PowerShell)
# This script updates the SQLite database with GitHub star counts for ALL repositories

$DB_FILE = "force_push_commits.sqlite3"

Write-Host "GitHub Star Count Database Updater" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host "Database: $DB_FILE"
Write-Host "Purpose: Update database with star counts for ALL repositories (no minimum)"
Write-Host ""

# Check if GitHub token is set
if (-not $env:GITHUB_TOKEN) {
    Write-Host "⚠️  Warning: GITHUB_TOKEN is not set" -ForegroundColor Yellow
    Write-Host "   Without a token, you're limited to 60 requests/hour" -ForegroundColor Yellow
    Write-Host "   With a token, you get 5000 requests/hour" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   To set your token:" -ForegroundColor Yellow
    Write-Host "   `$env:GITHUB_TOKEN='your_personal_access_token'" -ForegroundColor Yellow
    Write-Host ""
}

# Check if required files exist
if (-not (Test-Path $DB_FILE)) {
    Write-Host "❌ Error: Database file '$DB_FILE' not found" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path "github_star_counter.py")) {
    Write-Host "❌ Error: github_star_counter.py not found" -ForegroundColor Red
    exit 1
}

# Run the Python script
Write-Host "🚀 Starting database update with star counts..." -ForegroundColor Green
C:/Users/amede/AppData/Local/Programs/Python/Python311/python.exe github_star_counter.py

Write-Host "✅ Database update complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Now you can query organizations by stars using:" -ForegroundColor Cyan
Write-Host "  python query_orgs_by_stars.py 100    # Organizations with 100+ stars" -ForegroundColor Gray
Write-Host "  python query_orgs_by_stars.py 500    # Organizations with 500+ stars" -ForegroundColor Gray
Write-Host "  python query_orgs_by_stars.py 0      # All organizations" -ForegroundColor Gray