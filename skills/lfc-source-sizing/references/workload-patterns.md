# Workload patterns: which tables are busy, and when

The busy tables differ by workload and by time of day. OLTP keeps a few hot tables busy through the day, and a nightly batch (refresh, delete, maintenance) hits a different set. A CDC test should cover both an all-busy burst, where every table is written at once, and a shifting busy set, where a few hot tables are busy by day and a different set is busy during the batch.

The four TPC specifications below say what each workload writes and reads. Clause numbers are given so each claim can be checked. The "day" and "batch" labels are our framing: none of the specs defines a clock time for either.

## Sources and quote conventions

| Spec | Version | Text file checked |
|---|---|---|
| TPC-C | Revision 5.11 | tpc-c_v5.11.0.pdf |
| TPC-E | Revision 1.14.0 | tpc-e_v1.14.0.pdf |
| TPC-H | Revision 3.0.1 | tpc-h_v3.0.1.pdf |
| TPC-DS | Version 3.2.0 | tpc-ds_v3.2.0.pdf |

Quotes are copied from the PDF text conversion. Words the conversion split (for example "N ew -Ord er") are rejoined. Nothing else is changed.

---

## 1. TPC-C (Revision 5.11)

### Mix and tables

Clause 5.2.3, the minimum mix:

> "the terminal population must maintain a minimum percentage of mix for each transaction type as follows"

> "There is no minimum for the New-Order transaction as its measured rate is the reported throughput."

Clause 5.2.3, Comment 1:

> "The intent of the minimum percentage of mix for each transaction type is to execute approximately one Payment transaction for each New-Order transaction and approximately one Order-Status transaction, one Delivery transaction, and one Stock-Level transaction for every 10 New-Order transactions."

Clause 1.2.1 sets the schema size:

> "The components of the TPC-C database are defined to consist of nine separate and individual tables."

The nine tables are WAREHOUSE, DISTRICT, CUSTOMER, HISTORY, ORDER, NEW-ORDER, ORDER-LINE, STOCK and ITEM.

| Transaction | Share of the mix | Tables written (insert/update/delete) | Tables read only |
|---|---|---|---|
| New-Order | Rest of the mix. No minimum (clause 5.2.3 note). About 45% if the others sit at their minimum (derived: 100 - 43 - 4 - 4 - 4). | Insert: NEW-ORDER, ORDER, ORDER-LINE. Update: DISTRICT, STOCK. | WAREHOUSE, CUSTOMER, ITEM |
| Payment | Minimum 43.0% | Update: WAREHOUSE, DISTRICT, CUSTOMER. Insert: HISTORY. | none |
| Order-Status | Minimum 4.0% | none | CUSTOMER, ORDER, ORDER-LINE |
| Delivery (deferred) | Minimum 4.0% | Delete: NEW-ORDER. Update: ORDER, ORDER-LINE, CUSTOMER. | none |
| Stock-Level | Minimum 4.0% | none | DISTRICT, ORDER-LINE, STOCK |

ITEM is read by New-Order and written by no transaction.

Profile quotes (clause 2 sections):

- New-Order, clause 2.4.2.2: "A new row is inserted into both the NEW-ORDER table and the ORDER table to reflect the creation of the new order."
- New-Order, clause 2.4.2.2: "A new row is inserted into the ORDER-LINE table to reflect the item on the order."
- New-Order, clause 2.4.2.2: "S_QUANTITY, the quantity in stock, S_DIST_xx, where xx represents the district number, and S_DATA are retrieved." (STOCK is updated in the same bullet: "S_YTD is increased by OL_QUANTITY and S_ORDER_CNT is incremented by 1.")
- Payment, clause 2.5.2.2: "A new row is inserted into the HISTORY table with H_C_ID = C_ID, H_C_D_ID = C_D_ID, H_C_W_ID = C_W_ID, H_D_ID = D_ID, and H_W_ID = W_ID."
- Order-Status, clause 2.6.2.2: "All rows in the ORDER-LINE table with matching OL_W_ID (equals O_W_ID), OL_D_ID (equals O_D_ID), and OL_O_ID (equals O_ID) are selected."
- Delivery, clause 2.7.2.1: "Unlike the other transactions in this benchmark, the Delivery transaction must be executed in deferred mode."
- Delivery, clause 2.7.4.1: "The deferred execution of the Delivery transaction delivers one outstanding order (average items-per-order = 10) for each one of the 10 districts of the selected warehouse using one or more (up to 10) database transactions."
- Delivery, clause 2.7.4.2: "The selected row in the NEW-ORDER table is deleted."
- Stock-Level, clause 2.8: "It represents a heavy read-only database transaction with a low frequency of execution, a relaxed response time requirement, and relaxed consistency requirements."

