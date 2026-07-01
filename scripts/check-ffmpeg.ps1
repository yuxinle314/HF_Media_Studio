param()

$ErrorActionPreference = "Stop"

$Root = [System.IO.Path]::GetFullPath((Resolve-Path (Join-Path $PSScriptRoot "..")).Path)

function Find-Ffmpeg {
  if (-not [string]::IsNullOrWhiteSpace($env:FFMPEG_PATH) -and [System.IO.File]::Exists($env:FFMPEG_PATH)) {
    return $env:FFMPEG_PATH
  }

  $LocalCandidates = @(
    (Join-Path $Root "tools\ffmpeg.exe"),
    (Join-Path $Root "tools\ffmpeg\bin\ffmpeg.exe")
  )
  foreach ($Candidate in $LocalCandidates) {
    if ([System.IO.File]::Exists($Candidate)) {
      return $Candidate
    }
  }

  $ToolsDir = Join-Path $Root "tools"
  if ([System.IO.Directory]::Exists($ToolsDir)) {
    $Extracted = Get-ChildItem -LiteralPath $ToolsDir -Recurse -Filter ffmpeg.exe -File -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($Extracted) {
      return $Extracted.FullName
    }
  }

  $Command = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if ($Command) {
    return $Command.Source
  }

  return $null
}

$FfmpegPath = Find-Ffmpeg
if ($FfmpegPath) {
  Write-Host "ffmpeg found: $FfmpegPath"
  $Encoders = & $FfmpegPath -hide_banner -encoders 2>&1 | Out-String
  if ($Encoders -match "\blibx265\b") {
    Write-Host "Video encoder found: libx265 (H.265/HEVC)"
    exit 0
  }
  if ($Encoders -match "\blibx264\b") {
    Write-Host "Video encoder found: libx264 (H.264/AVC fallback)"
    exit 0
  }

  Write-Host ""
  Write-Host "ffmpeg.exe was found, but neither libx265 nor libx264 was found."
  Write-Host "Video transcoding needs a Windows ffmpeg build with H.265 or H.264 encoding support."
  Write-Host ""
  exit 1
}

Write-Host ""
Write-Host "ffmpeg.exe was not found. Video transcoding will be unavailable."
Write-Host ""
Write-Host "Supported setup options:"
Write-Host "  1. Put ffmpeg.exe at:"
Write-Host "     $Root\tools\ffmpeg.exe"
Write-Host ""
Write-Host "  2. Or extract a Windows ffmpeg build under:"
Write-Host "     $Root\tools\"
Write-Host "     The script will search tools\...\ffmpeg.exe automatically."
Write-Host ""
Write-Host "  3. Or install ffmpeg to PATH, for example:"
Write-Host "     winget install --id Gyan.FFmpeg -e"
Write-Host ""
Write-Host "  4. Or set FFMPEG_PATH to the full path of ffmpeg.exe."
Write-Host ""
exit 1
