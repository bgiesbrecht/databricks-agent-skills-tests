# jq -f mysql-normalize.jq: the MySQL collector's raw output -> the common stats format (the Postgres collector's)
.tables |= (map(
  . as $t
  | {name, row_count, size_bytes, comment, avg_row_bytes,
     primary_key: ([.keys[]? | select(.type == "PRIMARY KEY") | .cols | sort_by(.[0]) | map(.[1])] | first),
     unique: ([.keys[]? | select(.type == "UNIQUE") | .cols | sort_by(.[0]) | map(.[1])] | if length > 0 then . else null end),
     foreign_keys: ([.keys[]? | select(.type == "FOREIGN KEY") | .cols | sort_by(.[0])
                     | {columns: map(.[1]), ref_table: .[0][2], ref_columns: map(.[3])}] | if length > 0 then . else null end),
     checks, indexes: ([.indexes[]? | sort_by(.[0]) | map(.[1])] | if length > 0 then . else null end),
     columns: (.columns | sort_by(.pos) | map(
       . as $c
       | {name, data_type, nullable, null_fraction, n_distinct, min_value, max_value, histogram_buckets,
          most_common_values: (if .mcv_raw then (.mcv_raw | sort_by(-.f) | map({value: (if $c.keep_values == 1 or $c.keep_values == true then .v else null end), frequency: .f})) else null end),
          histogram_bounds: (if .bounds_raw then (.bounds_raw | sort_by(.[0]) | (map(.[1]) + [last[2]])) else null end)}
       | with_entries(select(.value != null))))}
  | with_entries(select(.value != null))) | sort_by(.name))
