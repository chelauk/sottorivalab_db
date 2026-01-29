#!/usr/bin/env bash
set -euo pipefail

# Function to display usage and exit
cmd="${1:-}"
shift || true

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sottoriva_db <command> [options]

Commands:
  add-sample           Add a sample if missing
  add-fastq            Add FASTQ files to a sample (detailed mode)
  add-fastq-simple     Add FASTQ files with automatic lane/read detection
  add-bam              Add a BAM file to a sample
  list-duplicate-bams  List all BAMs for samples with duplicates
  remove-bam           Remove a specific BAM from database (and optionally filesystem)
  cleanup-bams         Automatically remove old duplicate BAMs (keeps newest)


Run:
  sottoriva_db add-sample --help
  sottoriva_db add-fastq-simple <sample> <gf_id> <gf_project> <run> <seq_type> <path>
  sottoriva_db remove-bam --help
  sottoriva_db cleanup-bams --help
EOF
}

add_sample() {
  local sample="" patient="" project="" sample_type="" json="working_con_db.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sample)      sample="$2"; shift 2 ;;
      --patient)     patient="$2"; shift 2 ;;
      --project)     project="$2"; shift 2 ;;
      --sample-type) sample_type="$2"; shift 2 ;;
      --json)        json="$2"; shift 2 ;;
      --help)        echo "Usage: sottoriva_db add-sample --sample S --patient P --project PR --sample-type T [--json FILE]"; return 0 ;;

      *) die "Unexpected arg: $1" ;;
    esac
  done

  : "${sample:?Missing --sample}"
  : "${patient:?Missing --patient}"
  : "${project:?Missing --project}"
  : "${sample_type:?Missing --sample-type}"

  if [[ ! -f "$json" ]]; then
    # Create empty DB if not exists
    echo '{"samples":{}}' > "$json"
  fi

  local tmp_file
  tmp_file=$(mktemp)

  jq --arg s "$sample" \
     --arg pat "$patient" \
     --arg pr "$project" \
     --arg st "$sample_type" '
    .samples[$s] //= {
      patient: $pat,
      sex: null,
      sottorivalab_project: $pr,
      sample_type: $st,
      seq: {}
    }
  ' "$json" > "$tmp_file"
  
  if [[ $? -eq 0 ]]; then
    mv "$tmp_file" "$json"
    echo "Added sample $sample"
  else
    rm -f "$tmp_file"
    die "Failed to update JSON"
  fi
}

