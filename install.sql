/********************************************************************************************************
*                                                                                                       *
*                                     Snowflake Infer Schema                                            *
*                                                                                                       *
*  Copyright (c) 2021 Snowflake Computing Inc. All rights reserved.                                     *
*                                                                                                       *
*  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in  *
*  compliance with the License. You may obtain a copy of the License at                                 *
*                                                                                                       *
*                             http://www.apache.org/licenses/LICENSE-2.0                                *
*                                                                                                       *
*  Unless required by applicable law or agreed to in writing, software distributed under the License    *
*  is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or  *
*  implied. See the License for the specific language governing permissions and limitations under the   *
*  License.                                                                                             *
*                                                                                                       *
*  Copyright (c) 2021 Snowflake Computing Inc. All rights reserved.                                     *
*                                                                                                       *
********************************************************************************************************/

use database UTIL_DB;
use schema PUBLIC;

create or replace function TRY_MULTI_TIMESTAMP(STR string)
returns timestamp
language SQL
as
$$
    case
        when STR RLIKE '[A-Za-z]{3} \\d{2} \\d{4} \\d{1,2}:\\d{2}:\\d{2}' then try_to_timestamp(left(STR, 20), 'MON DD YYYY HH24:MI:SS')
        when STR RLIKE '\\d{1,4}-\\d{1,2}-\\d{2} \\d{1,2}:\\d{2}:\\d{2} [A|P][M]' then try_to_timestamp(STR, 'YYYY-MM-DD HH12:MI:SS AM')
        when STR RLIKE '\\d{1,2}/\\d{1,2}/\\d{4}' then try_to_timestamp(STR, 'mm/dd/yyyy')
        when STR RLIKE '\\d{1,2}\\/\\d{1,2}\\/\\d{4} \\d{1,2}:\\d{2}:\\d{2} [A-Za-z]{2}' then try_to_timestamp(STR, 'MM/DD/YYYY HH12:MI:SS AM')
        when STR RLIKE '\\d{1,2}\\/\\d{1,2}\\/\\d{4} \\d{1,2}:\\d{2}' then try_to_timestamp(STR, 'MM/DD/YYYY HH24:MI')
        when STR RLIKE '[A-Za-z]{3}, \\d{1,2} [A-Za-z]{3} \\d{4} \\d{1,2}:\\d{1,2}:\\d{1,2} [A-Za-z]{3}' then try_to_timestamp(left(STR, len(STR) - 4) || ' ' || '00:00', 'DY, DD MON YYYY HH:MI:SS TZH:TZM')   -- From Snowflake "LIST" command
        when STR RLIKE '\\d{1,2}/\\d{1,2}/\\d{2} \\d{1,2}:\\d{2} [A|P][M]' then try_to_timestamp(STR, 'MM/DD/YY HH12:MI AM')
        when STR RLIKE '[A-Za-z]{3} [A-Za-z]{3} \\d{2} \\d{4} \\d{1,2}:\\d{2}:\\d{2} GMT.*' then try_to_timestamp(left(replace(substr(STR, 5), 'GMT', ''), 26), 'MON DD YYYY HH:MI:SS TZHTZM')  -- Javascript
        else try_to_timestamp(STR) -- Final try without format specifier.
    end
$$;

create or replace function TRY_EXACT_DATE(STR string)
returns date
language sql
as
$$
    iff(
        try_multi_timestamp(STR) is not null and try_multi_timestamp(STR) = try_multi_timestamp(STR)::date,
        try_multi_timestamp(STR)::date,
        null
    )
$$;

create or replace function TRY_EXACT_INTEGER(STR string)
returns int
language sql
as
$$
    iff(
        try_to_double(STR) is not null and try_to_double(STR) = try_to_double(STR)::int,
        try_to_double(STR)::int,
        null
    )
$$;

create or replace file format READ_LINES
type = 'csv'
compression = 'auto'
field_delimiter = 'none'
record_delimiter = '\n' 
skip_header = 0 
field_optionally_enclosed_by = 'none'
trim_space = false
escape = 'none'
escape_unenclosed_field = '\134'
;

