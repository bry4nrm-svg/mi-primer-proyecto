-- =====================================================================
--  CHATBOT MADRE - Esquema multi-negocio (multi-tenant)
--  Un solo Postgres + un solo flujo de n8n atienden a TODOS tus clientes.
--  Para un negocio nuevo solo insertas filas (ver 02_seed_*.sql).
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- NEGOCIOS: toda la "personalidad" y configuracion de cada cliente
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS negocios (
  id                SERIAL PRIMARY KEY,
  nombre            TEXT NOT NULL,
  tipo              TEXT NOT NULL DEFAULT 'citas'
                    CHECK (tipo IN ('citas','pedidos','ambos','info')),
  activo            BOOLEAN NOT NULL DEFAULT TRUE,   -- apagar si no paga
  plan              TEXT NOT NULL DEFAULT 'basico',
  limite_mensajes   INT  NOT NULL DEFAULT 2000,      -- mensajes de IA al mes
  modelo_ia         TEXT NOT NULL DEFAULT 'claude-opus-5',
  -- WhatsApp
  wa_proveedor      TEXT NOT NULL DEFAULT 'evolution'
                    CHECK (wa_proveedor IN ('evolution','meta')),
  wa_canal_id       TEXT NOT NULL UNIQUE,  -- evolution: nombre de instancia | meta: phone_number_id
  wa_token          TEXT,                  -- solo meta: access token del negocio
  -- Datos para la IA
  zona_horaria      TEXT NOT NULL DEFAULT 'America/Mexico_City',
  moneda            TEXT NOT NULL DEFAULT 'MXN',
  personalidad      TEXT NOT NULL DEFAULT 'Amable, breve y profesional. Usa emojis con moderacion.',
  info              JSONB NOT NULL DEFAULT '{}'::jsonb,  -- direccion, pagos, envios, FAQs...
  -- Agenda (solo si tipo = citas/ambos)
  horario           JSONB NOT NULL DEFAULT
    '{"1":["09:00","18:00"],"2":["09:00","18:00"],"3":["09:00","18:00"],"4":["09:00","18:00"],"5":["09:00","18:00"],"6":["09:00","14:00"]}'::jsonb,
                    -- clave = dia ISO (1=lunes ... 7=domingo). Dia ausente = cerrado.
  duracion_cita_min INT  NOT NULL DEFAULT 30,
  citas_simultaneas INT  NOT NULL DEFAULT 1,   -- cuantas personas atienden a la vez
  google_calendar_id TEXT,                     -- opcional: sincroniza citas a su Google Calendar
  creado_en         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- CATALOGO: servicios (consultorio) o productos (pizzeria). Mismo formato.
CREATE TABLE IF NOT EXISTS catalogo (
  id            SERIAL PRIMARY KEY,
  negocio_id    INT NOT NULL REFERENCES negocios(id) ON DELETE CASCADE,
  categoria     TEXT NOT NULL DEFAULT 'General',
  nombre        TEXT NOT NULL,
  descripcion   TEXT,
  precio        NUMERIC(10,2) NOT NULL DEFAULT 0,
  duracion_min  INT,             -- solo servicios; si es NULL usa negocios.duracion_cita_min
  activo        BOOLEAN NOT NULL DEFAULT TRUE
);

-- CLIENTES de tus clientes (los que escriben por WhatsApp)
CREATE TABLE IF NOT EXISTS clientes (
  id           SERIAL PRIMARY KEY,
  negocio_id   INT NOT NULL REFERENCES negocios(id) ON DELETE CASCADE,
  telefono     TEXT NOT NULL,
  nombre       TEXT,
  notas        TEXT,
  bot_pausado  BOOLEAN NOT NULL DEFAULT FALSE,   -- TRUE = lo atiende un humano
  creado_en    TIMESTAMPTZ NOT NULL DEFAULT now(),
  ultimo_msg   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (negocio_id, telefono)
);

-- MENSAJES: historial visible en el panel + conteo para cobrar/limitar
CREATE TABLE IF NOT EXISTS mensajes (
  id          BIGSERIAL PRIMARY KEY,
  negocio_id  INT NOT NULL REFERENCES negocios(id) ON DELETE CASCADE,
  cliente_id  INT NOT NULL REFERENCES clientes(id) ON DELETE CASCADE,
  direccion   TEXT NOT NULL CHECK (direccion IN ('entrante','bot','humano')),
  texto       TEXT NOT NULL,
  wa_msg_id   TEXT,
  creado_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS mensajes_wa_msg_id_uq ON mensajes (negocio_id, wa_msg_id) WHERE wa_msg_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS mensajes_cliente_idx ON mensajes (cliente_id, creado_en);

-- CITAS
CREATE TABLE IF NOT EXISTS citas (
  id             SERIAL PRIMARY KEY,
  negocio_id     INT NOT NULL REFERENCES negocios(id) ON DELETE CASCADE,
  cliente_id     INT REFERENCES clientes(id) ON DELETE SET NULL,
  servicio_id    INT REFERENCES catalogo(id) ON DELETE SET NULL,
  inicio         TIMESTAMPTZ NOT NULL,
  fin            TIMESTAMPTZ NOT NULL,
  estado         TEXT NOT NULL DEFAULT 'confirmada'
                 CHECK (estado IN ('confirmada','cancelada','completada','no_asistio')),
  notas          TEXT,
  gcal_event_id  TEXT,
  creado_en      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS citas_negocio_inicio_idx ON citas (negocio_id, inicio);

-- PEDIDOS
CREATE TABLE IF NOT EXISTS pedidos (
  id           SERIAL PRIMARY KEY,
  negocio_id   INT NOT NULL REFERENCES negocios(id) ON DELETE CASCADE,
  cliente_id   INT REFERENCES clientes(id) ON DELETE SET NULL,
  items        JSONB NOT NULL,           -- [{id,nombre,precio,cantidad,nota,subtotal}]
  total        NUMERIC(10,2) NOT NULL,
  entrega      TEXT NOT NULL DEFAULT 'recoger' CHECK (entrega IN ('recoger','domicilio')),
  direccion    TEXT,
  notas        TEXT,
  estado       TEXT NOT NULL DEFAULT 'nuevo'
               CHECK (estado IN ('nuevo','preparando','en_camino','entregado','cancelado')),
  creado_en    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS pedidos_negocio_idx ON pedidos (negocio_id, creado_en DESC);

-- USUARIOS DEL PANEL (el dueno del negocio y su equipo)
CREATE TABLE IF NOT EXISTS usuarios_panel (
  id            SERIAL PRIMARY KEY,
  negocio_id    INT NOT NULL REFERENCES negocios(id) ON DELETE CASCADE,
  email         TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  nombre        TEXT
);
CREATE TABLE IF NOT EXISTS sesiones_panel (
  token       TEXT PRIMARY KEY,
  usuario_id  INT NOT NULL REFERENCES usuarios_panel(id) ON DELETE CASCADE,
  expira      TIMESTAMPTZ NOT NULL
);

-- =====================================================================
--  FUNCIONES QUE USA EL BOT (n8n solo llama estas funciones)
--  Ventaja: la logica vive aqui, probada, y n8n queda simple.
-- =====================================================================

-- Helper: registra el usuario del panel con password encriptado
CREATE OR REPLACE FUNCTION crear_usuario_panel(p_negocio INT, p_email TEXT, p_password TEXT, p_nombre TEXT DEFAULT NULL)
RETURNS INT LANGUAGE sql AS $$
  INSERT INTO usuarios_panel (negocio_id, email, password_hash, nombre)
  VALUES (p_negocio, lower(p_email), crypt(p_password, gen_salt('bf')), p_nombre)
  ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash, negocio_id = EXCLUDED.negocio_id
  RETURNING id;
$$;

-- 1) CONTEXTO: se llama con cada mensaje entrante.
--    Identifica al negocio, registra cliente + mensaje y decide si el bot responde.
CREATE OR REPLACE FUNCTION fn_contexto(
  p_proveedor TEXT, p_canal_id TEXT, p_telefono TEXT, p_nombre TEXT,
  p_texto TEXT, p_from_me BOOLEAN, p_wa_msg_id TEXT
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  n negocios%ROWTYPE;
  c clientes%ROWTYPE;
  usados INT;
  motivo TEXT := NULL;
BEGIN
  SELECT * INTO n FROM negocios WHERE wa_canal_id = p_canal_id AND wa_proveedor = p_proveedor;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('responder', false, 'motivo', 'negocio_no_encontrado');
  END IF;

  INSERT INTO clientes (negocio_id, telefono, nombre)
  VALUES (n.id, p_telefono, NULLIF(p_nombre,''))
  ON CONFLICT (negocio_id, telefono) DO UPDATE
    SET ultimo_msg = now(), nombre = COALESCE(clientes.nombre, EXCLUDED.nombre)
  RETURNING * INTO c;

  -- Si el dueno contesta desde su celular, pausamos el bot para ese cliente
  IF p_from_me THEN
    UPDATE clientes SET bot_pausado = TRUE WHERE id = c.id;
    INSERT INTO mensajes (negocio_id, cliente_id, direccion, texto, wa_msg_id)
    VALUES (n.id, c.id, 'humano', p_texto, p_wa_msg_id) ON CONFLICT DO NOTHING;
    RETURN jsonb_build_object('responder', false, 'motivo', 'respondio_humano');
  END IF;

  -- Evita responder dos veces el mismo mensaje (WhatsApp a veces reenvia)
  BEGIN
    INSERT INTO mensajes (negocio_id, cliente_id, direccion, texto, wa_msg_id)
    VALUES (n.id, c.id, 'entrante', p_texto, p_wa_msg_id);
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('responder', false, 'motivo', 'duplicado');
  END;

  SELECT count(*) INTO usados FROM mensajes
   WHERE negocio_id = n.id AND direccion = 'bot' AND creado_en >= date_trunc('month', now());

  IF NOT n.activo THEN motivo := 'negocio_inactivo';
  ELSIF c.bot_pausado THEN motivo := 'bot_pausado';
  ELSIF usados >= n.limite_mensajes THEN motivo := 'limite_mensajes';
  END IF;

  RETURN jsonb_build_object(
    'responder', motivo IS NULL,
    'motivo', motivo,
    'ahora_local', to_char(now() AT TIME ZONE n.zona_horaria, 'YYYY-MM-DD HH24:MI') || ' (' ||
                   (ARRAY['lunes','martes','miercoles','jueves','viernes','sabado','domingo'])
                   [extract(isodow FROM now() AT TIME ZONE n.zona_horaria)::int] || ')',
    'negocio', jsonb_build_object(
      'id', n.id, 'nombre', n.nombre, 'tipo', n.tipo, 'modelo_ia', n.modelo_ia,
      'wa_proveedor', n.wa_proveedor, 'wa_canal_id', n.wa_canal_id, 'wa_token', n.wa_token,
      'zona_horaria', n.zona_horaria, 'moneda', n.moneda, 'personalidad', n.personalidad,
      'info', n.info, 'horario', n.horario, 'duracion_cita_min', n.duracion_cita_min),
    'cliente', jsonb_build_object('id', c.id, 'telefono', c.telefono, 'nombre', c.nombre),
    'catalogo', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', id, 'categoria', categoria, 'nombre', nombre,
               'descripcion', descripcion, 'precio', precio, 'duracion_min', duracion_min)
               ORDER BY categoria, nombre)
        FROM catalogo WHERE negocio_id = n.id AND activo), '[]'::jsonb)
  );
