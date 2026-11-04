-- Paste into SSMS on the SAP server. Read-only: three SELECTs, as B1if's SQL atoms will run them.
-- Built by tests/Test-B1ifXsl.ps1's transforms from Manna Treads SO 557 (DocEntry 6896) and PO 237 (DocEntry 2019).
-- Each should return rows and no error. Step 2's Hi-Tech query lists one item, PMB00101002.
-- PO 237 was made by the script, not B1if, so step 2a's MtSo and MtSoNum come back empty for it.

USE [TEST_MANNA_TREADS];
-- Step 1: the sales order, its lines, the settings, the supplier

SELECT
	T0.DocEntry, T0.DocNum, T0.CANCELED AS Cancelled, T0.DocStatus, T0.DiscPrcnt AS HeaderDisc,
	CONVERT(char(10), T0.DocDate, 23) AS DocDate,
	CONVERT(char(10), CASE WHEN T0.DocDueDate < CAST(GETDATE() AS date) THEN CAST(GETDATE() AS date) ELSE T0.DocDueDate END, 23) AS DueDate,
	ISNULL(T0.NumAtCard, '') AS NumAtCard, LEFT(ISNULL(CAST(T0.Comments AS nvarchar(254)), ''), 254) AS Remarks,
	T1.LineNum, ISNULL(T1.ItemCode, '') AS ItemCode, T1.Quantity, T1.PriceAfVAT, T1.VatPrcnt, T1.DiscPrcnt AS LineDisc,
	ISNULL(I.InvntItem, '') AS InvntItem, ISNULL(I.PrchseItem, '') AS PrchseItem, ISNULL(I.frozenFor, '') AS ItemFrozen,
	S.Enabled, S.StartDate, S.Margin, S.Vendor, S.PoSeries, S.PoBranch, S.PoWhs, S.PoLocation,
	S.HomeState, S.TaxInState, S.TaxOutState, S.ErpPrefix,
	ISNULL(V.CardType, '') AS VendorType, ISNULL(V.frozenFor, '') AS VendorFrozen, ISNULL(V.State1, '') AS VendorState,
	(SELECT COUNT(*) FROM OPOR P WHERE P.U_MannaMtSo = CAST(T0.DocEntry AS nvarchar(11)) AND P.CANCELED = 'N') AS PoCount,
	(SELECT MIN(P.DocNum) FROM OPOR P WHERE P.U_MannaMtSo = CAST(T0.DocEntry AS nvarchar(11)) AND P.CANCELED = 'N') AS PoDocNum
FROM ORDR T0
JOIN RDR1 T1 ON T1.DocEntry = T0.DocEntry
LEFT JOIN OITM I ON I.ItemCode = T1.ItemCode
CROSS JOIN (
	SELECT
		MAX(CASE WHEN Code = 'ENABLED'       THEN U_Value END) AS Enabled,
		MAX(CASE WHEN Code = 'START_DATE'    THEN U_Value END) AS StartDate,
		MAX(CASE WHEN Code = 'MARGIN'        THEN U_Value END) AS Margin,
		MAX(CASE WHEN Code = 'VENDOR'        THEN U_Value END) AS Vendor,
		MAX(CASE WHEN Code = 'PO_SERIES'     THEN U_Value END) AS PoSeries,
		MAX(CASE WHEN Code = 'PO_BRANCH'     THEN U_Value END) AS PoBranch,
		MAX(CASE WHEN Code = 'PO_WHS'        THEN U_Value END) AS PoWhs,
		MAX(CASE WHEN Code = 'PO_LOCATION'   THEN U_Value END) AS PoLocation,
		MAX(CASE WHEN Code = 'HOME_STATE'    THEN U_Value END) AS HomeState,
		MAX(CASE WHEN Code = 'TAX_IN_STATE'  THEN U_Value END) AS TaxInState,
		MAX(CASE WHEN Code = 'TAX_OUT_STATE' THEN U_Value END) AS TaxOutState,
		MAX(CASE WHEN Code = 'ERP_PREFIX'    THEN U_Value END) AS ErpPrefix
	FROM [@MANNA_IC]
) S
LEFT JOIN OCRD V ON V.CardCode = S.Vendor
WHERE T0.DocEntry = 6896
ORDER BY T1.LineNum
;