create or replace file format SKIP_HEADER
type = 'csv'
compression = 'auto'
field_delimiter = ','
record_delimiter = '\n' 
skip_header = 1 
field_optionally_enclosed_by = 'none'
trim_space = false
error_on_column_count_mismatch = true
escape = 'none'
escape_unenclosed_field = '\134'
date_format = 'auto'
timestamp_format = 'auto'
null_if = ('\\N')
;

create or replace procedure INFER_DELIMITED_SCHEMA(STAGE_PATH string, FILE_FORMAT string, FIRST_ROW_IS_HEADER boolean, NEW_TABLE_NAME string)
returns string
language javascript
execute as caller
as
$$

/****************************************************************************************************
*  Preferences Section                                                                              *
****************************************************************************************************/

const MAX_ROW_SAMPLES          = 100000;        // Sets the maximum number of rows the inference will test.
const PROJECT_NAMESPACE        = "UTIL_DB.PUBLIC"
const USE_TRY_MULTI_TIMESTAMP  = true;
const REGULARIZE_COLUMN_NAMES  = true;
const NUMBERED_COLUMN_PREFIX   = "COLUMN_";
const RAW_SUFFIX               = "_raw";
const NONCONFORMING_SUFFIX     = "_NONCONFORMING";

/****************************************************************************************************
*  Do not modify below this section                                                                 *
****************************************************************************************************/

/****************************************************************************************************
*  DataType Classes                                                                                 *
****************************************************************************************************/

class Query{
    constructor(statement){
        this.statement = statement;
    }
}

class DataType {
    constructor(column, ordinalPosition, sourceQuery) {
        this.sourceQuery = sourceQuery
        this.column = column;
        this.ordinalPosition = ordinalPosition;
        this.insert = '@~COLUMN~@';
        this.totalCount = 0;
        this.notNullCount = 0;
        this.typeCount = 0;
        this.blankCount = 0;
        this.minTypeOf  = 0.95;
        this.minNotNull = 1.00;
    }
    setSQL(sqlTemplate){
        this.sql = sqlTemplate;
        this.sql = this.sql.replace(/@~COLUMN~@/g, this.column);
    }
    getCounts(){
        var rs;
        rs = GetResultSet(this.sql);
        rs.next();
        this.totalCount   = rs.getColumnValue("TOTAL_COUNT");
        this.notNullCount = rs.getColumnValue("NON_NULL_COUNT");
        this.typeCount    = rs.getColumnValue("TO_TYPE_COUNT");
        this.blankCount   = rs.getColumnValue("BLANK");
    }
    isCorrectType(){
        return (this.typeCount / (this.notNullCount - this.blankCount) >= this.minTypeOf);
    }
    isNotNull(){
        return (this.notNullCount / this.totalCount >= this.minNotNull);
    }
}

class DateType extends DataType{
    constructor(column, ordinalPosition, sourceQuery){
        super(column, ordinalPosition, sourceQuery)
        this.syntax = "date";
        this.insert = `${PROJECT_NAMESPACE}.try_exact_date(trim("@~COLUMN~@"))`;
        this.sourceQuery = sourceQuery;
        this.setSQL(GetCheckTypeSQL(this.insert, this.sourceQuery));
        this.getCounts();
    }
}

class TimestampType extends DataType{
    constructor(column, ordinalPosition, sourceQuery){
        super(column, ordinalPosition, sourceQuery)
        this.syntax = "timestamp";
        this.insert = `${PROJECT_NAMESPACE}.try_multi_timestamp(trim("@~COLUMN~@"))`;
        this.sourceQuery = sourceQuery;
        this.setSQL(GetCheckTypeSQL(this.insert, this.sourceQuery));
        this.getCounts();
    }
}

class IntegerType extends DataType{
    constructor(column, ordinalPosition, sourceQuery){
        super(column, ordinalPosition, sourceQuery)
        this.syntax = "number(38,0)";
        this.insert = `${PROJECT_NAMESPACE}.try_exact_integer(trim("@~COLUMN~@"))`;
        this.setSQL(GetCheckTypeSQL(this.insert, this.sourceQuery));
        this.getCounts();
    }
}

class DoubleType extends DataType{
    constructor(column, ordinalPosition, sourceQuery){
        super(column, ordinalPosition, sourceQuery)
        this.syntax = "double";
        this.insert = 'try_to_double(trim("@~COLUMN~@"))';
        this.setSQL(GetCheckTypeSQL(this.insert, this.sourceQuery));
        this.getCounts();
    }
}

