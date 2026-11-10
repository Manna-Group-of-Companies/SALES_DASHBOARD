-- B1iF invoices package (Manna Treads): the A/R invoices the SAP Invoice mirror
-- holds, in the shape manna_sap_invoices takes. No database name.
-- Every uncancelled invoice posted in the current financial year (from 1 April),
-- plus every one still open whatever its date. CANCELED = 'N' leaves out both a
-- cancelled invoice ('Y') and the cancellation document SAP makes for it ('C').
SELECT
	I.DocEntry AS entry, I.DocNum AS num, I.CardCode AS code,
	CONVERT(char(10), I.DocDate, 23) AS [date], CONVERT(char(10), I.DocDueDate, 23) AS due,
	CAST(I.DocTotal AS decimal(19, 6)) AS total, CAST(I.PaidToDate AS decimal(19, 6)) AS paid,
	I.DocStatus AS status
FROM OINV I
WHERE I.CANCELED = 'N'
	AND (I.DocStatus = 'O' OR I.DocDate >= DATEFROMPARTS(YEAR(GETDATE()) - CASE WHEN MONTH(GETDATE()) < 4 THEN 1 ELSE 0 END, 4, 1))
ORDER BY I.DocEntry;
