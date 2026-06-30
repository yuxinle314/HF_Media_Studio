param(
  [int]$Port = 8080,
  [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$Root = [System.IO.Path]::GetFullPath((Resolve-Path (Join-Path $PSScriptRoot "..")).Path)
$RootWithSlash = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$Address = [System.Net.IPAddress]::Parse("127.0.0.1")

function Get-ContentType {
  param([string]$Path)

  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { "text/html; charset=utf-8"; break }
    ".htm" { "text/html; charset=utf-8"; break }
    ".js" { "text/javascript; charset=utf-8"; break }
    ".mjs" { "text/javascript; charset=utf-8"; break }
    ".css" { "text/css; charset=utf-8"; break }
    ".svg" { "image/svg+xml"; break }
    ".json" { "application/json; charset=utf-8"; break }
    ".webmanifest" { "application/manifest+json; charset=utf-8"; break }
    ".wasm" { "application/wasm"; break }
    ".png" { "image/png"; break }
    ".jpg" { "image/jpeg"; break }
    ".jpeg" { "image/jpeg"; break }
    ".webp" { "image/webp"; break }
    ".mp3" { "audio/mpeg"; break }
    ".wav" { "audio/wav"; break }
    ".c2" { "application/octet-stream"; break }
    default { "application/octet-stream" }
  }
}

function Send-Response {
  param(
    [System.IO.Stream]$Stream,
    [int]$StatusCode,
    [string]$Reason,
    [byte[]]$Body,
    [string]$ContentType,
    [bool]$IncludeBody = $true
  )

  if ($null -eq $Body) {
    $Body = [byte[]]::new(0)
  }

  $Headers = @(
    "HTTP/1.1 $StatusCode $Reason",
    "Content-Type: $ContentType",
    "Content-Length: $($Body.Length)",
    "Cache-Control: no-store",
    "Cross-Origin-Opener-Policy: same-origin",
    "Cross-Origin-Embedder-Policy: require-corp",
    "Cross-Origin-Resource-Policy: same-origin",
    "Access-Control-Allow-Origin: *",
    "Connection: close",
    "",
    ""
  ) -join "`r`n"

  $HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($Headers)
  $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
  if ($IncludeBody -and $Body.Length -gt 0) {
    $Stream.Write($Body, 0, $Body.Length)
  }
}

function Send-Text {
  param(
    [System.IO.Stream]$Stream,
    [int]$StatusCode,
    [string]$Reason,
    [string]$Text,
    [bool]$IncludeBody = $true
  )

  $Body = [System.Text.Encoding]::UTF8.GetBytes($Text)
  Send-Response -Stream $Stream -StatusCode $StatusCode -Reason $Reason -Body $Body -ContentType "text/plain; charset=utf-8" -IncludeBody $IncludeBody
}

$RequestedPort = $Port
$Listener = $null

for ($CandidatePort = $RequestedPort; $CandidatePort -le ($RequestedPort + 20); $CandidatePort++) {
  $CandidateListener = [System.Net.Sockets.TcpListener]::new($Address, $CandidatePort)
  try {
    $CandidateListener.Start()
    $Listener = $CandidateListener
    $Port = $CandidatePort
    break
  } catch {
    try {
      $CandidateListener.Stop()
    } catch {
    }
  }
}

if ($null -eq $Listener) {
  Write-Host "No available local port was found from $RequestedPort to $($RequestedPort + 20)."
  exit 1
}

$Url = "http://127.0.0.1:$Port/"

Write-Host ""
Write-Host "HF Media Studio local server"
Write-Host "Root: $Root"
if ($Port -ne $RequestedPort) {
  Write-Host "Port $RequestedPort is busy; using port $Port instead."
}
Write-Host "URL : $Url"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

if (-not $NoBrowser) {
  Start-Process $Url
}

try {
  while ($true) {
    $Client = $Listener.AcceptTcpClient()
    $Client.ReceiveTimeout = 5000
    $Client.SendTimeout = 5000

    try {
      $Stream = $Client.GetStream()
      $Reader = [System.IO.StreamReader]::new($Stream, [System.Text.Encoding]::ASCII, $false, 8192, $true)
      $RequestLine = $Reader.ReadLine()

      if ([string]::IsNullOrWhiteSpace($RequestLine)) {
        continue
      }

      do {
        $Line = $Reader.ReadLine()
      } while ($null -ne $Line -and $Line.Length -gt 0)

      $Parts = $RequestLine.Split(" ")
      if ($Parts.Length -lt 2) {
        Send-Text -Stream $Stream -StatusCode 400 -Reason "Bad Request" -Text "Bad Request"
        continue
      }

      $Method = $Parts[0].ToUpperInvariant()
      $RequestPath = $Parts[1].Split("?")[0]
      $IncludeBody = $Method -ne "HEAD"

      if ($Method -ne "GET" -and $Method -ne "HEAD") {
        Send-Text -Stream $Stream -StatusCode 405 -Reason "Method Not Allowed" -Text "Method Not Allowed" -IncludeBody $IncludeBody
        continue
      }

      $DecodedPath = [System.Uri]::UnescapeDataString($RequestPath)
      if ($DecodedPath -eq "/") {
        $DecodedPath = "/index.html"
      }

      $RelativePath = $DecodedPath.TrimStart("/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
      $FullPath = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))

      if (-not $FullPath.StartsWith($RootWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Text -Stream $Stream -StatusCode 403 -Reason "Forbidden" -Text "Forbidden" -IncludeBody $IncludeBody
        continue
      }

      if ([System.IO.Directory]::Exists($FullPath)) {
        $FullPath = Join-Path $FullPath "index.html"
      }

      if (-not [System.IO.File]::Exists($FullPath)) {
        Send-Text -Stream $Stream -StatusCode 404 -Reason "Not Found" -Text "Not Found" -IncludeBody $IncludeBody
        continue
      }

      $Body = [System.IO.File]::ReadAllBytes($FullPath)
      $ContentType = Get-ContentType -Path $FullPath
      Send-Response -Stream $Stream -StatusCode 200 -Reason "OK" -Body $Body -ContentType $ContentType -IncludeBody $IncludeBody
      Write-Host "$Method $RequestPath -> 200"
    } catch {
      try {
        Send-Text -Stream $Stream -StatusCode 500 -Reason "Internal Server Error" -Text "Internal Server Error"
      } catch {
      }
    } finally {
      $Client.Close()
    }
  }
} finally {
  $Listener.Stop()
}