add_fastq() {
  local sample="" seq_type="" gf_id="" gf_project="" run="" lane="" r1="" r2="" r3="" json="working_con_db.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sample)         sample="$2"; shift 2 ;;
      --seq-type)       seq_type="$2"; shift 2 ;;
      --gf-id)          gf_id="$2"; shift 2 ;;
      --gf-project)     gf_project="$2"; shift 2 ;;
      --run)            run="$2"; shift 2 ;;
      --lane)           lane="$2"; shift 2 ;;
      --r1)             r1="$2"; shift 2 ;;
      --r2)             r2="$2"; shift 2 ;;
      --r3)             r3="$2"; shift 2 ;;
      --json)           json="$2"; shift 2 ;;
      --help)           echo "Usage: sottoriva_db add-fastq ..."; return 0 ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done

  : "${sample:?Missing --sample}"
  : "${seq_type:?Missing --seq-type}"
  : "${gf_id:?Missing --gf-id}"
  : "${gf_project:?Missing --gf-project}"
  : "${run:?Missing --run}"
  : "${lane:?Missing --lane}"
  : "${r1:?Missing --r1}"

  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi

  local tmp_file
  tmp_file=$(mktemp)

  jq --arg s "$sample" \
     --arg st "$seq_type" \
     --arg gfid "$gf_id" \
     --arg gfp "$gf_project" \
     --arg run "$run" \
     --arg lane "$lane" \
     --arg r1 "$r1" \
     --arg r2 "$r2" \
     --arg r3 "$r3" \
     '
    # Ensure seq type object exists
    .samples[$s].seq[$st].raw_sequence //= [] |
    
    # 1. Find or create the object for this gf_id
    (.samples[$s].seq[$st].raw_sequence | map(.gf_id == $gfid) | index(true)) as $gf_idx |
    if $gf_idx == null then
      .samples[$s].seq[$st].raw_sequence += [{
        gf_id: $gfid,
        fastqs: []
      }]
    else . end |
    
    # Re-calculate index in case we just added it
    (.samples[$s].seq[$st].raw_sequence | map(.gf_id == $gfid) | index(true)) as $final_gf_idx |

    # 2. Find or create the fastq entry for this project+run inside that gf_id object
    (.samples[$s].seq[$st].raw_sequence[$final_gf_idx].fastqs | map(.gf_project == $gfp and .run == $run) | index(true)) as $fq_idx |
    if $fq_idx == null then
       .samples[$s].seq[$st].raw_sequence[$final_gf_idx].fastqs += [{
         gf_project: $gfp,
         run: $run,
         files: {}
       }]
    else . end |

    # Re-calculate index
    (.samples[$s].seq[$st].raw_sequence[$final_gf_idx].fastqs | map(.gf_project == $gfp and .run == $run) | index(true)) as $final_fq_idx |

    # 3. Add/Update the lane files
    .samples[$s].seq[$st].raw_sequence[$final_gf_idx].fastqs[$final_fq_idx].files[$lane] = (
      { R1: $r1 } 
      + (if $r2 != "" then { R2: $r2 } else {} end)
      + (if $r3 != "" then { R3: $r3 } else {} end)
    )
  ' "$json" > "$tmp_file"
  
  if [[ $? -eq 0 ]]; then
    mv "$tmp_file" "$json"
    echo "Added FASTQs for $sample"
  else
    rm -f "$tmp_file"
    die "Failed to update JSON"
  fi
}

