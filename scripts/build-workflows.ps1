<#
.SYNOPSIS
    Genera n8n/workflows/*.json a partir del codigo de n8n/src (workflows como codigo).

.DESCRIPTION
    Ejecuta el builder dentro de la imagen de n8n fijada en docker-compose.yml (misma version de Node
    que en ejecucion; no hace falta Node en el equipo).

.PARAMETER Check
    No escribe nada: falla con codigo 1 si algun JSON difiere de lo que generaria el codigo.

.EXAMPLE
    .\scripts\build-workflows.ps1
    .\scripts\build-workflows.ps1 -Check
#>
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$compose = [System.IO.File]::ReadAllText((Join-Path $root 'docker-compose.yml'))
if ($compose -notmatch '(?m)^\s*image:\s*(n8nio/n8n:\S+)') { throw 'No se encuentra la imagen de n8n en docker-compose.yml' }
$image = $Matches[1]

$nodeArgs = @('src/build.js')
if ($Check) { $nodeArgs += '--check' }

docker run --rm -v "$($root)\n8n:/work" -w /work --entrypoint node $image @nodeArgs
exit $LASTEXITCODE
