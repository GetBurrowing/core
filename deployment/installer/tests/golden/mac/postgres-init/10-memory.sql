-- memory-service database (registry service: memory-service).
-- Runs once, on an EMPTY core-postgres data volume. A fresh postgres has none of
-- this; moon's did because its data was restored from hive.
\getenv memory_db_password MEMORY_DB_PASSWORD
CREATE ROLE memory LOGIN PASSWORD :'memory_db_password';
CREATE DATABASE memory OWNER memory;
\connect memory
CREATE EXTENSION IF NOT EXISTS vector;