# Simplified add_fastq that detects lane and read info from filename
add_fastq_simple() {
  local sample gf_id gf_project run seq_type path json="working_con_db.json"
  
  # Parse positional arguments
  if [[ $# -lt 5 ]]; then
    echo "Usage: sottoriva_db add-fastq-simple <sample> <gf_id> <gf_project> <run> <seq_type> <path> [--json FILE]"
    echo "Example: sottoriva_db add-fastq-simple SAMPLE1 LAZ_123 RITM001 RUN_001 wgs /path/to/file_L001_R1_001.fastq.gz"
    return 1
  fi
  
  sample="$1"
  gf_id="$2"
  gf_project="$3"
  run="$4"
  seq_type="$5"
  path="$6"
  shift 6
  
  # Handle optional --json flag
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json="$2"; shift 2 ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done
  
  # Extract filename from path
  local filename
  filename=$(basename "$path")
  
  # Detect lane (e.g., L001, L002, etc.)
  local lane
  if [[ $filename =~ _L([0-9]{3}) ]]; then
    lane="L${BASH_REMATCH[1]}"
  else
    die "Could not detect lane from filename: $filename (expected pattern: _L001, _L002, etc.)"
  fi
  
  # Detect read type (R1, R2, R3)
  local read_type
  if [[ $filename =~ _R([1-3])_ ]]; then
    read_type="R${BASH_REMATCH[1]}"
  else
    die "Could not detect read type from filename: $filename (expected pattern: _R1_, _R2_, _R3_)"
  fi
  
  # Now we need to intelligently merge this file into the structure
  # We'll use jq to update the JSON
  local tmp_file
  tmp_file=$(mktemp)
  
  jq --arg s "$sample" \
     --arg st "$seq_type" \
     --arg gfid "$gf_id" \
     --arg gfp "$gf_project" \
     --arg run "$run" \
     --arg lane "$lane" \
     --arg read_type "$read_type" \
     --arg path "$path" \
     '
    # Ensure seq type object exists
    .samples[$s].seq[$st].raw_sequence //= [] |
    
    # 1. Find or create the object for this gf_id
    (.samples[$s].seq[$st].raw_sequence | map(.gf_id == $gfid) | index(true)) as $gf_idx |
    if $gf_idx == null then
      .samples[$s].seq[$st].raw_sequence += [{
        gf_id: $gfid,
        fastqs: []
      }]
    else . end |
    
    # Re-calculate index in case we just added it
    (.samples[$s].seq[$st].raw_sequence | map(.gf_id == $gfid) | index(true)) as $final_gf_idx |

    # 2. Find or create the fastq entry for this project+run inside that gf_id object
    (.samples[$s].seq[$st].raw_sequence[$final_gf_idx].fastqs | map(.gf_project == $gfp and .run == $run) | index(true)) as $fq_idx |
    if $fq_idx == null then
       .samples[$s].seq[$st].raw_sequence[$final_gf_idx].fastqs += [{
         gf_project: $gfp,
         run: $run,
         files: {}
       }]
    else . end |

    # Re-calculate index
    (.samples[$s].seq[$st].raw_sequence[$final_gf_idx].fastqs | map(.gf_project == $gfp and .run == $run) | index(true)) as $final_fq_idx |

    # 3. Add/Update the lane files - merge with existing reads
    .samples[$s].seq[$st].raw_sequence[$final_gf_idx].fastqs[$final_fq_idx].files[$lane] //= {} |
    .samples[$s].seq[$st].raw_sequence[$final_gf_idx].fastqs[$final_fq_idx].files[$lane][$read_type] = $path
  ' "$json" > "$tmp_file"
  
  if [[ $? -eq 0 ]]; then
    mv "$tmp_file" "$json"
    echo "Added $read_type for lane $lane to sample $sample (gf_id: $gf_id, run: $run)"
  else
    rm -f "$tmp_file"
    die "Failed to update JSON"
  fi
}

add_bam() {
  local sample="" seq_type="" epoch="" created="" size="" bam="" pipeline_url="" json="working_con_db.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sample)       sample="$2"; shift 2 ;;
      --seq-type)     seq_type="$2"; shift 2 ;;
      --epoch)        epoch="$2"; shift 2 ;;
      --created)      created="$2"; shift 2 ;;
      --size)         size="$2"; shift 2 ;;
      --bam)          bam="$2"; shift 2 ;;
      --pipeline-url) pipeline_url="$2"; shift 2 ;;
      --json)         json="$2"; shift 2 ;;
      --help)         echo "Usage: sottoriva_db add-bam ..."; return 0 ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done

  : "${sample:?Missing --sample}"
  : "${seq_type:?Missing --seq-type}"
  : "${bam:?Missing --bam}"

  # Default values if not provided
  epoch="${epoch:-0}"
  created="${created:-unknown}"
  size="${size:-unknown}"

  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi

  # Check if sample exists
  local sample_exists
  sample_exists=$(jq --arg s "$sample" '.samples | has($s)' "$json")
  
  if [[ "$sample_exists" != "true" ]]; then
    echo "Warning: Sample '$sample' does not exist in the database. BAM file not added." >&2
    echo "       Please use 'add-sample' to create the sample first." >&2
    return 1
  fi

  local tmp_file
  tmp_file=$(mktemp)

  jq --arg s "$sample" \
     --arg st "$seq_type" \
     --arg e "$epoch" \
     --arg c "$created" \
     --arg sz "$size" \
     --arg bam "$bam" \
     --arg url "$pipeline_url" \
     '
    .samples[$s].seq[$st].processed_data.bam //= [] |
    .samples[$s].seq[$st].processed_data.bam += [{
      file_path: $bam,
      file_type: "bam",
      pipeline_url: $url,
      metadata: {
        size: $sz,
        created: $c,
        epoch: ($e | tonumber)
      }
    }]
  ' "$json" > "$tmp_file"
  
  if [[ $? -eq 0 ]]; then
    mv "$tmp_file" "$json"
    echo "Added BAM to sample $sample ($seq_type)"
  else
    rm -f "$tmp_file"
    die "Failed to update JSON"
  fi
}

