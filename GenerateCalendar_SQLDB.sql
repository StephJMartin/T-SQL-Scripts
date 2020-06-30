-- =============================================
-- Author:      Steph Middleton
-- Create date: 2017-04-20
-- Description: Default Stored Procedure to populate a Date Dimension in a star schema.  Extend as necessary to add extra required columns. 
--			 Suitable for use with on-premises SQL Server and SQLDB
-- =============================================

CREATE PROCEDURE [dim].[GenerateCalendar]
(
    @YearsToGenerate TINYINT
)
AS
BEGIN

DECLARE @startDate DATE = CASE	WHEN (SELECT MAX([Date]) FROM dim.DimDate) > '1901-01-01' 
								THEN (SELECT DATEADD(DAY,1,MAX([Date])) FROM dim.DimDate) 
								ELSE '2010-01-01' 
						  END;

IF (@YearsToGenerate IS NULL)
BEGIN
	SET @YearsToGenerate = 1
END;

WITH Numbers
AS
(
	SELECT	0 AS Number
			UNION
			SELECT ROW_NUMBER() OVER (order by s1.[object_id]) 
	FROM sys.objects s1
	CROSS JOIN sys.columns s2
)
, Dates 
AS
(
    SELECT	CONVERT(VARCHAR(8),DATEADD(day, Number,@startDate),112) as DateKey,
			DATEADD(day,number,@startDate) as [Date],
			DATEPART(MONTH,DATEADD(day,number,@startDate)) AS MonthNumber,
			DATENAME(MONTH,DATEADD(day,number,@startDate)) AS [MonthName],
			DATEPART(QUARTER,DATEADD(day,number,@startDate)) AS QuarterNumber,
			CAST(DATEPART(YEAR,DATEADD(day,number,@startDate)) AS CHAR(4)) + 'Q' + 
				CAST(DATEPART(QUARTER,DATEADD(day,number,@startDate)) AS CHAR(1)) AS QuarterName,
			DATEPART(YEAR,DATEADD(day,number,@startDate)) AS YearNumber,
			CAST(DATEPART(YEAR,DATEADD(day,number,@startDate)) AS CHAR(4)) AS YearName,
			CAST(DATEPART(YEAR,DATEADD(day,number,@startDate)) AS CHAR(4)) + 
				RIGHT('0' + RTRIM(MONTH(DATEADD(day,number,@startDate))) , 2) AS MonthYear,
			CONVERT(VARCHAR(20),DATEADD(day, Number,@startDate),126) AS DateString

    FROM Numbers AS n
)
INSERT INTO dim.DimDate
(
    DateKey,
    [Date],
    MonthNumber,
    [MonthName],
    QuarterNumber,
    QuarterName,
    YearNumber,
    YearName,
    MonthYear,
    DateString   
)
SELECT
	DateKey,
    [Date],
    MonthNumber,
    [MonthName],
    QuarterNumber,
    QuarterName,
    YearNumber,
    YearName,
    MonthYear,
    DateString
FROM Dates AS d
WHERE d.[Date] < DATEADD(YEAR,@YearsToGenerate,@startDate)

END

GO


