param(
  [int]$Port = 8080,
  [ValidateSet("Local", "Lan")]
  [string]$Mode = "Local",
  [string]$Username = "cuc",
  [string]$Password = "ecdav",
  [switch]$DefaultAuth,
  [switch]$AskAuth,
  [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$Root = [System.IO.Path]::GetFullPath((Resolve-Path (Join-Path $PSScriptRoot "..")).Path)
$RootWithSlash = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$UploadRoot = Join-Path $Root "server_uploads"
$MaxRequestBytes = 300 * 1024 * 1024
$MaxStoredUploadBytes = 256000
$IsLanMode = $Mode -ieq "Lan"
$Address = if ($IsLanMode) {
  [System.Net.IPAddress]::Any
} else {
  [System.Net.IPAddress]::Parse("127.0.0.1")
}
$AuthRealm = "HF Media Studio"
$DefaultUsername = "cuc"
$DefaultPassword = "ecdav"

if (-not $AskAuth -and ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrEmpty($Password))) {
  $Username = $DefaultUsername
  $Password = $DefaultPassword
}

if ($AskAuth) {
  Write-Host ""
  Write-Host "Login protection"
  Write-Host "Press Enter without a username to use cuc / ecdav."
  $InputUsername = Read-Host "Username"
  if (-not [string]::IsNullOrWhiteSpace($InputUsername)) {
    $SecurePassword = Read-Host "Password" -AsSecureString
    $PasswordPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
      $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($PasswordPtr)
    } finally {
      [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($PasswordPtr)
    }
    $Username = $InputUsername.Trim()
  } else {
    $Username = $DefaultUsername
    $Password = $DefaultPassword
  }
}

$AuthEnabled = -not [string]::IsNullOrWhiteSpace($Username) -and $null -ne $Password -and $Password.Length -gt 0
$ExpectedAuthHeader = $null
if ($AuthEnabled) {
  $CredentialBytes = [System.Text.Encoding]::UTF8.GetBytes("${Username}:${Password}")
  $ExpectedAuthHeader = "Basic " + [Convert]::ToBase64String($CredentialBytes)
}

function Get-LanUrls {
  param([int]$Port)

  try {
    $HostName = [System.Net.Dns]::GetHostName()
    $Addresses = [System.Net.Dns]::GetHostEntry($HostName).AddressList
    $Addresses |
      Where-Object {
        $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
        -not [System.Net.IPAddress]::IsLoopback($_) -and
        -not $_.IPAddressToString.StartsWith("169.254.")
      } |
      ForEach-Object { "http://$($_.IPAddressToString):$Port/" } |
      Select-Object -Unique
  } catch {
    @()
  }
}

function Find-HeaderEnd {
  param(
    [byte[]]$Bytes,
    [int]$Length
  )

  if ($Length -lt 4) {
    return -1
  }

  for ($i = 0; $i -le ($Length - 4); $i++) {
    if (
      $Bytes[$i] -eq 13 -and
      $Bytes[$i + 1] -eq 10 -and
      $Bytes[$i + 2] -eq 13 -and
      $Bytes[$i + 3] -eq 10
    ) {
      return $i
    }
  }

  return -1
}

function Read-HttpRequest {
  param([System.IO.Stream]$Stream)

  $MaxHeaderBytes = 64 * 1024
  $Buffer = [byte[]]::new(8192)
  $Memory = [System.IO.MemoryStream]::new()
  $HeaderEnd = -1

  while ($HeaderEnd -lt 0) {
    $Read = $Stream.Read($Buffer, 0, $Buffer.Length)
    if ($Read -le 0) {
      break
    }
    $Memory.Write($Buffer, 0, $Read)
    if ($Memory.Length -gt $MaxHeaderBytes) {
      throw "Request headers are too large."
    }
    $Bytes = $Memory.ToArray()
    $HeaderEnd = Find-HeaderEnd -Bytes $Bytes -Length $Bytes.Length
  }

  if ($HeaderEnd -lt 0) {
    throw "Invalid HTTP request."
  }

  $AllBytes = $Memory.ToArray()
  $HeaderLength = $HeaderEnd + 4
  $HeaderText = [System.Text.Encoding]::ASCII.GetString($AllBytes, 0, $HeaderEnd)
  $Lines = $HeaderText -split "`r?`n"
  $RequestLine = $Lines[0]
  $Headers = @{}

  for ($i = 1; $i -lt $Lines.Count; $i++) {
    $Line = $Lines[$i]
    $Colon = $Line.IndexOf(":")
    if ($Colon -le 0) {
      continue
    }
    $Key = $Line.Substring(0, $Colon).Trim().ToLowerInvariant()
    $Value = $Line.Substring($Colon + 1).Trim()
    $Headers[$Key] = $Value
  }

  $ContentLength = 0
  if ($Headers.ContainsKey("content-length")) {
    $ParsedLength = 0
    if ([int]::TryParse($Headers["content-length"], [ref]$ParsedLength)) {
      $ContentLength = $ParsedLength
    }
  }
  if ($ContentLength -gt $MaxRequestBytes) {
    throw "Request body is too large."
  }

  $Body = [byte[]]::new($ContentLength)
  $Available = [Math]::Max(0, $AllBytes.Length - $HeaderLength)
  $Copied = [Math]::Min($Available, $ContentLength)
  if ($Copied -gt 0) {
    [Array]::Copy($AllBytes, $HeaderLength, $Body, 0, $Copied)
  }

  while ($Copied -lt $ContentLength) {
    $Read = $Stream.Read($Body, $Copied, $ContentLength - $Copied)
    if ($Read -le 0) {
      throw "Incomplete request body."
    }
    $Copied += $Read
  }

  $Parts = $RequestLine.Split(" ")
  if ($Parts.Length -lt 2) {
    throw "Bad request line."
  }

  @{
    RequestLine = $RequestLine
    Method = $Parts[0].ToUpperInvariant()
    Target = $Parts[1]
    Headers = $Headers
    Body = $Body
  }
}

function Get-QueryParams {
  param([string]$Target)

  $Result = @{}
  $Question = $Target.IndexOf("?")
  if ($Question -lt 0 -or $Question -eq ($Target.Length - 1)) {
    return $Result
  }

  $QueryString = $Target.Substring($Question + 1)
  foreach ($Pair in $QueryString.Split("&")) {
    if ([string]::IsNullOrWhiteSpace($Pair)) {
      continue
    }
    $Eq = $Pair.IndexOf("=")
    if ($Eq -ge 0) {
      $Key = $Pair.Substring(0, $Eq)
      $Value = $Pair.Substring($Eq + 1)
    } else {
      $Key = $Pair
      $Value = ""
    }
    $Result[[System.Uri]::UnescapeDataString($Key)] = [System.Uri]::UnescapeDataString($Value)
  }

  $Result
}

function Get-SafeUploadFileName {
  param([string]$FileName)

  if ([string]::IsNullOrWhiteSpace($FileName)) {
    $FileName = "upload_$((Get-Date).ToString("yyyyMMdd_HHmmss")).bin"
  }

  $SafeName = [System.IO.Path]::GetFileName($FileName).Trim()
  if ([string]::IsNullOrWhiteSpace($SafeName)) {
    $SafeName = "upload_$((Get-Date).ToString("yyyyMMdd_HHmmss")).bin"
  }

  foreach ($Char in [System.IO.Path]::GetInvalidFileNameChars()) {
    $SafeName = $SafeName.Replace([string]$Char, "_")
  }

  if ($SafeName.Length -gt 140) {
    $Ext = [System.IO.Path]::GetExtension($SafeName)
    $Stem = [System.IO.Path]::GetFileNameWithoutExtension($SafeName)
    $MaxStemLength = [Math]::Max(1, 140 - $Ext.Length)
    $SafeName = $Stem.Substring(0, [Math]::Min($Stem.Length, $MaxStemLength)) + $Ext
  }

  $SafeName
}

function Save-UploadedBlob {
  param(
    [string]$Subdir,
    [string]$FileName,
    [byte[]]$Body
  )

  if ($null -eq $Body -or $Body.Length -eq 0) {
    return @{ ok = $false; error = "Empty upload." }
  }
  if ($Body.Length -gt $MaxStoredUploadBytes) {
    return @{ ok = $false; error = "Upload is larger than 256 kB (256000 bytes)." }
  }
  if ($Subdir -notin @("pics", "voices")) {
    return @{ ok = $false; error = "Unsupported upload directory." }
  }

  $SafeName = Get-SafeUploadFileName -FileName $FileName
  $TargetDir = Join-Path $UploadRoot $Subdir
  [System.IO.Directory]::CreateDirectory($TargetDir) | Out-Null

  $Stem = [System.IO.Path]::GetFileNameWithoutExtension($SafeName)
  $Ext = [System.IO.Path]::GetExtension($SafeName)
  $TargetPath = Join-Path $TargetDir $SafeName
  $Index = 2
  while ([System.IO.File]::Exists($TargetPath)) {
    $Candidate = "$Stem-$Index$Ext"
    $TargetPath = Join-Path $TargetDir $Candidate
    $Index++
  }

  [System.IO.File]::WriteAllBytes($TargetPath, $Body)
  $StoredName = [System.IO.Path]::GetFileName($TargetPath)

  @{
    ok = $true
    filename = $StoredName
    bytes = $Body.Length
    path = "server_uploads/$Subdir/$StoredName"
  }
}

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
    [bool]$IncludeBody = $true,
    [string[]]$ExtraHeaders = @()
  )

  if ($null -eq $Body) {
    $Body = [byte[]]::new(0)
  }

  $HeaderLines = @(
    "HTTP/1.1 $StatusCode $Reason",
    "Content-Type: $ContentType",
    "Content-Length: $($Body.Length)",
    "Cache-Control: no-store",
    "Cross-Origin-Opener-Policy: same-origin",
    "Cross-Origin-Embedder-Policy: require-corp",
    "Cross-Origin-Resource-Policy: same-origin",
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: GET, HEAD, POST, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type, Authorization",
    "Connection: close"
  )
  if ($null -ne $ExtraHeaders -and $ExtraHeaders.Count -gt 0) {
    $HeaderLines += $ExtraHeaders
  }
  $Headers = ($HeaderLines + @("", "")) -join "`r`n"

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