END $$;

-- 2) DISPONIBILIDAD: horarios libres de un dia
CREATE OR REPLACE FUNCTION fn_disponibilidad(p_negocio INT, p_fecha DATE, p_servicio_id INT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  n negocios%ROWTYPE;
  rango JSONB;
  dur INT;
  t TIMESTAMP;   -- hora local sin zona
  t_fin TIMESTAMP;
  libres TEXT[] := '{}';
  ocupadas INT;
BEGIN
  SELECT * INTO n FROM negocios WHERE id = p_negocio;
  IF p_fecha < (now() AT TIME ZONE n.zona_horaria)::date THEN
    RETURN jsonb_build_object('fecha', p_fecha, 'libres', '[]'::jsonb, 'nota', 'Fecha en el pasado');
  END IF;
  rango := n.horario -> extract(isodow FROM p_fecha)::int::text;
  IF rango IS NULL THEN
    RETURN jsonb_build_object('fecha', p_fecha, 'libres', '[]'::jsonb, 'nota', 'Cerrado ese dia');
  END IF;
  SELECT COALESCE(duracion_min, n.duracion_cita_min) INTO dur FROM catalogo WHERE id = p_servicio_id AND negocio_id = p_negocio;
  dur := COALESCE(dur, n.duracion_cita_min);

  t     := p_fecha + (rango->>0)::time;
  t_fin := p_fecha + (rango->>1)::time;
  WHILE t + make_interval(mins => dur) <= t_fin LOOP
    IF (t AT TIME ZONE n.zona_horaria) > now() + interval '30 minutes' THEN
      SELECT count(*) INTO ocupadas FROM citas
       WHERE negocio_id = p_negocio AND estado = 'confirmada'
         AND inicio < (t + make_interval(mins => dur)) AT TIME ZONE n.zona_horaria
         AND fin    > t AT TIME ZONE n.zona_horaria;
      IF ocupadas < n.citas_simultaneas THEN
        libres := libres || to_char(t, 'HH24:MI');
      END IF;
    END IF;
    t := t + make_interval(mins => n.duracion_cita_min);
  END LOOP;
  RETURN jsonb_build_object('fecha', p_fecha, 'duracion_min', dur, 'libres', to_jsonb(libres));
END $$;

-- 3) CREAR CITA (valida que el horario siga libre)
CREATE OR REPLACE FUNCTION fn_crear_cita(p_negocio INT, p_cliente INT, p_fecha_hora TEXT,
                                         p_servicio_id INT, p_nombre TEXT, p_notas TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  n negocios%ROWTYPE;
  local_ts TIMESTAMP := p_fecha_hora::timestamp;
  disp JSONB;
  dur INT;
  nueva citas%ROWTYPE;
BEGIN
  SELECT * INTO n FROM negocios WHERE id = p_negocio;
  IF n.tipo NOT IN ('citas','ambos') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Este negocio no agenda citas');
  END IF;
  disp := fn_disponibilidad(p_negocio, local_ts::date, p_servicio_id);
  IF NOT (disp->'libres') ? to_char(local_ts, 'HH24:MI') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Ese horario ya no esta disponible', 'libres', disp->'libres');
  END IF;
  dur := (disp->>'duracion_min')::int;
  IF NULLIF(p_nombre,'') IS NOT NULL THEN
    UPDATE clientes SET nombre = p_nombre WHERE id = p_cliente;
  END IF;
  INSERT INTO citas (negocio_id, cliente_id, servicio_id, inicio, fin, notas)
  VALUES (p_negocio, p_cliente,
          (SELECT id FROM catalogo WHERE id = p_servicio_id AND negocio_id = p_negocio),
          local_ts AT TIME ZONE n.zona_horaria,
          (local_ts + make_interval(mins => dur)) AT TIME ZONE n.zona_horaria,
          NULLIF(p_notas,''))
  RETURNING * INTO nueva;
  RETURN jsonb_build_object('ok', true, 'cita_id', nueva.id,
                            'inicio', to_char(local_ts, 'YYYY-MM-DD HH24:MI'), 'duracion_min', dur);
END $$;

-- 4) CITAS FUTURAS DEL CLIENTE
CREATE OR REPLACE FUNCTION fn_mis_citas(p_negocio INT, p_cliente INT)
RETURNS JSONB LANGUAGE sql AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'cita_id', ci.id,
           'inicio', to_char(ci.inicio AT TIME ZONE n.zona_horaria, 'YYYY-MM-DD HH24:MI'),
           'servicio', ca.nombre) ORDER BY ci.inicio), '[]'::jsonb)
    FROM citas ci JOIN negocios n ON n.id = ci.negocio_id
    LEFT JOIN catalogo ca ON ca.id = ci.servicio_id
   WHERE ci.negocio_id = p_negocio AND ci.cliente_id = p_cliente
     AND ci.estado = 'confirmada' AND ci.inicio > now();
