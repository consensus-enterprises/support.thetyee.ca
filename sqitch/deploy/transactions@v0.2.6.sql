-- Deploy transactions
-- requires: schema

BEGIN;

    SET client_min_messages = 'warning';
    
    CREATE TABLE support.transactions (
        id          SERIAL PRIMARY KEY NOT NULL UNIQUE,
        email       TEXT NOT NULL,
        first_name  TEXT NOT NULL,
        last_name   TEXT NOT NULL,
        trans_date  TIMESTAMP NOT NULL,
        amount_in_cents INT NOT NULL,
        plan_name   TEXT NULL,
        plan_code   TEXT NULL,
        city        TEXT NULL,
        state       TEXT NULL,
        zip         TEXT NOT NULL,
        country     TEXT NULL,
        pref_anonymous TEXT NULL,
        pref_frequency TEXT NULL,
        campaign    TEXT NULL
    );

COMMIT;