function Send-Json {
  param(
    [System.IO.Stream]$Stream,
    [int]$StatusCode,
    [string]$Reason,
    [object]$Data,
    [bool]$IncludeBody = $true
  )

  $Json = $Data | ConvertTo-Json -Depth 6 -Compress
  $Body = [System.Text.Encoding]::UTF8.GetBytes($Json)
  Send-Response -Stream $Stream -StatusCode $StatusCode -Reason $Reason -Body $Body -ContentType "application/json; charset=utf-8" -IncludeBody $IncludeBody
}

function Test-Authorized {
  param([hashtable]$Headers)

  if (-not $AuthEnabled) {
    return $true
  }
  if (-not $Headers.ContainsKey("authorization")) {
    return $false
  }

  $Headers["authorization"] -eq $ExpectedAuthHeader
}

function Send-AuthRequired {
  param(
    [System.IO.Stream]$Stream,
    [bool]$IncludeBody = $true
  )

  $Body = [System.Text.Encoding]::UTF8.GetBytes("Login required")
  Send-Response `
    -Stream $Stream `
    -StatusCode 401 `
    -Reason "Unauthorized" `
    -Body $Body `
    -ContentType "text/plain; charset=utf-8" `
    -IncludeBody $IncludeBody `
    -ExtraHeaders @("WWW-Authenticate: Basic realm=`"$AuthRealm`", charset=`"UTF-8`"")
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

