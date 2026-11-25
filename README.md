# ICT371 Advanced Database: Question 8: Transport Fleet Maintenance

**Student number:** 202407871 | **Mulungushi University**

PostgreSQL solution for Question 8, parts (a) to (g): tables and seed data, function, procedure, trigger, view, index with EXPLAIN, and a pg_cron scheduled job.

## Run
```bash
psql -d yourdb -f ICT371_202407871_Q8_Fleet.sql
```
- Everything is created in schema `q8_fleet`; the script drops and recreates it, so it is safe to re-run.
- The test section at the bottom of the file demonstrates each part; expected failures print as `EXPECTED ERROR`.
- Scheduled jobs need the `pg_cron` extension.
- Seed data uses `CURRENT_DATE`, so dates and totals depend on the day you run it.
- EXPLAIN sections temporarily disable sequential scans so the index is visible on small tables.

## Assumptions
- Part (g): an existing alert keeps its original `flagged_on`; only `km_since_service` is refreshed.
