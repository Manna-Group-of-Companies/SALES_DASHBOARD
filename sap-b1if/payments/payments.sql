-- B1iF payments package (Manna Treads): every incoming payment from a customer
-- posted in the current financial year (from 1 April), cancelled ones included
-- so ERPNext can mark them, in the shape manna_sap_payments takes. No database name.
--   amount     = the payment's total (ORCT.DocTotal)
--   on_account = the part not set against any invoice (ORCT.NoDocSum)
--   mode       = how it was paid, by which of SAP's four sums is filled
--   reference  = transfer reference, else the counter reference
--   invoices   = what it paid: "INV 1234: 5000.00, INV 1240: 2000.00" (CN = credit note)
SELECT
	P.DocEntry AS entry,
	P.DocNum AS num,
	P.CardCode AS code,
	CONVERT(char(10), P.DocDate, 23) AS [date],
	CAST(P.DocTotal AS decimal(19, 2)) AS amount,
	CAST(ISNULL(P.NoDocSum, 0) AS decimal(19, 2)) AS on_account,
	CASE WHEN P.Canceled = 'Y' THEN 'Y' ELSE 'N' END AS cancelled,
	LTRIM(CASE WHEN P.TrsfrSum > 0 THEN ' Bank Transfer' ELSE '' END + CASE WHEN P.CheckSum > 0 THEN ' Cheque' ELSE '' END
		+ CASE WHEN P.CashSum > 0 THEN ' Cash' ELSE '' END + CASE WHEN P.CreditSum > 0 THEN ' Card' ELSE '' END) AS mode,
	COALESCE(NULLIF(LTRIM(RTRIM(P.TrsfrRef)), ''), NULLIF(LTRIM(RTRIM(P.CounterRef)), ''), '') AS reference,
	LEFT(ISNULL(P.Comments, ''), 140) AS remarks,
	ISNULL(STUFF((
		SELECT ', ' + CASE L.InvType WHEN 13 THEN 'INV ' WHEN 14 THEN 'CN ' WHEN 203 THEN 'DP ' ELSE 'DOC ' END
			+ CAST(COALESCE(I.DocNum, C.DocNum, L.DocEntry) AS varchar(12)) + ': ' + CAST(CAST(L.SumApplied AS decimal(19, 2)) AS varchar(24))
		FROM RCT2 L
		LEFT JOIN OINV I ON L.InvType = 13 AND I.DocEntry = L.DocEntry
		LEFT JOIN ORIN C ON L.InvType = 14 AND C.DocEntry = L.DocEntry
		WHERE L.DocNum = P.DocEntry
		ORDER BY L.InvoiceId
		FOR XML PATH('')), 1, 2, ''), '') AS invoices
FROM ORCT P
WHERE P.DocType = 'C'
	AND P.DocDate >= DATEFROMPARTS(YEAR(GETDATE()) - CASE WHEN MONTH(GETDATE()) < 4 THEN 1 ELSE 0 END, 4, 1)
ORDER BY P.DocEntry;
