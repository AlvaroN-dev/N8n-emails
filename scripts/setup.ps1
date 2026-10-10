<#
.SYNOPSIS
    Crea o completa el archivo .env a partir de .env.example con secretos aleatorios.

.DESCRIPTION
    - Si .env NO existe: lo crea. Cada linea "VARIABLE=CHANGE_ME" se reemplaza por un secreto
      aleatorio criptograficamente seguro (32 bytes, 64 caracteres hexadecimales).
    - Si .env YA existe: no modifica ningun valor existente. Solo ANADE las variables nuevas de
      .env.example que falten (por ejemplo, tras actualizar el proyecto). Regenerar
      N8N_ENCRYPTION_KEY haria que las credenciales guardadas en n8n dejaran de descifrarse.

.PARAMETER Force
    Regenera .env completo. El .env anterior se guarda como .env.bak-<fecha> para no perder
    la clave de cifrado.

.EXAMPLE
    .\scripts\setup.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force,
    # Archivo de entorno a crear/completar, relativo a la raiz del proyecto (por defecto .env).
    [string]$EnvFile = '.env'
)

$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$example = Join-Path $root '.env.example'
$target  = Join-Path $root $EnvFile

if (-not (Test-Path -LiteralPath $example)) {
    throw "No se encuentra $example"
}

function New-HexSecret {
    param([int]$Bytes = 32)
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    return (($buffer | ForEach-Object { $_.ToString('x2') }) -join '')
}

# UTF-8 sin BOM y finales de linea LF (un BOM puede corromper la primera variable en Docker Compose).
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$generated = New-Object System.Collections.Generic.List[string]

function ConvertTo-EnvLine {
    param([string]$Line)
    if ($Line -match '^([A-Z][A-Z0-9_]*)=CHANGE_ME\s*$') {
        $generated.Add($Matches[1])
        return ('{0}={1}' -f $Matches[1], (New-HexSecret))
    }
    return $Line
}

$exampleLines = [System.IO.File]::ReadAllLines($example, $utf8NoBom)

# --- Modo "completar": .env existe y no se pidio -Force ---------------------------------
if ((Test-Path -LiteralPath $target) -and -not $Force) {
    $currentLines = [System.IO.File]::ReadAllLines($target, $utf8NoBom)
    $existingKeys = @{}
    foreach ($l in $currentLines) {
        if ($l -match '^([A-Z][A-Z0-9_]*)=') { $existingKeys[$Matches[1]] = $true }
    }

    $toAppend = New-Object System.Collections.Generic.List[string]
    $pendingComments = New-Object System.Collections.Generic.List[string]
    foreach ($l in $exampleLines) {
        if ($l -match '^([A-Z][A-Z0-9_]*)=') {
            if (-not $existingKeys.ContainsKey($Matches[1])) {
                foreach ($c in $pendingComments) { $toAppend.Add($c) }
                $toAppend.Add((ConvertTo-EnvLine $l))
            }
            $pendingComments.Clear()
        }
        elseif ($l -match '^\s*#') { $pendingComments.Add($l) }
        else { $pendingComments.Clear() }
    }

    if ($toAppend.Count -eq 0) {
        Write-Host ".env ya contiene todas las variables de .env.example: no se modifica nada."
        Write-Host "(Usa -Force solo si quieres regenerarlo por completo; se guardaria una copia .env.bak-<fecha>.)"
        return
    }

    $addition = "`n# --- Anadido por setup.ps1 el $(Get-Date -Format 'yyyy-MM-dd') ---`n" + ($toAppend -join "`n") + "`n"
    $current  = [System.IO.File]::ReadAllText($target, $utf8NoBom)
    if (-not $current.EndsWith("`n")) { $current += "`n" }
    [System.IO.File]::WriteAllText($target, $current + $addition, $utf8NoBom)

    Write-Host ".env completado (los valores existentes NO se tocaron)."
    Write-Host "Variables anadidas: $((($toAppend | Where-Object { $_ -match '^[A-Z]' }) | ForEach-Object { ($_ -split '=',2)[0] }) -join ', ')"
    if ($generated.Count -gt 0) { Write-Host "Secretos generados (valores NO mostrados): $($generated -join ', ')" }
    return
}

# --- Modo "crear" (o regenerar con -Force) -----------------------------------------------
if (Test-Path -LiteralPath $target) {
    $backup = "$target.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $target -Destination $backup
    Write-Host "Copia del .env anterior: $backup"
    Write-Host "AVISO: se regenera N8N_ENCRYPTION_KEY; las credenciales ya guardadas en n8n dejaran de funcionar."
}

$output = foreach ($line in $exampleLines) { ConvertTo-EnvLine $line }
[System.IO.File]::WriteAllText($target, (($output -join "`n") + "`n"), $utf8NoBom)

Write-Host ".env creado en: $target"
Write-Host "Secretos generados (valores NO mostrados): $($generated -join ', ')"
Write-Host "Recuerda: .env esta en .gitignore y no debe subirse a Git. Guarda una copia de N8N_ENCRYPTION_KEY."