Busy by day / busy in batch: New-Order and Payment write DISTRICT, STOCK, WAREHOUSE, CUSTOMER, HISTORY, NEW-ORDER, ORDER and ORDER-LINE all day. Delivery is the only deferred, batch-like transaction. It touches NEW-ORDER, ORDER, ORDER-LINE and CUSTOMER and nothing else.

---

## 2. TPC-E (Revision 1.14.0)

### Mix

Clause 3.3, the transaction set:

> "Ten of the Transactions follow a specific mix to generate the desired workload while keeping the benchmark environment simple, repeatable and easy to execute. The eleventh Transaction is not part of the Transaction Mix, but is executed at fixed intervals."

Clause 6.3.1, the mix table (target percentages; the text lists the required range for each):

| Transaction | Target | Category | Writes? |
|---|---|---|---|
| Broker-Volume | 4.9% | Brokerage initiated | read-only |
| Customer-Position | 13% | Customer initiated | read-only |
| Market-Feed | 1% | Market triggered | read-write |
| Market-Watch | 18% | Customer initiated | read-only |
| Security-Detail | 14% | Customer initiated | read-only |
| Trade-Lookup | 8% | Brokerage/customer initiated | read-only |
| Trade-Order | 10.1% | Customer initiated | read-write |
| Trade-Result | 10% | Market triggered | read-write |
| Trade-Status | 19% | Customer initiated | read-only |
| Trade-Update | 2% | Brokerage/customer initiated | read-write |
| Total | 100% | | |

The Trade-Result note in clause 6.3.1 says: "There is one Trade-Result per Trade-Order completed by the MEE, but ~1% of Trade-Order Transactions rollback at time of initial processing."

Clause 6.3.1, Market-Feed note: "Each Market-Feed contains entries for 10 completed Trade-Results."

### Writes

Write sets come from the database footprint of each transaction (clauses 3.3.x.2). The asterisk means the action is conditional (footprint notation, clause 3.1.2, Comment 1).

| Transaction | Share | Written (verb) | Read only |
|---|---|---|---|
| Trade-Order (3.3.7.2) | 10.1% | Add: TRADE, TRADE_HISTORY, TRADE_REQUEST* (limit orders only) | ACCOUNT_PERMISSION, BROKER, CHARGE, COMMISSION_RATE, COMPANY, CUSTOMER, CUSTOMER_ACCOUNT, CUSTOMER_TAXRATE, HOLDING, HOLDING_SUMMARY, LAST_TRADE, SECURITY, TAXRATE, TRADE_TYPE |
| Trade-Result (3.3.8.2) | 10% | Modify: TRADE, BROKER, CUSTOMER_ACCOUNT (CA_BAL)*, HOLDING*, HOLDING_SUMMARY*. Add: CASH_TRANSACTION*, HOLDING*, HOLDING_HISTORY, HOLDING_SUMMARY*, SETTLEMENT, TRADE_HISTORY. Remove: HOLDING*, HOLDING_SUMMARY*. | COMMISSION_RATE, CUSTOMER, CUSTOMER_TAXRATE, SECURITY, TAXRATE, TRADE_TYPE |
| Market-Feed (3.3.3.2) | 1% | Modify: LAST_TRADE, TRADE*. Add: TRADE_HISTORY*. Remove: TRADE_REQUEST*. | none |
| Trade-Update (3.3.10.2) | 2% | Modify: TRADE (frame 1), SETTLEMENT (frame 2), CASH_TRANSACTION (frame 3). | SECURITY, TRADE_HISTORY, TRADE_TYPE |
| Data-Maintenance (3.3.11) | not in mix, once per minute | Alters one reference table per run, in rotation (list below) | none |
| Trade-Cleanup (3.3.12.2) | not in mix, once before a run | Modify: TRADE. Add: TRADE_HISTORY. Remove: TRADE_REQUEST. | TRADE (T_ID), TRADE_REQUEST (TR_T_ID), by reference |

