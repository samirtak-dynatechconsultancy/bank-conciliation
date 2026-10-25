# Builds the portable client package: dist\ReconVerify\ + dist\ReconVerify.zip
# Contains the built app (Next.js standalone), a portable node.exe, start.bat, diagnose.bat, .env.example, README.txt.
# Never copies .env / .env.local.
#   powershell -ExecutionPolicy Bypass -File packaging\build-package.ps1
#   optional: -NodeExe "C:\path\to\node.exe"  (default: the node.exe on PATH; must be Node 20.6+ for --env-file)
param([string]$NodeExe = (Get-Command node).Source)

$ErrorActionPreference = "Stop"
$app  = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $app "dist"
$out  = Join-Path $dist "ReconVerify"
$buildDir = ".next-package"          # separate from .next so a running `npm run dev` keeps working

Set-Location $app
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
if (Test-Path "$dist\ReconVerify.zip") { Remove-Item "$dist\ReconVerify.zip" -Force }

Write-Host "1/4 Building the app ..."
$env:NEXT_DIST_DIR = $buildDir
npm run build
if ($LASTEXITCODE -ne 0) { throw "npm run build failed" }
Remove-Item Env:NEXT_DIST_DIR

Write-Host "2/4 Copying the standalone server ..."
Copy-Item "$buildDir\standalone" $out -Recurse
Copy-Item "$buildDir\static" "$out\$buildDir\static" -Recurse
if (Test-Path "public") { Copy-Item "public" "$out\public" -Recurse }
# never ship secrets that the build may have traced
Get-ChildItem $out -Force -Filter ".env*" | Where-Object Name -ne ".env.example" | Remove-Item -Force

Write-Host "3/4 Adding node.exe, launchers and docs ..."
Copy-Item $NodeExe "$out\node.exe"
Copy-Item "packaging\start.bat", "packaging\diagnose.bat", "packaging\README.txt" $out
Copy-Item ".env.example" "$out\.env.example"
New-Item -ItemType Directory "$out\scripts" -Force | Out-Null
Copy-Item "scripts\diagnose.mjs" "$out\scripts\diagnose.mjs"

Write-Host "4/4 Zipping ..."
Compress-Archive -Path "$out\*" -DestinationPath "$dist\ReconVerify.zip"
$size = "{0:N1} MB" -f ((Get-Item "$dist\ReconVerify.zip").Length / 1MB)
Write-Host "Done: $dist\ReconVerify.zip ($size)"
