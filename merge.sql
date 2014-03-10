-------------------------------------------------------------------------------
-- MERGE UTILITIES
-------------------------------------------------------------------------------
-- Copyright (c) 2005-2014 Dave Hughes <dave@waveform.org.uk>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to
-- deal in the Software without restriction, including without limitation the
-- rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
-- sell copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
-- IN THE SOFTWARE.
-------------------------------------------------------------------------------
-- MERGE is an extremely useful command in SQL. Unfortunately, its syntax is
-- excessively verbose (admittedly like much of SQL). A common use-case for
-- MERGE, at least for us, is to update a table from an equivalently structured
-- source. This module contains utility routines which automatically construct
-- the MERGE statements required to do this from information in the system
-- catalog tables.
-------------------------------------------------------------------------------


-- ROLES
-------------------------------------------------------------------------------
-- The following roles grant usage and administrative rights to the objects
-- created by this module.
-------------------------------------------------------------------------------

CREATE ROLE UTILS_MERGE_USER!
CREATE ROLE UTILS_MERGE_ADMIN!

GRANT ROLE UTILS_MERGE_USER TO ROLE UTILS_USER!
GRANT ROLE UTILS_MERGE_USER TO ROLE UTILS_MERGE_ADMIN WITH ADMIN OPTION!
GRANT ROLE UTILS_MERGE_ADMIN TO ROLE UTILS_ADMIN WITH ADMIN OPTION!

-- SQLSTATES
-------------------------------------------------------------------------------
-- The following variables define the set of SQLSTATEs raised by the procedures
-- and functions in this module.
-------------------------------------------------------------------------------

CREATE VARIABLE MERGE_NO_KEY_STATE CHAR(5) CONSTANT '90010'!
CREATE VARIABLE MERGE_PARTIAL_KEY_STATE CHAR(5) CONSTANT '90011'!
CREATE VARIABLE MERGE_SAME_TABLE_STATE CHAR(5) CONSTANT '90012'!

GRANT READ ON VARIABLE MERGE_NO_KEY_STATE TO ROLE UTILS_MERGE_USER!
GRANT READ ON VARIABLE MERGE_NO_KEY_STATE TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!
GRANT READ ON VARIABLE MERGE_PARTIAL_KEY_STATE TO ROLE UTILS_MERGE_USER!
GRANT READ ON VARIABLE MERGE_PARTIAL_KEY_STATE TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!
GRANT READ ON VARIABLE MERGE_SAME_TABLE_STATE TO ROLE UTILS_MERGE_USER!
GRANT READ ON VARIABLE MERGE_SAME_TABLE_STATE TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!

COMMENT ON VARIABLE MERGE_NO_KEY_STATE
    IS 'The SQLSTATE raised when an attempt is made to AUTO_MERGE to a target without a unique constraint'!

COMMENT ON VARIABLE MERGE_PARTIAL_KEY_STATE
    IS 'The SQLSTATE raised when AUTO_MERGE is run on a key which does not completely exist in the source and target tables'!

COMMENT ON VARIABLE MERGE_SAME_TABLE_STATE
    IS 'The SQLSTATE raised when AUTO_MERGE is run with the same table as source and target'!

-- X_BUILD_MERGE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, DEST_KEY)
-- X_BUILD_DELETE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, DEST_KEY)
-------------------------------------------------------------------------------
-- These functions are effectively private utility subroutines for the
-- procedures defined below. They simply generate snippets of SQL given a set
-- of input parameters.
-------------------------------------------------------------------------------

