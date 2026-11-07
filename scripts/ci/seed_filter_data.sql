-- Test data for the filter/catalog checks in scripts/ci/smoke.sh.
-- Covers: vendor names in different casing, a substring trap (Sun vs
-- Samsung), CVEs without a date, a non-array JSON value, several months.
INSERT INTO vulnerabilities
  (cve_id, title, description, severity, cvss_score, exploited_in_the_wild,
   vendors, products, cwe_ids, source_tags, published_at, created_at, updated_at)
VALUES
  ('CVE-2026-90001', 'nginx overflow', 'd', 'CRITICAL', 9.8, true,
   '["Nginx"]', '["Nginx"]', '["CWE-787"]', '[]', now() - interval '3 days', now(), now()),
  ('CVE-2026-90002', 'nginx dos', 'd', 'HIGH', 7.5, false,
   '["nginx"]', '["Nginx"]', '["CWE-400"]', '[]', now() - interval '40 days', now(), now()),
  ('CVE-2026-90003', 'nginx njs bug', 'd', 'MEDIUM', 5.3, false,
   '["F5", "Nginx"]', '["Njs"]', '["CWE-787"]', '[]', now() - interval '75 days', now(), now()),
  ('CVE-2025-90004', 'old nginx issue', 'd', 'LOW', 3.1, false,
   '["Nginx"]', '["Nginx"]', '["CWE-20"]', '[]', now() - interval '400 days', now(), now()),
  ('CVE-2026-90005', 'samsung phone', 'd', 'HIGH', 8.1, false,
   '["Samsung"]', '["Galaxy"]', '["CWE-787"]', '[]', now() - interval '1 days', now(), now()),
  ('CVE-2026-90006', 'sun java', 'd', 'CRITICAL', 9.1, true,
   '["Sun"]', '["Java"]', '["CWE-502"]', '[]', now() - interval '2 days', now(), now()),
  ('CVE-2026-90007', 'undated cve', 'd', 'MEDIUM', 6.0, false,
   '["Nginx"]', '["Nginx"]', '[]', '[]', NULL, now(), now()),
  ('CVE-2026-90008', 'weird vendors json', 'd', NULL, NULL, false,
   '{"not": "an array"}', NULL, NULL, '[]', now() - interval '5 days', now(), now());
