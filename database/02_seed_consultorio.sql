-- =====================================================================
--  EJEMPLO 1: CONSULTORIO (agenda citas + informa servicios)
--  Copia este archivo, cambia los datos y ejecutalo para un cliente nuevo.
-- =====================================================================
WITH nuevo AS (
  INSERT INTO negocios (nombre, tipo, plan, wa_proveedor, wa_canal_id, zona_horaria, moneda,
                        personalidad, info, horario, duracion_cita_min, citas_simultaneas)
  VALUES (
    'Consultorio Dental Sonrisa',
    'citas',
    'pro',
    'evolution',
    'dental-sonrisa',              -- nombre EXACTO de la instancia en Evolution API
    'America/Mexico_City',
    'MXN',
    'Eres Sofi, la asistente del consultorio. Calida, profesional y breve. Nunca das diagnosticos medicos; si hay dolor fuerte o emergencia, sugiere llamar al consultorio.',
    '{
      "direccion": "Av. Reforma 123, Col. Centro, CDMX",
      "telefono_emergencias": "55 1234 5678",
      "google_maps": "https://maps.google.com/?q=Av+Reforma+123",
      "formas_pago": ["Efectivo", "Tarjeta", "Transferencia"],
      "estacionamiento": "Si, gratuito",
      "faqs": [
        {"p": "Aceptan seguros?", "r": "Si, GNP y AXA con reembolso."},
        {"p": "Atienden ninos?", "r": "Si, desde los 3 anos."}
      ],
      "politicas": "Cancelar con 24 h de anticipacion. Llegar 10 minutos antes."
    }',
    '{"1":["09:00","19:00"],"2":["09:00","19:00"],"3":["09:00","19:00"],"4":["09:00","19:00"],"5":["09:00","17:00"],"6":["09:00","13:00"]}',
    30,
    1
  ) RETURNING id
)
INSERT INTO catalogo (negocio_id, categoria, nombre, descripcion, precio, duracion_min)
SELECT id, c.categoria, c.nombre, c.descripcion, c.precio, c.duracion FROM nuevo, (VALUES
  ('Consultas',   'Consulta de valoracion', 'Revision general y plan de tratamiento', 350, 30),
  ('Limpieza',    'Limpieza dental',        'Profilaxis con ultrasonido',             700, 60),
  ('Estetica',    'Blanqueamiento',         'Blanqueamiento en consultorio',         3500, 90),
  ('Tratamientos','Resina',                 'Curacion con resina estetica por pieza', 900, 60)
) AS c(categoria, nombre, descripcion, precio, duracion);

-- Usuario del panel para el dueno (cambia correo y contrasena)
SELECT crear_usuario_panel((SELECT id FROM negocios WHERE wa_canal_id = 'dental-sonrisa'),
                           'dra@dentalsonrisa.com', 'CambiaEsta123', 'Dra. Laura');
