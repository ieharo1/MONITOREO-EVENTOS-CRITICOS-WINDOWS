# Monitoreo de Eventos Criticos Windows - Documentacion Operativa

Script principal: `windows-critical-events-monitor.ps1`

## Objetivo
Extraer eventos de nivel Error/Critical de `Application` y `System` en las ultimas 24h, persistir en SQL y enviar resumen diario.

## Funcionamiento
1. Valida disponibilidad de `Get-WinEvent`.
2. Consulta logs de Windows segun `LookbackHours`.
3. Filtra niveles 1 (Critical) y 2 (Error).
4. Inserta eventos en SQL (`dbo.WindowsEventAudit`).
5. Genera resumen por proveedor de eventos.
6. Envia resumen diario o alerta de fallo.

## Prerequisitos
- Windows Server 2019/2022
- Permisos de lectura de Event Logs
- SQL Server disponible
- SMTP y Telegram activos

## Configuracion
- `LookbackHours`
- `LogsToQuery`
- `Sql.Server`, `Sql.Database`, `Sql.Table`
- `Notification.Mail.*`
- `Notification.Telegram.*`

## Variables de entorno
- `AUTOMATION_SQL_PASSWORD` (si SQL auth)
- `AUTOMATION_SMTP_PASSWORD`
- `AUTOMATION_TELEGRAM_BOT_TOKEN`
- `AUTOMATION_TELEGRAM_CHAT_ID`

## Estructura SQL esperada (referencia)
Tabla: `dbo.WindowsEventAudit`
Campos sugeridos:
- `ServerName`
- `LogName`
- `EventId`
- `LevelDisplayName`
- `ProviderName`
- `MessageText`
- `TimeCreated`

## Como ejecutar

```powershell
cd C:\Users\Nabetse\Downloads\server\Bot-Zoom
.\windows-critical-events-monitor.ps1
```

## Programacion recomendada
- Trigger: diario (ejemplo 23:50)
- Cuenta con permisos de lectura sobre Event Logs y escritura SQL

## Seguridad
- Limitar acceso a mensajes de evento si contienen datos sensibles
- No almacenar secretos en el script
- Rotar credenciales periodicamente
---
## ‍ Desarrollado por Isaac Esteban Haro Torres
**Ingeniero en Sistemas · Full Stack · Automatización · Data**
-  Email: zackharo1@gmail.com
-  WhatsApp: 098805517
-  GitHub: https://github.com/ieharo1
-  Portafolio: https://ieharo1.github.io/portafolio-isaac.haro/
---
##  Licencia
© 2026 Isaac Esteban Haro Torres - Todos los derechos reservados.