list_duplicate_bams() {
  local json="working_con_db.json"
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json="$2"; shift 2 ;;
      --help) echo "Usage: sottoriva_db list-duplicate-bams [--json FILE]"; return 0 ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done
  
  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  
  echo "Samples with duplicate BAMs:"
  echo "=============================="
  echo ""
  
  local has_duplicates=false
  
  jq -r '
    .samples | to_entries[] | 
    .key as $sample |
    .value.seq | to_entries[] |
    .key as $seq_type |
    select(.value.processed_data.bam | length > 1) |
    {
      sample: $sample,
      seq_type: $seq_type,
      bams: (.value.processed_data.bam | sort_by(.metadata.epoch // 0) | reverse)
    } |
    "\(.sample)\t\(.seq_type)\t\(.bams | @json)"
  ' "$json" | while IFS=$'\t' read -r sample seq_type bams_json; do
    has_duplicates=true
    echo "Sample: $sample"
    echo "Seq Type: $seq_type"
    echo ""
    
    # Parse and display each BAM with index
    echo "$bams_json" | jq -r 'to_entries[] | 
      "  [\(.key + 1)] \(.value.file_path)\n" +
      "      Created: \(.value.metadata.created // "unknown")\n" +
      "      Size: \(.value.metadata.size // "unknown")\n" +
      "      Pipeline: \(.value.pipeline_url // "unknown")\n" +
      "      Epoch: \(.value.metadata.epoch // 0)"
    '
    echo ""
    echo "---"
    echo ""
  done
  
  if [[ "$has_duplicates" == "false" ]]; then
    echo "No duplicate BAMs found."
  fi
}

remove_bam() {
  local sample="" seq_type="" file_path="" delete_file=false json="working_con_db.json"
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sample) sample="$2"; shift 2 ;;
      --seq-type) seq_type="$2"; shift 2 ;;
      --file-path) file_path="$2"; shift 2 ;;
      --delete-file) delete_file=true; shift ;;
      --json) json="$2"; shift 2 ;;
      --help)
        echo "Usage: sottoriva_db remove-bam --sample NAME --seq-type TYPE --file-path PATH [--delete-file] [--json FILE]"
        echo ""
        echo "Remove a specific BAM from the database."
        echo ""
        echo "Options:"
        echo "  --sample NAME       Sample name"
        echo "  --seq-type TYPE     Sequence type (e.g., wgs, low_pass_wgs)"
        echo "  --file-path PATH    Exact file path of the BAM to remove"
        echo "  --delete-file       Also delete the file from filesystem"
        echo "  --json FILE         Use specified JSON file (default: working_con_db.json)"
        return 0
        ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done
  
  : "${sample:?Missing --sample}"
  : "${seq_type:?Missing --seq-type}"
  : "${file_path:?Missing --file-path}"
  
  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  
  # Check if the BAM exists in the database
  local exists
  exists=$(jq --arg s "$sample" --arg st "$seq_type" --arg fp "$file_path" '
    .samples[$s].seq[$st].processed_data.bam // [] | 
    any(.file_path == $fp)
  ' "$json")
  
  if [[ "$exists" != "true" ]]; then
    die "BAM not found in database: sample=$sample, seq_type=$seq_type, file_path=$file_path"
  fi
  
  echo "Removing BAM from database..."
  echo "  Sample: $sample"
  echo "  Seq Type: $seq_type"
  echo "  File: $file_path"
  
  # Remove from database
  local tmp_file
  tmp_file=$(mktemp)
  
  jq --arg s "$sample" --arg st "$seq_type" --arg fp "$file_path" '
    .samples[$s].seq[$st].processed_data.bam = (
      .samples[$s].seq[$st].processed_data.bam // [] | 
      map(select(.file_path != $fp))
    )
  ' "$json" > "$tmp_file"
  
  if [[ $? -eq 0 ]]; then
    mv "$tmp_file" "$json"
    echo "✓ Removed from database"
  else
    rm -f "$tmp_file"
    die "Failed to update database"
  fi
  
  # Delete file if requested
  if [[ "$delete_file" == "true" ]]; then
    if [[ -f "$file_path" ]]; then
      rm -f "$file_path"
      if [[ $? -eq 0 ]]; then
        echo "✓ Deleted file from filesystem"
      else
        echo "✗ Failed to delete file from filesystem"
      fi
    else
      echo "⊘ File not found on filesystem (skipped)"
    fi
  fi
  
  echo ""
  echo "Done."
}

