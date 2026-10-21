-- name: customer_orders
-- cluster_by: tier
-- comment: Each source's customers with the count and total of their orders, for readers that filter by tier (sources merged, keyed by _source)
SELECT c._source, c.id AS customer_id, c.name, c.tier, COUNT(o.id) AS orders, CAST(COALESCE(SUM(o.amount), 0) AS DECIMAL(12,2)) AS amount
  FROM customers c LEFT JOIN orders o ON o._source = c._source AND o.customer_id = c.id GROUP BY c._source, c.id, c.name, c.tier
