-- B1iF item package (Manna Treads): one row per sellable item, in the shape
-- manna_sap_items takes. No database name: B1iF runs it on the sender's own
-- connection, so the same text serves TEST and LIVE.
-- @code = '' sends every item (the nightly run); an ItemCode sends one (the event).
-- Every sellable item goes; ERPNext decides which are shared codes, so the rule
-- lives in one place (manna_sap_items, SHARED_PREFIXES).
--   active = not inactive and not frozen
--   hsn    = SAP's chapter code (OCHP.ChapterID, e.g. 40.0829.40); ERPNext drops the dots
DECLARE @code nvarchar(50) = N'';

SELECT
	I.ItemCode AS code,
	I.ItemName AS name,
	CASE WHEN I.validFor = 'N' OR I.frozenFor = 'Y' THEN 'N' ELSE 'Y' END AS active,
	LTRIM(RTRIM(ISNULL(I.InvntryUom, ''))) AS uom,
	ISNULL(C.ChapterID, '') AS hsn
FROM OITM I
LEFT JOIN OCHP C ON C.AbsEntry = I.ChapterID
WHERE I.SellItem = 'Y' AND (@code = N'' OR I.ItemCode = @code)
ORDER BY I.ItemCode;
