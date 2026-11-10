-- B1iF weights package (Hi-Tech Pretreads): the roll figures of every sellable
-- item that has either, in the shape manna_sap_weights takes. No database name.
--   wpr = U_WeightPerRoll (kg in a roll), bpr = U_BeltsPerRoll
SELECT I.ItemCode AS code, CAST(ISNULL(I.U_WeightPerRoll, 0) AS decimal(19, 3)) AS wpr, ISNULL(I.U_BeltsPerRoll, 0) AS bpr
FROM OITM I
WHERE I.SellItem = 'Y' AND (ISNULL(I.U_WeightPerRoll, 0) > 0 OR ISNULL(I.U_BeltsPerRoll, 0) > 0)
ORDER BY I.ItemCode;
