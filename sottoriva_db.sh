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
  add-sample   Add a sample if missing
  add-fastq    Add FASTQ files to a sample
  add-bam      Add a BAM file to a sample


Run:
  sottoriva_db add-sample --help
EOF
}

add_sample() {
  local sample="" patient="" project="" sample_type="" json="working_con_db.json"

  # GNU getopt for long options
  local opts
  opts=$(getopt -o '' \
    --long sample:,patient:,project:,sample-type:,json:,help \
    -n 'sottoriva_db add-sample' -- "$@") || exit 1
  eval set -- "$opts"

  while true; do
    case "$1" in
      --sample)      sample="$2"; shift 2 ;;
      --patient)     patient="$2"; shift 2 ;;
      --project)     project="$2"; shift 2 ;;
      --sample-type) sample_type="$2"; shift 2 ;;
      --json)        json="$2"; shift 2 ;;
      --help)        echo "Usage: sottoriva_db add-sample --sample S --patient P --project PR --sample-type T [--json FILE]"; return 0 ;;
      --) shift; break ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done

  : "${sample:?Missing --sample}"
  : "${patient:?Missing --patient}"
  : "${project:?Missing --project}"
  : "${sample_type:?Missing --sample-type}"

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
  ' "$json"
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
  ' "$json"
}

add_bam() {
  local sample="" seq_type="" bam="" pipeline_url="" json="working_con_db.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sample)       sample="$2"; shift 2 ;;
      --seq-type)     seq_type="$2"; shift 2 ;;
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

  jq --arg s "$sample" \
     --arg st "$seq_type" \
     --arg bam "$bam" \
     --arg url "$pipeline_url" \
     '
    .samples[$s].seq[$st].processed_data.bam //= [] |
    .samples[$s].seq[$st].processed_data.bam += [{
      file_path: $bam,
      file_type: "bam",
      pipeline_url: $url,
      metadata: {}
    }]
  ' "$json"
}

case "$cmd" in
  add-sample) add_sample "$@" ;;
  add-fastq)  add_fastq "$@" ;;
  add-bam)    add_bam "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "Unknown command: $cmd" ;;
esac