The read-only transactions (Broker-Volume 3.3.1.2, Customer-Position, Market-Watch, Security-Detail, Trade-Lookup, Trade-Status) only read. Their read sets come from each footprint table. For Broker-Volume the footprint lists BROKER, TRADE_REQUEST, SECTOR, INDUSTRY, COMPANY and SECURITY.

Key quotes for the writes:

- Clause 3.3.7.2 (Trade-Order): "This Transaction includes a mixture of Add, Reference, and Return access methods."
- Clause 3.3.8.7 (Trade-Result, frame 5): "The database access methods used in Frame 5 are a mixture of Modifies, Adds and Removes."
- Clause 3.3.8, frame 6 (Trade-Result): "The database access methods used in Frame 6 are a mixture Adds and Modifies."
- Clause 3.3.10.3 (Trade-Update, frame 1): "The first Frame is responsible for retrieving information about the specified array of trade IDs and modifying some data from the TRADE table."
- Clause 3.3.10.4 (Trade-Update, frame 2): "...modifies the SETTLEMENT row for each trade returned."
- Clause 3.3.10.5 (Trade-Update, frame 3): "...modifies the related CASH_TRANSACTION row for each trade returned."
- Clause 3.3.3 (Market-Feed): "Each Market-Feed ticker consists of 20 entries... Ten of these entries are a result of trades submitted to the MEE by this brokerage house."

### Periodic and one-off writes

- Clause 6.3.3: "A single Data-Maintenance Transaction must be invoked every sixty seconds."
- Clause 3.3.11: "This Transaction runs once per minute."
- Clause 3.3.11: "Each time this Transaction is run the Driver alters the next table in the list. This means that each table in the list will only get altered once every twelve minutes."
- Clause 3.3.11 rotation list: ACCOUNT_PERMISSION, ADDRESS, COMPANY, CUSTOMER, CUSTOMER_TAXRATE, DAILY_MARKET, EXCHANGE, FINANCIAL, NEWS_ITEM, SECURITY, TAXRATE, WATCH_ITEM.
- Clause 3.3.11: "The intent of the Transaction is to alter data tables that would not otherwise be written to by the benchmark."
- Clause 6.3.4: "The special Trade-Cleanup Transaction is not part of the Transaction Mix."
- Clause 3.3 (summary): Trade-Cleanup "must be executed once before a Test Run if the database is not in its initially populated state".

Clause 2.1 sets the size: "The TPC-E database is defined to consist of 33 separate and individual tables."

Busy by day / busy in batch: By day, the mix writes TRADE, TRADE_HISTORY, TRADE_REQUEST, LAST_TRADE, BROKER, CUSTOMER_ACCOUNT, HOLDING, HOLDING_SUMMARY, HOLDING_HISTORY, CASH_TRANSACTION and SETTLEMENT. Market-Feed and Trade-Result arrive from the market side, so they follow trade volume. In the "batch" slot, Data-Maintenance writes one reference table per minute. Each of the 12 rotation tables is written once every 12 minutes, so only one reference table is busy at any moment.

---

## 3. TPC-H (Revision 3.0.1)

### Refresh functions

Clause 2.5.1, the refresh data set:

> "This set of rows represents 0.1% of the initial population of these two tables (see Table 4: LINEITEM Cardinality)."

Clause 2.6.2, RF1 (new sales):

> "LOOP (SF * 1500) TIMES / INSERT a new row into the ORDERS table / LOOP RANDOM(1, 7) TIMES / INSERT a new row into the LINEITEM table / END LOOP / END LOOP"

Clause 2.7.2, RF2 (old sales):

> "LOOP (SF * 1500) TIMES / DELETE FROM ORDERS WHERE O_ORDERKEY = [value] / DELETE FROM LINEITEM WHERE L_ORDERKEY = [value] / END LOOP"

| Function | Rows per execution | Tables | Operation |
|---|---|---|---|
| RF1 (2.6) | SF x 1500 orders, each with 1 to 7 lineitems (average 4, derived) | ORDERS, LINEITEM | Insert |
| RF2 (2.7) | SF x 1500 orders, plus their lineitems | ORDERS, LINEITEM | Delete |

SF x 1500 is 0.1% of the initial ORDERS population of SF x 1,500,000 (the schema figure gives ORDERS as SF*1,500,000 rows). RF1 and RF2 never touch the six dimension tables.

