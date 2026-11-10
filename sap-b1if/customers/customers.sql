-- B1iF customer package (Manna Treads): one row per customer, in the shape
-- manna_sap_customers takes. No database name: B1iF runs it on the sender's own
-- connection, so the same text serves TEST and LIVE.
-- @code = '' sends every customer (the nightly run); a CardCode sends one (the event).
-- Fields follow sap-credit-sync exactly, so the two agree while both run:
--   phone   = Cellular, else Phone1
--   address = the default bill-to, else any bill-to, else any address:
--             "Street, Block, City, State, ZipCode, Country" (State as SAP's code)
--   state   = that address's state, by name
--   gstin   = the first GSTIN on a bill-to, else on any address
DECLARE @code nvarchar(15) = N'';

WITH A AS (
	SELECT A.CardCode, A.Address, A.AdresType, A.Street, A.Block, A.City, A.State, A.ZipCode, A.Country, A.GSTRegnNo,
		ROW_NUMBER() OVER (PARTITION BY A.CardCode ORDER BY
			CASE WHEN A.AdresType = 'B' AND A.Address = C.BillToDef THEN 0 WHEN A.AdresType = 'B' THEN 1 ELSE 2 END, A.LineNum) AS Pick,
		ROW_NUMBER() OVER (PARTITION BY A.CardCode ORDER BY
			CASE WHEN ISNULL(A.GSTRegnNo, '') = '' THEN 2 WHEN A.AdresType = 'B' THEN 0 ELSE 1 END, A.LineNum) AS GstPick
	FROM CRD1 A JOIN OCRD C ON C.CardCode = A.CardCode
)
SELECT
	C.CardCode AS code,
	C.CardName AS name,
	CASE WHEN C.validFor = 'N' OR C.frozenFor = 'Y' THEN 'N' ELSE 'Y' END AS active,
	ISNULL(S.SlpName, '') AS sales_employee,
	COALESCE(NULLIF(LTRIM(RTRIM(C.Cellular)), ''), LTRIM(RTRIM(ISNULL(C.Phone1, '')))) AS phone,
	ISNULL(STUFF(
		ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.Street)), ''), '') + ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.Block)), ''), '') +
		ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.City)), ''), '') + ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.State)), ''), '') +
		ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.ZipCode)), ''), '') + ISNULL(', ' + NULLIF(LTRIM(RTRIM(B.Country)), ''), ''), 1, 2, ''), '') AS address,
	COALESCE(ST.Name, B.State, '') AS state,
	ISNULL(G.GSTRegnNo, '') AS gstin
FROM OCRD C
LEFT JOIN OSLP S ON S.SlpCode = C.SlpCode AND C.SlpCode <> -1
LEFT JOIN A B ON B.CardCode = C.CardCode AND B.Pick = 1
LEFT JOIN OCST ST ON ST.Code = B.State AND ST.Country = B.Country
LEFT JOIN A G ON G.CardCode = C.CardCode AND G.GstPick = 1 AND ISNULL(G.GSTRegnNo, '') <> ''
WHERE C.CardType = 'C' AND (@code = N'' OR C.CardCode = @code)
ORDER BY C.CardCode;
