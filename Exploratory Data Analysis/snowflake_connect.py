import os

import snowflake.connector
from dotenv import load_dotenv

load_dotenv()


def get_connection():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE"),
        database=os.environ.get("SNOWFLAKE_DATABASE"),
        schema=os.environ.get("SNOWFLAKE_SCHEMA"),
        role=os.environ.get("SNOWFLAKE_ROLE"),
    )


if __name__ == "__main__":
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute("SELECT CURRENT_VERSION()")
        print("Connected. Snowflake version:", cur.fetchone()[0])
    finally:
        conn.close()
