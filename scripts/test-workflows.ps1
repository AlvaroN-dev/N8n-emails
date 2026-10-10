<#
.SYNOPSIS
    Pruebas del codigo de los workflows: tests unitarios de los nodos Code + comprobacion de que los
    JSON versionados estan al dia respecto al codigo.

.EXAMPLE
    .\scripts\test-workflows.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$compose = [System.IO.File]::ReadAllText((Join-Path $root 'docker-compose.yml'))
if ($compose -notmatch '(?m)^\s*image:\s*(n8nio/n8n:\S+)') { throw 'No se encuentra la imagen de n8n en docker-compose.yml' }
$image = $Matches[1]

# La salida de docker va directa a la consola (Out-Host): si se devolviera por el pipeline se mezclaria
# con el codigo de salida que devuelve la funcion.
function Invoke-InImage {
    param([string[]]$NodeArgs)
    docker run --rm -v "$($root)\n8n:/work" -w /work --entrypoint node $image @NodeArgs | Out-Host
    $script:lastExit = $LASTEXITCODE
}

Write-Host '== 1/2 JSON versionados al dia respecto al codigo'
Invoke-InImage @('src/build.js', '--check')
$drift = $script:lastExit

Write-Host '== 2/2 Tests unitarios de los nodos Code (node --test)'
Invoke-InImage @('--test', 'tests/*.test.js')
$tests = $script:lastExit

if ($drift -ne 0 -or $tests -ne 0) {
    Write-Host 'RESULTADO: FALLO' -ForegroundColor Red
    exit 1
}
Write-Host 'RESULTADO: OK'
exit 0
