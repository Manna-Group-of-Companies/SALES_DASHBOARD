-- B1iF status package, Manna Treads side: every line of every Manna sales
-- order made from ERPNext (NumAtCard = the ERPNext name), in the shape
-- manna_sap_status takes with source = manna. No database name.
--   stage = Dispatched  an uncancelled Manna A/R invoice covers the line, drawn
--                       from the order itself or from its delivery
--           ''          otherwise (including a cancelled order)
-- Orders still open, and any from the last @days days.
DECLARE @days int = 120;

SELECT
	H.NumAtCard AS [order],
	L.ItemCode AS item,
	CASE WHEN H.CANCELED = 'N' AND (D1.Hit = 1 OR D2.Hit = 1) THEN 'Dispatched' ELSE '' END AS stage
FROM ORDR H
JOIN RDR1 L ON L.DocEntry = H.DocEntry
OUTER APPLY (
	SELECT TOP 1 1 AS Hit FROM INV1 I JOIN OINV J ON J.DocEntry = I.DocEntry AND J.CANCELED = 'N'
	WHERE I.BaseType = 17 AND I.BaseEntry = H.DocEntry AND I.BaseLine = L.LineNum
) D1
OUTER APPLY (
	SELECT TOP 1 1 AS Hit FROM INV1 I JOIN OINV J ON J.DocEntry = I.DocEntry AND J.CANCELED = 'N'
	JOIN DLN1 N ON I.BaseType = 15 AND N.DocEntry = I.BaseEntry AND N.LineNum = I.BaseLine
	JOIN ODLN M ON M.DocEntry = N.DocEntry AND M.CANCELED = 'N'
	WHERE N.BaseType = 17 AND N.BaseEntry = H.DocEntry AND N.BaseLine = L.LineNum
) D2
WHERE H.NumAtCard LIKE N'SAL-ORD-%'
	AND (H.DocStatus = 'O' OR H.UpdateDate >= DATEADD(day, -@days, CAST(GETDATE() AS date)))
	AND ISNULL(L.ItemCode, '') <> ''
ORDER BY H.NumAtCard, L.LineNum;
