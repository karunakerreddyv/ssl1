-- =============================================================================
-- PostgreSQL Initialization Script
-- Creates databases and users for Pravaha Platform
-- =============================================================================
--
-- This script runs automatically on first PostgreSQL startup.
-- It creates the Superset database (platform database is created via POSTGRES_DB).
--
-- IMPORTANT: PostgreSQL init scripts do NOT support environment variable
-- substitution. The database names below are hardcoded and MUST match:
--   - PLATFORM_DB must be set to 'autoanalytics' in .env
--   - SUPERSET_DB must be set to 'superset' in .env
--
-- If you need different database names, modify this file accordingly.
--
-- =============================================================================

-- Create Superset database if it doesn't exist
SELECT 'CREATE DATABASE superset'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'superset')\gexec

-- Create extensions for platform database (name must match PLATFORM_DB in .env)
\c autoanalytics
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Create extensions for superset database (name must match SUPERSET_DB in .env)
\c superset
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
