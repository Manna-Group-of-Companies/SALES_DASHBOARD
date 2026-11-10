-- B1iF status package, Hi-Tech side: every line of every Hi-Tech sales order
-- made for an ERPNext order (NumAtCard = the ERPNext name, SAL-ORD-...), in
-- the shape manna_sap_status takes with source = hitech. No database name.
-- Orders still open, and any from the last @days days, so a closed order's
-- last change still reaches ERPNext.
--   stage = Cancelled  the order is cancelled, or the line closed with nothing
--                      picked, delivered or invoiced (an item left off the pick list)
--           Picked     the line is on a pick list the store has CONFIRMED in SAP
--                      (OPKL.U_Confirmed = 'Y', 9 Nov 2026) and was not picked as 0
--                      - step 3's rule for what is sent - or has been delivered
--                      or invoiced. A list only released is still "In SAP".
--           In SAP     otherwise
DECLARE @days int = 120;

SELECT
	H.NumAtCard AS [order],
	L.ItemCode AS item,
	CASE
		WHEN H.CANCELED <> 'N' THEN 'Cancelled'
		WHEN L.DelivrdQty > 0 OR P.Picked = 1 OR V.Invoiced = 1 THEN 'Picked'
		WHEN L.LineStatus = 'C' THEN 'Cancelled'
		ELSE 'In SAP'
	END AS stage
FROM ORDR H
JOIN RDR1 L ON L.DocEntry = H.DocEntry
OUTER APPLY (
	SELECT TOP 1 1 AS Picked FROM PKL1 K JOIN OPKL Q ON Q.AbsEntry = K.AbsEntry
	WHERE K.BaseObject = 17 AND K.OrderEntry = H.DocEntry AND K.OrderLine = L.LineNum AND ISNULL(Q.U_Confirmed, 'N') = 'Y'
		AND (K.PickQtty > 0 OR (K.RelQtty > 0 AND NOT EXISTS (SELECT 1 FROM PKL1 Z WHERE Z.AbsEntry = K.AbsEntry AND Z.PickQtty > 0)))
) P
OUTER APPLY (
	SELECT TOP 1 1 AS Invoiced FROM INV1 I JOIN OINV J ON J.DocEntry = I.DocEntry AND J.CANCELED = 'N'
	WHERE I.BaseType = 17 AND I.BaseEntry = H.DocEntry AND I.BaseLine = L.LineNum
) V
WHERE H.NumAtCard LIKE N'SAL-ORD-%'
	AND (H.DocStatus = 'O' OR H.UpdateDate >= DATEADD(day, -@days, CAST(GETDATE() AS date)))
	AND ISNULL(L.ItemCode, '') <> ''
ORDER BY H.NumAtCard, L.LineNum;
