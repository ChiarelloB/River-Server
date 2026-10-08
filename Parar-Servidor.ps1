# Encerra somente o River Server iniciado desta pasta.
$root = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$exe = Join-Path $root 'Servidor\BeamMP-Server.exe'
$procs = @(Get-Process -Name 'BeamMP-Server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
if (-not $procs.Count) { Write-Host 'O River Server não está rodando.'; exit 0 }
foreach ($p in $procs) { $p.CloseMainWindow() | Out-Null; if (-not $p.WaitForExit(8000)) { Stop-Process -Id $p.Id } }
Write-Host 'River Server encerrado. Os dados ficam em Servidor\Resources\Server\RiverLife\data.'