class BooleanType extends DataType{
    constructor(column, ordinalPosition, sourceQuery){
        super(column, ordinalPosition, sourceQuery)
        this.syntax = "boolean";
        this.insert = 'try_to_boolean(trim("@~COLUMN~@"))';
        this.setSQL(GetCheckTypeSQL(this.insert, this.sourceQuery));
        this.getCounts();
    }
}

 // Catch all is STRING data type
class StringType extends DataType{
    constructor(column, ordinalPosition, sourceQuery){
        super(column, ordinalPosition, sourceQuery)
        this.syntax = "string";
        this.totalCount   = 1;
        this.notNullCount = 0;
        this.typeCount    = 1;
        this.minTypeOf    = 0;
        this.minNotNull   = 1;
    }
}

/****************************************************************************************************
*  Main function                                                                                    *
****************************************************************************************************/

let headerSQL = `select $1 as HEADER from ${STAGE_PATH} (file_format => '${PROJECT_NAMESPACE}.READ_LINES') limit 1;`;
let headerRow = ExecuteSingleValueQuery('HEADER', headerSQL);

let header;

if (FIRST_ROW_IS_HEADER) {
    header = headerRow.split(',');
} else {
    header = [];
    let cols = headerRow.split(',');
    for (let colPos = 0; colPos < cols.length; colPos++ ) {
        header.push(NUMBERED_COLUMN_PREFIX + colPos+1);
    }
}

if (REGULARIZE_COLUMN_NAMES) {
    header = regularizeColumnNames(header);
}

let sql = "select\n";
for (let i = 0; i < header.length; i++) {
    sql += (i > 0 ? ",$" : "$") + `${i+1} as "${header[i]}"\n`;
}
sql += `from ${STAGE_PATH} ( file_format => '${FILE_FORMAT}') limit ${MAX_ROW_SAMPLES}`;

let qMain = GetQuery(sql);

let column;
let typeOf;
let ins = '';

var newTableDDL = '';
var badTableDDL = '';
var insertDML   = '';

for (let c = 0; c < header.length; c++) {
    if(c > 0){
        newTableDDL += "\n\t,";
        badTableDDL += "\n\t,";
        insertDML   += "\n\t,";
    } else {
        newTableDDL += "\t ";
        badTableDDL += "\t ";
        insertDML   += "\n\t,";
    }
    if (FIRST_ROW_IS_HEADER) {
        column = '"' + header[c] + '"';
    } else {
        column = "$" + c+1;
    }

    typeOf = InferDataType(header[c], c + 1, qMain.statement.getQueryId());
    newTableDDL += GetColumnDdlName(typeOf, FIRST_ROW_IS_HEADER, NUMBERED_COLUMN_PREFIX) + ' ' + typeOf.syntax;
    badTableDDL += GetColumnDdlName(typeOf, FIRST_ROW_IS_HEADER, NUMBERED_COLUMN_PREFIX) + ' string';
    ins = typeOf.insert;
    insertDML   += ins.replace(/@~COLUMN~@/g, "$" + typeOf.ordinalPosition) + " as " + `"${header[c]}"`;
}

let insertStatement;

insertStatement = GetInsertPrefixSQL(NEW_TABLE_NAME)         +
                  insertDML                                  +
                  GetInsertSuffixSQL(STAGE_PATH, FILE_FORMAT);

let mtInsert = getMultiInsert(
                     NEW_TABLE_NAME
                    ,getColumnList(header, "", false)
                    ,NONCONFORMING_SUFFIX
                    ,getColumnConditions(header, RAW_SUFFIX)
                    ,getColumnList(header, RAW_SUFFIX, false)
                    ,getColumnList(header, RAW_SUFFIX, true)
                    ,insertDML
                    ,STAGE_PATH
                    ,FILE_FORMAT
                );
                
return GetOpeningComments()                                  +
       GetDDLPrefixSQL(NEW_TABLE_NAME)                       +
       newTableDDL                                           +
       GetDDLSuffixSQL()                                     +
       GetBadPrefixSQL(NEW_TABLE_NAME, NONCONFORMING_SUFFIX) +
       badTableDDL                                           +
       GetDDLSuffixSQL()                                     +
       GetDividerSQL()                                       +
       mtInsert;

