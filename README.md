# RYU Health Vitals Tracker 🩺

A single-file PWA for tracking Blood Pressure, Blood Sugar, and Heart Rate — built for personal health monitoring.

## Features
- Log BP & Pulse + Heart Rate in one combined form
- Blood Sugar logging with ADA 2026 classification
- Trend charts (7/14/30/90 days)
- Normal range alerts (AHA/ACC 2025 & ADA 2026)
- CSV export & import
- Dark mode support
- Offline-capable (localStorage)

## Files
- `health-vitals-tracker.html` — Single-file PWA (open in any browser)
- `bp_sugar_reference_ranges.json` — Reference data for BP & glucose ranges
- `supabase/migrations/001_schema.sql` — Supabase DB schema (for cloud sync)

## Reference Guidelines
- Blood Pressure: AHA/ACC 2025
- Blood Glucose: ADA 2026
