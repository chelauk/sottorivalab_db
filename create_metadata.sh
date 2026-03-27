#!/usr/bin/env bash

usage() { # Print a help message.
      echo "Usage: $0 [ -i input ] [ -o output ]" 1>&2
      exit 1
  }

while getopts "i:o:" flag; do
      case "$flag" in
              i) input=$OPTARG ;;
              o) output=$OPTARG ;;
              *) usage ;;
      esac
done

#  required arguments check
if [[ -z ${input:-} || -z ${output:-} ]]; then
  echo "ERROR: both -i (input) and -o (output) are required." >&2
  usage
fi

while read -r i; do
  sample=$(basename "$i")
  epoch=$(stat -c %Y "$i")
  human=$(date -d "@$epoch" "+%F %T %z")
  size=$(stat -c %s "$i" | numfmt --to=iec)

  if [[ $i == *low_pass* ]]; then
    seq_type="low_pass_wgs"
    url="https://gitlab.fht.org/sottoriva-lab/lp-wgs"

  elif [[ $i == *wes* ]]; then
    seq_type="wes"
    url="https://github.com/nf-core/sarek"

  elif [[ $i == */wgs/* ]]; then
    seq_type="wgs"
    url="https://github.com/nf-core/sarek"
  
  else
    continue   # skip unclassified paths
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$sample" "$seq_type" "$epoch" "$human" "$size" "$i" "$url"
done < "$input" > "$output"