Clause 5.3.3.2, power test order:

> "1. The refresh function RF1 is executed by the refresh stream. 2. The full query set is executed once by the query stream. 3. The refresh function RF2 is executed by the refresh stream."

Clause 5.1.2.4, refresh stream:

> "A refresh stream is defined as the sequential execution of an integral number of pairs of refresh functions submitted from within a batch program."

### Queries (read-only)

The 22 queries (clause 2.4) are SELECT statements. Clause 2.4 gives the query text. The spec text does not say "read-only" for each query, so this is our reading of the FROM clauses.

Table use across the 22 queries, from the FROM clauses (subqueries included, so approximate):

| Table | Queries that read it | Table | Queries that read it |
|---|---|---|---|
| LINEITEM | 17 | PART | 9 |
| ORDERS | 12 | NATION | 9 |
| SUPPLIER | 10 | CUSTOMER | 8 |
| PARTSUPP | 5 | REGION | 3 |

Busy by day / busy in batch: The query streams read LINEITEM and ORDERS in most queries. The refresh stream writes only ORDERS and LINEITEM, once per pair. The six dimension tables are not written in any phase.

---

## 4. TPC-DS (Version 3.2.0)

### Maintenance functions

Clause 5.3.2, Table 5-4 (data maintenance function summary):

| ID | Function | Method | Target table |
|---|---|---|---|
| 1 | LF_CR (5.3.11.6) | 1 (insert) | catalog_returns |
| 2 | LF_CS (5.3.11.5) | 1 (insert) | catalog_sales |
| 3 | LF_I (5.3.11.7) | 1 (insert) | inventory |
| 4 | LF_SR (5.3.11.2) | 1 (insert) | store_returns |
| 5 | LF_SS (5.3.11.1) | 1 (insert) | store_sales |
| 6 | LF_WR (5.3.11.4) | 1 (insert) | web_returns |
| 7 | LF_WS (5.3.11.3) | 1 (insert) | web_sales |
| 8 | DF_CS (5.3.11.10) | 2 (delete) | catalog_sales [S], catalog_returns [R] |
| 9 | DF_SS (5.3.11.9) | 2 (delete) | store_sales [S], store_returns [R] |
| 10 | DF_WS (5.3.11.11) | 2 (delete) | web_sales [S], web_returns [R] |
| 11 | DF_I (5.3.11.12) | 3 (delete) | inventory [I] |

Method quotes:

- Clause 5.3.7 (Method 1, pseudo code): "for every row v in view V corresponding to sales fact table F / insert v into F;"
- Clause 5.3.8 (Method 2): "Delete rows from R with corresponding rows in S where d_date between Date1 and Date2 / Delete rows from S where d_date between Date1 and Date2"
- Clause 5.3.9 (Method 3): "Delete rows from I where d_date between Date1 and Date2"
- Clauses 5.3.4 to 5.3.6: "(intentionally left blank)". The spec has no dimension maintenance functions.

Clause 2.1 sets the schema: "The schema includes seven fact tables", and clause 2.1 adds "17 dimension tables that are associated with all sales channels."

### Refresh run and ETL

- Clause 1.5: "The TPC-DS data maintenance process starts from generated flat files that are assumed to be the output of this external Extraction process."
- Clause 1.5, Load: "This is the actual insertion, modification and deletion of data within the decision support database."
- Clause 5.1.1: "Data maintenance operations execute separately from queries. Refresh runs do not overlap; at most one refresh run is running at any time."
- Clause 5.1.3 (d): "All delete DM operations finish before any insert DM function begin."
- Clause 7.4.2 test sequence: a) Database Load Test, b) Power Test, c) Throughput Test 1, d) Data Maintenance Test 1, e) Throughput Test 2, f) Data Maintenance Test 2.
- Clause 7.4.8.2: "Data Maintenance Test 1 immediately follows Throughput Test 1 and Data Maintenance Test 2 immediately follows Throughput Test 2."
- Clause 7.4.8.3: "Each Data Maintenance Test shall execute Sq/2 refresh runs."

Busy by day / busy in batch: Query streams run all day in the Throughput Tests, and the spec writes no table during them. In each Data Maintenance Test, the seven fact tables are written: inserts into catalog_returns, catalog_sales, inventory, store_returns, store_sales, web_returns and web_sales, then deletes from the sales, returns and inventory tables. Dimensions are not written.

