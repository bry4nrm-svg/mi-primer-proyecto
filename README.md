# 🤖 Chatbot Madre: chats inteligentes por WhatsApp para negocios

Una sola instalación atiende a **todos tus clientes**. Para dar de alta un negocio nuevo **no tocas el flujo**: solo insertas sus datos en la base de datos (nombre, catálogo, horario, WhatsApp) y listo.

- 🦷 **Consultorio** → informa servicios y **agenda citas** (valida horarios libres, cancela, sincroniza con Google Calendar).
- 🍕 **Pizzería** → da precios y **toma pedidos** (el total lo calcula la BD, la IA no puede inventar precios).
- 📊 **Panel web para el dueño**: pedidos en vivo (con sonido), agenda, clientes, historial de chats, pausar el bot para atender en persona, editar precios.

---

## 🧱 Cómo funciona

```
WhatsApp del cliente
      │
      ▼
Evolution API (o Meta Cloud API) ──webhook──►  n8n: "Chatbot Madre"
                                               1. Normaliza el mensaje
                                               2. fn_contexto(): ¿qué negocio es? ¿quién escribe? ¿responder?
                                               3. Arma el prompt con los datos del negocio
                                               4. Agente IA (Claude) + memoria + herramientas:
                                                  ver_disponibilidad · agendar_cita · mis_citas
                                                  cancelar_cita · crear_pedido · pedir_humano
                                               5. Responde por WhatsApp y guarda el mensaje
                                                      │
Panel web (panel.tudominio.com) ◄──── n8n: "API del Panel" ──► Postgres (fn_panel)
```

**La clave:** toda la lógica vive en funciones de Postgres (`database/01_schema.sql`). n8n solo las llama. Así el flujo queda simple y cada negocio es solo "datos".

| Carpeta | Qué tiene |
|---|---|
| `database/01_schema.sql` | Tablas + funciones (bot y panel). Probado en Postgres 16. |
| `database/02_seed_consultorio.sql` | Ejemplo completo de consultorio (plantilla para copiar). |
| `database/03_seed_pizzeria.sql` | Ejemplo completo de pizzería. |
| `n8n/1-chatbot-madre.json` | Flujo principal (importar en n8n). |
| `n8n/2-panel-api.json` | API que usa el panel. |
| `n8n/3-sync-google-calendar.json` | Opcional: copia las citas al Google Calendar del negocio. |
| `panel/index.html` | Panel para tus clientes (un solo archivo, funciona en celular). |
| `infra/` | Docker Compose con n8n + Postgres + Evolution API + HTTPS automático. |
| `tools/generar_workflows.py` | Regenera los JSON de n8n si editas el código. |

---

## ☁️ Dónde alojarlo (lo más rentable)

**Recomendación: un VPS en Hetzner (CX22 / CX23: 2 vCPU, 4 GB RAM, ~5 €/mes).** Con esta instalación aguanta cómodo **20–40 negocios** pequeños, porque el trabajo pesado (la IA) lo hace la API de Claude, no tu servidor.

| Opción | Precio aprox. | Veredicto |
|---|---|---|
| **Hetzner Cloud** | ~5 €/mes (+20 % con backups) | ✅ La mejor relación precio/potencia. Empieza aquí. |
| Hostinger VPS KVM 2 | ~7–9 USD/mes | ✅ Buena si prefieres pagar en tu moneda/soporte en español. |
| DigitalOcean | ~24 USD/mes (4 GB) | 👍 Fácil, pero más caro. |
| AWS (EC2 / Lightsail) | 20–40 USD/mes + transferencia | ❌ Para empezar no: más caro y más complejo. Tiene sentido con 100+ clientes. |
| n8n Cloud | desde ~24 USD/mes | ❌ Te limita ejecuciones y no puedes correr Evolution API ni Postgres ahí. |

Cuando crezcas: un segundo VPS o subir a CX32 (8 GB). Solo migras el volumen de Postgres.

---

## 🚀 Instalación (una sola vez, ~30 min)

