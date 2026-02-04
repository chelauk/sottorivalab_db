# Working CON DB Schema

This document describes the current structure of `working_con_db.json`.

Machine-readable schema: `working_con_db.schema.json`

## Top-level structure

```json
{
  "version": "string (optional)",
  "updated_at": "ISO timestamp (optional)",
  "samples": {
    "<sample_id>": { "...sample object..." }
  }
}
```

## Sample object

```json
{
  "sample_meta": {
    "patient": "string",
    "sex": "string|null",
    "sottorivalab_project": "string",
    "sample_type": "string",
    "phenotype": "string|null",
    "case_control": "string|null",
    "tissue_site": "string|null"
  },
  "seq": {
    "<seq_type>": { "...sequence object..." }
  }
}
```

## Sequence object (`seq.<seq_type>`)

```json
{
  "indexing": "string|null",
  "technology": "string|null",
  "raw_sequence": [
    {
      "gf_id": "string",
      "fastqs": [
        {
          "gf_project": "string",
          "run": "string",
          "files": {
            "L001": {
              "R1": "path",
              "R2": "path",
              "R3": "path (optional)"
            }
          }
        }
      ]
    }
  ],
  "processed_data": {
    "bam": [ "...processed file object..." ],
    "vcf": [ "...processed file object..." ],
    "cna": [ "...processed file object..." ],
    "qc": [ "...processed file object..." ]
  }
}
```

## Processed file object

```json
{
  "file_path": "path",
  "file_type": "bam|vcf|cna|qc",
  "pipeline_url": "string",
  "metadata": {
    "size": "string",
    "created": "string",
    "epoch": 0
  }
}
```

## Notes

- `sample_id` is the key under `samples`.
- `seq_type` is the key under `seq` (for example: `low_pass_wgs`, `wgs`, `wes`).
- `indexing` and `technology` are sequence-level fields (not sample-level).
- `gf_project` and `gf_id` belong to `raw_sequence` content.

## Validation

You can validate the DB with:

```bash
bash sottoriva_db.sh validate-db
```

Optional:

```bash
bash sottoriva_db.sh validate-db --json working_con_db.json --schema working_con_db.schema.json
```

Note: this command uses Python `jsonschema` (`pip install jsonschema`).