/****************************************************************************************************
*  Helper functions                                                                                 *
****************************************************************************************************/

function getMultiInsert(tableName, columnList, nonconformingSuffix, conditionList, rawColumnList, rawColumns, tryColumns, stageName, fileFormat) {
return `
insert first when
${conditionList}
then into ${tableName}${nonconformingSuffix}
(
${columnList}
)
values
(
${rawColumnList}
)
else into ${tableName}
(
${columnList}
)
values
(
${columnList}
)
select 
${rawColumns}

${tryColumns}

from ${stageName} (file_format => '${fileFormat}');
`;
}

function getColumnConditions(header, suffix) {  // NOTE: Improve by writing only non-string types
    let list = "\t   ";
    for(let i = 0; i < header.length; i++) {
        if(i > 0) list += "\n\tor ";
        list += `"${header[i]}"\tis null and\t"${header[i]}${suffix}"\t is not null`;
    }
    return list;
}

function getColumnList(header, suffix, numberThem) {
    let list = "\t ";
    for(let i = 0; i < header.length; i++) {
        if(i > 0) list += "\n\t,";
        if(numberThem) list += "$" + `${i+1} as `;
        list += `"${header[i]}${suffix}"`;
    }
    return list;
}

function InferDataType(column, ordinalPosition, sourceQuery){

    var typeOf;

    typeOf = new IntegerType(column, ordinalPosition, sourceQuery);
    if (typeOf.isCorrectType()) return typeOf;

    typeOf = new DoubleType(column, ordinalPosition, sourceQuery);
    if (typeOf.isCorrectType()) return typeOf;

    typeOf = new BooleanType(column, ordinalPosition, sourceQuery);        // May want to do a distinct and look for two values
    if (typeOf.isCorrectType()) return typeOf;

    typeOf = new DateType(column, ordinalPosition, sourceQuery);
    if (typeOf.isCorrectType()) return typeOf;

    typeOf = new TimestampType(column, ordinalPosition, sourceQuery);
    if (typeOf.isCorrectType()) return typeOf;

    typeOf = new StringType(column, ordinalPosition, sourceQuery);
    if (typeOf.isCorrectType()) return typeOf;

    return null;
}

function regularizeColumnNames(header) {
    s = "";
    newHeader = [];
    for (let i = 0; i < header.length; i++) {
        s = header[i];
        s = s.replace(/ /g,"_").toUpperCase();
        newHeader.push(s);
    }
    return newHeader;
}

function GetQuery(sql){
    cmd = {sqlText: sql};
    var query = new Query(snowflake.createStatement(cmd));
    query.resultSet = query.statement.execute();
    return query;
}

/****************************************************************************************************
*  SQL Template Functions                                                                           *
****************************************************************************************************/

function GetColumnDdlName(typeOf, firstRowIsHeader, numberedColumnPrefix) {
    if (firstRowIsHeader) {
        return '"' + typeOf.column + '"';
    } else {
        return numberedColumnPrefix + typeOf.ordinalPosition;
    }
}

function GetCheckTypeSQL(insert, sourceQuery){

var sql = 
`
select      count(1)                              as TOTAL_COUNT,
            count("@~COLUMN~@")                   as NON_NULL_COUNT,
            count(${insert})                      as TO_TYPE_COUNT,
            sum(iff(trim("@~COLUMN~@")='', 1, 0)) as BLANK
from        (select * from table(result_scan('${sourceQuery}')))
`;

return sql;
}

function GetTableColumnsSQL(dbName, schemaName, tableName){

var sql = 
`
select  COLUMN_NAME 
from    ${dbName}.INFORMATION_SCHEMA.COLUMNS
where   TABLE_CATALOG = '${dbName}' and
        TABLE_SCHEMA  = '${schemaName}' and
        TABLE_NAME    = '${tableName}'
order by ORDINAL_POSITION;
`;
  
return sql;
}

function GetOpeningComments(){
return `
/**************************************************************************************************************
*   Copy, paste, review and run to create a typed table and insert into the new table from stage.             *
**************************************************************************************************************/
`;
}

