-- B1iF stock package (Hi-Tech Pretreads): Hi-Tech's whole saleable stock, one
-- row per item, in the shape manna_sap_stock takes. No database name: B1iF runs
-- it on the sender's own connection, so the same text serves TEST and LIVE.
-- qty = available to promise: on hand less what open sales orders have
-- committed, in ONE warehouse: 01 STORE, the one the order flow puts every
-- Hi-Tech order line on (@MANNA_IC SO_WHS in Hi-Tech, line_warehouse in the
-- order sync). The rule (the user's, 11 Nov 2026): the stock a rep is shown is
-- the stock the order will be picked from, so the two name the same warehouse,
-- and it is 01 on TEST and on live. Change one and the other must follow.
-- Why it matters: the order flow named 07 from 18 Sep 2026 because the TEST
-- stock had been seeded there, but 07 is "STORE 1 (Aged Stock)" - on the 8 Nov
-- 2026 copy of live Hi-Tech it holds 2,700 kg in 39 sales items against
-- 223,529 kg in 1,122 in 01, where production receives.
-- Every item with a row
-- in that warehouse is sent, zeros included: ERPNext treats the batch as the
-- whole shelf and sets anything missing to 0.
DECLARE @whs nvarchar(8) = N'01';

SELECT W.ItemCode AS code, CAST(W.OnHand - W.IsCommited AS decimal(19, 3)) AS qty
FROM OITW W
JOIN OITM I ON I.ItemCode = W.ItemCode
WHERE W.WhsCode = @whs AND I.SellItem = 'Y' AND I.InvntItem = 'Y'
ORDER BY W.ItemCode;
