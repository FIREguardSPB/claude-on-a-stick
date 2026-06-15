# payload/decrypt.ps1 - STICK-SIDE token decryptor (Windows).  [VERIFIED template]
#
# Copied verbatim onto the stick by the builder. Invoked by env.bat:
#     for /f "usebackq delims=" %%T in (`powershell -NoProfile -ExecutionPolicy Bypass ^
#         -File "%~dp0decrypt.ps1" "%~dp0config\oauth.enc"`) do set "CLAUDE_CODE_OAUTH_TOKEN=%%T"
#
# CONTRACT (do not change without re-verifying the round-trip):
#   * Reads  salt[16] || iv[16] || AES-256-CBC(PKCS7) ciphertext  from <path>.
#   * KDF = PBKDF2-HMAC-SHA1, 300000 iters, 32-byte key  (Rfc2898DeriveBytes 3-arg = SHA1).
#   * The password PROMPT and all errors go to STDERR.
#   * The decrypted token is the ONLY thing written to STDOUT, with NO trailing newline,
#     so the caller can capture stdout straight into CLAUDE_CODE_OAUTH_TOKEN.
#   * Exit code 1 on any failure (missing file, wrong password / bad padding).
#
# Self-contained: pure .NET, no openssl, no shared module needed at run time.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string] $Path
)

$ErrorActionPreference = 'Stop'

# Make sure the masked prompt and any diagnostics render correctly and DON'T pollute stdout.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Localized prompt text is baked by the builder; default to English here.
# (Builder may string-replace this line when generating the stick in another language.)
$promptText = 'Stick password'

try {
  if (-not (Test-Path -LiteralPath $Path)) {
    [Console]::Error.WriteLine("decrypt.ps1: file not found: $Path")
    exit 1
  }

  $all = [System.IO.File]::ReadAllBytes($Path)
  if ($all.Length -lt 33) {
    [Console]::Error.WriteLine('decrypt.ps1: oauth.enc is too short / corrupt')
    exit 1
  }

  # Split fixed-size header from ciphertext.
  [byte[]]$salt = $all[0..15]
  [byte[]]$iv   = $all[16..31]
  [byte[]]$ct   = $all[32..($all.Length - 1)]

  # --- password prompt -> STDERR (prompt never touches stdout, which carries only the token) ---
  # On a real interactive console we use Read-Host -AsSecureString for a MASKED prompt.
  # When stdin is redirected (input piped from a launcher / automation), Read-Host -AsSecureString
  # reads nothing on some hosts, so we fall back to a plain redirected-stdin line read.
  [Console]::Error.Write($promptText + ': ')
  if ([Console]::IsInputRedirected) {
    # Non-interactive: take one line from the redirected STDIN (cannot mask a redirected stream).
    $pw = [Console]::In.ReadLine()
    if ($null -eq $pw) { $pw = '' }
    [Console]::Error.WriteLine('')   # tidy newline after the prompt
  } else {
    # Interactive console: masked entry.
    $secure = Read-Host -AsSecureString
    $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
      $pw = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
      [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  }

  # --- derive key: 3-arg Rfc2898DeriveBytes ctor == PBKDF2-HMAC-SHA1 (matches openssl/python/perl) ---
  $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, 300000)
  try   { $key = $kdf.GetBytes(32) }
  finally { $kdf.Dispose() }

  # --- AES-256-CBC / PKCS7 decrypt ---
  $aes = [System.Security.Cryptography.Aes]::Create()
  try {
    $aes.KeySize = 256
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key     = $key
    $aes.IV      = $iv

    $dec = $aes.CreateDecryptor()
    try {
      $ptBytes = $dec.TransformFinalBlock($ct, 0, $ct.Length)
    } finally { $dec.Dispose() }
  } finally {
    $aes.Dispose()
    if ($key) { for ($i = 0; $i -lt $key.Length; $i++) { $key[$i] = 0 } }
  }

  $token = [System.Text.Encoding]::UTF8.GetString($ptBytes)

  # Token -> STDOUT with NO trailing newline. Use the raw stdout stream to avoid Write-Output
  # appending a line ending (which would corrupt the captured token).
  [Console]::Out.Write($token)
  [Console]::Out.Flush()
  exit 0
}
catch {
  # Wrong password manifests as a CryptographicException (bad PKCS7 padding) here.
  [Console]::Error.WriteLine('decrypt.ps1: decryption failed (wrong password or corrupt file).')
  exit 1
}