function GetDDLPrefixSQL(table) {

var sql =
`
create or replace table ${table}
(
`;

    return sql;
}
  
function GetBadPrefixSQL(table, suffix) {

var sql =
`

create or replace table ${table}${suffix}
(
`;

    return sql;
}

function GetDDLSuffixSQL(){
    return "\n);";
}

function GetDividerSQL(){
return `\n
/**************************************************************************************************************
*   The SQL statement below this attempts to copy all rows from the stage to the typed table.                 *
**************************************************************************************************************/
`;
}

function GetInsertPrefixSQL(table) {
var sql =
`\ninsert into ${table} select\n`;
return sql;
}

function GetInsertSuffixSQL(stagePath, fileFormat){
var sql =
`\nfrom ${stagePath} (file_format => '${fileFormat}');`;
return sql;
}

/****************************************************************************************************
*  SQL functions                                                                                    *
****************************************************************************************************/

function GetResultSet(sql) {
    cmd = {sqlText: sql};
    stmt = snowflake.createStatement(cmd);
    var rs;
    rs = stmt.execute();
    return rs;
}

function ExecuteNonQuery(queryString) {
    var out = '';
    cmd1 = {sqlText: queryString};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    rs = stmt.execute();
}

function ExecuteSingleValueQuery(columnName, queryString) {
    var out;
    cmd1 = {sqlText: queryString};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    try{
        rs = stmt.execute();
        rs.next();
        return rs.getColumnValue(columnName);
    }
    catch(err) {
        if (err.message.substring(0, 18) == "ResultSet is empty"){
            throw "ERROR: No rows returned in query.";
        } else {
            throw "ERROR: " + err.message.replace(/\n/g, " ");
        } 
    }
    return out;
}

function ExecuteFirstValueQuery(queryString) {
    var out;
    cmd1 = {sqlText: queryString};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    try{
        rs = stmt.execute();
        rs.next();
        return rs.getColumnValue(1);
    }
    catch(err) {
        if (err.message.substring(0, 18) == "ResultSet is empty"){
            throw "ERROR: No rows returned in query.";
        } else {
            throw "ERROR: " + err.message.replace(/\n/g, " ");
        } 
    }
    return out;
}

function getQuery(sql){
    var cmd = {sqlText: sql};
    var query = new Query(snowflake.createStatement(cmd));
    try {
        query.resultSet = query.statement.execute();
    } catch (err) {
        throw "ERROR: " + err.message.replace(/\n/g, " ");
    }
    return query;
}

$$;

create or replace procedure create_view_over_variant (TABLE_NAME varchar, COL_NAME varchar, VIEW_NAME varchar)
returns varchar
language javascript
as
$$
/****************************************************************************************************************
*                                                                                                               *
* CREATE_VIEW_OVER_JSON - Craig Warman, Alan Eldridge and Greg Pavlik Snowflake Computing, (c) 2019, 2020, 2021 *
*                                                                                                               *
* This stored procedure creates a view on a table that contains JSON data in a column.                          *
* of type VARIANT.  It can be used for easily generating views that enable access to                            *
* this data for BI tools without the need for manual view creation based on the underlying                      *
* JSON document structure.                                                                                      *
*                                                                                                               *
* Parameters:                                                                                                   *
* TABLE_NAME    - Name of table that contains the semi-structured data.                                         *
* COL_NAME      - Name of VARIANT column in the aforementioned table.                                           *
* VIEW_NAME     - Name of view to be created by this stored procedure.                                          *
*                                                                                                               *
* Usage Example:                                                                                                *
* call create_view_over_json('db.schema.semistruct_data', 'variant_col', 'db.schema.semistruct_data_vw');       *
*                                                                                                               *
* Important notes:                                                                                              *
*   - This version of the procedure does not support:                                                           *
*         - Column case preservation (all view column names will be case-insensitive).                          *
*         - JSON document attributes that are SQL reserved words (like TYPE or NUMBER).                         *
*         - "Exploding" arrays into separate view columns - instead, arrays are simply                          *
*           materialized as view columns of type ARRAY.                                                         *
*                                                                                                               *
* Attribution:                                                                                                  *
* Stored procedure original concept and execution, Craig Warman                                                 *
* Typecasting of variant types uses SQL code developed by Alan Eldridge as the basis for this procedure.        *
* Procedure rewritten and maintained by Greg Pavik with Craig's and Alan's permission.                          *
****************************************************************************************************************/

