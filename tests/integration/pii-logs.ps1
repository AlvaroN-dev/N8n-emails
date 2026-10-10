<#
.SYNOPSIS
    T19: comprueba que los LOGS de la API, n8n y PostgreSQL no contienen datos personales ni secretos.

.DESCRIPTION
    Busca en los logs de los contenedores (1) los datos personales SINTETICOS que usan las suites de integracion
    (correos, telefono, asuntos y fragmentos de mensajes de tickets) y (2) los valores reales de los secretos de .env.
    Solo imprime recuentos, nunca el contenido de las lineas. Para que el resultado tenga valor, ejecutalo DESPUES de
    las suites de integracion (que generan trafico con esos datos): informa cuantas lineas de log se analizaron.
    Mailpit se excluye a proposito: es el buzon de pruebas y SU CONTENIDO son los correos.
    El historial de EJECUCIONES de n8n (base de datos) SI guarda los payloads: se comprueba que existe retencion finita.

.EXAMPLE
    .\tests\integration\pii-logs.ps1
#>
[CmdletBinding()]
param([int]$MinLines = 200)

. "$PSScriptRoot\lib.ps1"

# Datos personales sinteticos usados por las suites (si aparecen en un log, es una fuga)
$piiNeedles = [ordered]@{
    'correo ana.test@example.com'             = 'ana.test@example.com'
    'correo cliente.prueba@example.com'       = 'cliente.prueba@example.com'
    'correo cliente.sintetico@example.com'    = 'cliente.sintetico@example.com'
    'correo maria.privada@example.com'        = 'maria.privada@example.com'
    'correo ana.private@example.com'          = 'ana.private@example.com'
    'correo smoke.test@example.com'           = 'smoke.test@example.com'
    'correos wf3.privado.*'                   = 'wf3.privado.'
    'telefono +34 612 345 678'                = '612 345 678'
    'mensaje "No puedo iniciar sesion desde"' = 'No puedo iniciar sesion desde'
    'mensaje "No puedo pagar mi factura"'     = 'No puedo pagar mi factura'
    'mensaje "Mi correo es"'                  = 'Mi correo es'
    'asunto "Problema con el pago"'           = 'Problema con el pago'
    'asunto "Fallo de prueba WF3"'            = 'Fallo de prueba WF3'
    'asunto "Cobro duplicado"'                = 'Cobro duplicado'
}
# Valores reales de los secretos de .env
$secretNeedles = [ordered]@{}
foreach ($k in $script:EnvVars.Keys) {
    if ($k -match '(KEY|TOKEN|PASSWORD|SECRET)' -and $script:EnvVars[$k].Length -ge 16) { $secretNeedles["secreto $k"] = $script:EnvVars[$k] }
}

# Devuelve "<nombre>: N lineas" por cada aguja que aparece en $Lines (nunca el contenido de las lineas).
function Get-Leaks($Lines, $Needles) {
    $found = @()
    foreach ($name in $Needles.Keys) {
        $n = @($Lines | Where-Object { $_.Contains($Needles[$name]) }).Count
        if ($n -gt 0) { $found += ("{0}: {1} lineas" -f $name, $n) }
    }
    return $found
}
function Get-LogLines([string[]]$DockerArgs) {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $log = (& docker @DockerArgs 2>&1 | Out-String) } finally { $ErrorActionPreference = $previous }
    return @($log -split "`r?`n" | Where-Object { $_.Length -gt 0 })
}

Write-Host '== T19 - PII y secretos en los logs'

# CONTROL POSITIVO: un contenedor desechable imprime datos personales conocidos; el detector DEBE encontrarlos.
$previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try {
    & docker rm -f tt-pii-control 2>&1 | Out-Null
    # Sin comillas dobles dentro del argumento: PowerShell 5.1 las elimina al invocar un .exe y el contenedor imprimiria solo "cliente".
    & docker run --name tt-pii-control --entrypoint sh postgres:17-alpine -c 'echo cliente ana.test@example.com tel 612 345 678' 2>&1 | Out-Null
}
finally { $ErrorActionPreference = $previous }
$controlLeaks = Get-Leaks (Get-LogLines @('logs', 'tt-pii-control')) $piiNeedles
$previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { & docker rm -f tt-pii-control 2>&1 | Out-Null } finally { $ErrorActionPreference = $previous }
Assert-That 'T19' 'control positivo: el detector SI encuentra correo y telefono en un log que los contiene' ($controlLeaks.Count -ge 2) ($controlLeaks -join ' | ')

$services = @('api', 'n8n', 'postgres')
foreach ($svc in $services) {
    $lines = Get-LogLines @('compose', 'logs', $svc, '--no-color')
    Assert-That 'T19' ("logs de '$svc': {0} lineas analizadas (minimo {1} para que la prueba tenga valor)" -f $lines.Count, $MinLines) ($lines.Count -ge $MinLines) 'ejecuta antes las suites de integracion'
    $leaks = @(Get-Leaks $lines $piiNeedles)
    Assert-That 'T19' "logs de '$svc': 0 lineas con datos personales de los tickets" ($leaks.Count -eq 0) ($leaks -join ' | ')
    $sleaks = @(Get-Leaks $lines $secretNeedles)
    Assert-That 'T19' "logs de '$svc': 0 lineas con secretos de .env" ($sleaks.Count -eq 0) ($sleaks -join ' | ')
}

# Retencion del historial de n8n (los payloads se guardan alli): debe ser finita
$prune = (& docker compose exec -T n8n sh -c 'echo "$EXECUTIONS_DATA_PRUNE:$EXECUTIONS_DATA_MAX_AGE"') -join ''
Assert-That 'T19' "el historial de ejecuciones de n8n (contiene los payloads) tiene retencion finita ($($prune.Trim()))" ($prune.Trim() -match '^true:[0-9]+$') $prune

$failed = Write-Summary
exit ([int]($failed -gt 0))
