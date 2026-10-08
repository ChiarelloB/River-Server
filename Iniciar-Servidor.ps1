# River Server - inicia o servidor BeamMP com o RiverLife (na primeira vez, configura antes).
param([ValidateSet('', 'west_coast_usa', 'river_highway')][string]$Mapa = '')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$server = Join-Path $root 'Servidor'
$settingsPath = Join-Path $server 'servidor.json'
$exe = Join-Path $server 'BeamMP-Server.exe'

$running = @(Get-Process -Name 'BeamMP-Server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
if ($running.Count) { Write-Host 'O River Server já está rodando.' -ForegroundColor Yellow; exit 0 }

$cfg = [IO.File]::ReadAllText((Join-Path $root 'opcionais.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$client = Join-Path $server 'Resources\Client'
$statePath = Join-Path $server 'configurado.txt'
$state = @{}
if (Test-Path -LiteralPath $statePath) {
  foreach ($line in [IO.File]::ReadAllLines($statePath)) { $k, $v = $line -split '=', 2; if ($null -ne $v) { $state[$k] = $v } }
}
$semRLS = $state['rls'] -eq 'False'

# What this release hands the players for $map but is missing or outdated here, plus files of older releases.
function Get-Pending($map) {
  $out = @()
  foreach ($o in $cfg.opcionais) {
    $wanted = if ($o.id -eq 'rls') { -not $semRLS } else { @($o.mapas) -contains $map }
    $f = Join-Path $client $o.arquivo
    if ($wanted -and (-not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -ne $o.size)) { $out += $o.nome }
  }
  foreach ($old in @($cfg.obsoletos)) { if ($old -and (Test-Path -LiteralPath (Join-Path $client $old))) { $out += $old } }
  $out
}

# First run, another map, or a new release extracted over this folder: the setup downloads what is missing.
$configured = (Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $statePath)
$current = if (Test-Path -LiteralPath $settingsPath) { ([IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json).map } else { '' }
if (-not $configured) {
  & (Join-Path $root 'Configurar.ps1') -PeloIniciar -Mapa $Mapa
} elseif ($Mapa -and $Mapa -ne $current) {
  & (Join-Path $root 'Configurar.ps1') -PeloIniciar -Mapa $Mapa -Silencioso -SemRLS:$semRLS
} elseif ($state['versao'] -ne '1.1.0' -or @(Get-Pending $current).Count) {
  Write-Host "Atualizando para o River Server 1.1.0..." -ForegroundColor Cyan
  & (Join-Path $root 'Configurar.ps1') -PeloIniciar -Mapa $current -Silencioso -SemRLS:$semRLS
}
$s = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$pending = @(Get-Pending $s.map)
if ($pending.Count) {
  Write-Host ("Faltam arquivos no servidor ({0}): rode Configurar.cmd." -f ($pending -join ', ')) -ForegroundColor Yellow; exit 1
}

$key = [string]$s.authKey
if (-not $key.Trim()) {
  Write-Host 'AVISO: sem AuthKey do BeamMP. O servidor sobe como privado (amigos entram pelo IP).' -ForegroundColor Yellow
  Write-Host '       Para aparecer na lista do BeamMP, crie a chave em https://keymaster.beammp.com e cole em Servidor\servidor.json.' -ForegroundColor Yellow
  $key = 'river-server-sem-chave-privado-000000'
}
$private = if ($s.private -eq $false) { 'false' } else { 'true' }
$toml = @"
# River Server - BeamMP. Gerado por Iniciar-Servidor a partir de servidor.json.
[General]
Port = $([int]$s.port)
AuthKey = "$key"
AllowGuests = true
LogChat = true
Debug = false
IP = "::"
Private = $private
InformationPacket = true
Name = "$(([string]$s.name).Replace('"', "'"))"
Tags = "Roleplay,Career,Modded"
MaxCars = $([int]$s.maxCars)
MaxPlayers = $([int]$s.maxPlayers)
Map = "/levels/$($s.map)/info.json"
Description = "$(([string]$s.description).Replace('"', "'"))"
ResourceFolder = "Resources"

[Misc]
ImScaredOfUpdates = true
UpdateReminderTime = "30d"
"@
[IO.File]::WriteAllText((Join-Path $server 'ServerConfig.toml'), $toml, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host "Iniciando River Server: mapa $($s.map), porta $($s.port), até $($s.maxPlayers) jogadores." -ForegroundColor Green
$ips = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' -and ($_.Name + $_.Description) -notmatch 'vEthernet|Hyper-V|WSL|VirtualBox|VMware' } |
  ForEach-Object { $_.GetIPProperties().UnicastAddresses } | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and -not $_.Address.ToString().StartsWith('169.254.') } | ForEach-Object { $_.Address.ToString() })
foreach ($ip in $ips) { Write-Host "  Endereço para os amigos: ${ip}:$($s.port)" }
Write-Host '  Fora da sua casa: libere a porta no roteador (TCP e UDP) ou usem a mesma VPN (Radmin, Tailscale, ZeroTier).'
Write-Host 'Console do servidor: rl status | rl backup | rl give <nome> <dólares> | admin add <conta BeamMP>'
Start-Process -FilePath $exe -WorkingDirectory $server | Out-Null
