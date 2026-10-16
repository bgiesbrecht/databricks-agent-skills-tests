-- one strict-mode INSERT per column, for n at the boundaries (id = column position * 10 + row number)
SELECT CONCAT('INSERT INTO `', db, '`.`', tbl, '` (id, `', col, '`) SELECT ', pos, ' * 10 + x.k, ', COALESCE(expr0, 'NULL'),
              ' FROM (VALUES ROW(1, 1), ROW(2, 2), ROW(1000003, 3), ROW(1000000000039, 4), ROW(4611686018427387904, 5), ROW(9223372036854775806, 6)) x(n, k);')
FROM lfc_cols WHERE NOT is_pk ORDER BY pos;