$LocalUrl = "http://127.0.0.1:$Port/"
$LanUrls = if ($IsLanMode) { @(Get-LanUrls -Port $Port) } else { @() }

Write-Host ""
Write-Host "HF Media Studio local server"
Write-Host "Root: $Root"
Write-Host "Mode: $(if ($IsLanMode) { "LAN (same-network devices)" } else { "Local (this computer only)" })"
Write-Host "Login: $(if ($AuthEnabled) { "enabled (username: $Username)" } else { "disabled" })"
if ($Port -ne $RequestedPort) {
  Write-Host "Port $RequestedPort is busy; using port $Port instead."
}
Write-Host "Local URL: $LocalUrl"
if ($IsLanMode) {
  if ($LanUrls.Count -gt 0) {
    Write-Host "LAN URLs:"
    foreach ($LanUrl in $LanUrls) {
      Write-Host "  $LanUrl"
    }
  } else {
    Write-Host "LAN URL: no non-loopback IPv4 address was detected."
  }
  Write-Host "Allow this port in Windows Firewall if other devices cannot connect."
  Write-Host "Camera and microphone features may require HTTPS on remote devices."
}
Write-Host "Press Ctrl+C to stop."
Write-Host ""

if (-not $NoBrowser) {
  Start-Process $LocalUrl
}

try {
  while ($true) {
    $Client = $Listener.AcceptTcpClient()
    $Client.ReceiveTimeout = 300000
    $Client.SendTimeout = 300000

    try {
      $Stream = $Client.GetStream()
      $Request = Read-HttpRequest -Stream $Stream

      if ([string]::IsNullOrWhiteSpace($Request.RequestLine)) {
        continue
      }

      $Method = $Request.Method
      $RequestTarget = $Request.Target
      $RequestPath = $RequestTarget.Split("?")[0]
      $IncludeBody = $Method -ne "HEAD"

      if ($Method -eq "OPTIONS") {
        Send-Text -Stream $Stream -StatusCode 204 -Reason "No Content" -Text "" -IncludeBody $false
        continue
      }

      if (-not (Test-Authorized -Headers $Request.Headers)) {
        Send-AuthRequired -Stream $Stream -IncludeBody $IncludeBody
        Write-Host "$Method $RequestPath -> 401"
        continue
      }

      if ($RequestPath -eq "/api/upload") {
        if ($Method -ne "POST") {
          Send-Text -Stream $Stream -StatusCode 405 -Reason "Method Not Allowed" -Text "Method Not Allowed" -IncludeBody $IncludeBody
          continue
        }

        $Query = Get-QueryParams -Target $RequestTarget
        $Result = Save-UploadedBlob -Subdir $Query["subdir"] -FileName $Query["filename"] -Body $Request.Body
        if ($Result.ok) {
          Send-Json -Stream $Stream -StatusCode 200 -Reason "OK" -Data $Result -IncludeBody $IncludeBody
          Write-Host "$Method $RequestPath -> saved $($Result.path) ($($Result.bytes) bytes)"
        } else {
          Send-Json -Stream $Stream -StatusCode 400 -Reason "Bad Request" -Data $Result -IncludeBody $IncludeBody
        }
        continue
      }

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
