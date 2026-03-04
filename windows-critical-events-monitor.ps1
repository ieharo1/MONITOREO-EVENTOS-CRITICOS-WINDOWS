# ===============================================================
# windows-critical-events-monitor.ps1
# Monitoreo de errores/críticos de Event Viewer con persistencia SQL
# ===============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ================= CONFIG =================
$Config = @{
    ScriptName = 'Windows-Critical-Events-Monitor'
    LogRoot = 'C:\Scripts\Logs\Windows-Critical-Events'
    LookbackHours = 24
    LogsToQuery = @('Application','System')
    Sql = @{ Enabled = $true; Server = 'SQLSERVER01'; Database = 'AutomationDB'; Table = 'dbo.WindowsEventAudit'; UseIntegratedSecurity = $true; SqlUser = 'sql_user_placeholder'; SqlPasswordEnvVar = 'AUTOMATION_SQL_PASSWORD'; CommandTimeoutSeconds = 60 }
    Notification = @{
        Mail = @{ Enabled = $true; SmtpServer = 'smtp.company.local'; Port = 587; UseSsl = $true; User = 'smtp_user_placeholder'; PasswordEnvVar = 'AUTOMATION_SMTP_PASSWORD'; From = 'automation@company.local'; To = @('ops@company.local') }
        Telegram = @{ Enabled = $true; BotTokenEnvVar = 'AUTOMATION_TELEGRAM_BOT_TOKEN'; ChatIdEnvVar = 'AUTOMATION_TELEGRAM_CHAT_ID' }
    }
}