CREATE FUNCTION X_BUILD_MERGE(
    SOURCE_SCHEMA VARCHAR(128),
    SOURCE_TABLE VARCHAR(128),
    DEST_SCHEMA VARCHAR(128),
    DEST_TABLE VARCHAR(128),
    DEST_KEY VARCHAR(128)
)
    RETURNS CLOB(64K)
    SPECIFIC X_BUILD_MERGE
    LANGUAGE SQL
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    READS SQL DATA
BEGIN ATOMIC
    DECLARE JOIN_CLAUSE CLOB(64K) DEFAULT '';
    DECLARE INSERT_COLS CLOB(64K) DEFAULT '';
    DECLARE INSERT_VALS CLOB(64K) DEFAULT '';
    DECLARE UPDATE_COLS CLOB(64K) DEFAULT '';
    DECLARE UPDATE_VALS CLOB(64K) DEFAULT '';

    FOR D AS
        SELECT
            T.COLNAME AS NAME,
            CASE WHEN K.COLNAME IS NULL
                THEN 'N'
                ELSE 'Y'
            END AS KEY_COL
        FROM
            SYSCAT.COLUMNS S
            INNER JOIN SYSCAT.COLUMNS T
                ON S.COLNAME = T.COLNAME
            INNER JOIN SYSCAT.TABCONST C
                ON T.TABSCHEMA = C.TABSCHEMA
                AND T.TABNAME = C.TABNAME
            LEFT JOIN SYSCAT.KEYCOLUSE K
                ON C.TABSCHEMA = K.TABSCHEMA
                AND C.TABNAME = K.TABNAME
                AND C.CONSTNAME = K.CONSTNAME
                AND T.COLNAME = K.COLNAME
        WHERE
            S.TABSCHEMA = SOURCE_SCHEMA
            AND S.TABNAME = SOURCE_TABLE
            AND T.TABSCHEMA = DEST_SCHEMA
            AND T.TABNAME = DEST_TABLE
            AND C.CONSTNAME = DEST_KEY
            AND C.TYPE IN ('P', 'U')
    DO
        IF D.KEY_COL = 'Y' THEN
            IF JOIN_CLAUSE <> '' THEN
                SET JOIN_CLAUSE = JOIN_CLAUSE || ' AND ';
            END IF;
            SET JOIN_CLAUSE = JOIN_CLAUSE ||
                'S.' || QUOTE_IDENTIFIER(NAME) || ' = ' ||
                'T.' || QUOTE_IDENTIFIER(NAME);
        ELSE
            IF UPDATE_COLS <> '' THEN
                SET UPDATE_COLS = UPDATE_COLS || ',';
                SET UPDATE_VALS = UPDATE_VALS || ',';
            END IF;
            SET UPDATE_COLS = UPDATE_COLS || QUOTE_IDENTIFIER(NAME);
            SET UPDATE_VALS = UPDATE_VALS || 'S.' || QUOTE_IDENTIFIER(NAME);
        END IF;
        IF INSERT_COLS <> '' THEN
            SET INSERT_COLS = INSERT_COLS || ',';
            SET INSERT_VALS = INSERT_VALS || ',';
        END IF;
        SET INSERT_COLS = INSERT_COLS || QUOTE_IDENTIFIER(NAME);
        SET INSERT_VALS = INSERT_VALS || 'S.' || QUOTE_IDENTIFIER(NAME);
    END FOR;

    RETURN
        'MERGE INTO ' || QUOTE_IDENTIFIER(DEST_SCHEMA) || '.' || QUOTE_IDENTIFIER(DEST_TABLE) || ' AS T '
        || 'USING ' || QUOTE_IDENTIFIER(SOURCE_SCHEMA) || '.' || QUOTE_IDENTIFIER(SOURCE_TABLE) || ' AS S '
        || 'ON ' || JOIN_CLAUSE || ' '
        || 'WHEN MATCHED THEN UPDATE SET (' || UPDATE_COLS || ') = (' || UPDATE_VALS || ') '
        || 'WHEN NOT MATCHED THEN INSERT (' || INSERT_COLS || ') VALUES (' || INSERT_VALS || ')';
END!

