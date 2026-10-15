# MongoDB

> **Lakeflow Connect support:** check the current [connector list](https://docs.databricks.com/aws/en/ingestion/lakeflow-connect/) before promising ingestion from this engine. This page covers preparing the database; whether and how Lakeflow Connect ingests from it (query-based, CDC, or a community connector) changes between releases.


## Overview

MongoDB uses **Change Streams** for CDC. Change Streams require:
1. Replica set mode (not standalone)
2. Session / transaction support (enables changeStreamPreAndPostImages)
3. LFC user with `readAnyDatabase` + `clusterMonitor` roles

Unlike relational engines, MongoDB tracks document changes (not table rows); pre/post images of document modifications.

## Prerequisites

- MongoDB 3.6+ (for Change Streams)
- MongoDB 4.2+ (for changeStreamPreAndPostImages)
- Replica set initialized (`--replSet rs0`)
- Admin user with authentication enabled

## Replica Set Initialization

Change Streams require replica set mode.

**Podman / Local:**

```bash
# Start MongoDB with replica set
podman run -d \
  --name mongodb \
  -e MONGO_INITDB_ROOT_USERNAME=admin \
  -e MONGO_INITDB_ROOT_PASSWORD=<password> \
  --replSet=rs0 \
  mongo:latest
```

**Initialize replica set (once):**

```javascript
// mongosh (or mongo shell)
rs.initiate();
rs.status();  // Check myState === 1 (PRIMARY)
```

## LFC User Setup

```javascript
// mongosh or mongo shell
db = db.getSiblingDB('admin');

// Create LFC user with CDC permissions
db.createUser({
  user: '<lfc_user>',
  pwd: '<password-from-file>',
  roles: [
    { role: 'readAnyDatabase', db: 'admin' },
    { role: 'clusterMonitor', db: 'admin' },
    { role: 'readWrite', db: '<target_database>' }
  ]
});

// Verify
db.getUser('<lfc_user>');
```

## Seed Collections

MongoDB has no tables; instead, **collections** (analogous to tables) store documents.

```javascript
// mongosh
use <target_database>;

db.createCollection('intpk');
db.createCollection('dtix');

// Enable changeStreamPreAndPostImages (MongoDB 4.2+)
// This captures full document state before/after changes
db.runCommand({
  collMod: 'intpk',
  changeStreamPreAndPostImages: { enabled: true }
});

db.runCommand({
  collMod: 'dtix',
  changeStreamPreAndPostImages: { enabled: true }
});

// Seed documents
db.intpk.insertMany([
  { _id: 1, ops: 'seed' },
  { _id: 2, ops: 'seed' },
  // ... 8 more
]);

db.dtix.insertMany([
  { _id: 1, ops: 'seed' },
  { _id: 2, ops: 'seed' },
  // ... 8 more
]);

// Verify
db.intpk.countDocuments({});   // Should return 10
db.dtix.countDocuments({});    // Should return 10
```

## CDC via Change Streams

Change Streams deliver a stream of document changes (insert, update, delete, replace, invalidate).

```javascript
// mongosh
use <target_database>;

// Watch collection for changes (cursor-based)
const changeStream = db.intpk.watch();

changeStream.on('change', (change) => {
  console.log(change);  // {operationType: 'insert', fullDocument: {...}, ...}
});

// For LFC: specify batchSize and startAtOperationTime for resume

const opts = {
  batchSize: 100,
  startAtOperationTime: <timestamp>  // Resume from here
};

const cs = db.intpk.watch([], opts);
```

## Gotchas

- **No replica set = no Change Streams:** Standalone MongoDB cannot use Change Streams. Requires replica set initialization.
- **Pre/post images optional:** `changeStreamPreAndPostImages` must be enabled per collection for full document capture. Without it, only change metadata is available.
- **No transactions on collections:** MongoDB transactions work at the session level; individual collection CDC is atomic per document.
- **Network authentication required:** Change Streams require authentication; anonymous access is not supported.
- **Oplog retention:** Change Streams read from the oplog (operations log). If LFC lags and oplog rolls over, CDC stream breaks. Default oplog size is ~5% of disk; increase if needed:
  ```javascript
  db.adminCommand({ replSetResizeOplog: 1, size: 20000 });  // 20 GB
  ```

## LFC Support Status

✓ Query-based ingestion  
✓ Standard CDC (Change Streams)  
✗ Integrated CDC (not applicable; MongoDB architecture differs)

---

## Troubleshooting

- **Can't connect:** check reachability (`nc -zv <host> <port>`), the firewall / security group, and the credentials.
- **Change streams receive nothing:** the replica set must have a PRIMARY (`rs.status()`), `changeStreamPreAndPostImages` must be on for the collection (`db.runCommand({listCollections: 1})`), and the oplog must not roll over before the reader catches up (`rs.printReplicationInfo()`; increase the oplog size if needed).
- **Password rotation:** `db.getSiblingDB('admin').changeUserPassword('<lfc_user>', passwordPrompt())` (prompts instead of putting the password in the command).

## When to use

Document data and real-time change feeds through change streams.
