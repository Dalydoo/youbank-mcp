-- Audit §2.7 / Week 2 PR 1: enable the pgvector extension for cosine kNN.
-- PAUSE POINT: do not apply without explicit approval from Daz.
-- CREATE EXTENSION is a one-way change against production Supabase.
CREATE EXTENSION IF NOT EXISTS vector;