CREATE FUNCTION X_BUILD_DELETE(
    SOURCE_SCHEMA VARCHAR(128),
    SOURCE_TABLE VARCHAR(128),
    DEST_SCHEMA VARCHAR(128),
    DEST_TABLE VARCHAR(128),
    DEST_KEY VARCHAR(128)
)
    RETURNS CLOB(64K)
    SPECIFIC X_BUILD_DELETE
    LANGUAGE SQL
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    READS SQL DATA
BEGIN ATOMIC
    DECLARE KEY_COLS CLOB(64K) DEFAULT '';

    FOR D AS
        SELECT
            T.COLNAME AS NAME,
            CASE WHEN K.COLNAME IS NULL
                THEN 'N'
                ELSE 'Y'
            END AS KEY_COL
        FROM
            SYSCAT.COLUMNS S
            INNER JOIN SYSCAT.COLUMNS T
                ON S.COLNAME = T.COLNAME
            INNER JOIN SYSCAT.TABCONST C
                ON T.TABSCHEMA = C.TABSCHEMA
                AND T.TABNAME = C.TABNAME
            INNER JOIN SYSCAT.KEYCOLUSE K
                ON C.TABSCHEMA = K.TABSCHEMA
                AND C.TABNAME = K.TABNAME
                AND C.CONSTNAME = K.CONSTNAME
                AND T.COLNAME = K.COLNAME
        WHERE
            S.TABSCHEMA = SOURCE_SCHEMA
            AND S.TABNAME = SOURCE_TABLE
            AND T.TABSCHEMA = DEST_SCHEMA
            AND T.TABNAME = DEST_TABLE
            AND C.CONSTNAME = DEST_KEY
            AND C.TYPE IN ('P', 'U')
    DO
        IF KEY_COLS <> '' THEN
            SET KEY_COLS = KEY_COLS || ',';
        END IF;
        SET KEY_COLS = KEY_COLS || QUOTE_IDENTIFIER(NAME);
    END FOR;

    RETURN
        'DELETE FROM ' || QUOTE_IDENTIFIER(DEST_SCHEMA) || '.' || QUOTE_IDENTIFIER(DEST_TABLE) || ' '
        || 'WHERE (' || KEY_COLS || ') IN ('
        || 'SELECT ' || KEY_COLS || ' '
        || 'FROM ' || QUOTE_IDENTIFIER(DEST_SCHEMA) || '.' || QUOTE_IDENTIFIER(DEST_TABLE) || ' '
        || 'EXCEPT '
        || 'SELECT ' || KEY_COLS || ' '
        || 'FROM ' || QUOTE_IDENTIFIER(SOURCE_SCHEMA) || '.' || QUOTE_IDENTIFIER(SOURCE_TABLE)
        || ')';
END!

CREATE PROCEDURE X_MERGE_CHECKS(
    SOURCE_SCHEMA VARCHAR(128),
    SOURCE_TABLE VARCHAR(128),
    DEST_SCHEMA VARCHAR(128),
    DEST_TABLE VARCHAR(128),
    DEST_KEY VARCHAR(128)
)
    SPECIFIC X_MERGE_CHECKS
    MODIFIES SQL DATA
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    LANGUAGE SQL
BEGIN ATOMIC
    CALL ASSERT_TABLE_EXISTS(SOURCE_SCHEMA, SOURCE_TABLE);
    CALL ASSERT_TABLE_EXISTS(DEST_SCHEMA, DEST_TABLE);

    -- Check all columns of the destination key are present in the source table
    IF (
        SELECT COUNT(*)
        FROM SYSCAT.KEYCOLUSE
        WHERE
            TABSCHEMA = DEST_SCHEMA
            AND TABNAME = DEST_TABLE
            AND CONSTNAME = DEST_KEY
        ) <> (
        SELECT COUNT(*)
        FROM
            SYSCAT.KEYCOLUSE K
            INNER JOIN SYSCAT.COLUMNS C
                ON K.COLNAME = C.COLNAME
        WHERE
            K.TABSCHEMA = DEST_SCHEMA
            AND K.TABNAME = DEST_TABLE
            AND K.CONSTNAME = DEST_KEY
            AND C.TABSCHEMA = SOURCE_SCHEMA
            AND C.TABNAME = SOURCE_TABLE
        ) THEN
        CALL SIGNAL_STATE(MERGE_PARTIAL_KEY_STATE,
            'All fields of constraint ' || DEST_KEY ||
            ' must exist in the source and the target tables');
    END IF;

    -- Check source and target are distinct
    IF SOURCE_SCHEMA = DEST_SCHEMA THEN
        IF SOURCE_TABLE = DEST_TABLE THEN
            CALL SIGNAL_STATE(MERGE_SAME_TABLE_STATE,
                'Source and destination tables cannot be the same');
        END IF;
    END IF;
END!

-- AUTO_MERGE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, DEST_KEY)
-- AUTO_MERGE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE)
-- AUTO_MERGE(SOURCE_TABLE, DEST_TABLE, DEST_KEY)
-- AUTO_MERGE(SOURCE_TABLE, DEST_TABLE)
-------------------------------------------------------------------------------
-- The AUTO_MERGE procedure performs an "upsert", or combined insert and update
-- of all data from SOURCE_TABLE into DEST_TABLE by means of an automatically
-- generated MERGE statement.
--
-- The DEST_KEY parameter specifies the name of the unique key to use for
-- identifying rows in the destination table. If specified, it must be the name
-- of a unique key or primary key which covers columns which exist in both the
-- source and destination tables. If omitted, it defaults to the name of the
-- primary key of the destination table.
--
-- If SOURCE_SCHEMA and DEST_SCHEMA are not specified they default to the
-- current schema.
-------------------------------------------------------------------------------

