# River Server - inicia o servidor BeamMP com o RiverLife (na primeira vez, configura antes).
param([ValidateSet('', 'west_coast_usa', 'river_highway')][string]$Mapa = '')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$server = Join-Path $root 'Servidor'
$settingsPath = Join-Path $server 'servidor.json'
$exe = Join-Path $server 'BeamMP-Server.exe'

$running = @(Get-Process -Name 'BeamMP-Server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
if ($running.Count) { Write-Host 'O River Server já está rodando.' -ForegroundColor Yellow; exit 0 }

# First run (or another map): the setup downloads what is missing.
$configured = (Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath (Join-Path $server 'configurado.txt'))
$current = if (Test-Path -LiteralPath $settingsPath) { ([IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json).map } else { '' }
if (-not $configured) {
  & (Join-Path $root 'Configurar.ps1') -Mapa $Mapa
} elseif ($Mapa -and $Mapa -ne $current) {
  & (Join-Path $root 'Configurar.ps1') -Mapa $Mapa -Silencioso
}
$s = [IO.File]::ReadAllText($settingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
if ($s.map -eq 'river_highway' -and -not (Test-Path -LiteralPath (Join-Path $server 'Resources\Client\rls_river_highway_public_0.1.zip'))) {
  Write-Host 'O mapa River Highway não está no servidor: rode Configurar.cmd.' -ForegroundColor Yellow; exit 1
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