$$;

-- 5) CANCELAR CITA (solo las del propio cliente)
CREATE OR REPLACE FUNCTION fn_cancelar_cita(p_negocio INT, p_cliente INT, p_cita INT)
RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
  UPDATE citas SET estado = 'cancelada'
   WHERE id = p_cita AND negocio_id = p_negocio AND cliente_id = p_cliente AND estado = 'confirmada';
  IF FOUND THEN RETURN jsonb_build_object('ok', true); END IF;
  RETURN jsonb_build_object('ok', false, 'error', 'No encontre esa cita a nombre del cliente');
END $$;

-- 6) CREAR PEDIDO: precios SIEMPRE salen del catalogo (la IA no puede inventarlos)
--    p_items = [{"id": 3, "cantidad": 2, "nota": "sin cebolla"}]
CREATE OR REPLACE FUNCTION fn_crear_pedido(p_negocio INT, p_cliente INT, p_items TEXT,
                                           p_entrega TEXT, p_direccion TEXT, p_notas TEXT, p_nombre TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  n negocios%ROWTYPE;
  items_ok JSONB;
  faltantes JSONB;
  v_total NUMERIC;
  nuevo pedidos%ROWTYPE;
  entrega_norm TEXT := CASE WHEN lower(coalesce(p_entrega,'')) LIKE 'dom%' THEN 'domicilio' ELSE 'recoger' END;
BEGIN
  SELECT * INTO n FROM negocios WHERE id = p_negocio;
  IF n.tipo NOT IN ('pedidos','ambos') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Este negocio no toma pedidos');
  END IF;
  IF entrega_norm = 'domicilio' AND NULLIF(trim(p_direccion),'') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Falta la direccion de entrega');
  END IF;

  WITH pedido AS (
    SELECT (e->>'id')::int AS id, GREATEST(COALESCE((e->>'cantidad')::int,1),1) AS cantidad, e->>'nota' AS nota
      FROM jsonb_array_elements(p_items::jsonb) e
  )
  SELECT jsonb_agg(jsonb_build_object('id', c.id, 'nombre', c.nombre, 'precio', c.precio,
                   'cantidad', p.cantidad, 'nota', p.nota, 'subtotal', c.precio * p.cantidad)),
         sum(c.precio * p.cantidad),
         (SELECT jsonb_agg(p2.id) FROM pedido p2 WHERE NOT EXISTS
            (SELECT 1 FROM catalogo c2 WHERE c2.id = p2.id AND c2.negocio_id = p_negocio AND c2.activo))
    INTO items_ok, v_total, faltantes
    FROM pedido p JOIN catalogo c ON c.id = p.id AND c.negocio_id = p_negocio AND c.activo;

  IF faltantes IS NOT NULL OR items_ok IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Productos no validos', 'ids_invalidos', faltantes);
  END IF;
  IF NULLIF(p_nombre,'') IS NOT NULL THEN
    UPDATE clientes SET nombre = p_nombre WHERE id = p_cliente;
  END IF;

  INSERT INTO pedidos (negocio_id, cliente_id, items, total, entrega, direccion, notas)
  VALUES (p_negocio, p_cliente, items_ok, v_total, entrega_norm, NULLIF(p_direccion,''), NULLIF(p_notas,''))
  RETURNING * INTO nuevo;
  RETURN jsonb_build_object('ok', true, 'pedido_id', nuevo.id, 'items', items_ok,
                            'total', v_total, 'moneda', n.moneda, 'entrega', entrega_norm);
END $$;

-- 7) PASAR A HUMANO: pausa el bot para ese cliente
CREATE OR REPLACE FUNCTION fn_pedir_humano(p_cliente INT, p_motivo TEXT)
RETURNS JSONB LANGUAGE plpgsql AS $$
BEGIN
  UPDATE clientes SET bot_pausado = TRUE,
         notas = concat_ws(E'\n', notas, to_char(now(),'YYYY-MM-DD HH24:MI') || ' pidio humano: ' || p_motivo)
   WHERE id = p_cliente;
  RETURN jsonb_build_object('ok', true);
