-- B1iF credit package (Manna Treads): one row per customer with SAP's own sums,
-- in the shape manna_sap_credit takes. No database name. The rules that decide
-- what ERPNext writes are in that script; this only adds up.
--   limit/balance = OCRD.CreditLine / OCRD.Balance (the account balance)
--   terms_code/terms = the payment terms group and its name (-1 = none set)
--   b1..b4 = open invoices LESS open credit notes (DocTotal - PaidToDate, anything
--            under half a paisa ignored), aged by POSTING date: <=30, 31-60, 61-90, 91+ days.
--            A credit note sits in the bucket of its own date.
--   od_amt/od_days = open amount on INVOICES past the customer's terms, and the
--            days the oldest of them is past them. Past the terms = older than
--            invoice date + the terms' days (14 Nov 2026, the user), NOT SAP's
--            DocDueDate: Net - 3, Net-7 and Net-20 carry 0 additional days in
--            OCTG, so their invoices fall due the day they are made. The days
--            are the number in the term's name ("Net-15" 15, "Net - 3" 3),
--            else OCTG's own months and days; Advance and Cash are 0. Due today
--            is not overdue.
SELECT
	C.CardCode AS code,
	CAST(ISNULL(C.CreditLine, 0) AS decimal(19, 6)) AS limit,
	CAST(ISNULL(C.Balance, 0) AS decimal(19, 6)) AS balance,
	ISNULL(C.GroupNum, -1) AS terms_code,
	ISNULL(T.PymntGroup, '') AS terms,
	CAST(ISNULL(A.b1, 0) AS decimal(19, 6)) AS b1, CAST(ISNULL(A.b2, 0) AS decimal(19, 6)) AS b2,
	CAST(ISNULL(A.b3, 0) AS decimal(19, 6)) AS b3, CAST(ISNULL(A.b4, 0) AS decimal(19, 6)) AS b4,
	CAST(ISNULL(A.od_amt, 0) AS decimal(19, 6)) AS od_amt, ISNULL(A.od_days, 0) AS od_days
FROM OCRD C
LEFT JOIN OCTG T ON T.GroupNum = ISNULL(C.GroupNum, -1)
LEFT JOIN (
	SELECT D.CardCode,
		SUM(CASE WHEN D.age <= 30 THEN D.sgn * D.opn ELSE 0 END) AS b1,
		SUM(CASE WHEN D.age BETWEEN 31 AND 60 THEN D.sgn * D.opn ELSE 0 END) AS b2,
		SUM(CASE WHEN D.age BETWEEN 61 AND 90 THEN D.sgn * D.opn ELSE 0 END) AS b3,
		SUM(CASE WHEN D.age >= 91 THEN D.sgn * D.opn ELSE 0 END) AS b4,
		SUM(CASE WHEN D.sgn = 1 AND D.opn > 0.005 AND D.due < CAST(GETDATE() AS date) THEN D.opn ELSE 0 END) AS od_amt,
		MAX(CASE WHEN D.sgn = 1 AND D.opn > 0.005 AND D.due < CAST(GETDATE() AS date) THEN DATEDIFF(day, D.due, CAST(GETDATE() AS date)) ELSE 0 END) AS od_days
	FROM (
		SELECT I.CardCode, 1 AS sgn, I.DocTotal - I.PaidToDate AS opn, DATEDIFF(day, I.DocDate, CAST(GETDATE() AS date)) AS age,
			DATEADD(day, ISNULL(P.days, 0), CAST(I.DocDate AS date)) AS due
		FROM OINV I
		LEFT JOIN (
			SELECT C2.CardCode,
				CASE WHEN PATINDEX('%[0-9]%', T2.PymntGroup) > 0
					THEN CAST(LEFT(SUBSTRING(T2.PymntGroup, PATINDEX('%[0-9]%', T2.PymntGroup), 4),
						PATINDEX('%[^0-9]%', SUBSTRING(T2.PymntGroup, PATINDEX('%[0-9]%', T2.PymntGroup), 4) + 'x') - 1) AS int)
					ELSE 30 * ISNULL(T2.ExtraMonth, 0) + ISNULL(T2.ExtraDays, 0) END AS days
			FROM OCRD C2 LEFT JOIN OCTG T2 ON T2.GroupNum = C2.GroupNum
		) P ON P.CardCode = I.CardCode
		WHERE I.DocStatus = 'O'
		UNION ALL
		SELECT CardCode, -1, DocTotal - PaidToDate, DATEDIFF(day, DocDate, CAST(GETDATE() AS date)), CAST(DocDueDate AS date)
		FROM ORIN WHERE DocStatus = 'O'
	) D
	WHERE ABS(D.opn) >= 0.005
	GROUP BY D.CardCode
) A ON A.CardCode = C.CardCode
WHERE C.CardType = 'C'
ORDER BY C.CardCode;
