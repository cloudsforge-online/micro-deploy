-- One server, two databases. Rule 1 of 03 §2: a service owns exactly one
-- database and reads no other, so the slice gives each its own rather than
-- sharing a schema and proving the opposite of what it is here to prove.
CREATE DATABASE identity;
CREATE DATABASE ledger;
CREATE DATABASE activity;
CREATE DATABASE notify;
