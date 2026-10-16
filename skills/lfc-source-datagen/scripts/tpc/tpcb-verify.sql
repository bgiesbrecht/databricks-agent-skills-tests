-- tpcb-verify.sql: TPC-B scaling (clause 4.2) and relationships, checked on the data; every "bad" should be 0.
SELECT 'rows branch teller account history', (SELECT COUNT(*) FROM branch), (SELECT COUNT(*) FROM teller), (SELECT COUNT(*) FROM account), (SELECT COUNT(*) FROM history);
SELECT 'bad: tellers per branch <> 10', COUNT(*) FROM (SELECT t_b_id FROM teller GROUP BY t_b_id HAVING COUNT(*) <> 10) x;
SELECT 'bad: accounts per branch <> 100000', COUNT(*) FROM (SELECT a_b_id FROM account GROUP BY a_b_id HAVING COUNT(*) <> 100000) x;
SELECT 'bad: history branch is not its teller''s', COUNT(*) FROM history h JOIN teller t ON t.t_id = h.h_t_id WHERE t.t_b_id <> h.h_b_id;
