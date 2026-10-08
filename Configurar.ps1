# River Server - configuração: escolhe o mapa, baixa o BeamMP-Server oficial e os opcionais.
# Uso: Configurar.cmd   (pergunta tudo)
#      Configurar.ps1 -Mapa river_highway|west_coast_usa [-SemRLS] [-Silencioso]
param(
  [ValidateSet('', 'west_coast_usa', 'river_highway')][string]$Mapa = '',
  [switch]$SemRLS,
  [switch]$Silencioso
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$root = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$server = Join-Path $root 'Servidor'
$client = Join-Path $server 'Resources\Client'
$parked = Join-Path $server 'opcionais-desligados'
$cfg = [IO.File]::ReadAllText((Join-Path $root 'opcionais.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$settingsPath = Join-Path $server 'servidor.json'
if (-not (Test-Path -LiteralPath $settingsPath)) { Copy-Item -LiteralPath (Join-Path $server 'servidor.example.json') -Destination $settingsPath }
$s = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json

function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false)) }

# Downloads $url to $dest and checks size and SHA-256; a file already in place is kept.
function Get-Checked($url, $dest, $sha, $size, $label) {
  if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -eq $size) {
    if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $sha.ToUpperInvariant()) { Write-Host "  $label - já está aqui."; return }
  }
  $part = "$dest.part"
  if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
  Write-Host ("  Baixando {0} ({1:N0} MB)..." -f $label, ($size / 1MB))
  try {
    Start-BitsTransfer -Source $url -Destination $part -DisplayName $label -Description 'River Server' -ErrorAction Stop
  } catch {
    Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing
  }
  if ((Get-Item -LiteralPath $part).Length -ne $size -or (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $sha.ToUpperInvariant()) {
    Remove-Item -LiteralPath $part -Force
    throw "$label veio corrompido (tamanho/hash diferente). Rode o Configurar de novo."
  }
  Move-Item -LiteralPath $part -Destination $dest -Force
}

Write-Host "River Server 1.0.0 - configuração" -ForegroundColor Cyan
$running = @(Get-Process -Name 'BeamMP-Server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq (Join-Path $server 'BeamMP-Server.exe') })
if ($running.Count) { Write-Host 'Pare o servidor antes de configurar (Parar-Servidor.cmd).' -ForegroundColor Yellow; exit 1 }

if (-not $Silencioso) {
  if (-not $Mapa) {
    Write-Host ''
    Write-Host 'Mapa do servidor:'
    Write-Host '  1) West Coast USA  - vem com o BeamNG, nada para baixar'
    Write-Host '  2) River Highway   - baixa o mapa (1,7 GB) e as correções riverpack'
    $c = Read-Host "Escolha [1/2] (Enter = $($s.map))"
    if ($c -eq '1') { $Mapa = 'west_coast_usa' } elseif ($c -eq '2') { $Mapa = 'river_highway' }
  }
  if (-not $SemRLS) {
    Write-Host ''
    $q = Read-Host 'Entregar o RLS Career Overhaul aos jogadores? É ele que dá a carreira onde o RiverLife roda (S/n)'
    if ($q -match '^[nN]') { $SemRLS = $true }
  }
}
if (-not $Mapa) { $Mapa = [string]$s.map }
if ($Mapa -notin @('west_coast_usa', 'river_highway')) { $Mapa = 'west_coast_usa' }

Write-Host ''
Write-Host 'BeamMP Server (oficial):'
$b = $cfg.beammpServer
Get-Checked $b.url (Join-Path $server 'BeamMP-Server.exe') $b.sha256 $b.size ("BeamMP-Server " + $b.version)

Write-Host 'Mods entregues aos jogadores ao entrar:'
New-Item -ItemType Directory -Path $client -Force | Out-Null
foreach ($o in $cfg.opcionais) {
  $wanted = if ($o.id -eq 'rls') { -not $SemRLS } else { @($o.mapas) -contains $Mapa }
  $dest = Join-Path $client $o.arquivo
  if ($wanted) {
    $parkedFile = Join-Path $parked $o.arquivo
    if (-not (Test-Path -LiteralPath $dest) -and (Test-Path -LiteralPath $parkedFile)) { Move-Item -LiteralPath $parkedFile -Destination $dest }
    Get-Checked $o.url $dest $o.sha256 $o.size $o.nome
  } elseif (Test-Path -LiteralPath $dest) {
    # Off: kept aside (not deleted), so turning it back on does not download again.
    New-Item -ItemType Directory -Path $parked -Force | Out-Null
    Move-Item -LiteralPath $dest -Destination (Join-Path $parked $o.arquivo) -Force
    Write-Host "  $($o.nome) - desligado (guardado em Servidor\opcionais-desligados)."
  }
}

$s.map = $Mapa
Write-Utf8 $settingsPath ($s | ConvertTo-Json)
$pluginCfg = Join-Path $server 'Resources\Server\RiverLife\config.json'
$p = [IO.File]::ReadAllText($pluginCfg, [Text.Encoding]::UTF8) | ConvertFrom-Json
$p.map = $Mapa
Write-Utf8 $pluginCfg ($p | ConvertTo-Json)
Write-Utf8 (Join-Path $server 'configurado.txt') ("mapa=$Mapa`nrls=" + (-not $SemRLS) + "`n")

Write-Host ''
Write-Host "Pronto: mapa $Mapa$(if ($SemRLS) { ', sem RLS (os jogadores precisam tê-lo)' })." -ForegroundColor Green
Write-Host 'Agora rode Iniciar-Servidor.cmd.'