1. **Compra el VPS** (Ubuntu 24.04) y un dominio. Crea 3 registros DNS tipo **A** apuntando a la IP del VPS:
   `n8n.tudominio.com`, `wa.tudominio.com`, `panel.tudominio.com`.
2. **Instala Docker** en el VPS:
   ```bash
   curl -fsSL https://get.docker.com | sh
   git clone <este-repo> chatbot && cd chatbot/infra
   cp .env.example .env && nano .env      # pon tus dominios y genera secretos con: openssl rand -hex 24
   docker compose up -d
   ```
   Esto crea las BD `n8n`, `evolution` y `chatbot` (con el esquema ya cargado) y saca los certificados HTTPS solo.
3. **Entra a n8n** (`https://n8n.tudominio.com`), crea tu usuario y agrega 2 credenciales:
   - **Postgres** llamada `Postgres Chatbot` → host `postgres`, BD `chatbot`, usuario/contraseña del `.env`.
   - **Anthropic** → tu API key de https://console.anthropic.com
4. **Importa los flujos** (menú ⋯ → *Import from file*): `1-chatbot-madre.json` y `2-panel-api.json`. En cada nodo con credencial roja, elige la que creaste. **Activa** ambos flujos.
5. Listo. El webhook de Evolution ya apunta a n8n (configurado en el compose de forma global para todas las instancias).

---

## ➕ Dar de alta un negocio nuevo (~10 min)

1. Copia `database/02_seed_consultorio.sql` o `03_seed_pizzeria.sql`, cambia los datos y ejecútalo:
   ```bash
   docker compose exec -T postgres psql -U chatbot -d chatbot < mi_cliente.sql
   ```
   Lo que cambias por negocio:
   | Campo | Para qué |
   |---|---|
   | `tipo` | `citas`, `pedidos`, `ambos` o `info` (solo responde dudas) |
   | `wa_canal_id` | Nombre de la instancia de Evolution (ej. `pizzeria-don-tono`) |
   | `personalidad` | Nombre y tono del bot ("Eres Sofi, cálida y profesional...") |
   | `info` | JSON libre: dirección, pagos, envíos, FAQs, promos. Todo lo que pongas, la IA lo sabe. |
   | `horario`, `duracion_cita_min`, `citas_simultaneas` | Agenda (1 = lunes ... 7 = domingo) |
   | `catalogo` | Servicios o productos con precio |
   | `plan`, `limite_mensajes`, `modelo_ia` | Lo que le vendiste |
   | `crear_usuario_panel(...)` | Correo y contraseña del dueño para el panel |
2. Conecta su WhatsApp:
   ```bash
   cd infra && ./nuevo-cliente-whatsapp.sh pizzeria-don-tono
   ```
   Abre `https://wa.tudominio.com/manager`, entra a la instancia y **escanea el QR** con el WhatsApp del negocio.
3. (Opcional) **Agenda de Google:** el negocio comparte su Google Calendar con tu cuenta de Google (permiso "hacer cambios"), pones su ID en `negocios.google_calendar_id` e importas/activas `3-sync-google-calendar.json` (una sola vez para todos).
4. Mándale el panel: `https://panel.tudominio.com` + su correo/contraseña.

Para **apagar** a un cliente que no pagó: `UPDATE negocios SET activo = false WHERE id = X;`

---

## 💬 WhatsApp: Evolution API vs Meta oficial

| | Evolution API (incluida) | Meta Cloud API (oficial) |
|---|---|---|
| Alta | Escanear QR, 1 minuto | Verificar negocio en Meta, días |
| Costo | Gratis | Responder a clientes es gratis; plantillas/marketing se cobran |
| Riesgo | ⚠️ No oficial: WhatsApp puede **bloquear el número** si detecta abuso (spam, mensajes masivos) | Ninguno |
| Recomendado para | Negocios chicos, empezar rápido | Clientes grandes o que no pueden arriesgar su número |