---

## Turning it into a test

For each model, the hot set in the day phase and the batch phase. The shares are of all tables in that schema.

### TPC-C (9 tables)

- Day phase (New-Order and Payment): New-Order and Payment touch 9 of 9 tables. Written: 8 of 9 (ITEM is read-only). Hot set: NEW-ORDER, ORDER, ORDER-LINE, DISTRICT, STOCK, WAREHOUSE, CUSTOMER, HISTORY.
- Batch phase (Delivery, deferred): NEW-ORDER, ORDER, ORDER-LINE, CUSTOMER. 4 of 9 tables (44%), all written.
- Overlap: NEW-ORDER, ORDER, ORDER-LINE and CUSTOMER are busy in both phases. WAREHOUSE, DISTRICT, STOCK and HISTORY go quiet at night. ITEM is never written.

### TPC-E (33 tables)

- Day phase (the mix): 11 tables written: TRADE, TRADE_HISTORY, TRADE_REQUEST, LAST_TRADE, BROKER, CUSTOMER_ACCOUNT, HOLDING, HOLDING_SUMMARY, HOLDING_HISTORY, CASH_TRANSACTION, SETTLEMENT. That is 11 of 33 (33%). Reads add CUSTOMER, WATCH_ITEM, WATCH_LIST, SECURITY, COMPANY, DAILY_MARKET and others.
- Batch phase (Data-Maintenance, once a minute): one table per minute, in a 12-table rotation: ACCOUNT_PERMISSION, ADDRESS, COMPANY, CUSTOMER, CUSTOMER_TAXRATE, DAILY_MARKET, EXCHANGE, FINANCIAL, NEWS_ITEM, SECURITY, TAXRATE, WATCH_ITEM. At any minute, 1 of 33 tables (3%) is busy. Each rotation table is busy once every 12 minutes.
- Once before a run: Trade-Cleanup writes TRADE, TRADE_HISTORY and TRADE_REQUEST. Not part of the mix.
- Overlap: CUSTOMER and SECURITY are read all day and written only by the rotation (CUSTOMER and SECURITY are in the rotation list; Trade-Status and Trade-Order read them).

### TPC-H (8 tables)

- Day phase (query streams): LINEITEM (17 of 22 queries) and ORDERS (12 of 22) are hot. Reads reach all 8 tables. Writes: none.
- Batch phase (refresh stream, RF1 then RF2 per pair): ORDERS and LINEITEM only. 2 of 8 tables (25%). Inserts and deletes both hit the same two tables.
- Quiet in both phases: PART, PARTSUPP, SUPPLIER, CUSTOMER, NATION, REGION are never written.

### TPC-DS (24 tables: 7 fact, 17 dimension)

- Day phase (query streams, Throughput Tests): reads across the 24 tables. Writes: none. Per-query table use is not mapped here.
- Batch phase (Data Maintenance Test 1 and 2): writes 7 of 24 tables (29%), all fact tables: catalog_returns, catalog_sales, inventory, store_returns, store_sales, web_returns, web_sales. Order inside a run: clause 5.1.3 (d) requires "All delete DM operations finish before any insert DM function begin." So the deletes come first, then the inserts.
- Dimensions (17 tables): written in no phase.

---

## Caveats and what was not found

- None of the four specs defines a day or a night. The "day" and "batch" labels are our mapping. The closest spec terms are TPC-C's "deferred mode" for Delivery, TPC-E's "time triggered" Data-Maintenance, and TPC-H's refresh stream "submitted from within a batch program".
- TPC-E read sets come from footprint tables in the PDF text conversion. The column layout was parsed by hand and may be off by a column in places. Check a specific transaction against its PDF page before relying on one read.
- TPC-H query table counts come from a text pass over the FROM clauses, subqueries included. They are approximate.
- TPC-DS: the 99 query templates were not read one by one, so per-query table use is not mapped. The day phase reads "across the schema" only.
- The TPC-C New-Order share (about 45%) is derived by subtraction. The spec gives no minimum for it.
- The TPC-C Appendix C example mix (44.5 / 43.1 / 4.1 / 4.2 / 4.1) is an illustrative example in the spec, not a requirement. The spec gives no measured result for us to compare against.
- No measured numbers from our runs appear in this file.
