# How shape.py chooses each column

[`shape.py`](../scripts/shape.py) reads `schema.yaml` (and `stats.yaml`, if any) and writes the same schema with each table's target rows and each column's **lfc-source-datagen** tags in its comment: `lfc:v={integer formula in x.n}` (the column's usual cast of the formula), `lfc:e={SQL expression}` (the value as is: literal strings), `lfc:len={L}`, and in the table's `lfc_tags`: `lfc:rows=`, `lfc:n={n from a row}`, `lfc:by={column}`. Formulas are written in MySQL syntax; [`ddl.py`](../scripts/ddl.py) transpiles them for the target. Every decision it makes (a cut list, a capped table, a replaced rule) is printed to stderr.

## A column's value, first match wins

1. **Its generation rule** in `schema.yaml`:

   | Rule | Formula |
   |---|---|
   | `sequential` (min) | `min + n − 1` |
   | `cyclic` (min, max) | `min + (n − 1) mod span` |
   | `block` (min, block_size) | `min + (n − 1) DIV block_size`; a foreign-key column wraps at its parent column's range |
   | `block_cyclic` (min, block_size, cycle) | `min + ((n − 1) DIV block_size) mod cycle` |
   | `constant` | the value |
   | `uniform` (min, max) | `min + (n − 1) × p mod span` |
   | `zipf` (min, max or values; `a`) | the inverse CDF of a power law at a per-row uniform `u` |
   | `normal` (mean, std, min, max) | Box–Muller from two per-row uniforms, clamped |
   | value list (weights) | each value takes its weight's share of a permutation of the rows; text values as `lfc:e` |
   | `format_pattern` | `first_name`, `last_name`, `full_name`, `city`, `address`, `phone_us`, `phone_intl`, `postal_us`, `zip_code`, `email`, `url`, `upper_id`, `upper_alpha`, `zero_padded_int`, `word`, `sentence`, `tpcc_last_name` (TPC-C's syllables), cut to the column's length |

2. **Its statistics** in `stats.yaml`, at the new size:
   - **Null fraction**: the first share of a permutation of the rows (`(n − 1) × p mod rows`, `p` a large prime per column) is `NULL`: exact at any size.
   - **Most common values**: each takes its frequency's share of another permutation (up to 100 per column); numeric and date values are the real ones when the file has them, otherwise a stand-in per entry; when they are every value, their frequencies are renormalized to the whole column.
   - **The rest**: spread evenly over the remaining distinct values (`permutation × count DIV rows`, so each value occurs equally often), placed through the **histogram** bounds when there are any (quantile → between two bounds), else evenly between min and max, else as stand-ins.
   - **Distinct count**: at most the rows and the range; one at least 10% of the source's rows grows with the table, a smaller one stays.
   - **A foreign key**: spread over the parent's keys, with the source's share of parents that have children; hot parents first when it has most common values.

3. **Nothing known**: no tag; the planner fills it with its own scramble (or a foreign key with its probe of the parent's range).

## Keys

- **Rules that form a mixed radix** (every key column `sequential`, `cyclic`, `block`, or `block_cyclic`): `n − 1 = Σ (column − min) × stride`, so `lfc:n` reads `n` back from the key; the column with the largest stride is `lfc:by`. That's how TPC-C's warehouse → district → customer → order → order line keys work.
- **Otherwise a codec per key column**, an integer index to the column's values and back, which the children's foreign keys share so every child value is a parent key:

  | Column | Encode | Decode |
  |---|---|---|
  | integer | the index | the column |
  | text with a code list | the i-th code of the sorted list (wrapping) | `CASE` on the code |
  | text, digits fit (`10^L` > rows) | zero-padded digits (the planner's cast) | `CAST(col AS SIGNED)` |
  | short text, digits don't fit | base 36 (`CHAR(2)` holds 1,296) | position of each character |
  | date / timestamp | days / seconds since 1970 | `LFC_DAYS(col)` / `LFC_EPOCH(col)` (per engine, in `ddl.py`) |

  A composite key numbers its first two columns (`k1 = (n − 1) DIV f + 1`, `k2 = (n − 1) mod f + 1`, `f` from the statistics or the parent's rows, each kept within its parent); further key columns are constant.
- **A one-column key that is also a foreign key** (one child per parent) takes the parent's codec, and the table gets at most as many rows as the parent.
- **No primary key**: the table stays without one; a timestamp (one second per row from 2023-11-14) or else an integer column numbers the rows.
- **Text-key order:** the resume probe reads the highest key, so `n` must rise with the key's sort order: code lists are sorted, digits and base 36 sort as numbers in byte order.

## Foreign keys without a rule

The parent's key formula at a parent row `m`: `1 + permutation mod parent rows` (`fk_distribution: uniform`), or a zipf rank (`fk_distribution: zipf`). A column's own rule is replaced by the parent's key (and said so) unless it is a structural rule (`sequential`, `cyclic`, `block`, `block_cyclic`), which follows the parent by construction.

## Checks

[`compare.sql`](../scripts/compare.sql) (DuckDB) reads `expected.json` from `shape.py` and the collector's output on the copy, and prints only what's off: null fraction and top frequency beyond 0.02 (or 3 standard errors on a small table), distinct counts beyond 20%, a histogram median (of common values and histogram together) beyond 5% of the range (or `1/√rows`), and row counts beyond 10%.
