-- Deploy transactions
-- requires: schema

BEGIN;

    SET client_min_messages = 'warning';
    
    ALTER TABLE support.transactions DROP COLUMN pref_lapel;

COMMIT;