cleanup_bams() {
  local json="working_con_db.json" dry_run=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json="$2"; shift 2 ;;
      --dry-run) dry_run=true; shift ;;
      --help) 
        echo "Usage: sottoriva_db cleanup-bams [--json FILE] [--dry-run]"
        echo ""
        echo "Removes old BAMs from database and filesystem, keeping only the newest per sample/seq_type."
        echo ""
        echo "Options:"
        echo "  --dry-run    Show what would be deleted without actually deleting"
        echo "  --json FILE  Use specified JSON file (default: working_con_db.json)"
        return 0
        ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done
  
  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  
  if [[ "$dry_run" == "true" ]]; then
    echo "DRY RUN MODE - No files will be deleted"
    echo ""
  fi
  
  # Get list of files to delete
  local files_to_delete
  files_to_delete=$(jq -r '
    .samples | to_entries[] | 
    .value.seq | to_entries[] |
    select(.value.processed_data.bam | length > 1) |
    .value.processed_data.bam | sort_by(.metadata.epoch // 0) | reverse | .[1:] | .[].file_path
  ' "$json")
  
  if [[ -z "$files_to_delete" ]]; then
    echo "No duplicate BAMs found. Nothing to clean up."
    return 0
  fi
  
  local deleted_count=0
  local failed_count=0
  
  # Delete files from filesystem
  while IFS= read -r file_path; do
    if [[ -z "$file_path" ]]; then
      continue
    fi
    
    echo "Processing: $file_path"
    
    if [[ "$dry_run" == "true" ]]; then
      if [[ -f "$file_path" ]]; then
        echo "  [DRY RUN] Would delete file"
      else
        echo "  [DRY RUN] File not found (would skip)"
      fi
    else
      if [[ -f "$file_path" ]]; then
        rm -f "$file_path"
        if [[ $? -eq 0 ]]; then
          echo "  ✓ Deleted from filesystem"
          ((deleted_count++))
        else
          echo "  ✗ Failed to delete"
          ((failed_count++))
        fi
      else
        echo "  ⊘ File not found (skipping)"
      fi
    fi
  done <<< "$files_to_delete"
  
  # Update JSON to remove old BAMs
  if [[ "$dry_run" == "false" ]]; then
    local tmp_file
    tmp_file=$(mktemp)
    
    jq '
      .samples |= (
        to_entries | map(
          .value.seq |= (
            to_entries | map(
              if .value.processed_data.bam | length > 1 then
                # Keep only the newest BAM
                .value.processed_data.bam = ([.value.processed_data.bam[] | . + {sort_key: (.metadata.epoch // 0)}] | sort_by(.sort_key) | reverse | first | del(.sort_key) | [.])
              else
                .
              end
            ) | from_entries
          )
        ) | from_entries
      )
    ' "$json" > "$tmp_file"
    
    if [[ $? -eq 0 ]]; then
      mv "$tmp_file" "$json"
      echo ""
      echo "✓ Database updated"
    else
      rm -f "$tmp_file"
      die "Failed to update database"
    fi
  fi
  
  echo ""
  echo "Summary:"
  echo "  Files deleted: $deleted_count"
  echo "  Failed deletions: $failed_count"
  
  if [[ "$dry_run" == "true" ]]; then
    echo ""
    echo "Run without --dry-run to actually delete files"
  fi
}

case "$cmd" in
  add-sample) add_sample "$@" ;;
  add-fastq)  add_fastq "$@" ;;
  add-fastq-simple) add_fastq_simple "$@" ;;
  add-bam)    add_bam "$@" ;;
  list-duplicate-bams) list_duplicate_bams "$@" ;;
  remove-bam) remove_bam "$@" ;;
  cleanup-bams) cleanup_bams "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "Unknown command: $cmd" ;;
esac