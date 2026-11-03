-- a stand-in for the DDL file a workload names (ddl.py --dialect tsql writes the real one)
CREATE TABLE [branch] (bid int NOT NULL PRIMARY KEY);
CREATE TABLE [teller] (tid int NOT NULL PRIMARY KEY);
CREATE TABLE [account] (aid int NOT NULL PRIMARY KEY);
CREATE TABLE [history] (hid int NOT NULL);
