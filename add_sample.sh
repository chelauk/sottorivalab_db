#!/usr/bin/env bash

# Function to display usage and exit
usage() {
    echo "Usage: $0 <sample_name> <patient> <project> <sample_type>"
    exit 1
}

if [ "$#" -ne 4 ]; then
    usage
fi

sample="$1"
patient="$2"
project="$3"
sample_type="$4"

DB_FILE="working_con_db.json"
TMP_FILE=$(mktemp)

# Check if DB file exists
if [ ! -f "$DB_FILE" ]; then
    echo "Error: Database file '$DB_FILE' not found."
    exit 1
fi

# Run jq to update the JSON
jq --arg s "$sample" \
   --arg p "$patient" \
   --arg pr "$project" \
   --arg st "$sample_type" \
   '.samples[$s] //= {
        "patient": $p,
        "sottorivalab_project": $pr,
        "sample_type": $st,
        "sex": null,
        "seq": {}
    }' "$DB_FILE" > "$TMP_FILE"

# Check if jq succeeded
if [ $? -eq 0 ]; then
    mv "$TMP_FILE" "$DB_FILE"
    echo "Successfully added sample '$sample' to $DB_FILE"
    # Pretty print the added entry for verification
    jq --arg s "$sample" '.samples[$s]' "$DB_FILE"
else
    echo "Error: Failed to update database."
    rm "$TMP_FILE"
    exit 1
fi