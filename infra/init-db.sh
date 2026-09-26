#!/bin/sh
# Se ejecuta SOLO la primera vez que se crea el volumen de Postgres.
# Crea la BD de Evolution y la BD "chatbot" con todo el esquema.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d n8n <<SQL
CREATE DATABASE evolution;
CREATE DATABASE chatbot;
SQL
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d chatbot -f /schema/01_schema.sql
