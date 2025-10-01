#!/bin/bash

# GitHub Organization Star Counter Script
# This script helps you find and order organizations by GitHub star count

DB_FILE="force_push_commits.sqlite3"
MIN_STARS=${MIN_STARS:-100}  # Default to 100, can be overridden

echo "GitHub Organization Star Counter"
echo "================================"
echo "Database: $DB_FILE"
echo "Minimum stars: $MIN_STARS"
echo ""

# Check if GitHub token is set
if [ -z "$GITHUB_TOKEN" ]; then
    echo "⚠️  Warning: GITHUB_TOKEN is not set"
    echo "   Without a token, you're limited to 60 requests/hour"
    echo "   With a token, you get 5000 requests/hour"
    echo ""
    echo "   To set your token:"
    echo "   export GITHUB_TOKEN='your_personal_access_token'"
    echo ""
fi

# Check if required files exist
if [ ! -f "$DB_FILE" ]; then
    echo "❌ Error: Database file '$DB_FILE' not found"
    exit 1
fi

if [ ! -f "simple_star_checker.py" ]; then
    echo "❌ Error: simple_star_checker.py not found"
    exit 1
fi

# Run the Python script
echo "🚀 Starting star count analysis..."
python3 simple_star_checker.py

echo "✅ Analysis complete!"
