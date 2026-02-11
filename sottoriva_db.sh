#!/usr/bin/env bash
set -euo pipefail

# Function to display usage and exit
cmd="${1:-}"
shift || true

die() { echo "ERROR: $*" >&2; exit 1; }

VIEW_JSON=""
VIEW_TMP=""

is_patient_centric_json() {
  local json="$1"
  jq -e 'has("patients") and (.patients | type == "object")' "$json" >/dev/null 2>&1
}

to_sample_centric_json() {
  local src="$1" dst="$2"
  jq '
    {
      version: (.version // null),
      updated_at: (.updated_at // null),
      samples: (
        (.patients // {})
        | to_entries
        | reduce .[] as $p ({};
            . + (
              ($p.value.cases // {})
              | to_entries
              | reduce .[] as $c ({};
                  . + (
                    ($c.value.samples // {})
                    | to_entries
                    | reduce .[] as $s ({};
                        ($s.value.sample_meta // {}) as $m |
                        . + {
                          ($s.key): {
                            sample_meta: (
                              $m + {
                                patient: ($m.patient // $p.key),
                                sex: ($m.sex // $p.value.sex // null),
                                sottorivalab_project: ($m.sottorivalab_project // $c.value.project_id // null),
                                sample_type: ($m.sample_type // null),
                                phenotype: ($m.phenotype // null),
                                case_control: ($m.case_control // null),
                                tissue_site: ($m.tissue_site // null),
                                patient_id: ($m.patient_id // $p.key),
                                case_id: ($m.case_id // $c.key),
                                project_id: ($m.project_id // $c.value.project_id // null)
                              }
                            ),
                            seq: (($s.value.analyses // $s.value.seq) // {})
                          }
                        }
                      )
                  )
                )
            )
          )
      )
    }
  ' "$src" > "$dst"
}

to_patient_centric_json() {
  local src="$1" dst="$2"
  jq '
    {
      version: (.version // "0.2.0"),
      updated_at: (.updated_at // null),
      patients: (
        (.samples // {})
        | to_entries
        | reduce .[] as $s ({};
            ($s.value.sample_meta // {}) as $m |
            ($m.patient_id // $m.patient // "UNKNOWN_PATIENT") as $pid |
            ($m.case_id // $pid) as $cid |
            ($m.project_id // $m.sottorivalab_project // null) as $prj |
            .[$pid] //= { sex: ($m.sex // null), cases: {} } |
            if .[$pid].sex == null and ($m.sex != null) then
              .[$pid].sex = $m.sex
            else
              .
            end |
            .[$pid].cases[$cid] //= { project_id: $prj, samples: {} } |
            if .[$pid].cases[$cid].project_id == null and ($prj != null) then
              .[$pid].cases[$cid].project_id = $prj
            else
              .
            end |
            .[$pid].cases[$cid].samples[$s.key] = {
              sample_meta: {
                tissue_site: ($m.tissue_site // null),
                sample_type: ($m.sample_type // null),
                phenotype: ($m.phenotype // null),
                case_control: ($m.case_control // null)
              },
              analyses: (($s.value.seq // $s.value.analyses) // {})
            }
          )
      )
    }
  ' "$src" > "$dst"
}

prepare_json_view() {
  local src="$1"
  VIEW_JSON="$src"
  VIEW_TMP=""
  if is_patient_centric_json "$src"; then
    VIEW_TMP=$(mktemp)
    to_sample_centric_json "$src" "$VIEW_TMP" || return 1
    VIEW_JSON="$VIEW_TMP"
  fi
}

commit_json_view() {
  local dst="$1"
  if [[ -n "$VIEW_TMP" ]]; then
    local out_tmp
    out_tmp=$(mktemp)
    to_patient_centric_json "$VIEW_JSON" "$out_tmp" || { rm -f "$out_tmp"; return 1; }
    mv "$out_tmp" "$dst"
  fi
}

cleanup_json_view() {
  if [[ -n "$VIEW_TMP" ]]; then
    rm -f "$VIEW_TMP"
  fi
  VIEW_JSON=""
  VIEW_TMP=""
}

usage() {
  cat <<'EOF'
Usage:
  sottoriva_db <command> [options]

Commands:
  add-sample           Add a sample if missing
  set-sample-meta      Update sample metadata fields for an existing sample
  set-seq-meta         Update sequencing metadata (indexing/technology) for a seq type
  show-sample-meta     Show sample metadata for a sample
  list-missing-raw-seq List sample seq blocks with missing raw_sequence
  audit                Run a data-quality audit (missing required fields)
  validate-db          Validate DB JSON against JSON Schema
  add-processed        Add processed output (vcf/cna/qc) to a sample
  add-fastq            Add FASTQ files to a sample (detailed mode)
  add-fastq-simple     Add FASTQ files with automatic lane/read detection
  add-bam              Add a BAM file to a sample
  list-duplicate-bams  List all BAMs for samples with duplicates
  remove-bam           Remove a specific BAM from database (and optionally filesystem)
  cleanup-bams         Automatically remove old duplicate BAMs (keeps newest)


Run:
  sottoriva_db add-sample --help
  sottoriva_db set-sample-meta --help
  sottoriva_db set-seq-meta --help
  sottoriva_db show-sample-meta --help
  sottoriva_db list-missing-raw-seq --help
  sottoriva_db audit --help
  sottoriva_db validate-db --help
  sottoriva_db add-processed --help
  sottoriva_db add-fastq-simple <sample> <gf_id> <gf_project> <run> <seq_type> <path>
  sottoriva_db remove-bam --help
  sottoriva_db cleanup-bams --help
EOF
}

add_sample() {
  local sample="" patient="" case_id="" project="" sample_type="" json="working_con_db.json"
  local phenotype="" case_control="" tissue_site=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sample)      sample="$2"; shift 2 ;;
      --patient-id|--patient) patient="$2"; shift 2 ;;
      --case-id)     case_id="$2"; shift 2 ;;
      --project-id|--project) project="$2"; shift 2 ;;
      --sample-type) sample_type="$2"; shift 2 ;;
      --phenotype)   phenotype="$2"; shift 2 ;;
      --case-control) case_control="$2"; shift 2 ;;
      --tissue-site) tissue_site="$2"; shift 2 ;;
      --json)        json="$2"; shift 2 ;;
      --help)        echo "Usage: sottoriva_db add-sample --sample S --patient-id P --case-id C --project-id PR --sample-type T [--phenotype V] [--case-control V] [--tissue-site V] [--json FILE]"; return 0 ;;

      *) die "Unexpected arg: $1" ;;
    esac
  done

  : "${sample:?Missing --sample}"
  : "${patient:?Missing --patient-id}"
  : "${project:?Missing --project-id}"
  : "${sample_type:?Missing --sample-type}"
  case_id="${case_id:-$patient}"

  if [[ ! -f "$json" ]]; then
    # Create empty patient-centric DB if not exists
    echo '{"version":"0.2.0","updated_at":null,"patients":{}}' > "$json"
  fi

  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"

  local tmp_file
  tmp_file=$(mktemp)

  jq --arg s "$sample" \
     --arg pat "$patient" \
     --arg pid "$patient" \
     --arg cid "$case_id" \
     --arg pr "$project" \
     --arg st "$sample_type" \
     --arg pheno "$phenotype" \
     --arg cc "$case_control" \
     --arg site "$tissue_site" '
    .samples[$s] //= {
      sample_meta: {
        patient: $pat,
        sex: null,
        sottorivalab_project: $pr,
        sample_type: $st,
        phenotype: null,
        case_control: null,
        tissue_site: null,
        patient_id: $pid,
        case_id: $cid,
        project_id: $pr
      },
      seq: {}
    } |
    .samples[$s].sample_meta //= {
      patient: null,
      sex: null,
      sottorivalab_project: null,
      sample_type: null,
      phenotype: null,
      case_control: null,
      tissue_site: null,
      patient_id: null,
      case_id: null,
      project_id: null
    } |
    .samples[$s].sample_meta.patient = (.samples[$s].sample_meta.patient // .samples[$s].patient // $pat) |
    .samples[$s].sample_meta.sex = (.samples[$s].sample_meta.sex // .samples[$s].sex // null) |
    .samples[$s].sample_meta.sottorivalab_project = (.samples[$s].sample_meta.sottorivalab_project // .samples[$s].sottorivalab_project // $pr) |
    .samples[$s].sample_meta.sample_type = (.samples[$s].sample_meta.sample_type // .samples[$s].sample_type // $st) |
    .samples[$s].sample_meta.patient_id = (.samples[$s].sample_meta.patient_id // $pid) |
    .samples[$s].sample_meta.case_id = (.samples[$s].sample_meta.case_id // $cid) |
    .samples[$s].sample_meta.project_id = (.samples[$s].sample_meta.project_id // $pr) |
    .samples[$s].sample_meta.phenotype = (if $pheno == "" then .samples[$s].sample_meta.phenotype else $pheno end) |
    .samples[$s].sample_meta.case_control = (if $cc == "" then .samples[$s].sample_meta.case_control else $cc end) |
    .samples[$s].sample_meta.tissue_site = (if $site == "" then .samples[$s].sample_meta.tissue_site else $site end) |
    del(.samples[$s].patient, .samples[$s].sex, .samples[$s].sottorivalab_project, .samples[$s].sample_type)
  ' "$json" > "$tmp_file"
  
  if [[ $? -eq 0 ]]; then
    mv "$tmp_file" "$json"
    commit_json_view "$json_src" || { cleanup_json_view; die "Failed to write patient-centric JSON"; }
    cleanup_json_view
    echo "Added sample $sample"
  else
    rm -f "$tmp_file"
    cleanup_json_view
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
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"

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
    .samples[$s].seq[$st].indexing //= null |
    .samples[$s].seq[$st].technology //= null |
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
    commit_json_view "$json_src" || { cleanup_json_view; die "Failed to write patient-centric JSON"; }
    cleanup_json_view
    echo "Added FASTQs for $sample"
  else
    rm -f "$tmp_file"
    cleanup_json_view
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
  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"

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
    .samples[$s].seq[$st].indexing //= null |
    .samples[$s].seq[$st].technology //= null |
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
    commit_json_view "$json_src" || { cleanup_json_view; die "Failed to write patient-centric JSON"; }
    cleanup_json_view
    echo "Added $read_type for lane $lane to sample $sample (gf_id: $gf_id, run: $run)"
  else
    rm -f "$tmp_file"
    cleanup_json_view
    die "Failed to update JSON"
  fi
}

set_sample_meta() {
  local sample="" phenotype="" case_control="" tissue_site="" json="working_con_db.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sample)       sample="$2"; shift 2 ;;
      --phenotype)    phenotype="$2"; shift 2 ;;
      --case-control) case_control="$2"; shift 2 ;;
      --tissue-site)  tissue_site="$2"; shift 2 ;;
      --json)         json="$2"; shift 2 ;;
      --help)
        echo "Usage: sottoriva_db set-sample-meta --sample S [--phenotype V] [--case-control V] [--tissue-site V] [--json FILE]"
        return 0
        ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done

  : "${sample:?Missing --sample}"

  if [[ -z "$phenotype" && -z "$case_control" && -z "$tissue_site" ]]; then
    die "No metadata fields provided. Set at least one of: --phenotype, --case-control, --tissue-site"
  fi

  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"

  local sample_exists
  sample_exists=$(jq --arg s "$sample" '.samples | has($s)' "$json")
  if [[ "$sample_exists" != "true" ]]; then
    cleanup_json_view
    die "Sample not found: $sample"
  fi

  local tmp_file
  tmp_file=$(mktemp)

  jq --arg s "$sample" \
     --arg pheno "$phenotype" \
     --arg cc "$case_control" \
     --arg site "$tissue_site" '
    .samples[$s].sample_meta //= {
      patient: null,
      sex: null,
      sottorivalab_project: null,
      sample_type: null,
      phenotype: null,
      case_control: null,
      tissue_site: null
    } |
    .samples[$s].sample_meta.patient = (.samples[$s].sample_meta.patient // .samples[$s].patient // null) |
    .samples[$s].sample_meta.sex = (.samples[$s].sample_meta.sex // .samples[$s].sex // null) |
    .samples[$s].sample_meta.sottorivalab_project = (.samples[$s].sample_meta.sottorivalab_project // .samples[$s].sottorivalab_project // null) |
    .samples[$s].sample_meta.sample_type = (.samples[$s].sample_meta.sample_type // .samples[$s].sample_type // null) |
    .samples[$s].sample_meta.phenotype = (if $pheno == "" then .samples[$s].sample_meta.phenotype else $pheno end) |
    .samples[$s].sample_meta.case_control = (if $cc == "" then .samples[$s].sample_meta.case_control else $cc end) |
    .samples[$s].sample_meta.tissue_site = (if $site == "" then .samples[$s].sample_meta.tissue_site else $site end) |
    del(.samples[$s].patient, .samples[$s].sex, .samples[$s].sottorivalab_project, .samples[$s].sample_type)
  ' "$json" > "$tmp_file"

  if [[ $? -eq 0 ]]; then
    mv "$tmp_file" "$json"
    commit_json_view "$json_src" || { cleanup_json_view; die "Failed to write patient-centric JSON"; }
    cleanup_json_view
    echo "Updated sample_meta for $sample"
  else
    rm -f "$tmp_file"
    cleanup_json_view
    die "Failed to update JSON"
  fi
}

set_seq_meta() {
  local sample="" seq_type="" indexing="" technology="" json="working_con_db.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sample) sample="$2"; shift 2 ;;
      --seq-type) seq_type="$2"; shift 2 ;;
      --indexing) indexing="$2"; shift 2 ;;
      --technology) technology="$2"; shift 2 ;;
      --json) json="$2"; shift 2 ;;
      --help)
        echo "Usage: sottoriva_db set-seq-meta --sample S --seq-type ST [--indexing V] [--technology V] [--json FILE]"
        return 0
        ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done

  : "${sample:?Missing --sample}"
  : "${seq_type:?Missing --seq-type}"

  if [[ -z "$indexing" && -z "$technology" ]]; then
    die "No sequencing metadata provided. Set at least one of: --indexing, --technology"
  fi

  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"

  local sample_exists
  sample_exists=$(jq --arg s "$sample" '.samples | has($s)' "$json")
  if [[ "$sample_exists" != "true" ]]; then
    cleanup_json_view
    die "Sample not found: $sample"
  fi

  local tmp_file
  tmp_file=$(mktemp)

  jq --arg s "$sample" --arg st "$seq_type" --arg idx "$indexing" --arg tech "$technology" '
    .samples[$s].seq[$st].indexing //= null |
    .samples[$s].seq[$st].technology //= null |
    .samples[$s].seq[$st].raw_sequence //= [] |
    .samples[$s].seq[$st].processed_data //= {} |
    .samples[$s].seq[$st].processed_data.bam //= [] |
    .samples[$s].seq[$st].processed_data.vcf //= [] |
    .samples[$s].seq[$st].processed_data.cna //= [] |
    .samples[$s].seq[$st].processed_data.qc //= [] |
    .samples[$s].seq[$st].indexing = (if $idx == "" then .samples[$s].seq[$st].indexing else $idx end) |
    .samples[$s].seq[$st].technology = (if $tech == "" then .samples[$s].seq[$st].technology else $tech end)
  ' "$json" > "$tmp_file"

  if [[ $? -eq 0 ]]; then
    mv "$tmp_file" "$json"
    commit_json_view "$json_src" || { cleanup_json_view; die "Failed to write patient-centric JSON"; }
    cleanup_json_view
    echo "Updated sequencing metadata for $sample ($seq_type)"
  else
    rm -f "$tmp_file"
    cleanup_json_view
    die "Failed to update JSON"
  fi
}

show_sample_meta() {
  local sample="" json="working_con_db.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sample) sample="$2"; shift 2 ;;
      --json)   json="$2"; shift 2 ;;
      --help)
        echo "Usage: sottoriva_db show-sample-meta --sample S [--json FILE]"
        return 0
        ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done

  : "${sample:?Missing --sample}"

  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"

  local sample_exists
  sample_exists=$(jq --arg s "$sample" '.samples | has($s)' "$json")
  if [[ "$sample_exists" != "true" ]]; then
    cleanup_json_view
    die "Sample not found: $sample"
  fi

  jq -r --arg s "$sample" '
    .samples[$s].sample_meta // {
      patient: null,
      sex: null,
      sottorivalab_project: null,
      sample_type: null,
      phenotype: null,
      case_control: null,
      tissue_site: null
    } as $m |
    "sample: \($s)\n" +
    "patient: \($m.patient // "null")\n" +
    "sex: \($m.sex // "null")\n" +
    "sottorivalab_project: \($m.sottorivalab_project // "null")\n" +
    "sample_type: \($m.sample_type // "null")\n" +
    "phenotype: \($m.phenotype // "null")\n" +
    "case_control: \($m.case_control // "null")\n" +
    "tissue_site: \($m.tissue_site // "null")"
  ' "$json"
  cleanup_json_view
}

validate_db() {
  local json="working_con_db.json" schema="patient_centric.schema.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json="$2"; shift 2 ;;
      --schema) schema="$2"; shift 2 ;;
      --help)
        echo "Usage: sottoriva_db validate-db [--json FILE] [--schema FILE]"
        return 0
        ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done

  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  if [[ ! -f "$schema" ]]; then
    die "Schema file not found: $schema"
  fi

  python3 - "$json" "$schema" <<'PY'
import json
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
schema_path = Path(sys.argv[2])

try:
    import jsonschema  # type: ignore
except Exception:
    print("ERROR: python package 'jsonschema' is not installed.", file=sys.stderr)
    print("Install with: pip install jsonschema", file=sys.stderr)
    sys.exit(2)

try:
    data = json.loads(json_path.read_text())
except Exception as exc:
    print(f"ERROR: failed to parse JSON '{json_path}': {exc}", file=sys.stderr)
    sys.exit(1)

try:
    schema = json.loads(schema_path.read_text())
except Exception as exc:
    print(f"ERROR: failed to parse schema '{schema_path}': {exc}", file=sys.stderr)
    sys.exit(1)

try:
    jsonschema.validate(instance=data, schema=schema)
except jsonschema.ValidationError as exc:
    location = "/".join(str(p) for p in exc.absolute_path) or "<root>"
    print(f"INVALID: {exc.message}", file=sys.stderr)
    print(f"At: {location}", file=sys.stderr)
    sys.exit(1)

print(f"VALID: {json_path} matches {schema_path}")
PY
}

list_missing_raw_seq() {
  local json="working_con_db.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json="$2"; shift 2 ;;
      --help)
        echo "Usage: sottoriva_db list-missing-raw-seq [--json FILE]"
        return 0
        ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done

  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"

  local out
  out=$(jq -r '
    .samples | to_entries[] as $s |
    ($s.value.seq // {}) | to_entries[] |
    (.value.raw_sequence // null) as $rs |
    select($rs == null or (($rs | type) != "array") or (($rs | length) == 0)) |
    "\($s.key)\t\(.key)"
  ' "$json")

  if [[ -z "$out" ]]; then
    echo "No null/empty raw_sequence entries found."
    cleanup_json_view
    return 0
  fi

  echo -e "sample\tseq_type"
  echo "$out"
  cleanup_json_view
}

audit_db() {
  local json="working_con_db.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json="$2"; shift 2 ;;
      --help)
        echo "Usage: sottoriva_db audit [--json FILE]"
        return 0
        ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done

  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"

  echo "Audit report for: $json_src"
  echo "======================="
  echo ""

  local sample_meta_missing_values
  sample_meta_missing_values=$(jq -r '
    .samples | to_entries[] as $s |
    ($s.value.sample_meta // {}) as $m |
    ["patient","sex","sottorivalab_project","sample_type","phenotype","case_control","tissue_site"][] as $k |
    ($m[$k]) as $v |
    select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == "")) |
    "\($s.key)\t\($k)"
  ' "$json")

  local seq_meta_missing_values
  seq_meta_missing_values=$(jq -r '
    .samples | to_entries[] as $s |
    ($s.value.seq // {}) | to_entries[] as $q |
    ["indexing","technology"][] as $k |
    ($q.value[$k]) as $v |
    select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == "")) |
    "\($s.key)\t\($q.key)\t\($k)"
  ' "$json")

  local raw_sequence_empty
  raw_sequence_empty=$(jq -r '
    .samples | to_entries[] as $s |
    ($s.value.seq // {}) | to_entries[] as $q |
    ($q.value.raw_sequence // []) as $rs |
    select(($rs | type) != "array" or ($rs | length) == 0) |
    "\($s.key)\t\($q.key)"
  ' "$json")

  local processed_arrays_empty
  processed_arrays_empty=$(jq -r '
    .samples | to_entries[] as $s |
    ($s.value.seq // {}) | to_entries[] as $q |
    ($q.value.processed_data // {}) as $pd |
    ["bam","vcf","cna","qc"][] as $k |
    (($pd[$k]) // []) as $arr |
    select(($arr | type) != "array" or ($arr | length) == 0) |
    "\($s.key)\t\($q.key)\t\($k)"
  ' "$json")

  local sample_meta_missing_count=0
  local seq_meta_missing_count=0
  local raw_empty_count=0
  local processed_empty_count=0
  [[ -n "$sample_meta_missing_values" ]] && sample_meta_missing_count=$(printf '%s\n' "$sample_meta_missing_values" | wc -l | tr -d ' ')
  [[ -n "$seq_meta_missing_values" ]] && seq_meta_missing_count=$(printf '%s\n' "$seq_meta_missing_values" | wc -l | tr -d ' ')
  [[ -n "$raw_sequence_empty" ]] && raw_empty_count=$(printf '%s\n' "$raw_sequence_empty" | wc -l | tr -d ' ')
  [[ -n "$processed_arrays_empty" ]] && processed_empty_count=$(printf '%s\n' "$processed_arrays_empty" | wc -l | tr -d ' ')

  local counts
  counts=$(jq -r '
    {
      samples: (.samples | length),
      seq_blocks: ([.samples[]?.seq | to_entries[]?] | length),
      sm_patient_missing_value: ([.samples | to_entries[] | (.value.sample_meta.patient // null) as $v | select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == ""))] | length),
      sm_sex_missing_value: ([.samples | to_entries[] | (.value.sample_meta.sex // null) as $v | select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == ""))] | length),
      sm_project_missing_value: ([.samples | to_entries[] | (.value.sample_meta.sottorivalab_project // null) as $v | select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == ""))] | length),
      sm_sample_type_missing_value: ([.samples | to_entries[] | (.value.sample_meta.sample_type // null) as $v | select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == ""))] | length),
      sm_phenotype_missing_value: ([.samples | to_entries[] | (.value.sample_meta.phenotype // null) as $v | select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == ""))] | length),
      sm_case_control_missing_value: ([.samples | to_entries[] | (.value.sample_meta.case_control // null) as $v | select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == ""))] | length),
      sm_tissue_site_missing_value: ([.samples | to_entries[] | (.value.sample_meta.tissue_site // null) as $v | select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == ""))] | length),
      seq_indexing_missing_value: ([.samples[]?.seq | to_entries[]? | (.value.indexing // null) as $v | select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == ""))] | length),
      seq_technology_missing_value: ([.samples[]?.seq | to_entries[]? | (.value.technology // null) as $v | select($v == null or (($v | type) == "string" and ($v | gsub("\\s+"; "")) == ""))] | length),
      seq_raw_sequence_empty: ([.samples[]?.seq | to_entries[]? | (.value.raw_sequence // []) as $v | select(($v | type) != "array" or ($v | length) == 0)] | length),
      pd_bam_empty: ([.samples[]?.seq | to_entries[]? | (.value.processed_data.bam // []) as $v | select(($v | type) != "array" or ($v | length) == 0)] | length),
      pd_vcf_empty: ([.samples[]?.seq | to_entries[]? | (.value.processed_data.vcf // []) as $v | select(($v | type) != "array" or ($v | length) == 0)] | length),
      pd_cna_empty: ([.samples[]?.seq | to_entries[]? | (.value.processed_data.cna // []) as $v | select(($v | type) != "array" or ($v | length) == 0)] | length),
      pd_qc_empty: ([.samples[]?.seq | to_entries[]? | (.value.processed_data.qc // []) as $v | select(($v | type) != "array" or ($v | length) == 0)] | length)
    }
  ' "$json")

  echo "Summary:"
  echo "$counts" | jq -r '
    "  samples: \(.samples)\n" +
    "  seq_blocks: \(.seq_blocks)\n" +
    "  sample_meta.patient null/empty: \(.sm_patient_missing_value)\n" +
    "  sample_meta.sex null/empty: \(.sm_sex_missing_value)\n" +
    "  sample_meta.sottorivalab_project null/empty: \(.sm_project_missing_value)\n" +
    "  sample_meta.sample_type null/empty: \(.sm_sample_type_missing_value)\n" +
    "  sample_meta.phenotype null/empty: \(.sm_phenotype_missing_value)\n" +
    "  sample_meta.case_control null/empty: \(.sm_case_control_missing_value)\n" +
    "  sample_meta.tissue_site null/empty: \(.sm_tissue_site_missing_value)\n" +
    "  seq.indexing null/empty: \(.seq_indexing_missing_value)\n" +
    "  seq.technology null/empty: \(.seq_technology_missing_value)\n" +
    "  seq.raw_sequence empty: \(.seq_raw_sequence_empty)\n" +
    "  processed_data.bam empty: \(.pd_bam_empty)\n" +
    "  processed_data.vcf empty: \(.pd_vcf_empty)\n" +
    "  processed_data.cna empty: \(.pd_cna_empty)\n" +
    "  processed_data.qc empty: \(.pd_qc_empty)"
  '
  echo ""

  if [[ -n "$seq_meta_missing_values" ]]; then
    echo "Sample/seq null or empty values (sample, seq_type, key):"
    echo -e "sample\tseq_type\tkey"
    echo "$seq_meta_missing_values"
    echo ""
  fi

  if [[ -n "$raw_sequence_empty" ]]; then
    echo "Empty raw_sequence arrays (sample, seq_type):"
    echo -e "sample\tseq_type"
    echo "$raw_sequence_empty"
    echo ""
  fi

  if [[ -n "$processed_arrays_empty" ]]; then
    echo "Empty processed_data arrays (sample, seq_type, key):"
    echo -e "sample\tseq_type\tkey"
    echo "$processed_arrays_empty"
    echo ""
  fi

  if [[ -n "$sample_meta_missing_values" ]]; then
    echo "Sample-level null or empty values (sample, key):"
    echo -e "sample\tkey"
    echo "$sample_meta_missing_values"
    echo ""
  fi

  if [[ "$sample_meta_missing_count" -eq 0 && "$seq_meta_missing_count" -eq 0 && "$raw_empty_count" -eq 0 && "$processed_empty_count" -eq 0 ]]; then
    echo "No missing values found."
  fi
  cleanup_json_view
}

add_processed() {
  local sample="" seq_type="" data_type="" file_path="" pipeline_url="" epoch="" created="" size="" json="working_con_db.json"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sample)       sample="$2"; shift 2 ;;
      --seq-type)     seq_type="$2"; shift 2 ;;
      --data-type)    data_type="$2"; shift 2 ;;
      --file-path)    file_path="$2"; shift 2 ;;
      --pipeline-url) pipeline_url="$2"; shift 2 ;;
      --epoch)        epoch="$2"; shift 2 ;;
      --created)      created="$2"; shift 2 ;;
      --size)         size="$2"; shift 2 ;;
      --json)         json="$2"; shift 2 ;;
      --help)
        echo "Usage: sottoriva_db add-processed --sample S --seq-type ST --data-type (vcf|cna|qc) --file-path PATH [--pipeline-url URL] [--epoch E] [--created D] [--size N] [--json FILE]"
        return 0
        ;;
      *) die "Unexpected arg: $1" ;;
    esac
  done

  : "${sample:?Missing --sample}"
  : "${seq_type:?Missing --seq-type}"
  : "${data_type:?Missing --data-type}"
  : "${file_path:?Missing --file-path}"

  if [[ "$data_type" != "vcf" && "$data_type" != "cna" && "$data_type" != "qc" ]]; then
    die "Invalid --data-type: $data_type (allowed: vcf, cna, qc)"
  fi

  # Default values if not provided
  epoch="${epoch:-0}"
  created="${created:-unknown}"
  size="${size:-unknown}"

  if [[ ! -f "$json" ]]; then
    die "Database file not found: $json"
  fi
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"

  # Check if sample exists
  local sample_exists
  sample_exists=$(jq --arg s "$sample" '.samples | has($s)' "$json")

  if [[ "$sample_exists" != "true" ]]; then
    echo "Warning: Sample '$sample' does not exist in the database. Data not added." >&2
    echo "       Please use 'add-sample' to create the sample first." >&2
    cleanup_json_view
    return 1
  fi

  # Skip if exact file already exists
  local file_exists
  file_exists=$(jq --arg s "$sample" --arg st "$seq_type" --arg dt "$data_type" --arg fp "$file_path" '
    .samples[$s].seq[$st].processed_data[$dt] // [] |
    any(.file_path == $fp)
  ' "$json")

  if [[ "$file_exists" == "true" ]]; then
    echo "Warning: $data_type file '$file_path' already exists for sample '$sample' ($seq_type). Skipping." >&2
    cleanup_json_view
    return 0
  fi

  local tmp_file
  tmp_file=$(mktemp)

  jq --arg s "$sample" \
     --arg st "$seq_type" \
     --arg dt "$data_type" \
     --arg fp "$file_path" \
     --arg url "$pipeline_url" \
     --arg e "$epoch" \
     --arg c "$created" \
     --arg sz "$size" \
     '
    .samples[$s].seq[$st].indexing //= null |
    .samples[$s].seq[$st].technology //= null |
    .samples[$s].seq[$st].processed_data //= {} |
    .samples[$s].seq[$st].processed_data.bam //= [] |
    .samples[$s].seq[$st].processed_data.vcf //= [] |
    .samples[$s].seq[$st].processed_data.cna //= [] |
    .samples[$s].seq[$st].processed_data.qc //= [] |
    .samples[$s].seq[$st].processed_data[$dt] += [{
      file_path: $fp,
      file_type: $dt,
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
    commit_json_view "$json_src" || { cleanup_json_view; die "Failed to write patient-centric JSON"; }
    cleanup_json_view
    echo "Added $data_type to sample $sample ($seq_type)"
  else
    rm -f "$tmp_file"
    cleanup_json_view
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
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"

  # Check if sample exists
  local sample_exists
  sample_exists=$(jq --arg s "$sample" '.samples | has($s)' "$json")
  
  if [[ "$sample_exists" != "true" ]]; then
    echo "Warning: Sample '$sample' does not exist in the database. BAM file not added." >&2
    echo "       Please use 'add-sample' to create the sample first." >&2
    cleanup_json_view
    return 1
  fi

  # Check if BAM already exists for this sample/seq_type
  local bam_exists
  bam_exists=$(jq --arg s "$sample" --arg st "$seq_type" --arg bam "$bam" '
    .samples[$s].seq[$st].processed_data.bam // [] | 
    any(.file_path == $bam)
  ' "$json")
  
  if [[ "$bam_exists" == "true" ]]; then
    echo "Warning: BAM file '$bam' already exists for sample '$sample' ($seq_type). Skipping." >&2
    cleanup_json_view
    return 0
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
    .samples[$s].seq[$st].indexing //= null |
    .samples[$s].seq[$st].technology //= null |
    .samples[$s].seq[$st].processed_data //= {} |
    .samples[$s].seq[$st].processed_data.bam //= [] |
    .samples[$s].seq[$st].processed_data.vcf //= [] |
    .samples[$s].seq[$st].processed_data.cna //= [] |
    .samples[$s].seq[$st].processed_data.qc //= [] |
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
    commit_json_view "$json_src" || { cleanup_json_view; die "Failed to write patient-centric JSON"; }
    cleanup_json_view
    echo "Added BAM to sample $sample ($seq_type)"
  else
    rm -f "$tmp_file"
    cleanup_json_view
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
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"
  
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
  cleanup_json_view
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
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"
  
  # Check if the BAM exists in the database
  local exists
  exists=$(jq --arg s "$sample" --arg st "$seq_type" --arg fp "$file_path" '
    .samples[$s].seq[$st].processed_data.bam // [] | 
    any(.file_path == $fp)
  ' "$json")
  
  if [[ "$exists" != "true" ]]; then
    cleanup_json_view
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
    commit_json_view "$json_src" || { cleanup_json_view; die "Failed to write patient-centric JSON"; }
    cleanup_json_view
    echo "✓ Removed from database"
  else
    rm -f "$tmp_file"
    cleanup_json_view
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
  local json_src="$json"
  prepare_json_view "$json_src" || die "Failed to prepare JSON view"
  json="$VIEW_JSON"
  
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
    cleanup_json_view
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
      commit_json_view "$json_src" || { cleanup_json_view; die "Failed to write patient-centric JSON"; }
      echo ""
      echo "✓ Database updated"
    else
      rm -f "$tmp_file"
      cleanup_json_view
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
  cleanup_json_view
}

case "$cmd" in
  add-sample) add_sample "$@" ;;
  set-sample-meta) set_sample_meta "$@" ;;
  set-seq-meta) set_seq_meta "$@" ;;
  show-sample-meta) show_sample_meta "$@" ;;
  list-missing-raw-seq) list_missing_raw_seq "$@" ;;
  audit) audit_db "$@" ;;
  validate-db) validate_db "$@" ;;
  add-processed) add_processed "$@" ;;
  add-fastq)  add_fastq "$@" ;;
  add-fastq-simple) add_fastq_simple "$@" ;;
  add-bam)    add_bam "$@" ;;
  list-duplicate-bams) list_duplicate_bams "$@" ;;
  remove-bam) remove_bam "$@" ;;
  cleanup-bams) cleanup_bams "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "Unknown command: $cmd" ;;
esac
