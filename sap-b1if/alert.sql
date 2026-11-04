-- What B1if has not followed. Two queries for SAP alerts (Administration -> Alerts Management), or for SSMS.
--
-- B1if writes nothing back when it decides not to make a document - the reason is only in its message log -
-- so these are how somebody notices. Each lists orders from START_DATE on that have been open more than
-- 30 minutes without the next document. Read-only.

-- 1. In Manna Treads: sales orders from ERPNext with no purchase order to Hi-Tech. Orders keyed in SAP are
--    not B1if's (user, 4 Nov 2026), so they are left out the way step 1 leaves them out.
SELECT T0.DocEntry, T0.DocNum, T0.DocDate, T0.CardCode, T0.NumAtCard, T0.CreateDate, T0.CreateTS
FROM ORDR T0
WHERE T0.CANCELED = 'N'
	AND T0.NumAtCard LIKE (SELECT MAX(U_Value) FROM [@MANNA_IC] WHERE Code = 'ERP_PREFIX') + '%'
	AND CAST(T0.Comments AS nvarchar(254)) LIKE 'From ERPNext ' + T0.NumAtCard + '%'
	AND T0.DocDate >= (SELECT CAST(MAX(U_Value) AS date) FROM [@MANNA_IC] WHERE Code = 'START_DATE')
	AND NOT EXISTS (SELECT 1 FROM OPOR P WHERE P.U_MannaMtSo = CAST(T0.DocEntry AS nvarchar(11)) AND P.CANCELED = 'N')
	AND DATEADD(minute, 30, DATEADD(second, (T0.CreateTS / 10000) * 3600 + ((T0.CreateTS / 100) % 100) * 60 + T0.CreateTS % 100, CAST(T0.CreateDate AS datetime))) < GETDATE()
ORDER BY T0.DocEntry;

-- 2. In Manna Treads: purchase orders B1if made that have no Hi-Tech sales order. Reads Hi-Tech's database by
--    name - HITECH_PRETREADS_LIVE on live, TEST_HITECH_PRETREADS on the test copy; change it to match.
SELECT P.DocEntry, P.DocNum, P.DocDate, P.NumAtCard, P.U_MannaMtSo
FROM OPOR P
WHERE P.CANCELED = 'N'
	AND ISNULL(P.U_MannaMtSo, '') <> ''
	AND NOT EXISTS (SELECT 1 FROM [HITECH_PRETREADS_LIVE].dbo.ORDR O WHERE O.U_MannaMtPo = CAST(P.DocEntry AS nvarchar(11)) AND O.CANCELED = 'N')
	AND DATEADD(minute, 30, DATEADD(second, (P.CreateTS / 10000) * 3600 + ((P.CreateTS / 100) % 100) * 60 + P.CreateTS % 100, CAST(P.CreateDate AS datetime))) < GETDATE()
ORDER BY P.DocEntry;
