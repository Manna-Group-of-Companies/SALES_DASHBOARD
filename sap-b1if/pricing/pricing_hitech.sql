-- B1iF pricing package, Hi-Tech side: every sales item with what a "twin" needs
-- (the same code in Manna Treads), as one result set shaped like the Manna one.
--   D  the company database            c01 name
--   L  price list 1                    c01 no, c02 name
--   H  sales items                     c01 code, c02 name, c03 valid, c04 frozen, c05 sales item, c06 updated,
--        c07 on hand, c08 U_BeltsPerRoll ('' = none), c09 U_WeightPerRoll ('' = none), c10 list-1 price ('' = no row), c11 currency
SELECT 'D' AS k, CAST(DB_NAME() AS nvarchar(254)) AS c01, CAST('' AS nvarchar(254)) AS c02, CAST('' AS nvarchar(254)) AS c03, CAST('' AS nvarchar(254)) AS c04,
	CAST('' AS nvarchar(254)) AS c05, CAST('' AS nvarchar(254)) AS c06, CAST('' AS nvarchar(254)) AS c07, CAST('' AS nvarchar(254)) AS c08, CAST('' AS nvarchar(254)) AS c09,
	CAST('' AS nvarchar(254)) AS c10, CAST('' AS nvarchar(254)) AS c11
UNION ALL SELECT 'L', CAST(ListNum AS nvarchar(20)), ISNULL(ListName, ''), '', '', '', '', '', '', '', '', '' FROM OPLN WHERE ListNum = 1
UNION ALL SELECT 'H', I.ItemCode, ISNULL(I.ItemName, ''), ISNULL(I.validFor, ''), ISNULL(I.frozenFor, ''), ISNULL(I.SellItem, ''), ISNULL(CONVERT(char(10), I.UpdateDate, 23), ''),
	CAST(CAST(ISNULL(I.OnHand, 0) AS decimal(19, 6)) AS nvarchar(40)), ISNULL(CAST(I.U_BeltsPerRoll AS nvarchar(20)), ''), ISNULL(CAST(CAST(I.U_WeightPerRoll AS decimal(19, 6)) AS nvarchar(40)), ''),
	ISNULL(CAST(CAST(R.Price AS decimal(19, 6)) AS nvarchar(40)), ''), ISNULL(R.Currency, '')
	FROM OITM I LEFT JOIN ITM1 R ON R.ItemCode = I.ItemCode AND R.PriceList = 1
	WHERE I.SellItem = 'Y'
