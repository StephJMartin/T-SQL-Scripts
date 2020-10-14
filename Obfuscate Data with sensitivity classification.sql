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

DECLARE @sql NVARCHAR(MAX);

DECLARE @SchemaName NVARCHAR(128)
DECLARE @TableName NVARCHAR(128)
DECLARE @ColumnName NVARCHAR(128)
DECLARE @InformationType NVARCHAR(128)
DECLARE @DataType NVARCHAR(128)
DECLARE @CharacterMaxLength INT
DECLARE @NumericPrecision TINYINT
DECLARE @NumericScale INT;

DECLARE @Mask VARCHAR(100);

-- Default Mask Values --
--Strings
DECLARE @StringMask CHAR(80) = REPLICATE('x', 80)
DECLARE @EmailMask CHAR(80) = '@xxxxxxxxxx.com'
DECLARE @RandomStringLen INT;

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


SET @RandomStringLen = (SELECT CAST(RAND()*(CASE WHEN @CharacterMaxLength < LEN(@StringMask) THEN @CharacterMaxLength ELSE LEN(@StringMask) END -1) + 1 AS INT));


--	 Basic Mask Setting based on Data Type
SET @Mask = (
	SELECT 
		CASE 
		WHEN @DataType IN ('char', 'nchar', 'varchar', 'nvarchar', 'text', 'ntext')
			THEN '''' + RTRIM(LEFT(@StringMask, @RandomStringLen)) + ''''
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
				' SET ' + @ColumnName + ' = ''' + RIGHT(CONCAT(RTRIM(LEFT(@StringMask, @RandomStringLen)), RTRIM(@EmailMask)),@CharacterMaxLength) + ''';';
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
		DECLARE @sqlmaxrowscommand NVARCHAR(500) = N'SELECT @NumberOfRows = COUNT(*) FROM ' + @SchemaName + '.' + @TableName + ';' 
		DECLARE @MaxRows BIGINT 
		EXECUTE sp_executesql @sqlmaxrowscommand, N'@NumberOfRows INT OUTPUT', @NumberOfRows = @MaxRows OUTPUT;
		DECLARE @sqlidcolcommand NVARCHAR(500) = 
			N'SELECT @IDCol = c.[name] 
			FROM sys.columns AS c
			JOIN SYS.objects AS o on o.[object_id] = c.[object_id]
			WHERE SCHEMA_NAME(o.[schema_id]) = ''' + @SchemaName + ''' AND o.[name] = ''' + @TableName + ''' AND is_identity = 1 ;';
		DECLARE @IDColName VARCHAR(128)			
		EXECUTE sp_executesql @sqlidcolcommand, N'@IDCol VARCHAR(128) OUTPUT', @IDCol = @IDColName OUTPUT;
		
		SET @sql = 
			'DROP TABLE IF EXISTS #Numbers;
			DECLARE @MaxRows BIGINT = (SELECT COUNT(*) FROM ' + @SchemaName + '.' + @TableName + ');
			
			CREATE TABLE #Numbers (Number INT);
			WITH Numbers     
			AS     
			(      
				SELECT 1 AS Number
				UNION ALL
				SELECT Number + 1       
				FROM numbers       
				WHERE number < @MaxRows      
			)
			INSERT INTO #Numbers (Number)
			SELECT Number FROM Numbers
			OPTION (maxrecursion ' + CAST(@MaxRows AS VARCHAR(20)) + ');
			WITH
			MaskedCardNumbers AS
			(
				SELECT	Number,
						RIGHT(REPLICATE(''x'',16) + CAST(Number AS VARCHAR(16)), 16) AS MaskedCardNumber
				FROM	#Numbers AS n
			),
			ExistingCards AS 
			(
				SELECT ROW_NUMBER() OVER(ORDER BY ' + @IDColName + ') AS RowNo, ' + @IDColName + '
				FROM ' + @SchemaName + '.' + @TableName + '
			)
			UPDATE ' + @SchemaName + '.' + @TableName + '
				SET ' + @ColumnName + ' = CONCAT(SUBSTRING(MaskedCardNumber, 1, 4), ''-'',
												 SUBSTRING(MaskedCardNumber, 5, 4), ''-'',
												 SUBSTRING(MaskedCardNumber, 9, 4), ''-'',
												 SUBSTRING(MaskedCardNumber, 13, 4))
			FROM MaskedCardNumbers AS MaskedCards
			JOIN ExistingCards ON ExistingCards.RowNo = MaskedCards.Number
			JOIN ' + @SchemaName + '.' + @TableName + ' AS BaseTable
				ON BaseTable.' + @IDColName + ' = ExistingCards. ' + @IDColName + ' ;'
			
	END
	
	INSERT INTO DataMaskingScripts (SchemaName, TableName, ColumnName, UpdateScript)
		SELECT @SchemaName, @TableName, @ColumnName, @sql;
	
	FETCH NEXT FROM mask_cursor
	INTO @SchemaName, @TableName, @ColumnName, @InformationType

END 
CLOSE mask_cursor;
DEALLOCATE mask_cursor;


SELECT * FROM DataMaskingScripts;
