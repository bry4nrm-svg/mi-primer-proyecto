#!/bin/sh
# Crea la instancia de WhatsApp de un cliente nuevo en Evolution API.
# Uso:  ./nuevo-cliente-whatsapp.sh pizzeria-don-tono
# El nombre debe ser IGUAL al wa_canal_id que pusiste en la tabla negocios.
set -e
[ -z "$1" ] && echo "Uso: $0 nombre-instancia" && exit 1
. ./.env
curl -s -X POST "https://$EVOLUTION_DOMAIN/instance/create" \
  -H "apikey: $EVOLUTION_API_KEY" -H "Content-Type: application/json" \
  -d "{\"instanceName\": \"$1\", \"integration\": \"WHATSAPP-BAILEYS\", \"qrcode\": true}" > /dev/null
echo "Instancia '$1' creada. Para vincular el WhatsApp del negocio:"
echo "  1) Abre https://$EVOLUTION_DOMAIN/manager  (API key = EVOLUTION_API_KEY)"
echo "  2) Entra a la instancia '$1' y escanea el QR desde WhatsApp > Dispositivos vinculados"