# ================= LOG =================
if (-not (Test-Path -Path $Config.LogRoot)) { New-Item -Path $Config.LogRoot -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $Config.LogRoot ('{0}-{1:yyyyMMdd}.log' -f $Config.ScriptName, (Get-Date))

function Log {
    param([Parameter(Mandatory)] [string]$Message, [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO', [hashtable]$Data)
    $entry = [ordered]@{ timestamp=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); level=$Level; script=$Config.ScriptName; host=$env:COMPUTERNAME; message=$Message; data=$Data }
    Add-Content -Path $LogFile -Value ($entry | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8
    Write-Host ('[{0}] {1}' -f $Level, $Message)
}

function Send-Mail {
    param([Parameter(Mandatory)] [string]$Subject, [Parameter(Mandatory)] [string]$Body)
    if (-not $Config.Notification.Mail.Enabled) { return }
    try {
        $pwd = [Environment]::GetEnvironmentVariable($Config.Notification.Mail.PasswordEnvVar, 'Machine')
        if ([string]::IsNullOrWhiteSpace($pwd)) { $pwd = [Environment]::GetEnvironmentVariable($Config.Notification.Mail.PasswordEnvVar, 'Process') }
        if ([string]::IsNullOrWhiteSpace($pwd)) { throw "No existe variable '$($Config.Notification.Mail.PasswordEnvVar)'" }
        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $Config.Notification.Mail.From
        foreach ($recipient in $Config.Notification.Mail.To) { [void]$mail.To.Add($recipient) }
        $mail.Subject = $Subject
        $mail.Body = $Body
        $smtp = New-Object System.Net.Mail.SmtpClient($Config.Notification.Mail.SmtpServer, $Config.Notification.Mail.Port)
        $smtp.EnableSsl = $Config.Notification.Mail.UseSsl
        $smtp.Credentials = New-Object System.Net.NetworkCredential($Config.Notification.Mail.User, $pwd)
        $smtp.Send($mail)
        $mail.Dispose(); $smtp.Dispose()
        Log -Message 'Notificación SMTP enviada.'
    }
    catch { Log -Message "Error SMTP: $($_.Exception.Message)" -Level 'ERROR' }
}

function Send-Telegram {
    param([Parameter(Mandatory)] [string]$Message)
    if (-not $Config.Notification.Telegram.Enabled) { return }
    try {
        $bot = [Environment]::GetEnvironmentVariable($Config.Notification.Telegram.BotTokenEnvVar, 'Machine')
        $chat = [Environment]::GetEnvironmentVariable($Config.Notification.Telegram.ChatIdEnvVar, 'Machine')
        if ([string]::IsNullOrWhiteSpace($bot)) { $bot = [Environment]::GetEnvironmentVariable($Config.Notification.Telegram.BotTokenEnvVar, 'Process') }
        if ([string]::IsNullOrWhiteSpace($chat)) { $chat = [Environment]::GetEnvironmentVariable($Config.Notification.Telegram.ChatIdEnvVar, 'Process') }
        if ([string]::IsNullOrWhiteSpace($bot) -or [string]::IsNullOrWhiteSpace($chat)) { throw 'Faltan credenciales Telegram.' }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $bot) -Method Post -Body @{ chat_id=$chat; text=$Message } | Out-Null
        Log -Message 'Notificación Telegram enviada.'
    }
    catch { Log -Message "Error Telegram: $($_.Exception.Message)" -Level 'ERROR' }
}

function New-SqlConnection {
    if (-not $Config.Sql.Enabled) { return $null }
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $Config.Sql.Server
    $builder['Initial Catalog'] = $Config.Sql.Database
    if ($Config.Sql.UseIntegratedSecurity) {
        $builder['Integrated Security'] = $true
    }
    else {
        $pwd = [Environment]::GetEnvironmentVariable($Config.Sql.SqlPasswordEnvVar, 'Machine')
        if ([string]::IsNullOrWhiteSpace($pwd)) { $pwd = [Environment]::GetEnvironmentVariable($Config.Sql.SqlPasswordEnvVar, 'Process') }
        if ([string]::IsNullOrWhiteSpace($pwd)) { throw "No existe variable '$($Config.Sql.SqlPasswordEnvVar)'" }
        $builder['User ID'] = $Config.Sql.SqlUser
        $builder['Password'] = $pwd
    }
    $cn = New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
    $cn.Open()
    return $cn
}

function Test-Prerequisites {
    if (-not (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue)) { throw 'Get-WinEvent no está disponible.' }
}

$errorsList = New-Object System.Collections.Generic.List[string]
$sqlConnection = $null
$eventResults = @()

Log -Message '=== INICIO WINDOWS CRITICAL EVENTS MONITOR ==='

try {
    Test-Prerequisites
    $startTime = (Get-Date).AddHours(-1 * [math]::Abs($Config.LookbackHours))
    foreach ($logName in $Config.LogsToQuery) {
        $filter = @{ LogName = $logName; StartTime = $startTime; Level = 1,2 }
        $eventResults += Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
    }

    $sqlConnection = New-SqlConnection
    if ($Config.Sql.Enabled -and $null -ne $sqlConnection) {
        foreach ($event in $eventResults) {
            $cmd = $sqlConnection.CreateCommand()
            $cmd.CommandText = "INSERT INTO $($Config.Sql.Table) (ServerName, LogName, EventId, LevelDisplayName, ProviderName, MessageText, TimeCreated) VALUES (@ServerName, @LogName, @EventId, @LevelDisplayName, @ProviderName, @MessageText, @TimeCreated)"
            [void]$cmd.Parameters.Add('@ServerName', [System.Data.SqlDbType]::VarChar, 64)
            [void]$cmd.Parameters.Add('@LogName', [System.Data.SqlDbType]::VarChar, 64)
            [void]$cmd.Parameters.Add('@EventId', [System.Data.SqlDbType]::Int)
            [void]$cmd.Parameters.Add('@LevelDisplayName', [System.Data.SqlDbType]::VarChar, 32)
            [void]$cmd.Parameters.Add('@ProviderName', [System.Data.SqlDbType]::VarChar, 256)
            [void]$cmd.Parameters.Add('@MessageText', [System.Data.SqlDbType]::NVarChar, -1)
            [void]$cmd.Parameters.Add('@TimeCreated', [System.Data.SqlDbType]::DateTime)
            $cmd.Parameters['@ServerName'].Value = $env:COMPUTERNAME
            $cmd.Parameters['@LogName'].Value = [string]$event.LogName
            $cmd.Parameters['@EventId'].Value = [int]$event.Id
            $cmd.Parameters['@LevelDisplayName'].Value = [string]$event.LevelDisplayName
            $cmd.Parameters['@ProviderName'].Value = [string]$event.ProviderName
            $cmd.Parameters['@MessageText'].Value = [string]$event.Message
            $cmd.Parameters['@TimeCreated'].Value = [datetime]$event.TimeCreated
            [void]$cmd.ExecuteNonQuery()
            $cmd.Dispose()
        }
    }
}
catch {
    $errorsList.Add($_.Exception.Message)
    Log -Message "Error general: $($_.Exception.Message)" -Level 'ERROR'
}
finally {
    if ($null -ne $sqlConnection) {
        if ($sqlConnection.State -eq [System.Data.ConnectionState]::Open) { $sqlConnection.Close() }
        $sqlConnection.Dispose()
    }
}

# ================= NOTIFICACION FINAL =================
$summary = $eventResults | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 5
$summaryText = ($summary | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Count }) -join "`n"

if ($errorsList.Count -gt 0) {
    $msg = "Windows Critical Events Monitor ($env:COMPUTERNAME)`n" + ($errorsList -join "`n")
    Send-Mail -Subject "ERROR Windows Events Monitor - $env:COMPUTERNAME" -Body $msg
    Send-Telegram -Message $msg
}
else {
    $msg = "Resumen 24h $env:COMPUTERNAME`nTotal eventos: $($eventResults.Count)`nTop orígenes:`n$summaryText"
    Send-Mail -Subject "Resumen Windows Events - $env:COMPUTERNAME" -Body $msg
    Send-Telegram -Message $msg
}

Log -Message '=== FIN WINDOWS CRITICAL EVENTS MONITOR ==='

# ---
# ## ‍ Desarrollado por Isaac Esteban Haro Torres
# **Ingeniero en Sistemas · Full Stack · Automatización · Data**
# -  Email: zackharo1@gmail.com
# -  WhatsApp: 098805517
# -  GitHub: https://github.com/ieharo1
# -  Portafolio: https://ieharo1.github.io/portafolio-isaac.haro/
# ---
# ##  Licencia
# © 2026 Isaac Esteban Haro Torres - Todos los derechos reservados.
