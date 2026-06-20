-- ============================================================
-- Health Vitals — Supabase Migration 001: Schema
-- Sections 4 & 6.1 of the PRD | Created: 2026-06-19
--
-- RUN ORDER: execute this file first, then 002_rls.sql
-- DO NOT run against a database that already has these tables.
-- ============================================================


-- ============================================================
-- 1. ENUMS
-- Status values come from bp_sugar_reference_ranges.json.
-- The numeric thresholds are NOT stored here — classification
-- logic lives in the app layer, reading that JSON at runtime.
-- ============================================================

CREATE TYPE bp_status AS ENUM (
  'Low',       -- systolic < 90 OR diastolic < 60
  'Normal',    -- systolic ≤ 119 AND diastolic ≤ 79
  'Elevated',  -- systolic 120–129 AND diastolic ≤ 79
  'Stage1',    -- systolic 130–139 OR diastolic 80–89
  'Stage2',    -- systolic 140–179 OR diastolic 90–119
  'Crisis'     -- systolic ≥ 180 OR diastolic ≥ 120
);

CREATE TYPE bs_status AS ENUM (
  'Low',         -- ≤ 69 mg/dL (context-dependent hypoglycemia)
  'Normal',
  'Prediabetes',
  'Diabetes'
);

-- reading_type for blood sugar determines which reference range applies
CREATE TYPE bs_reading_type AS ENUM (
  'fasting',       -- use fasting ranges
  'before_meal',   -- use fasting ranges (treated same as fasting)
  'post_meal_2hr', -- use postMeal2hr ranges
  'random'         -- diagnostic flag only; shown with caution caveat in UI
);

-- blood sugar unit
CREATE TYPE bs_unit AS ENUM (
  'mg/dL',
  'mmol/L'
);

-- caregiver invite lifecycle
CREATE TYPE invite_status AS ENUM (
  'pending',
  'accepted',
  'revoked'
);


-- ============================================================
-- 2. PROFILES
-- One row per auth.users entry. Stores display name and the
-- user's preferred blood sugar unit (set during onboarding,
-- changeable in Settings).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.profiles (
  id            uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name  text        NOT NULL DEFAULT '',
  bs_unit       bs_unit     NOT NULL DEFAULT 'mg/dL',
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Auto-create a profile row whenever a new user signs up
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, display_name)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email, '')
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Keep updated_at current
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


-- ============================================================
-- 3. BP_READINGS
-- Blood pressure + pulse are always captured together (same
-- BP cuff measurement). Merged into one table per Section 4.1.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.bp_readings (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- Measurement values
  systolic       smallint    NOT NULL CHECK (systolic BETWEEN 40 AND 300),
  diastolic      smallint    NOT NULL CHECK (diastolic BETWEEN 20 AND 200),
  pulse          smallint    NOT NULL CHECK (pulse BETWEEN 20 AND 300),

  -- Classification: computed by app layer from bp_sugar_reference_ranges.json
  status         bp_status   NOT NULL,

  -- When the reading was actually taken (user-supplied, may differ from created_at)
  recorded_at    timestamptz NOT NULL DEFAULT now(),

  -- Optional free-text note
  note           text,

  -- Audit
  created_at     timestamptz NOT NULL DEFAULT now(),
  last_edited_at timestamptz           -- NULL means never edited after initial save

  CONSTRAINT systolic_gt_diastolic CHECK (systolic > diastolic)
);

CREATE INDEX idx_bp_readings_user_recorded
  ON public.bp_readings (user_id, recorded_at DESC);

CREATE TRIGGER bp_readings_updated_at
  BEFORE UPDATE ON public.bp_readings
  FOR EACH ROW EXECUTE PROCEDURE public.set_updated_at();

-- Track last_edited_at on every UPDATE (not the initial INSERT)
CREATE OR REPLACE FUNCTION public.set_last_edited_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.last_edited_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER bp_readings_last_edited
  BEFORE UPDATE ON public.bp_readings
  FOR EACH ROW EXECUTE FUNCTION public.set_last_edited_at();


-- ============================================================
-- 4. BS_READINGS
-- Blood sugar, measured independently and at different times
-- relative to meals. reading_type determines which reference
-- range band the app should apply.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.bs_readings (
  id             uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid           NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- What kind of measurement this is
  reading_type   bs_reading_type NOT NULL,

  -- The glucose value and its unit as entered by the user
  glucose_value  numeric(6,2)   NOT NULL CHECK (glucose_value > 0),
  unit           bs_unit        NOT NULL,

  -- Classification: computed by app layer from bp_sugar_reference_ranges.json.
  -- 'random' reading_type should still store the computed status, but the UI
  -- must display it with a caution caveat rather than a clean status badge.
  status         bs_status      NOT NULL,

  -- When the reading was actually taken
  recorded_at    timestamptz    NOT NULL DEFAULT now(),

  -- Optional free-text note
  note           text,

  -- Audit
  created_at     timestamptz    NOT NULL DEFAULT now(),
  last_edited_at timestamptz             -- NULL means never edited
);

CREATE INDEX idx_bs_readings_user_recorded
  ON public.bs_readings (user_id, recorded_at DESC);

CREATE TRIGGER bs_readings_last_edited
  BEFORE UPDATE ON public.bs_readings
  FOR EACH ROW EXECUTE FUNCTION public.set_last_edited_at();


-- ============================================================
-- 5. CAREGIVER_INVITES
-- Owner → caregiver sharing relationship. A caregiver gains
-- read-only access to one owner's readings upon accepting.
-- Owners can revoke at any time (status → 'revoked').
--
-- caregiver_email: recorded at invite time (before the recipient
-- may have an account). caregiver_id: populated on acceptance.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.caregiver_invites (
  id               uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id         uuid          NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  caregiver_email  text          NOT NULL,
  caregiver_id     uuid          REFERENCES auth.users(id) ON DELETE SET NULL,
  status           invite_status NOT NULL DEFAULT 'pending',
  created_at       timestamptz   NOT NULL DEFAULT now(),
  accepted_at      timestamptz,

  -- One active (pending or accepted) relationship per owner-caregiver pair
  CONSTRAINT unique_active_invite
    UNIQUE (owner_id, caregiver_email)
);

CREATE INDEX idx_caregiver_invites_owner
  ON public.caregiver_invites (owner_id);

CREATE INDEX idx_caregiver_invites_caregiver_id
  ON public.caregiver_invites (caregiver_id)
  WHERE caregiver_id IS NOT NULL;
