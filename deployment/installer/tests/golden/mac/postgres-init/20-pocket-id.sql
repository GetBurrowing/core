-- pocket-id database (registry service: pocket-id, target mac). Runs once, on an
-- EMPTY core-postgres data volume, so one pg_dump of core-postgres covers sign-in.
\getenv pocketid_db_password POCKETID_DB_PASSWORD
CREATE ROLE pocketid LOGIN PASSWORD :'pocketid_db_password';
CREATE DATABASE pocketid OWNER pocketid;
