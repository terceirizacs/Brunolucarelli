-- Régua de acompanhamento do Arrematador Caixa (pós-arrematação), lida do Chatwoot.
-- Somente leitura. Devolve 1 linha por contato da régua (cliente + mensagem + dia), sem telefone/e-mail em claro.
CREATE OR REPLACE FUNCTION public.cs_ac_regua(p_cliente_id uuid, p_inicio timestamptz DEFAULT '2026-11-03 00:00:00-03')
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '25s'
AS $function$
  WITH bruto0 AS (
    -- Trechos conferidos com os templates arrem_* aprovados na Meta (leitura de 31/10/2026).
    -- A nota privada do disparo é só o corpo do template com o primeiro nome, por isso o filtro pela saudação.
    SELECT m.chatwoot_conversation_id AS cid, m.message_created_at AS ts,
      CASE
        WHEN m.content ILIKE '%Vi que o seu check-in%' THEN 'M1A'
        WHEN m.content ILIKE '%acompanho você em toda a pós-arrematação%' THEN 'M1B'
        WHEN m.content ILIKE '%Passando para te dar notícia%' AND m.content ILIKE '%segue andando com a nossa equipe%' THEN 'M2'
        WHEN m.content ILIKE '%Contrato assinado!%' THEN 'M3'
        WHEN m.content ILIKE '%Já faz um mês que o seu contrato%' THEN 'M4'
        WHEN m.content ILIKE '%avançou bastante desde a assinatura%' THEN 'M5B'
        WHEN m.content ILIKE '%chegou na reta final%' THEN 'FIM'
      END AS tp
    FROM mensagens_chatwoot m
    WHERE m.cliente_id = p_cliente_id AND m.private = true AND m.message_type = 1
      AND m.message_created_at >= p_inicio
      AND m.content ~* '^\s*(Olá|Oiêeee|Ei), '
  ),
  bruto AS (
    -- M5A e M6 têm o mesmo texto de propósito. A M6 só sai para quem já recebeu a M5B,
    -- então a mensagem de reta final vira M6 quando há M5B anterior na mesma conversa, e M5A nos demais casos.
    SELECT cid, ts,
      CASE WHEN tp = 'FIM' THEN
        CASE WHEN COALESCE(bool_or(tp = 'M5B') OVER (PARTITION BY cid ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), false) THEN 'M6' ELSE 'M5A' END
      ELSE tp END AS tp
    FROM bruto0 WHERE tp IS NOT NULL
  ),
  ag AS (
    SELECT cid, tp, min(ts) AS ts, count(*) AS negocios
    FROM bruto WHERE tp IS NOT NULL
    GROUP BY cid, tp, ((ts AT TIME ZONE 'America/Sao_Paulo')::date)
  ),
  dd AS (
    SELECT ag.*, LEAST(COALESCE(lead(ts) OVER (PARTITION BY cid ORDER BY ts), 'infinity'::timestamptz), ts + interval '21 days') AS fim
    FROM ag
  ),
  r AS (
    SELECT dd.cid, dd.tp, dd.ts, dd.negocios,
      split_part(btrim(COALESCE(cv.contact_name,'')), ' ', 1) AS nome,
      CASE WHEN length(regexp_replace(COALESCE(cv.contact_phone,''),'\D','','g')) >= 8
           THEN encode(sha256(convert_to(right(regexp_replace(cv.contact_phone,'\D','','g'),8),'UTF8')),'hex') END AS tel_h,
      CASE WHEN COALESCE(cv.contact_email,'') <> ''
           THEN encode(sha256(convert_to(lower(btrim(cv.contact_email)),'UTF8')),'hex') END AS email_h,
      i.n_in, i.t1, i.texto,
      (SELECT min(o.message_created_at) FROM mensagens_chatwoot o
        WHERE o.cliente_id = p_cliente_id AND o.chatwoot_conversation_id = dd.cid
          AND o.message_type = 1 AND o.private = false
          AND o.message_created_at > i.t1 AND o.message_created_at < dd.fim) AS t_ret
    FROM dd
    LEFT JOIN conversas_chatwoot cv ON cv.cliente_id = p_cliente_id AND cv.chatwoot_conversation_id = dd.cid
    LEFT JOIN LATERAL (
      SELECT count(*) AS n_in, min(x.message_created_at) AS t1,
        left(string_agg(CASE WHEN COALESCE(btrim(x.content),'') = '' THEN '[mídia]' ELSE regexp_replace(x.content,'\s+',' ','g') END, ' | ' ORDER BY x.message_created_at), 700) AS texto
      FROM mensagens_chatwoot x
      WHERE x.cliente_id = p_cliente_id AND x.chatwoot_conversation_id = dd.cid
        AND x.message_type = 0 AND x.message_created_at > dd.ts AND x.message_created_at < dd.fim
    ) i ON true
  )
  SELECT jsonb_build_object(
    'gerado_em', (extract(epoch FROM now())*1000)::bigint,
    'inicio', (extract(epoch FROM p_inicio)*1000)::bigint,
    'contatos', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'cid', cid, 'tp', tp, 'ts', (extract(epoch FROM ts)*1000)::bigint, 'neg', negocios, 'nome', nome,
        'tel_h', tel_h, 'email_h', email_h,
        'n_in', COALESCE(n_in,0),
        'min1', CASE WHEN t1 IS NOT NULL THEN round(extract(epoch FROM t1 - ts)/60) END,
        'min_ret', CASE WHEN t_ret IS NOT NULL THEN round(extract(epoch FROM t_ret - t1)/60) END,
        'texto', regexp_replace(regexp_replace(texto, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[dado oculto]', 'g'), '\d[\d\.\-\s\(\)/]{6,}\d', '[dado oculto]', 'g')) ORDER BY ts) FROM r), '[]'::jsonb)
  );
$function$;
REVOKE ALL ON FUNCTION public.cs_ac_regua(uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cs_ac_regua(uuid, timestamptz) TO anon, authenticated, service_role;