El flujo soporta **ambos**. Para Meta: `wa_proveedor = 'meta'`, `wa_canal_id = phone_number_id`, `wa_token = access token`, y en Meta configura el webhook `https://n8n.tudominio.com/webhook/whatsapp` con tu `META_VERIFY_TOKEN`.

---

## 💰 Costos de IA y cómo cobrar

Cada mensaje del cliente = ~1–3 llamadas al modelo (por las herramientas). Estimado **por mensaje respondido** (~8 k tokens de entrada, ~400 de salida):

| Modelo (`negocios.modelo_ia`) | Precio API (entrada / salida por millón) | ≈ por mensaje | ≈ 1,000 mensajes |
|---|---|---|---|
| `claude-opus-5` (default) | $5 / $25 USD | ~$0.05 USD | ~$50 USD |
| `claude-sonnet-5` | $2 / $10 USD | ~$0.02 USD | ~$20 USD |
| `claude-haiku-4-5` | $1 / $5 USD | ~$0.01 USD | ~$10 USD |

El modelo se elige **por negocio**, así que puedes armar planes. Idea de precios (ajústalos a tu mercado):

| Plan | Incluye | Precio sugerido |
|---|---|---|
| Básico | Solo info/FAQ, 1,000 mensajes, Haiku | $990 MXN/mes |
| Pro | Citas **o** pedidos + panel, 3,000 mensajes, Sonnet | $1,990 MXN/mes |
| Premium | Todo + Google Calendar + Opus + soporte prioritario | $3,490 MXN/mes |
| Instalación | Carga de catálogo, personalidad, pruebas | $2,500–5,000 MXN (pago único) |

Con 20 clientes Pro: ~$39,800 MXN/mes de ingreso vs ~$100 USD servidor + IA. `limite_mensajes` evita que un cliente te dispare la factura (el bot deja de contestar al llegar al tope; el panel muestra el consumo).

---

## 🛡️ Qué ya está resuelto

- **Multi-negocio real:** cada consulta del panel y cada herramienta del bot va amarrada al `negocio_id`; un dueño no puede ver datos de otro.
- **Precios blindados:** `crear_pedido` recalcula todo con el catálogo; la IA solo manda ids y cantidades.
- **Sin choques de citas:** `agendar_cita` vuelve a revisar disponibilidad antes de guardar.
- **Humano al rescate:** si el cliente lo pide, o si el dueño contesta desde su celular, el bot se pausa para ese cliente. Se reactiva desde el panel.
- **Anti-duplicados:** si WhatsApp reenvía el mismo mensaje, no se contesta dos veces.
- **Audios/imágenes:** el bot pide amablemente que escriban en texto.
- **Contraseñas del panel** encriptadas (bcrypt), sesiones de 30 días.

## 🧩 Pendientes / siguientes mejoras (ideas para vender más)

- Transcribir audios (Whisper u otro servicio) antes de mandarlos a la IA.
- Recordatorio automático de cita 24 h antes (flujo con Schedule + plantilla).
- Aviso al dueño por WhatsApp cuando entra un pedido o alguien pide humano.
- Cancelar en Google Calendar cuando la cita se cancela (hoy solo crea eventos).
- Panel de "súper admin" para ti (ver todos los negocios y su consumo).

## 🔧 Problemas comunes

| Síntoma | Solución |
|---|---|
| El bot no contesta | En n8n → *Executions*. Si no hay ejecuciones: revisa que el flujo esté **activo** y que la instancia esté conectada. Si `motivo = negocio_no_encontrado`: el `wa_canal_id` no coincide con el nombre de la instancia. |
| Error de Anthropic sobre `temperature`/parámetros | Actualiza n8n (`docker compose pull && docker compose up -d`) o usa `claude-haiku-4-5` en ese negocio. |
| `$env` bloqueado | Revisa `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` en el compose. |
| El panel dice "sesión expirada" | Vuelve a entrar; o revisa que el flujo *API del Panel* esté activo. |
| Cambié el código de los flujos | Edita `tools/generar_workflows.py` → `python3 tools/generar_workflows.py` → vuelve a importar. |