END $$;

-- 8) GUARDAR RESPUESTA DEL BOT
CREATE OR REPLACE FUNCTION fn_log_bot(p_negocio INT, p_cliente INT, p_texto TEXT)
RETURNS VOID LANGUAGE sql AS $$
  INSERT INTO mensajes (negocio_id, cliente_id, direccion, texto) VALUES (p_negocio, p_cliente, 'bot', p_texto);
$$;

-- =====================================================================
--  API DEL PANEL: una sola funcion con login y acciones.
--  n8n recibe {token, accion, datos} y llama fn_panel(). Cada accion
--  esta amarrada al negocio del usuario: nadie ve datos de otro negocio.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_panel(p_token TEXT, p_accion TEXT, p_datos JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
  u usuarios_panel%ROWTYPE;
  n negocios%ROWTYPE;
  nuevo_token TEXT;
  desde TIMESTAMPTZ;
BEGIN
  p_datos := COALESCE(p_datos, '{}'::jsonb);

  IF p_accion = 'login' THEN
    SELECT * INTO u FROM usuarios_panel
     WHERE email = lower(p_datos->>'email') AND password_hash = crypt(p_datos->>'password', password_hash);
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'Correo o contrasena incorrectos'); END IF;
    nuevo_token := encode(gen_random_bytes(32), 'hex');
    INSERT INTO sesiones_panel VALUES (nuevo_token, u.id, now() + interval '30 days');
    DELETE FROM sesiones_panel WHERE expira < now();
    RETURN jsonb_build_object('ok', true, 'token', nuevo_token);
  END IF;

  SELECT up.* INTO u FROM sesiones_panel s JOIN usuarios_panel up ON up.id = s.usuario_id
   WHERE s.token = p_token AND s.expira > now();
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'sesion_expirada'); END IF;
  SELECT * INTO n FROM negocios WHERE id = u.negocio_id;

  CASE p_accion
  WHEN 'resumen' THEN
    desde := date_trunc('day', now() AT TIME ZONE n.zona_horaria) AT TIME ZONE n.zona_horaria;
    RETURN jsonb_build_object('ok', true,
      'negocio', jsonb_build_object('nombre', n.nombre, 'tipo', n.tipo, 'moneda', n.moneda, 'plan', n.plan),
      'usuario', u.nombre,
      'pedidos_hoy', (SELECT count(*) FROM pedidos WHERE negocio_id = n.id AND creado_en >= desde AND estado <> 'cancelado'),
      'ventas_hoy', (SELECT COALESCE(sum(total),0) FROM pedidos WHERE negocio_id = n.id AND creado_en >= desde AND estado <> 'cancelado'),
      'pedidos_pendientes', (SELECT count(*) FROM pedidos WHERE negocio_id = n.id AND estado IN ('nuevo','preparando','en_camino')),
      'citas_hoy', (SELECT count(*) FROM citas WHERE negocio_id = n.id AND estado = 'confirmada'
                     AND inicio >= desde AND inicio < desde + interval '1 day'),
      'clientes_total', (SELECT count(*) FROM clientes WHERE negocio_id = n.id),
      'esperando_humano', (SELECT count(*) FROM clientes WHERE negocio_id = n.id AND bot_pausado),
      'mensajes_mes', (SELECT count(*) FROM mensajes WHERE negocio_id = n.id AND direccion = 'bot'
                        AND creado_en >= date_trunc('month', now())),
      'limite_mensajes', n.limite_mensajes);

  WHEN 'pedidos' THEN
    RETURN jsonb_build_object('ok', true, 'pedidos', COALESCE((
      SELECT jsonb_agg(x ORDER BY x->>'creado_en' DESC) FROM (
        SELECT jsonb_build_object('id', p.id, 'items', p.items, 'total', p.total, 'entrega', p.entrega,
               'direccion', p.direccion, 'notas', p.notas, 'estado', p.estado,
               'creado_en', to_char(p.creado_en AT TIME ZONE n.zona_horaria, 'YYYY-MM-DD HH24:MI'),
               'cliente', cl.nombre, 'telefono', cl.telefono) AS x
          FROM pedidos p LEFT JOIN clientes cl ON cl.id = p.cliente_id
         WHERE p.negocio_id = n.id
           AND (p_datos->>'estado' IS NULL OR p.estado = p_datos->>'estado')
         ORDER BY p.creado_en DESC LIMIT 200) q), '[]'::jsonb));

  WHEN 'pedido_estado' THEN
    UPDATE pedidos SET estado = p_datos->>'estado'
     WHERE id = (p_datos->>'id')::int AND negocio_id = n.id;
    RETURN jsonb_build_object('ok', FOUND);

  WHEN 'citas' THEN
    RETURN jsonb_build_object('ok', true, 'citas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', ci.id,
               'inicio', to_char(ci.inicio AT TIME ZONE n.zona_horaria, 'YYYY-MM-DD HH24:MI'),
               'fin', to_char(ci.fin AT TIME ZONE n.zona_horaria, 'HH24:MI'),
               'servicio', ca.nombre, 'estado', ci.estado, 'notas', ci.notas,
               'cliente', cl.nombre, 'telefono', cl.telefono) ORDER BY ci.inicio)
        FROM citas ci LEFT JOIN clientes cl ON cl.id = ci.cliente_id
        LEFT JOIN catalogo ca ON ca.id = ci.servicio_id
       WHERE ci.negocio_id = n.id
         AND ci.inicio >= COALESCE((p_datos->>'desde')::date, (now() AT TIME ZONE n.zona_horaria)::date) AT TIME ZONE n.zona_horaria
         AND ci.inicio <  (COALESCE((p_datos->>'desde')::date, (now() AT TIME ZONE n.zona_horaria)::date) + 14) AT TIME ZONE n.zona_horaria
    ), '[]'::jsonb));

  WHEN 'cita_estado' THEN
    UPDATE citas SET estado = p_datos->>'estado'
     WHERE id = (p_datos->>'id')::int AND negocio_id = n.id;
    RETURN jsonb_build_object('ok', FOUND);

  WHEN 'clientes' THEN
    RETURN jsonb_build_object('ok', true, 'clientes', COALESCE((
      SELECT jsonb_agg(x) FROM (
        SELECT jsonb_build_object('id', c.id, 'nombre', c.nombre, 'telefono', c.telefono, 'notas', c.notas,
               'bot_pausado', c.bot_pausado,
               'ultimo_msg', to_char(c.ultimo_msg AT TIME ZONE n.zona_horaria, 'YYYY-MM-DD HH24:MI'),
               'pedidos', (SELECT count(*) FROM pedidos WHERE cliente_id = c.id),
               'gastado', (SELECT COALESCE(sum(total),0) FROM pedidos WHERE cliente_id = c.id AND estado <> 'cancelado'),
               'citas', (SELECT count(*) FROM citas WHERE cliente_id = c.id)) AS x
          FROM clientes c WHERE c.negocio_id = n.id
           AND (p_datos->>'buscar' IS NULL OR c.nombre ILIKE '%' || (p_datos->>'buscar') || '%'
                OR c.telefono LIKE '%' || (p_datos->>'buscar') || '%')
         ORDER BY c.bot_pausado DESC, c.ultimo_msg DESC LIMIT 300) q), '[]'::jsonb));

  WHEN 'cliente_editar' THEN
    UPDATE clientes SET
      nombre      = COALESCE(p_datos->>'nombre', nombre),
      notas       = COALESCE(p_datos->>'notas', notas),
      bot_pausado = COALESCE((p_datos->>'bot_pausado')::boolean, bot_pausado)
     WHERE id = (p_datos->>'id')::int AND negocio_id = n.id;
    RETURN jsonb_build_object('ok', FOUND);

  WHEN 'conversacion' THEN
    RETURN jsonb_build_object('ok', true, 'mensajes', COALESCE((
      SELECT jsonb_agg(x ORDER BY (x->>'id')::bigint) FROM (
        SELECT jsonb_build_object('id', m.id, 'direccion', m.direccion, 'texto', m.texto,
               'hora', to_char(m.creado_en AT TIME ZONE n.zona_horaria, 'DD/MM HH24:MI')) AS x
          FROM mensajes m WHERE m.negocio_id = n.id AND m.cliente_id = (p_datos->>'cliente_id')::int
         ORDER BY m.id DESC LIMIT 100) q), '[]'::jsonb));

  WHEN 'catalogo' THEN
    RETURN jsonb_build_object('ok', true, 'catalogo', COALESCE((
      SELECT jsonb_agg(to_jsonb(c) - 'negocio_id' ORDER BY c.categoria, c.nombre)
        FROM catalogo c WHERE c.negocio_id = n.id), '[]'::jsonb));

  WHEN 'catalogo_guardar' THEN
    IF (p_datos->>'id') IS NULL THEN
      INSERT INTO catalogo (negocio_id, categoria, nombre, descripcion, precio, duracion_min)
      VALUES (n.id, COALESCE(p_datos->>'categoria','General'), p_datos->>'nombre', p_datos->>'descripcion',
              COALESCE((p_datos->>'precio')::numeric,0), (p_datos->>'duracion_min')::int);
    ELSE
      UPDATE catalogo SET
        categoria = COALESCE(p_datos->>'categoria', categoria),
        nombre = COALESCE(p_datos->>'nombre', nombre),
        descripcion = COALESCE(p_datos->>'descripcion', descripcion),
        precio = COALESCE((p_datos->>'precio')::numeric, precio),
        activo = COALESCE((p_datos->>'activo')::boolean, activo)
       WHERE id = (p_datos->>'id')::int AND negocio_id = n.id;
    END IF;
    RETURN jsonb_build_object('ok', true);

  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'accion_desconocida');
  END CASE;
END $$;