-- Step 2a: the purchase order, read from Manna Treads

SELECT
	P.DocEntry, P.DocNum, P.CANCELED AS Cancelled, P.CardCode, P.DiscPrcnt AS HeaderDisc,
	ISNULL(P.NumAtCard, '') AS NumAtCard, ISNULL(P.U_MannaMtSo, '') AS MtSo,
	CONVERT(char(10), CASE WHEN P.DocDueDate < CAST(GETDATE() AS date) THEN CAST(GETDATE() AS date) ELSE P.DocDueDate END, 23) AS DueDate,
	L.LineNum, ISNULL(L.ItemCode, '') AS ItemCode, L.Quantity, L.Price,
	ISNULL(SP.SlpName, '') AS SlpName, ISNULL(CAST(SO.DocNum AS nvarchar(20)), '') AS MtSoNum,
	(SELECT MAX(U_Value) FROM [@MANNA_IC] WHERE Code = 'VENDOR') AS Vendor
FROM OPOR P
JOIN POR1 L ON L.DocEntry = P.DocEntry
LEFT JOIN ORDR SO ON CAST(SO.DocEntry AS nvarchar(11)) = P.U_MannaMtSo
LEFT JOIN OSLP SP ON SP.SlpCode = SO.SlpCode AND SO.SlpCode > 0
WHERE P.DocEntry = 2019
ORDER BY L.LineNum
;

USE [TEST_HITECH_PRETREADS];
-- Step 2b: Hi-Tech's settings, customer, items

SELECT
	X.ItemCode,
	ISNULL(I.SellItem, '') AS SellItem, ISNULL(I.InvntItem, '') AS InvntItem, ISNULL(I.frozenFor, '') AS ItemFrozen,
	S.Enabled, S.Customer, S.SoSeries, S.SoWhs, S.HomeState, S.TaxInState, S.TaxOutState,
	ISNULL(C.CardType, '') AS CustomerType, ISNULL(C.frozenFor, '') AS CustomerFrozen, ISNULL(C.State1, '') AS CustomerState,
	(SELECT COUNT(*) FROM ORDR O WHERE O.U_MannaMtPo = N'2019' AND O.CANCELED = 'N') AS SoCount,
	(SELECT MIN(O.DocNum) FROM ORDR O WHERE O.U_MannaMtPo = N'2019' AND O.CANCELED = 'N') AS SoDocNum,
	(SELECT MIN(SlpCode) FROM OSLP WHERE SlpName = N'x' AND SlpName <> '') AS SlpCode
FROM (VALUES (N'PMB00101002')) X(ItemCode)
CROSS JOIN (
	SELECT
		MAX(CASE WHEN Code = 'ENABLED'       THEN U_Value END) AS Enabled,
		MAX(CASE WHEN Code = 'CUSTOMER'      THEN U_Value END) AS Customer,
		MAX(CASE WHEN Code = 'SO_SERIES'     THEN U_Value END) AS SoSeries,
		MAX(CASE WHEN Code = 'SO_WHS'        THEN U_Value END) AS SoWhs,
		MAX(CASE WHEN Code = 'HOME_STATE'    THEN U_Value END) AS HomeState,
		MAX(CASE WHEN Code = 'TAX_IN_STATE'  THEN U_Value END) AS TaxInState,
		MAX(CASE WHEN Code = 'TAX_OUT_STATE' THEN U_Value END) AS TaxOutState
	FROM [@MANNA_IC]
) S
LEFT JOIN OCRD C ON C.CardCode = S.Customer
LEFT JOIN OITM I ON I.ItemCode = X.ItemCode
;
