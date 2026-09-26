-- =====================================================================
--  EJEMPLO 2: PIZZERIA (da precios + toma pedidos)
-- =====================================================================
WITH nuevo AS (
  INSERT INTO negocios (nombre, tipo, plan, wa_proveedor, wa_canal_id, zona_horaria, moneda, personalidad, info)
  VALUES (
    'Pizzeria Don Tono',
    'pedidos',
    'basico',
    'evolution',
    'pizzeria-don-tono',
    'America/Mexico_City',
    'MXN',
    'Eres Tono Bot. Alegre, rapido y con buena onda 🍕. Siempre sugiere una bebida o postre si el cliente no pidio.',
    '{
      "direccion": "Calle Hidalgo 45, Puebla",
      "horario_texto": "Martes a Domingo de 1:00 pm a 11:00 pm. Lunes cerrado.",
      "envio": "Envio gratis a menos de 3 km; si no, $30. Tiempo aprox 40 min.",
      "formas_pago": ["Efectivo", "Transferencia (se envia comprobante)"],
      "promos": "Martes 2x1 en pizzas medianas."
    }'
  ) RETURNING id
)
INSERT INTO catalogo (negocio_id, categoria, nombre, descripcion, precio)
SELECT id, c.categoria, c.nombre, c.descripcion, c.precio FROM nuevo, (VALUES
  ('Pizzas',  'Pepperoni mediana',   '8 rebanadas',                      169),
  ('Pizzas',  'Pepperoni grande',    '12 rebanadas',                     219),
  ('Pizzas',  'Hawaiana mediana',    'Jamon y pina',                     179),
  ('Pizzas',  'Mexicana grande',     'Chorizo, jalapeno, cebolla',       239),
  ('Extras',  'Orilla de queso',     'Aplica a cualquier pizza',          45),
  ('Bebidas', 'Refresco 2 L',        'Coca-Cola, Sprite o Fanta',         45),
  ('Postres', 'Brownie',             'Con nuez',                          55)
) AS c(categoria, nombre, descripcion, precio);

SELECT crear_usuario_panel((SELECT id FROM negocios WHERE wa_canal_id = 'pizzeria-don-tono'),
                           'dueno@dontono.com', 'CambiaEsta123', 'Don Tono');
