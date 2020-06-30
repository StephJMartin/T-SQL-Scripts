-- =============================================
-- Author:      Steph Martin
-- Create date: 2020-06-30
-- Description: Use data classified in sys.sensitivity_classifications to generate a series of update statements for obfuscating data in non-production environments.  
--              Extend as necessary to include specific technical or buiness requirements. 
--			    Suitable for use with on-premises SQL Server and SQLDB
-- =============================================

DROP TABLE IF EXISTS DataMaskingScripts;
GO
CREATE TABLE DataMaskingScripts (SchemaName NVARCHAR(128), TableName NVARCHAR(128), ColumnName NVARCHAR(128), UpdateScript NVARCHAR(MAX));
GO

DECLARE @sql NVARCHAR(MAX)

DECLARE @SchemaName NVARCHAR(128)
DECLARE @TableName NVARCHAR(128)
DECLARE @ColumnName NVARCHAR(128)
DECLARE @InformationType NVARCHAR(128);
DECLARE @DataType NVARCHAR(128)
DECLARE @CharacterMaxLength INT;
DECLARE @NumericPrecision TINYINT;
DECLARE @NumericScale INT;

DECLARE @Mask VARCHAR(50);

-- Default Mask Values --
--Strings
DECLARE @StringMask CHAR(30) = REPLICATE('x', 10)
DECLARE @EmailMask CHAR(100) = '@xxxxxx.com'

-- Dates
DECLARE @DateMask CHAR(10) = '1900-01-01' -- Date, DateTime, DateTime2
DECLARE @YearMask CHAR(4) = '1900' 

-- Numbers
DECLARE @NumberMask CHAR(20) = REPLICATE('1', 20)


DECLARE mask_cursor CURSOR LOCAL FAST_FORWARD 
 FOR 
 	 SELECT 
		schema_name(o.schema_id) AS schema_name,
		o.[name] AS table_name,
		c.[name] AS column_name,
		CAST([information_type] AS NVARCHAR(128)) AS info_type
	FROM sys.sensitivity_classifications AS sc
		JOIN sys.objects AS o ON sc.major_id = o.object_id
		JOIN sys.columns AS c ON sc.major_id = c.object_id  AND sc.minor_id = c.column_id
		
OPEN mask_cursor

FETCH NEXT FROM mask_cursor
INTO @SchemaName, @TableName, @ColumnName, @InformationType

WHILE @@FETCH_STATUS = 0

BEGIN
	SELECT	
			@DataType = DATA_TYPE,
			@CharacterMaxLength = CHARACTER_MAXIMUM_LENGTH,
			@NumericPrecision = NUMERIC_PRECISION,
			@NumericScale = NUMERIC_SCALE
	FROM	INFORMATION_SCHEMA.COLUMNS
	WHERE	TABLE_SCHEMA = @SchemaName
	AND		TABLE_NAME = @TableName
	AND		COLUMN_NAME = @ColumnName;
		
	-- Basic Mask Setting based on Data Type
SET @Mask = (
	SELECT 
		CASE 
		WHEN @DataType IN ('char', 'nchar', 'varchar', 'nvarchar')
			THEN '''' + LEFT(@StringMask, @CharacterMaxLength) + ''''
		WHEN @DataType IN ('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
			THEN '''' + @DateMask + ''''
		WHEN @DataType IN ('tinyint', 'smallint', 'int', 'bigint')
			THEN LEFT(@NumberMask, @NumericPrecision)
		WHEN @DataType IN ('decimal', 'numeric', 'money', 'smallmoney')
			THEN CONCAT(LEFT(@NumberMask, @NumericPrecision-@NumericScale),'.', LEFT(@NumberMask, @NumericScale))
		ELSE 
			'NULL'
		END AS Mask)
	
SET @sql = 'UPDATE ' + @SchemaName + '.' + @TableName + 
			' SET ' + @ColumnName + ' = ' + RTRIM(@Mask) + ';';

	-- Override special cases, based on column constraints or application constraints.

	-- Email must be in a valid format
	IF (@DataType IN ('char', 'nchar', 'varchar', 'nvarchar')) AND @ColumnName LIKE '%email%'
		BEGIN
			SET @sql = 'UPDATE ' + @SchemaName + '.' + @TableName + 
				' SET ' + @ColumnName + ' = ''' + RIGHT(CONCAT(RTRIM(@StringMask), RTRIM(@EmailMask)),@CharacterMaxLength) + ''';';
		END

	-- Year fields must be valid year
	IF (@DataType IN ('tinyint', 'smallint', 'int', 'bigint') AND @ColumnName LIKE '%year%')
		BEGIN
			SET @sql = 'UPDATE ' + @SchemaName + '.' + @TableName + 
					   ' SET ' + @ColumnName + ' = ' + @YearMask + ';';
		END
				
	-- Credit Card - Column has unique index so cannot use a default mask
	IF (@InformationType = 'Credit Card' AND @ColumnName = 'CardNumber')
	BEGIN
		DECLARE @sqlcommand NVARCHAR(500) = N'SELECT @NumberOfRows = COUNT(*) FROM ' + @SchemaName + '.' + @TableName + ';' 
		DECLARE @MaxRows BIGINT 
		EXECUTE sp_executesql @sqlcommand, N'@NumberOfRows INT OUTPUT', @NumberOfRows = @MaxRows OUTPUT;
		
		SET @sql = 
			'DECLARE @MaxRows BIGINT = (SELECT COUNT(*) FROM ' + @SchemaName + '.' + @TableName + '); 
			WITH Numbers
			AS
			(
				SELECT 1 AS Number   
				UNION ALL
				SELECT Number + 1 
				FROM numbers 
				WHERE number <= @MaxRows 
			),
			MaskedCardNumbers AS
			(
				SELECT	Number,
						RIGHT(REPLICATE(''x'',16) + CAST(Number AS VARCHAR(16)), 16) AS MaskedCardNumber
				FROM	Numbers AS n
			),
			ExistingCards AS 
			(
				SELECT ROW_NUMBER() OVER(ORDER BY CreditCardID) AS RowNo, CreditCardID
				FROM ' + @SchemaName + '.' + @TableName + '
			)
			UPDATE ' + + @SchemaName + '.' + @TableName + '
				SET ' + @ColumnName + ' = CONCAT(SUBSTRING(MaskedCardNumber, 1, 4), ''-'',
												 SUBSTRING(MaskedCardNumber, 5, 4), ''-'',
												 SUBSTRING(MaskedCardNumber, 9, 4), ''-'',
												 SUBSTRING(MaskedCardNumber, 13, 4))
			FROM MaskedCardNumbers AS MaskedCards
			JOIN ExistingCards AS ExistingCards
				ON ExistingCards.RowNo = MaskedCards.Number
				OPTION (maxrecursion ' + CAST(@MaxRows AS VARCHAR(20)) + ');'
			
	END
	
	INSERT INTO DataMaskingScripts (SchemaName, TableName, ColumnName, UpdateScript)
		SELECT @SchemaName, @TableName, @ColumnName, @sql;
	
	FETCH NEXT FROM mask_cursor
	INTO @SchemaName, @TableName, @ColumnName, @InformationType

END 
CLOSE mask_cursor;
DEALLOCATE mask_cursor;


SELECT * FROM DataMaskingScripts;
