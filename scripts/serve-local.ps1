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
$MaxVideoInputBytes = 300 * 1024 * 1024
$TargetVideoBytes = 256000
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
  if ($Subdir -notin @("pics", "voices", "videos")) {
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

function Get-FfmpegPath {
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

function Invoke-Ffmpeg {
  param(
    [string]$FfmpegPath,
    [string[]]$Arguments
  )

  $Output = & $FfmpegPath @Arguments 2>&1
  @{
    exitCode = $LASTEXITCODE
    output = ($Output | Out-String).Trim()
  }
}

function Test-FfmpegEncoder {
  param(
    [string]$FfmpegPath,
    [string]$Encoder
  )

  $Output = & $FfmpegPath -hide_banner -encoders 2>&1
  return (($Output | Out-String) -match "\b$([regex]::Escape($Encoder))\b")
}

function Get-FfmpegVideoCodec {
  param([string]$FfmpegPath)

  if (Test-FfmpegEncoder -FfmpegPath $FfmpegPath -Encoder "libx265") {
    return @{
      encoder = "libx265"
      name = "H.265/HEVC"
      extraArgs = @("-x265-params", "log-level=error", "-tag:v", "hvc1")
    }
  }

  if (Test-FfmpegEncoder -FfmpegPath $FfmpegPath -Encoder "libx264") {
    return @{
      encoder = "libx264"
      name = "H.264/AVC"
      extraArgs = @()
    }
  }

  return $null
}

function Convert-UploadedVideo {
  param(
    [hashtable]$Query,
    [byte[]]$Body
  )

  if ($null -eq $Body -or $Body.Length -eq 0) {
    return @{ ok = $false; error = "Empty video upload." }
  }
  if ($Body.Length -gt $MaxVideoInputBytes) {
    return @{ ok = $false; error = "Video upload is larger than 300 MB." }
  }

  $FfmpegPath = Get-FfmpegPath
  if ([string]::IsNullOrWhiteSpace($FfmpegPath)) {
    return @{
      ok = $false
      error = "Missing ffmpeg.exe on the server computer. Put it at tools\ffmpeg.exe, extract a ffmpeg build under tools\, add it to PATH, or set FFMPEG_PATH."
    }
  }
  $VideoCodec = Get-FfmpegVideoCodec -FfmpegPath $FfmpegPath
  if ($null -eq $VideoCodec) {
    return @{
      ok = $false
      error = "ffmpeg.exe does not include libx265 or libx264. Please use a Windows ffmpeg build with H.265 or H.264 encoding support."
    }
  }

  $Fps = 3
  if ($Query.ContainsKey("fps")) {
    [void][int]::TryParse($Query["fps"], [ref]$Fps)
  }
  $Fps = [Math]::Min(5, [Math]::Max(1, $Fps))

  $Seconds = 20
  if ($Query.ContainsKey("seconds")) {
    [void][int]::TryParse($Query["seconds"], [ref]$Seconds)
  }
  $Seconds = [Math]::Min(20, [Math]::Max(1, $Seconds))

  $MaxWidth = 640
  if ($Query.ContainsKey("maxw")) {
    [void][int]::TryParse($Query["maxw"], [ref]$MaxWidth)
  }
  $MaxWidth = [Math]::Min(640, [Math]::Max(160, $MaxWidth))

  $MaxHeight = 480
  if ($Query.ContainsKey("maxh")) {
    [void][int]::TryParse($Query["maxh"], [ref]$MaxHeight)
  }
  $MaxHeight = [Math]::Min(480, [Math]::Max(120, $MaxHeight))

  $TargetKb = [int][Math]::Ceiling($TargetVideoBytes / 1000)
  if ($Query.ContainsKey("targetkb")) {
    [void][int]::TryParse($Query["targetkb"], [ref]$TargetKb)
  }
  $TargetBytes = [int64]([Math]::Min(256, [Math]::Max(20, $TargetKb)) * 1000)

  $OriginalName = if ($Query.ContainsKey("filename")) { $Query["filename"] } else { "video.mp4" }
  $SafeInputName = Get-SafeUploadFileName -FileName $OriginalName
  $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($SafeInputName)
  if ([string]::IsNullOrWhiteSpace($BaseName)) {
    $BaseName = "video"
  }

  $StampText = (Get-Date).ToString("yyyyMMdd_HHmmss")
  $InputDir = Join-Path $UploadRoot "video_inputs"
  $OutputDir = Join-Path $UploadRoot "videos"
  [System.IO.Directory]::CreateDirectory($InputDir) | Out-Null
  [System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null

  $InputPath = Join-Path $InputDir "$StampText`_$SafeInputName"
  $OutputName = "$BaseName`_${Seconds}s_${Fps}fps_$StampText.mp4"
  $OutputName = Get-SafeUploadFileName -FileName $OutputName
  $OutputPath = Join-Path $OutputDir $OutputName

  [System.IO.File]::WriteAllBytes($InputPath, $Body)

  $ScaleCandidates = @()
  foreach ($Size in @(
    @{ Width = $MaxWidth; Height = $MaxHeight },
    @{ Width = [Math]::Min($MaxWidth, 480); Height = [Math]::Min($MaxHeight, 360) },
    @{ Width = [Math]::Min($MaxWidth, 320); Height = [Math]::Min($MaxHeight, 240) },
    @{ Width = [Math]::Min($MaxWidth, 240); Height = [Math]::Min($MaxHeight, 180) },
    @{ Width = [Math]::Min($MaxWidth, 160); Height = [Math]::Min($MaxHeight, 120) }
  )) {
    if ($Size.Width -lt 160 -or $Size.Height -lt 120) {
      continue
    }
    $Duplicate = $false
    foreach ($Existing in $ScaleCandidates) {
      if ($Existing.Width -eq $Size.Width -and $Existing.Height -eq $Size.Height) {
        $Duplicate = $true
        break
      }
    }
    if (-not $Duplicate) {
      $ScaleCandidates += $Size
    }
  }

  $DurationTargetKbps = [Math]::Max(48, [int][Math]::Floor(($TargetBytes * 8 / 1000 / $Seconds) * 0.82))
  $Bitrates = @()
  foreach ($Candidate in @(650, 450, $DurationTargetKbps, 320, 240, 180, 120, 80, 48)) {
    $Value = [Math]::Min(650, [Math]::Max(32, [int]$Candidate))
    if ($Bitrates -notcontains $Value) {
      $Bitrates += $Value
    }
  }
  $Bitrates = $Bitrates | Sort-Object -Descending

  $BestOutput = $null
  $BestBytes = [int64]::MaxValue
  $BestWidth = $MaxWidth
  $BestHeight = $MaxHeight
  $BestBitrate = 0
  $LastError = ""

  try {
    $FoundUnderTarget = $false

    foreach ($Scale in $ScaleCandidates) {
      $ScaleFilter = "fps={0},scale={1}:{2}:force_original_aspect_ratio=decrease:force_divisible_by=2" -f $Fps, $Scale.Width, $Scale.Height

      foreach ($Bitrate in $Bitrates) {
        if ([System.IO.File]::Exists($OutputPath)) {
          [System.IO.File]::Delete($OutputPath)
        }

        $Args = @(
          "-y",
          "-hide_banner",
          "-loglevel", "error",
          "-t", [string]$Seconds,
          "-i", $InputPath,
          "-vf", $ScaleFilter,
          "-an",
          "-c:v", $VideoCodec.encoder,
          "-preset", "veryfast",
          "-b:v", "${Bitrate}k",
          "-maxrate", "${Bitrate}k",
          "-bufsize", "$($Bitrate * 2)k",
          "-pix_fmt", "yuv420p"
        )
        $Args += $VideoCodec.extraArgs
        $Args += @("-movflags", "+faststart", $OutputPath)

        $Run = Invoke-Ffmpeg -FfmpegPath $FfmpegPath -Arguments $Args
        if ($Run.exitCode -ne 0 -or -not [System.IO.File]::Exists($OutputPath)) {
          $LastError = $Run.output
          continue
        }

        $Bytes = ([System.IO.FileInfo]$OutputPath).Length
        if ($Bytes -lt $BestBytes) {
          $BestBytes = $Bytes
          $BestOutput = [System.IO.File]::ReadAllBytes($OutputPath)
          $BestWidth = $Scale.Width
          $BestHeight = $Scale.Height
          $BestBitrate = $Bitrate
        }
        if ($Bytes -le $TargetBytes) {
          $BestOutput = [System.IO.File]::ReadAllBytes($OutputPath)
          $BestBytes = $Bytes
          $BestWidth = $Scale.Width
          $BestHeight = $Scale.Height
          $BestBitrate = $Bitrate
          $FoundUnderTarget = $true
          break
        }
      }

      if ($FoundUnderTarget) {
        break
      }
    }

    if ($null -eq $BestOutput) {
      if ([string]::IsNullOrWhiteSpace($LastError)) {
        $LastError = "ffmpeg failed to create an output file."
      }
      return @{ ok = $false; error = $LastError }
    }

    [System.IO.File]::WriteAllBytes($OutputPath, $BestOutput)
    $StoredBytes = ([System.IO.FileInfo]$OutputPath).Length
    if ($StoredBytes -gt $TargetBytes) {
      try { [System.IO.File]::Delete($OutputPath) } catch {}
      return @{
        ok = $false
        error = "Could not compress the video under 256 kB (256000 bytes). Try 320x240, 1 FPS, or a shorter source segment."
      }
    }

    $EncodedOutputName = [System.Uri]::EscapeDataString($OutputName)

    return @{
      ok = $true
      filename = $OutputName
      bytes = $StoredBytes
      inputBytes = $Body.Length
      fps = $Fps
      seconds = $Seconds
      maxWidth = $BestWidth
      maxHeight = $BestHeight
      codec = $VideoCodec.name
      bitrateKbps = $BestBitrate
      targetBytes = $TargetBytes
      underTarget = $StoredBytes -le $TargetBytes
      path = "server_uploads/videos/$OutputName"
      url = "/server_uploads/videos/$EncodedOutputName"
      downloadUrl = "/api/video/download?file=$EncodedOutputName"
    }
  } finally {
    try { [System.IO.File]::Delete($InputPath) } catch {}
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
    ".mp4" { "video/mp4"; break }
    ".m4v" { "video/mp4"; break }
    ".mov" { "video/quicktime"; break }
    ".webm" { "video/webm"; break }
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

function Get-AsciiFileName {
  param([string]$FileName)

  $Builder = [System.Text.StringBuilder]::new()
  foreach ($Char in $FileName.ToCharArray()) {
    $Code = [int][char]$Char
    if ($Code -ge 32 -and $Code -le 126 -and $Char -ne '"' -and $Char -ne '\' -and $Char -ne ";") {
      [void]$Builder.Append($Char)
    } else {
      [void]$Builder.Append("_")
    }
  }

  $AsciiName = $Builder.ToString().Trim("_")
  if ([string]::IsNullOrWhiteSpace($AsciiName)) {
    return "compressed.mp4"
  }
  $AsciiName
}

function Send-VideoDownload {
  param(
    [System.IO.Stream]$Stream,
    [string]$FileName,
    [bool]$IncludeBody = $true
  )

  if ([string]::IsNullOrWhiteSpace($FileName)) {
    Send-Text -Stream $Stream -StatusCode 400 -Reason "Bad Request" -Text "Missing video file name." -IncludeBody $IncludeBody
    return
  }

  $SafeName = Get-SafeUploadFileName -FileName $FileName
  if ([System.IO.Path]::GetExtension($SafeName).ToLowerInvariant() -ne ".mp4") {
    Send-Text -Stream $Stream -StatusCode 400 -Reason "Bad Request" -Text "Only MP4 video downloads are supported." -IncludeBody $IncludeBody
    return
  }

  $VideoDir = [System.IO.Path]::GetFullPath((Join-Path $UploadRoot "videos"))
  $VideoDirWithSlash = $VideoDir.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  $FullPath = [System.IO.Path]::GetFullPath((Join-Path $VideoDir $SafeName))

  if (-not $FullPath.StartsWith($VideoDirWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
    Send-Text -Stream $Stream -StatusCode 403 -Reason "Forbidden" -Text "Forbidden" -IncludeBody $IncludeBody
    return
  }
  if (-not [System.IO.File]::Exists($FullPath)) {
    Send-Text -Stream $Stream -StatusCode 404 -Reason "Not Found" -Text "Video not found." -IncludeBody $IncludeBody
    return
  }

  $Body = [System.IO.File]::ReadAllBytes($FullPath)
  $EncodedName = [System.Uri]::EscapeDataString($SafeName)
  $AsciiName = Get-AsciiFileName -FileName $SafeName
  Send-Response `
    -Stream $Stream `
    -StatusCode 200 `
    -Reason "OK" `
    -Body $Body `
    -ContentType "video/mp4" `
    -IncludeBody $IncludeBody `
    -ExtraHeaders @("Content-Disposition: attachment; filename=`"$AsciiName`"; filename*=UTF-8''$EncodedName")
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

function Test-ExternalNetwork {
  $Targets = @(
    "https://www.baidu.com/favicon.ico",
    "https://www.qq.com/favicon.ico"
  )

  foreach ($Target in $Targets) {
    try {
      $Request = [System.Net.HttpWebRequest]::Create($Target)
      $Request.Method = "GET"
      $Request.Timeout = 1500
      $Request.ReadWriteTimeout = 1500
      $Request.UserAgent = "HF-Media-Studio-Netcheck"
      $Response = $Request.GetResponse()
      $StatusCode = [int]$Response.StatusCode
      $Response.Close()
      if ($StatusCode -ge 200 -and $StatusCode -lt 500) {
        return @{
          ok = $true
          target = $Target
          status = $StatusCode
        }
      }
    } catch {
    }
  }

  @{
    ok = $false
    target = $null
    status = 0
  }
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
  Write-Host "Camera, microphone, and ffmpeg features may require HTTPS on remote devices."
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

      if ($RequestPath -eq "/api/video/transcode") {
        if ($Method -ne "POST") {
          Send-Text -Stream $Stream -StatusCode 405 -Reason "Method Not Allowed" -Text "Method Not Allowed" -IncludeBody $IncludeBody
          continue
        }

        $Query = Get-QueryParams -Target $RequestTarget
        $Result = Convert-UploadedVideo -Query $Query -Body $Request.Body
        if ($Result.ok) {
          Send-Json -Stream $Stream -StatusCode 200 -Reason "OK" -Data $Result -IncludeBody $IncludeBody
          Write-Host "$Method $RequestPath -> transcoded $($Result.path) ($($Result.bytes) bytes)"
        } else {
          Send-Json -Stream $Stream -StatusCode 400 -Reason "Bad Request" -Data $Result -IncludeBody $IncludeBody
        }
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

      if ($RequestPath -eq "/api/netcheck") {
        $Result = Test-ExternalNetwork
        Send-Json -Stream $Stream -StatusCode 200 -Reason "OK" -Data $Result -IncludeBody $IncludeBody
        continue
      }

      if ($RequestPath -eq "/api/video/download") {
        $Query = Get-QueryParams -Target $RequestTarget
        $DownloadFileName = $Query["file"]
        Send-VideoDownload -Stream $Stream -FileName $DownloadFileName -IncludeBody $IncludeBody
        Write-Host "$Method $RequestPath -> download $DownloadFileName"
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
