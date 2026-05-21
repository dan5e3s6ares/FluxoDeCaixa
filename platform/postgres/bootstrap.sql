-- Idempotent PostgreSQL bootstrap (doc 07): schemas lancamentos/consolidado.
-- RLS policy stubs per doc 05 — full policies applied when Alembic creates tables.

CREATE SCHEMA IF NOT EXISTS lancamentos;
CREATE SCHEMA IF NOT EXISTS consolidado;

COMMENT ON SCHEMA lancamentos IS 'Write path (svc-lancamentos); RLS on lancamentos.* per doc 05';
COMMENT ON SCHEMA consolidado IS 'Read model (svc-consolidado/consulta); RLS on consolidado_diario per doc 05';

-- Session helper: services call after JWT validation (doc 05).
CREATE OR REPLACE FUNCTION public.set_app_merchant_id(merchant_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM set_config('app.merchant_id', merchant_id::text, true);
END;
$$;

COMMENT ON FUNCTION public.set_app_merchant_id(uuid) IS
  'Sets app.merchant_id for RLS policies (merchant_id = current_setting(''app.merchant_id'', true))';

-- RLS stubs: run when application tables exist (db-migrate-{svc} jobs).
CREATE OR REPLACE FUNCTION public.apply_rls_stubs()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF to_regclass('lancamentos.lancamentos') IS NOT NULL THEN
    EXECUTE 'ALTER TABLE lancamentos.lancamentos ENABLE ROW LEVEL SECURITY';
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'lancamentos' AND tablename = 'lancamentos'
        AND policyname = 'tenant_isolation'
    ) THEN
      EXECUTE $policy$
        CREATE POLICY tenant_isolation ON lancamentos.lancamentos
          USING (merchant_id::text = current_setting('app.merchant_id', true))
      $policy$;
    END IF;
  END IF;

  IF to_regclass('consolidado.consolidado_diario') IS NOT NULL THEN
    EXECUTE 'ALTER TABLE consolidado.consolidado_diario ENABLE ROW LEVEL SECURITY';
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'consolidado' AND tablename = 'consolidado_diario'
        AND policyname = 'tenant_isolation'
    ) THEN
      EXECUTE $policy$
        CREATE POLICY tenant_isolation ON consolidado.consolidado_diario
          USING (merchant_id::text = current_setting('app.merchant_id', true))
      $policy$;
    END IF;
  END IF;
END;
$$;

SELECT public.apply_rls_stubs();
