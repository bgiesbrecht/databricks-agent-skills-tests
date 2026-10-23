-- name: customer_orders
-- cluster_by: tier
-- comment: Each customer with the count and total of their orders, for readers that filter by tier
SELECT c.id AS customer_id, c.name, c.tier, COUNT(o.id) AS orders, CAST(COALESCE(SUM(o.amount), 0) AS DECIMAL(12,2)) AS amount
  FROM customers c LEFT JOIN orders o ON o.customer_id = c.id GROUP BY c.id, c.name, c.tier
