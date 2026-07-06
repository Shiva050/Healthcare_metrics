"""
Load every CSV in a Snowflake stage into its OWN table.

For each file in the stage it:
  1. derives a table name from the file name
  2. uses INFER_SCHEMA + CREATE TABLE ... USING TEMPLATE to build the table
     (columns + types detected from the file's header/data automatically)
  3. COPY INTO ... MATCH_BY_COLUMN_NAME so columns line up by header name

Requires: pip install snowflake-connector-python python-dotenv
Connection settings (account/user/password/warehouse/database/schema/role/stage)
come from .env via snowflake_connect.get_connection().
"""

import os
import re

import snowflake.connector
from dotenv import load_dotenv

from snowflake_connect import get_connection

load_dotenv()

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------
STAGE = "@" + os.environ["SNOWFLAKE_STAGE"]  # e.g. @HEALTHCARE_METRICS_STAGE
FILE_FORMAT = "my_csv_ff"         # created below if it doesn't exist
DRY_RUN = False                    # True = print SQL only, don't execute loads
# ---------------------------------------------------------------------------


def table_name_from_file(path: str) -> str:
    """
    '@my_stage/2024_Sales-Report.csv.gz'  ->  '2024_SALES_REPORT'
    Strips the stage path, extensions, and any chars illegal in identifiers.
    """
    base = path.rsplit("/", 1)[-1]          # drop stage/path prefix
    base = re.sub(r"\.csv(\.gz)?$", "", base, flags=re.IGNORECASE)  # drop ext
    base = re.sub(r"[^0-9a-zA-Z_]", "_", base)   # sanitize
    base = re.sub(r"_+", "_", base).strip("_")   # collapse repeats
    if base and base[0].isdigit():          # identifiers can't start with a digit
        base = "T_" + base
    return base.upper()


def main():
    ctx = get_connection()
    cur = ctx.cursor()

    # 1. A file format that reads the header row so INFER_SCHEMA and
    #    MATCH_BY_COLUMN_NAME can work. PARSE_HEADER=TRUE means the header
    #    is used for column names and skipped automatically on load.
    cur.execute(f"""
        CREATE FILE FORMAT IF NOT EXISTS {FILE_FORMAT}
          TYPE = 'CSV'
          PARSE_HEADER = TRUE
          FIELD_OPTIONALLY_ENCLOSED_BY = '"'
          TRIM_SPACE = TRUE
          NULL_IF = ('', 'NULL', 'null')
    """)

    # Fallback format for files that aren't valid UTF-8 (e.g. smart quotes /
    # em-dashes saved as Windows-1252). Tried only if the UTF-8 load fails.
    cur.execute(f"""
        CREATE FILE FORMAT IF NOT EXISTS {FILE_FORMAT}_win1252
          TYPE = 'CSV'
          PARSE_HEADER = TRUE
          FIELD_OPTIONALLY_ENCLOSED_BY = '"'
          TRIM_SPACE = TRUE
          NULL_IF = ('', 'NULL', 'null')
          ENCODING = 'WINDOWS1252'
    """)

    # 2. Enumerate the files in the stage.
    cur.execute(f"LIST {STAGE}")
    rows = cur.fetchall()  # col 0 = 'name' (path relative to the stage, e.g. 'stagename/file.csv')
    files = [row[0] for row in rows if re.search(r"\.csv(\.gz)?$", row[0], re.IGNORECASE)]

    if not files:
        print(f"No CSV files found in {STAGE}")
        return

    print(f"Found {len(files)} CSV file(s).\n")

    # 3. Build stage refs relative to STAGE (which may be db.schema-qualified)
    #    instead of assuming the LIST 'name' column is a full, qualified path.
    jobs = []
    seen_tables = {}
    for full_path in files:
        rel_path = full_path.split("/", 1)[1] if "/" in full_path else full_path
        stage_ref = f"{STAGE}/{rel_path}"
        table = table_name_from_file(full_path)

        if table in seen_tables:
            print(
                f"WARNING: '{full_path}' and '{seen_tables[table]}' both map to "
                f"table {table} - skipping '{full_path}' to avoid mixing data. "
                "Rename one of the files or adjust table_name_from_file()."
            )
            continue
        seen_tables[table] = full_path
        jobs.append((stage_ref, table))

    failed = []

    def build_sql(stage_ref, table, file_format):
        create_sql = f"""
            CREATE TABLE IF NOT EXISTS {table} USING TEMPLATE (
              SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
              FROM TABLE(
                INFER_SCHEMA(
                  LOCATION      => '{stage_ref}',
                  FILE_FORMAT   => '{file_format}',
                  IGNORE_CASE   => TRUE
                )
              )
            )
        """
        copy_sql = f"""
            COPY INTO {table}
            FROM '{stage_ref}'
            FILE_FORMAT = (FORMAT_NAME = '{file_format}')
            MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
            ON_ERROR = 'ABORT_STATEMENT'
        """
        return create_sql, copy_sql

    for stage_ref, table in jobs:
        create_sql, copy_sql = build_sql(stage_ref, table, FILE_FORMAT)

        print(f"{stage_ref}  ->  table {table}")
        if DRY_RUN:
            print(create_sql)
            print(copy_sql)
            print("-" * 60)
            continue

        try:
            cur.execute(create_sql)
            cur.execute(copy_sql)
            for r in cur.fetchall():
                print("   ", r)
        except snowflake.connector.errors.ProgrammingError as e:
            if "Invalid UTF8" in str(e):
                print(f"    Invalid UTF-8, retrying with WINDOWS1252 encoding...")
                create_sql, copy_sql = build_sql(stage_ref, table, f"{FILE_FORMAT}_win1252")
                try:
                    cur.execute(create_sql)
                    cur.execute(copy_sql)
                    for r in cur.fetchall():
                        print("   ", r)
                except snowflake.connector.errors.ProgrammingError as e2:
                    print(f"    FAILED (win1252 retry): {e2}")
                    failed.append((table, str(e2)))
            else:
                print(f"    FAILED: {e}")
                failed.append((table, str(e)))

    cur.close()
    ctx.close()

    if failed:
        print(f"\n{len(failed)} file(s) failed to load:")
        for table, err in failed:
            print(f"  - {table}: {err}")
    print("\nDone.")


if __name__ == "__main__":
    main()