const ROW_SAMPLE_SIZE = 10000;

var currentActivity;

try{

    currentActivity   = "building the query for column types";
    var elementQuery  = GetElementQuery(TABLE_NAME, COL_NAME);
    
    currentActivity   = "running the query to get column names";
    var elementRS     = GetResultSet(elementQuery);

    currentActivity   = "building the column list";
    var colList       = GetColumnList(elementRS);

    currentActivity   = "building the view's DDL";
    var viewDDL       = GetViewDDL(VIEW_NAME, colList, TABLE_NAME);

    currentActivity   = "creating the view";
    return ExecuteSingleValueQuery("status", viewDDL);
}
catch(err){
    return "ERROR: Encountered an error while " + currentActivity + ".\n" + err.message;
}

/****************************************************************************************************************
*   End of main function. Helper functions below.                                                               *
****************************************************************************************************************/

function GetElementQuery(tableName, columnName){

// Build a query that returns a list of elements which will be used to build the column list for the CREATE VIEW statement

sql = 
`
SELECT DISTINCT '"' || array_to_string(split(f.path, '.'), '"."') || '"'                                         AS path_nAme,       -- This generates paths with levels enclosed by double quotes (ex: "path"."to"."element").  It also strips any bracket-enclosed array element references (like "[0]")
                DECODE (substr(typeof(f.value),1,1),'A','ARRAY','B','BOOLEAN','I','FLOAT','D','FLOAT','STRING')  AS attribute_type,  -- This generates column datatypes of ARRAY, BOOLEAN, FLOAT, and STRING only
                '"' || array_to_string(split(f.path, '.'), '.') || '"'                                           AS alias_name       -- This generates column aliases based on the path
FROM
        @~TABLE_NAME~@,
        LATERAL FLATTEN(@~COL_NAME~@, RECURSIVE=>true) f
WHERE   TYPEOF(f.value) != 'OBJECT'
        AND NOT contains(f.path, '[')         -- This prevents traversal down into arrays
limit   ${ROW_SAMPLE_SIZE}
`;

    sql = sql.replace(/@~TABLE_NAME~@/g, tableName);
    sql = sql.replace(/@~COL_NAME~@/g, columnName);

    return sql;
}

function GetColumnList(elementRS){

    /*  
        Add elements and datatypes to the column list
        They will look something like this when added:
            col_name:"name"."first"::STRING as name_first,
            col_name:"name"."last"::STRING as name_last
    */

    var col_list = "";

    while (elementRS.next()) {
        if (col_list != "") {
            col_list += ", \n";
        }
        col_list += COL_NAME + ":" + elementRS.getColumnValue("PATH_NAME");      // Start with the element path name
        col_list += "::"           + elementRS.getColumnValue("ATTRIBUTE_TYPE"); // Add the datatype
        col_list += ' as '         + elementRS.getColumnValue("ALIAS_NAME");     // And finally the element alias
    }
    return col_list;
}

function GetViewDDL(viewName, columnList, tableName){

sql = 
`
create or replace view @~VIEW_NAME~@ as
select 
    @~COLUMN_LIST~@
from @~TABLE_NAME~@;
`;
    sql = sql.replace(/@~VIEW_NAME~@/g, viewName);
    sql = sql.replace(/@~COLUMN_LIST~@/g, columnList);
    sql = sql.replace(/@~TABLE_NAME~@/g, tableName);

    return sql;
}

/****************************************************************************************************************
*   Library functions                                                                                           *
****************************************************************************************************************/

function ExecuteSingleValueQuery(columnName, queryString) {
    var out;
    cmd1 = {sqlText: queryString};
    stmt = snowflake.createStatement(cmd1);
    var rs;
    try{
        rs = stmt.execute();
        rs.next();
        return rs.getColumnValue(columnName);
    }
    catch(err) {
        throw err;
    }
    return out;
}

function GetResultSet(sql){

    try{
        cmd1 = {sqlText: sql};
        stmt = snowflake.createStatement(cmd1);
        var rs;
        rs = stmt.execute();
        return rs;
    }
    catch(err) {
        throw err;
    } 
}
$$;