CREATE PROCEDURE AUTO_MERGE(
    SOURCE_SCHEMA VARCHAR(128),
    SOURCE_TABLE VARCHAR(128),
    DEST_SCHEMA VARCHAR(128),
    DEST_TABLE VARCHAR(128),
    DEST_KEY VARCHAR(128)
)
    SPECIFIC AUTO_MERGE1
    MODIFIES SQL DATA
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    LANGUAGE SQL
BEGIN ATOMIC
    DECLARE DML CLOB(64K) DEFAULT '';

    CALL X_MERGE_CHECKS(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, DEST_KEY);
    SET DML = X_BUILD_MERGE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, DEST_KEY);
    EXECUTE IMMEDIATE DML;
END!

CREATE PROCEDURE AUTO_MERGE(
    SOURCE_SCHEMA VARCHAR(128),
    SOURCE_TABLE VARCHAR(128),
    DEST_SCHEMA VARCHAR(128),
    DEST_TABLE VARCHAR(128)
)
    SPECIFIC AUTO_MERGE2
    MODIFIES SQL DATA
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    LANGUAGE SQL
BEGIN ATOMIC
    CALL AUTO_MERGE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, (
        SELECT CONSTNAME
        FROM SYSCAT.TABCONST
        WHERE TABSCHEMA = DEST_SCHEMA
        AND TABNAME = DEST_TABLE
        AND TYPE = 'P'));
END!

CREATE PROCEDURE AUTO_MERGE(
    SOURCE_TABLE VARCHAR(128),
    DEST_TABLE VARCHAR(128),
    DEST_KEY VARCHAR(128)
)
    SPECIFIC AUTO_MERGE3
    MODIFIES SQL DATA
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    LANGUAGE SQL
BEGIN ATOMIC
    CALL AUTO_MERGE(CURRENT SCHEMA, SOURCE_TABLE, CURRENT SCHEMA, DEST_TABLE, DEST_KEY);
END!

CREATE PROCEDURE AUTO_MERGE(
    SOURCE_TABLE VARCHAR(128),
    DEST_TABLE VARCHAR(128)
)
    SPECIFIC AUTO_MERGE4
    MODIFIES SQL DATA
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    LANGUAGE SQL
BEGIN ATOMIC
    CALL AUTO_MERGE(CURRENT SCHEMA, SOURCE_TABLE, CURRENT SCHEMA, DEST_TABLE, (
        SELECT CONSTNAME
        FROM SYSCAT.TABCONST
        WHERE TABSCHEMA = CURRENT SCHEMA
        AND TABNAME = DEST_TABLE
        AND TYPE = 'P'));
END!

GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_MERGE1 TO ROLE UTILS_MERGE_USER!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_MERGE2 TO ROLE UTILS_MERGE_USER!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_MERGE3 TO ROLE UTILS_MERGE_USER!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_MERGE4 TO ROLE UTILS_MERGE_USER!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_MERGE1 TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_MERGE2 TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_MERGE3 TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_MERGE4 TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!

COMMENT ON SPECIFIC PROCEDURE AUTO_MERGE1
    IS 'Automatically inserts/updates ("upserts") data from SOURCE_TABLE into DEST_TABLE based on DEST_KEY'!
COMMENT ON SPECIFIC PROCEDURE AUTO_MERGE2
    IS 'Automatically inserts/updates ("upserts") data from SOURCE_TABLE into DEST_TABLE based on DEST_KEY'!
COMMENT ON SPECIFIC PROCEDURE AUTO_MERGE3
    IS 'Automatically inserts/updates ("upserts") data from SOURCE_TABLE into DEST_TABLE based on DEST_KEY'!
COMMENT ON SPECIFIC PROCEDURE AUTO_MERGE4
    IS 'Automatically inserts/updates ("upserts") data from SOURCE_TABLE into DEST_TABLE based on DEST_KEY'!

-- AUTO_DELETE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, DEST_KEY)
-- AUTO_DELETE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE)
-- AUTO_DELETE(SOURCE_TABLE, DEST_TABLE, DEST_KEY)
-- AUTO_DELETE(SOURCE_TABLE, DEST_TABLE)
-------------------------------------------------------------------------------
-- The AUTO_DELETE procedure deletes rows from DEST_TABLE that do not exist
-- in SOURCE_TABLE. This procedure is intended to be used after the AUTO_MERGE
-- procedure has been used to upsert from SOURCE to DEST.
--
-- The DEST_KEY parameter specifies the name of the unique key to use for
-- identifying rows in the destination table. If specified, it must be the name
-- of a unique key or primary key which covers columns which exist in both the
-- source and destination tables. If omitted, it defaults to the name of the
-- primary key of the destination table.
--
-- If SOURCE_SCHEMA and DEST_SCHEMA are not specified they default to the
-- current schema.
-------------------------------------------------------------------------------

