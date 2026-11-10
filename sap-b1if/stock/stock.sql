-- B1iF stock package (Hi-Tech Pretreads): Hi-Tech's whole saleable stock, one
-- row per item, in the shape manna_sap_stock takes. No database name: B1iF runs
-- it on the sender's own connection, so the same text serves TEST and LIVE.
-- qty = available to promise: on hand less what open sales orders have
-- committed, in the sales warehouse only (01 STORE - 07 Aged and 10 Seconds are
-- not offered to the reps). Every item with a row in that warehouse is sent,
-- zeros included: ERPNext treats the batch as the whole shelf and sets anything
-- missing to 0.
DECLARE @whs nvarchar(8) = N'01';

SELECT W.ItemCode AS code, CAST(W.OnHand - W.IsCommited AS decimal(19, 3)) AS qty
FROM OITW W
JOIN OITM I ON I.ItemCode = W.ItemCode
WHERE W.WhsCode = @whs AND I.SellItem = 'Y' AND I.InvntItem = 'Y'
ORDER BY W.ItemCode;