CREATE PROCEDURE AUTO_DELETE(
    SOURCE_SCHEMA VARCHAR(128),
    SOURCE_TABLE VARCHAR(128),
    DEST_SCHEMA VARCHAR(128),
    DEST_TABLE VARCHAR(128),
    DEST_KEY VARCHAR(128)
)
    SPECIFIC AUTO_DELETE1
    MODIFIES SQL DATA
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    LANGUAGE SQL
BEGIN ATOMIC
    DECLARE DML CLOB(64K) DEFAULT '';

    CALL X_MERGE_CHECKS(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, DEST_KEY);
    SET DML = X_BUILD_DELETE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, DEST_KEY);
    EXECUTE IMMEDIATE DML;
END!

CREATE PROCEDURE AUTO_DELETE(
    SOURCE_SCHEMA VARCHAR(128),
    SOURCE_TABLE VARCHAR(128),
    DEST_SCHEMA VARCHAR(128),
    DEST_TABLE VARCHAR(128)
)
    SPECIFIC AUTO_DELETE2
    MODIFIES SQL DATA
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    LANGUAGE SQL
BEGIN ATOMIC
    CALL AUTO_DELETE(SOURCE_SCHEMA, SOURCE_TABLE, DEST_SCHEMA, DEST_TABLE, (
        SELECT CONSTNAME
        FROM SYSCAT.TABCONST
        WHERE TABSCHEMA = DEST_SCHEMA
        AND TABNAME = DEST_TABLE
        AND TYPE = 'P'));
END!

CREATE PROCEDURE AUTO_DELETE(
    SOURCE_TABLE VARCHAR(128),
    DEST_TABLE VARCHAR(128),
    DEST_KEY VARCHAR(128)
)
    SPECIFIC AUTO_DELETE3
    MODIFIES SQL DATA
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    LANGUAGE SQL
BEGIN ATOMIC
    CALL AUTO_DELETE(CURRENT SCHEMA, SOURCE_TABLE, CURRENT SCHEMA, DEST_TABLE, DEST_KEY);
END!

CREATE PROCEDURE AUTO_DELETE(
    SOURCE_TABLE VARCHAR(128),
    DEST_TABLE VARCHAR(128)
)
    SPECIFIC AUTO_DELETE4
    MODIFIES SQL DATA
    NOT DETERMINISTIC
    NO EXTERNAL ACTION
    LANGUAGE SQL
BEGIN ATOMIC
    CALL AUTO_DELETE(CURRENT SCHEMA, SOURCE_TABLE, CURRENT SCHEMA, DEST_TABLE, (
        SELECT CONSTNAME
        FROM SYSCAT.TABCONST
        WHERE TABSCHEMA = CURRENT SCHEMA
        AND TABNAME = DEST_TABLE
        AND TYPE = 'P'));
END!

GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_DELETE1 TO ROLE UTILS_MERGE_USER!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_DELETE2 TO ROLE UTILS_MERGE_USER!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_DELETE3 TO ROLE UTILS_MERGE_USER!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_DELETE4 TO ROLE UTILS_MERGE_USER!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_DELETE1 TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_DELETE2 TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_DELETE3 TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!
GRANT EXECUTE ON SPECIFIC PROCEDURE AUTO_DELETE4 TO ROLE UTILS_MERGE_ADMIN WITH GRANT OPTION!

COMMENT ON SPECIFIC PROCEDURE AUTO_DELETE1
    IS 'Automatically removes data from DEST_TABLE that doesn''t exist in SOURCE_TABLE, based on DEST_KEY'!
COMMENT ON SPECIFIC PROCEDURE AUTO_DELETE2
    IS 'Automatically removes data from DEST_TABLE that doesn''t exist in SOURCE_TABLE, based on DEST_KEY'!
COMMENT ON SPECIFIC PROCEDURE AUTO_DELETE3
    IS 'Automatically removes data from DEST_TABLE that doesn''t exist in SOURCE_TABLE, based on DEST_KEY'!
COMMENT ON SPECIFIC PROCEDURE AUTO_DELETE4
    IS 'Automatically removes data from DEST_TABLE that doesn''t exist in SOURCE_TABLE, based on DEST_KEY'!

